import { CONFIG } from '../config';
import type { Database } from '../database';
import { enqueueOperation } from './registrations';

/** Multi-statement deletion of an installation from all control-plane tables. */
export async function purgeInstallation(db: Database, installationId: string): Promise<void> {
  await db.run('DELETE FROM installation_enrollments WHERE installation_id = ?', [installationId]);
  await db.run('DELETE FROM installation_chains WHERE installation_id = ?', [installationId]);
  // Release upstream references for the installation's effective rows.
  const pairs = await db.all(
    'SELECT chain_id, address FROM installation_addresses WHERE installation_id = ? AND revoked_at IS NULL',
    [installationId],
  );
  await db.run('DELETE FROM installation_addresses WHERE installation_id = ?', [installationId]);
  for (const pair of pairs) {
    await enqueueOperation(db, 'delete_subscription', String(pair.address), String(pair.chain_id));
  }
  await db.run('DELETE FROM installation_events WHERE installation_id = ?', [installationId]);
  await db.run('DELETE FROM apns_deliveries WHERE installation_id = ?', [installationId]);
  await db.run('DELETE FROM popup_liveness_request_ids WHERE installation_id = ?', [
    installationId,
  ]);
  await db.run('DELETE FROM installation_request_ids WHERE installation_id = ?', [installationId]);
  await db.run('DELETE FROM installations WHERE id = ?', [installationId]);
}

/** Expire installations whose liveness window has lapsed (background liveness expiry). */
export async function expireLapsedInstallations(db: Database, at: number): Promise<number> {
  const rows = await db.all('SELECT id FROM installations WHERE liveness_expires_at < ?', [at]);
  for (const row of rows) {
    await purgeInstallation(db, String(row.id));
  }
  return rows.length;
}

/** Delete expired installation-event feed rows beyond backend retention. */
export async function pruneInstallationEvents(db: Database, at: number): Promise<number> {
  const cutoff = at - CONFIG.eventRetentionSeconds * 1000;
  const result = await db.run('DELETE FROM installation_events WHERE created_at < ?', [cutoff]);
  return result.changes;
}

/** Prune stale replay-id, challenge, and rate-limit rows. */
export async function pruneScratchState(db: Database, at: number): Promise<void> {
  await db.run('DELETE FROM installation_request_ids WHERE expires_at < ?', [at]);
  await db.run('DELETE FROM popup_liveness_request_ids WHERE expires_at < ?', [at]);
  await db.run('DELETE FROM installation_challenges WHERE expires_at < ?', [at]);
  const rateCutoff = at - 24 * 60 * 60 * 1000;
  await db.run('DELETE FROM rate_limits WHERE window_start < ?', [rateCutoff]);
}
