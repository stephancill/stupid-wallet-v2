import { CONFIG } from '../config';
import type { Database } from '../database';
import { badRequest } from '../errors';
import { isNotificationEligible, now } from './util';
import { requireInstallation } from './installations';

export interface ChainStage {
  chainId: string;
  status: 'staged' | 'enabling' | 'active' | 'unsupported' | 'error' | 'operatorDisabled';
  eligibleCount: number;
}

const enrollmentKey = (chainId: string, address: string): string =>
  `${chainId}\u0000${address.toLowerCase()}`;

const splitKey = (key: string): [string, string] => {
  const index = key.indexOf('\u0000');
  return [key.slice(0, index), key.slice(index + 1)];
};

const configuredChainIds = async (db: Database, installationId: string): Promise<string[]> =>
  (
    await db.all('SELECT chain_id FROM installation_chains WHERE installation_id = ?', [
      installationId,
    ])
  ).map((row) => String(row.chain_id));

const qualifiedInstallationsForChain = async (
  db: Database,
  chainId: string,
  at: number,
): Promise<Set<string>> => {
  const rows = await db.all(
    `SELECT id FROM installations
      WHERE EXISTS (
        SELECT 1 FROM installation_chains
        WHERE installation_id = installations.id AND chain_id = ?
      )`,
    [chainId],
  );
  const ids = new Set<string>();
  for (const row of rows) {
    const full = await db.first('SELECT * FROM installations WHERE id = ?', [String(row.id)]);
    if (full && isNotificationEligible(full, at)) ids.add(String(row.id));
  }
  return ids;
};

export const listStages = async (db: Database): Promise<ChainStage[]> =>
  (await db.all('SELECT * FROM webhook_chain_stages ORDER BY chain_id')).map((row) => ({
    chainId: String(row.chain_id),
    status: String(row.status) as ChainStage['status'],
    eligibleCount: Number(row.eligible_installation_count),
  }));

export const activeChainIds = async (db: Database): Promise<string[]> =>
  (await db.all("SELECT chain_id FROM webhook_chain_stages WHERE status = 'active'")).map((row) =>
    String(row.chain_id),
  );

export const isChainActive = async (db: Database, chainId: string): Promise<boolean> => {
  const row = await db.first('SELECT status FROM webhook_chain_stages WHERE chain_id = ?', [
    chainId,
  ]);
  return row?.status === 'active';
};

/** Recompute one installation's effective registration rows from desired sources × active chains. */
export async function recomputeInstallationEffective(
  db: Database,
  installationId: string,
  at: number,
): Promise<void> {
  await requireInstallation(db, installationId);
  const addresses = (
    await db.all('SELECT address FROM installation_enrollments WHERE installation_id = ?', [
      installationId,
    ])
  ).map((row) => String(row.address).toLowerCase());

  const configured = await configuredChainIds(db, installationId);
  const active = new Set(await activeChainIds(db));
  const effectiveChains = configured.filter((chainId) => active.has(chainId));

  const desired = new Set<string>();
  for (const chainId of effectiveChains) {
    for (const address of addresses) {
      desired.add(enrollmentKey(chainId, address));
    }
  }

  const existing = (
    await db.all(
      'SELECT chain_id, address FROM installation_addresses WHERE installation_id = ? AND revoked_at IS NULL',
      [installationId],
    )
  ).map((row) => enrollmentKey(String(row.chain_id), String(row.address)));
  const present = new Set(existing);

  for (const key of present) {
    if (!desired.has(key)) {
      const [chainId, address] = splitKey(key);
      await db.run(
        'UPDATE installation_addresses SET revoked_at = ? WHERE installation_id = ? AND chain_id = ? AND address = ?',
        [at, installationId, chainId, address],
      );
    }
  }
  for (const key of desired) {
    if (!present.has(key)) {
      const [chainId, address] = splitKey(key);
      await db.run(
        `INSERT INTO installation_addresses (installation_id, chain_id, address, source_count, status, created_at)
         VALUES (?, ?, ?, 1, 'active', ?)
         ON CONFLICT (installation_id, chain_id, address)
         DO UPDATE SET revoked_at = NULL, status = 'active'`,
        [installationId, chainId, address, at],
      );
    }
  }
}

/** Recompute effective rows for every installation that configures a chain. */
export const recomputeChainForAll = async (
  db: Database,
  chainId: string,
  at: number,
): Promise<void> => {
  const rows = await db.all('SELECT installation_id FROM installation_chains WHERE chain_id = ?', [
    chainId,
  ]);
  for (const row of rows) {
    await recomputeInstallationEffective(db, String(row.installation_id), at);
  }
  await syncUpstream(db, at);
};

/** Evaluate staging for all distinct configured chains. */
export const refreshStaging = async (db: Database, at: number): Promise<void> => {
  const rows = await db.all('SELECT DISTINCT chain_id FROM installation_chains');
  for (const row of rows) {
    await refreshChainStage(db, String(row.chain_id), at);
  }
  await syncUpstream(db, at);
};

export async function refreshChainStage(db: Database, chainId: string, at: number): Promise<void> {
  const eligible = await qualifiedInstallationsForChain(db, chainId, at);
  const eligibleCount = eligible.size;
  const recognized = await db.first('SELECT * FROM webhook_chain_stages WHERE chain_id = ?', [
    chainId,
  ]);

  if (!recognized) {
    const initial = eligibleCount >= CONFIG.chainActivationThreshold ? 'enabling' : 'staged';
    await db.run(
      `INSERT INTO webhook_chain_stages (chain_id, eligible_installation_count, status, updated_at)
       VALUES (?, ?, ?, ?)`,
      [chainId, eligibleCount, initial, at],
    );
    if (initial === 'enabling') {
      await enqueueOperation(db, 'activate_chain', undefined, chainId);
    }
    return;
  }

  const status = String(recognized.status);
  if (status === 'operatorDisabled') {
    await db.run(
      'UPDATE webhook_chain_stages SET eligible_installation_count = ?, updated_at = ? WHERE chain_id = ?',
      [eligibleCount, at, chainId],
    );
    return;
  }

  if (eligibleCount >= CONFIG.chainActivationThreshold) {
    if (status !== 'active') {
      await db.run(
        "UPDATE webhook_chain_stages SET eligible_installation_count = ?, status = 'enabling', updated_at = ? WHERE chain_id = ?",
        [eligibleCount, at, chainId],
      );
      await enqueueOperation(db, 'activate_chain', undefined, chainId);
    } else {
      await db.run(
        'UPDATE webhook_chain_stages SET eligible_installation_count = ?, updated_at = ? WHERE chain_id = ?',
        [eligibleCount, at, chainId],
      );
    }
    return;
  }

  // Below threshold. Activation is sticky once active; otherwise ease back to staged.
  if (status !== 'active') {
    await db.run(
      "UPDATE webhook_chain_stages SET eligible_installation_count = ?, status = 'staged', updated_at = ? WHERE chain_id = ?",
      [eligibleCount, at, chainId],
    );
  } else {
    await db.run(
      'UPDATE webhook_chain_stages SET eligible_installation_count = ?, updated_at = ? WHERE chain_id = ?',
      [eligibleCount, at, chainId],
    );
  }
}

export async function enrollAddresses(
  db: Database,
  installationId: string,
  addresses: string[],
  at: number,
): Promise<void> {
  await requireInstallation(db, installationId);
  const distinct = [...new Set(addresses.map((address) => address.toLowerCase()))];
  if (distinct.length > CONFIG.quotas.maxAddresses) {
    throw badRequest('address quota exceeded');
  }

  const existing = await db.all(
    'SELECT address FROM installation_enrollments WHERE installation_id = ?',
    [installationId],
  );
  if (existing.length + distinct.length > CONFIG.quotas.maxAddresses) {
    throw badRequest('address quota exceeded');
  }

  for (const address of distinct) {
    await db.run(
      `INSERT INTO installation_enrollments (installation_id, address, source_count, created_at)
       VALUES (?, ?, 1, ?)
       ON CONFLICT (installation_id, address) DO UPDATE SET source_count = source_count + 1`,
      [installationId, address, at],
    );
  }

  await recomputeAndCheckEffectiveQuota(db, installationId, at);
  await syncUpstream(db, at);
}

export async function removeEnrollment(
  db: Database,
  installationId: string,
  address: string,
  at: number,
): Promise<void> {
  await requireInstallation(db, installationId);
  const canonical = address.toLowerCase();
  const row = await db.first(
    'SELECT * FROM installation_enrollments WHERE installation_id = ? AND address = ?',
    [installationId, canonical],
  );
  if (!row) return;
  if (Number(row.source_count) <= 1) {
    await db.run('DELETE FROM installation_enrollments WHERE installation_id = ? AND address = ?', [
      installationId,
      canonical,
    ]);
  } else {
    await db.run(
      'UPDATE installation_enrollments SET source_count = source_count - 1 WHERE installation_id = ? AND address = ?',
      [installationId, canonical],
    );
  }
  await recomputeInstallationEffective(db, installationId, at);
  await syncUpstream(db, at);
}

/** Enforce the effective pair quota atomically with the recompute. */
export async function recomputeAndCheckEffectiveQuota(
  db: Database,
  installationId: string,
  at: number,
): Promise<void> {
  await recomputeInstallationEffective(db, installationId, at);
  const rows = await db.all(
    'SELECT COUNT(*) AS count FROM installation_addresses WHERE installation_id = ? AND revoked_at IS NULL',
    [installationId],
  );
  if (Number(rows[0]?.count ?? 0) > CONFIG.quotas.maxEffectivePairs) {
    throw badRequest('effective address-chain pair quota exceeded');
  }
}

export type OperationKind = 'create_subscription' | 'delete_subscription' | 'activate_chain';

/** Insert one pending outbox operation; idempotent while a like op is pending/processing. */
export async function enqueueOperation(
  db: Database,
  kind: OperationKind,
  address: string | undefined,
  chainId: string,
): Promise<void> {
  const existing = await db.first(
    `SELECT id FROM upstream_operations
      WHERE kind = ? AND address IS ? AND chain_id = ? AND status IN ('pending', 'processing')`,
    [kind, address ?? null, chainId],
  );
  if (existing) return;
  await db.run(
    `INSERT INTO upstream_operations (kind, address, chain_id, status, attempts, created_at, updated_at)
     VALUES (?, ?, ?, 'pending', 0, ?, ?)`,
    [kind, address ?? null, chainId, now(), now()],
  );
}

/** Reconcile upstream 24h-subscription reference counts from effective registrations. */
export async function syncUpstream(db: Database, at: number): Promise<void> {
  const effective = await db.all(
    "SELECT chain_id, address FROM installation_addresses WHERE revoked_at IS NULL AND status = 'active'",
  );
  const countByKey = new Map<string, { address: string; chainId: string; count: number }>();
  for (const row of effective) {
    const address = String(row.address).toLowerCase();
    const key = enrollmentKey(String(row.chain_id), address);
    const entry = countByKey.get(key) ?? {
      address,
      chainId: String(row.chain_id),
      count: 0,
    };
    entry.count += 1;
    countByKey.set(key, entry);
  }

  const subscriptions = await db.all('SELECT * FROM upstream_subscriptions');
  const subByKey = new Map(
    subscriptions.map((row) => [enrollmentKey(String(row.chain_id), String(row.address)), row]),
  );

  for (const key of countByKey.keys()) {
    const entry = countByKey.get(key)!;
    const existingRow = subByKey.get(key);
    if (!existingRow) {
      await db.run(
        `INSERT INTO upstream_subscriptions (address, chain_id, ref_count, status, updated_at)
         VALUES (?, ?, ?, 'pending', ?)`,
        [entry.address, entry.chainId, entry.count, at],
      );
      await enqueueOperation(db, 'create_subscription', entry.address, entry.chainId);
    } else {
      await db.run(
        "UPDATE upstream_subscriptions SET ref_count = ?, status = 'active', updated_at = ? WHERE address = ? AND chain_id = ?",
        [entry.count, at, entry.address, entry.chainId],
      );
    }
  }

  for (const subRow of subscriptions) {
    const key = enrollmentKey(String(subRow.chain_id), String(subRow.address));
    if (!countByKey.has(key) && String(subRow.status) !== 'deleting') {
      const address = String(subRow.address);
      const chainId = String(subRow.chain_id);
      await db.run(
        "UPDATE upstream_subscriptions SET ref_count = 0, status = 'deleting', updated_at = ? WHERE address = ? AND chain_id = ?",
        [at, address, chainId],
      );
      await enqueueOperation(db, 'delete_subscription', address, chainId);
    }
  }
}

/** Mark a chain globally active after a successful upstream activation job. */
export const setChainActivated = async (
  db: Database,
  chainId: string,
  at: number,
): Promise<void> => {
  await db.run(
    "UPDATE webhook_chain_stages SET status = 'active', activated_at = ?, last_error = NULL, updated_at = ? WHERE chain_id = ?",
    [at, at, chainId],
  );
};

/** Replace a complete configured-chain inventory snapshot atomically. */
export const replaceChainsSnapshot = async (
  db: Database,
  installationId: string,
  revision: number,
  chainIds: string[],
  at: number,
): Promise<void> => {
  await requireInstallation(db, installationId);
  if (chainIds.length > CONFIG.quotas.maxChains) {
    throw badRequest('too many configured chains');
  }
  const unique = new Set(chainIds);
  if (unique.size !== chainIds.length) {
    throw badRequest('duplicate configured chains');
  }
  const inst = await requireInstallation(db, installationId);
  const storedRevision = Number(inst.chain_inventory_revision ?? 0);
  if (revision < storedRevision) {
    throw badRequest('stale chain revision');
  }
  await db.run('DELETE FROM installation_chains WHERE installation_id = ?', [installationId]);
  for (const chainId of unique) {
    await db.run(
      'INSERT INTO installation_chains (installation_id, chain_id, revision, created_at) VALUES (?, ?, ?, ?)',
      [installationId, chainId, revision, at],
    );
  }
  await db.run(
    'UPDATE installations SET chain_inventory_revision = ?, last_seen_at = ? WHERE id = ?',
    [revision, at, installationId],
  );
  await recomputeInstallationEffective(db, installationId, at);
  await refreshStaging(db, at);
  await syncUpstream(db, at);
};

/** Renew the desired enrollment set: insert missing, remove ended ones, recompute. */
export const reconcileEnrollments = async (
  db: Database,
  installationId: string,
  addresses: string[],
  at: number,
): Promise<void> => {
  await requireInstallation(db, installationId);
  if (addresses.length > CONFIG.quotas.maxAddresses) {
    throw badRequest('address quota exceeded');
  }
  const desired = new Set(addresses.map((address) => address.toLowerCase()));
  const existing = await db.all(
    'SELECT * FROM installation_enrollments WHERE installation_id = ?',
    [installationId],
  );
  for (const row of existing) {
    const address = String(row.address);
    if (!desired.has(address)) {
      await db.run(
        'DELETE FROM installation_enrollments WHERE installation_id = ? AND address = ?',
        [installationId, address],
      );
    }
  }
  for (const address of desired) {
    await db.run(
      `INSERT INTO installation_enrollments (installation_id, address, source_count, created_at)
       VALUES (?, ?, 1, ?)
       ON CONFLICT (installation_id, address) DO NOTHING`,
      [installationId, address, at],
    );
  }
  await recomputeAndCheckEffectiveQuota(db, installationId, at);
  await syncUpstream(db, at);
};
