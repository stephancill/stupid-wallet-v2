import type { Database } from '../database';
import { base64UrlEncode, sha256 } from '../crypto';
import type { WebhookEvent } from '../schemas';
import { classifyEvent } from '../services/eventKinds';
import { isNotificationEligible } from './util';
import { nextCounter } from './counter';

/** An opaque installation-scoped registration id stable across events (both sides derive it). */
export const opaqueRegistrationId = async (
  installationId: string,
  address: string,
): Promise<string> => {
  const digest = await sha256(`${installationId}\u0000${address}`);
  return `ar_${base64UrlEncode(digest).slice(0, 24)}`;
};

export interface FanoutTarget {
  installationId: string;
  opaqueRegistrationId: string;
}

/**
 * Insert a verified webhook event and deterministically fan it out to matching
 * eligible installations. Returns a duplicate marker when the delivery was already
 * applied for this (webhookId, eventType).
 */
export async function ingestWebhook(
  db: Database,
  payload: WebhookEvent,
  webhookId: string,
  at: number,
): Promise<{ duplicate: boolean; eventId: string; eventKind: string; fanout: FanoutTarget[] }> {
  const eventId = `evt_${crypto.randomUUID()}`;
  const eventKind = classifyEvent(payload);
  const observationId = payload.observationId;

  try {
    await db.run(
      `INSERT INTO activity_events
        (event_id, observation_id, webhook_id, event_type, chain_id, address, event_kind,
         block_number, block_hash, block_timestamp, transaction_hash, transaction_from,
         transaction_to, transaction_status, transaction_nonce, transaction_value,
         initiated_by_tracked_address, effects_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        eventId,
        observationId,
        webhookId,
        payload.eventType,
        payload.chainId,
        payload.address.toLowerCase(),
        eventKind,
        payload.blockNumber !== undefined ? Number(payload.blockNumber) : null,
        payload.blockHash ?? null,
        payload.blockTimestamp ?? null,
        payload.transactionHash ?? null,
        payload.transactionFrom?.toLowerCase() ?? null,
        payload.transactionTo?.toLowerCase() ?? null,
        payload.transactionStatus ?? null,
        payload.transactionNonce ?? null,
        payload.transactionValue ?? null,
        payload.initiatedByTrackedAddress === true ? 1 : 0,
        payload.effects ? JSON.stringify(payload.effects) : null,
        at,
      ],
    );
  } catch (error) {
    const message = (error as { message?: string })?.message ?? String(error);
    if (message.includes('UNIQUE constraint failed')) {
      return { duplicate: true, eventId: '', eventKind: '', fanout: [] };
    }
    throw error;
  }

  const registrations = await db.all(
    `SELECT ra.installation_id
       FROM installation_addresses ra
       JOIN installations i ON i.id = ra.installation_id
      WHERE ra.chain_id = ? AND ra.address = ?
        AND ra.revoked_at IS NULL AND ra.status = 'active'`,
    [payload.chainId, payload.address.toLowerCase()],
  );

  const fanout: FanoutTarget[] = [];
  for (const row of registrations) {
    const installationId = String(row.installation_id);
    const installation = await db.first('SELECT * FROM installations WHERE id = ?', [
      installationId,
    ]);
    if (!installation || !isNotificationEligible(installation, at)) continue;

    const cursorSeq = await nextCounter(db, `events:${installationId}`);
    const regId = await opaqueRegistrationId(installationId, payload.address.toLowerCase());
    await db.run(
      `INSERT INTO installation_events
        (installation_id, event_id, cursor_seq, address, address_registration_id, event_kind, chain_id, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        installationId,
        eventId,
        cursorSeq,
        payload.address.toLowerCase(),
        regId,
        eventKind,
        payload.chainId,
        at,
      ],
    );
    fanout.push({ installationId, opaqueRegistrationId: regId });
  }

  return { duplicate: false, eventId, eventKind, fanout };
}
