import { describe, expect, it, beforeAll } from 'vitest';
import { createTestDb } from './helpers';
import { createInstallation } from '../src/domain/installations';
import {
  activeChainIds,
  enrollAddresses,
  listStages,
  recomputeChainForAll,
  refreshStaging,
  replaceChainsSnapshot,
  setChainActivated,
  syncUpstream,
} from '../src/domain/registrations';
import { ingestWebhook } from '../src/domain/webhook';
import { listInstallationEvents } from '../src/domain/events';
import { purgeInstallation } from '../src/domain/lifecycle';
import type { WebhookEvent } from '../src/schemas';

const APP_KEY = { appDataKey: Buffer.from(Array(32).fill(0x7f)).toString('base64url') };
const NOW = Date.now();
const TOKEN = '111a'.repeat(16);

const ADDRESS_A = '0x1111111111111111111111111111111111111111';
const ADDRESS_B = '0x2222222222222222222222222222222222222222';

const webhook = (over: Partial<WebhookEvent> = {}): WebhookEvent => ({
  eventId: 'obs-1',
  eventType: 'activity.observed',
  chainId: '1',
  address: ADDRESS_A,
  observationId: 'obs-1',
  transactionHash: `0x${'ab'.repeat(32)}`,
  transactionFrom: ADDRESS_B,
  transactionStatus: 'success',
  transactionValue: '1000000000000000000',
  initiatedByTrackedAddress: false,
  ...over,
});

const install = async (db: ReturnType<typeof createTestDb>, i: number): Promise<string> =>
  createInstallation(db, APP_KEY, {
    publicKey: `PK_${i}`,
    apnsToken: TOKEN,
    apnsEnvironment: 'production',
    notificationAuthorization: 'authorized',
    notificationAlertSetting: 'enabled',
    appVersion: '1.0.0',
    appBuild: String(90 + i),
  });

describe('installation registration and chain staging', () => {
  let db: ReturnType<typeof createTestDb>;
  let ids: string[] = [];

  beforeAll(async () => {
    db = createTestDb();
    for (let i = 0; i < 6; i += 1) ids.push(await install(db, i));
    for (let i = 0; i < 5; i += 1) {
      await replaceChainsSnapshot(db, ids[i]!, 1, ['1'], NOW);
      await enrollAddresses(db, ids[i]!, [ADDRESS_A], NOW);
    }
  });

  it('persists the route-scoped popup liveness key', async () => {
    const popupKey = 'popup-public-key';
    const id = await createInstallation(db, APP_KEY, {
      publicKey: 'installation-public-key',
      popupLivenessPublicKey: popupKey,
    });
    const row = await db.first('SELECT popup_liveness_public_key FROM installations WHERE id = ?', [
      id,
    ]);
    expect(row?.popup_liveness_public_key).toBe(popupKey);
  });

  it('stages a chain at 5 eligible installations', async () => {
    const stage = (await listStages(db)).find((s) => s.chainId === '1');
    expect(stage?.status).toBe('enabling');
    expect(stage?.eligibleCount).toBe(5);
  });

  it('promotes to active and derives effective registrations + upstream refs', async () => {
    await setChainActivated(db, '1', NOW);
    await recomputeChainForAll(db, '1', NOW);
    await syncUpstream(db, NOW);

    expect(await activeChainIds(db)).toContain('1');

    const sub = await db.first(
      'SELECT * FROM upstream_subscriptions WHERE address = ? AND chain_id = ?',
      [ADDRESS_A, '1'],
    );
    expect(sub?.ref_count).toBe(5);
    expect(sub?.status).toBe('active');

    const effective = await db.all(
      "SELECT * FROM installation_addresses WHERE chain_id = '1' AND revoked_at IS NULL",
    );
    expect(effective.length).toBe(5);
  });

  it('keeps the chain active (sticky) below five while dropping stale refs', async () => {
    // Remove one of the five registered installations so the count falls below five.
    await purgeInstallation(db, ids[4]!);
    await refreshStaging(db, NOW);
    const stages = await listStages(db);
    expect(stages.find((s) => s.chainId === '1')?.status).toBe('active');

    const sub = await db.first(
      'SELECT * FROM upstream_subscriptions WHERE address = ? AND chain_id = ?',
      [ADDRESS_A, '1'],
    );
    expect(sub?.status).toBe('active');
  });

  it('retains the remaining registrations and adjustments', async () => {
    await purgeInstallation(db, ids[4]!);
    await refreshStaging(db, NOW);
    const rows = await db.all(
      "SELECT * FROM installation_addresses WHERE chain_id = '1' AND revoked_at IS NULL",
    );
    expect(rows.length).toBe(4);
  });
});

describe('webhook ingestion, dedup, and cursor feed', () => {
  let db: ReturnType<typeof createTestDb>;
  let installationId: string;

  beforeAll(async () => {
    db = createTestDb();
    installationId = await install(db, 99);
    await replaceChainsSnapshot(db, installationId, 1, ['1'], NOW);
    await setChainActivated(db, '1', NOW);
    await enrollAddresses(db, installationId, [ADDRESS_A], NOW);
    await syncUpstream(db, NOW);
  });

  it('fanouts a webhook to installations with active registrations', async () => {
    const result = await ingestWebhook(db, webhook(), 'hook-1', NOW);
    expect(result.duplicate).toBe(false);
    expect(result.fanout.length).toBe(1);
    expect(result.eventKind).toBe('nativeReceived');

    const page = await listInstallationEvents(db, installationId, null, 10);
    expect(page.items.length).toBe(1);
    expect(page.items[0]?.addressRegistrationId).toContain('ar_');
  });

  it('deduplicates the same (webhookId, eventType)', async () => {
    const second = await ingestWebhook(db, webhook(), 'hook-1', NOW);
    expect(second.duplicate).toBe(true);
    const page = await listInstallationEvents(db, installationId, null, 10);
    expect(page.items.length).toBe(1);
  });

  it('applies a reverted delivery sharing the same webhook id exactly once', async () => {
    const reverted = await ingestWebhook(
      db,
      webhook({ eventType: 'activity.reverted', observationId: 'obs-1' }),
      'hook-1',
      NOW,
    );
    expect(reverted.duplicate).toBe(false);
    const page = await listInstallationEvents(db, installationId, null, 10);
    expect(page.items.length).toBe(2);
    expect(page.items.at(-1)?.eventKind).toBe('activityReverted');
  });
});
