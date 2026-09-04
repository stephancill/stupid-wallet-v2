import { CONFIG } from '../config';
import { bodyDigestOf, buildCanonicalSequence } from './request';
import { verifyP256 } from '../p256';
import { badRequest, forbidden, gone, unauthorized } from '../errors';
import type { Database, Row } from '../database';

/**
 * Popup liveness request: a request signed with the popup capability key that may
 * only extend an existing installation's liveness up to its settings ceiling. It
 * verifies over an empty body digest and records its own replay id.
 */
export async function verifyPopupLiveness(
  db: Database,
  installationId: string,
  timestampMilliseconds: string,
  requestId: string,
  signature: string,
  pathAndQuery: string,
  now = Date.now(),
): Promise<Row> {
  const timestamp = Number(timestampMilliseconds);
  if (!Number.isFinite(timestamp)) {
    throw badRequest('malformed timestamp');
  }
  if (Math.abs(now - timestamp) > CONFIG.clockSkewSeconds * 1000) {
    throw unauthorized('request timestamp outside the accepted window');
  }
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(requestId)) {
    throw badRequest('malformed request id');
  }

  const installation = await db.first('SELECT * FROM installations WHERE id = ?', [installationId]);
  if (!installation || String(installation.status) !== 'active') {
    throw gone('installation not found or inactive');
  }
  if (Number(installation.liveness_expires_at) < now) {
    throw gone('installation liveness expired');
  }

  const popupKey = String(installation.popup_liveness_public_key ?? '');
  if (!popupKey) {
    throw gone('popup liveness capability not associated');
  }

  const emptyDigest = await bodyDigestOf(new Uint8Array(0));
  const canonical = buildCanonicalSequence(
    'POST',
    pathAndQuery,
    timestampMilliseconds,
    requestId,
    emptyDigest,
  );

  const valid = await verifyP256(popupKey, signature, new TextEncoder().encode(canonical));
  if (!valid) {
    throw forbidden('popup liveness signature verification failed');
  }

  await db.run('DELETE FROM popup_liveness_request_ids WHERE expires_at < ?', [now]);
  try {
    await db.run(
      'INSERT INTO popup_liveness_request_ids (installation_id, request_id, consumed_at, expires_at) VALUES (?, ?, ?, ?)',
      [installationId, requestId, now, now + CONFIG.popupReplaySeconds * 1000],
    );
  } catch (error) {
    const message = (error as { message?: string })?.message ?? String(error);
    if (message.includes('UNIQUE constraint failed')) {
      // Idempotent: a repeated request id yields the current state.
      return installation;
    }
    throw error;
  }

  return installation;
}
