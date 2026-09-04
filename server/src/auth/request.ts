import { CONFIG } from '../config';
import { base64UrlEncode, sha256 } from '../crypto';
import { verifyP256 } from '../p256';
import { badRequest, forbidden, gone, notFound, unauthorized } from '../errors';
import type { Database, Row } from '../database';

/** The canonical signed byte sequence for installation-key requests. */
export const buildCanonicalSequence = (
  method: string,
  pathAndQuery: string,
  timestamp: string,
  requestId: string,
  bodyDigestBase64Url: string,
): string =>
  ['v1', method.toUpperCase(), pathAndQuery, timestamp, requestId, bodyDigestBase64Url].join('\n');

/** Base64url SHA-256 of the exact request body bytes. */
export const bodyDigestOf = async (body: Uint8Array): Promise<string> => {
  const digest = await sha256(body);
  return base64UrlEncode(digest);
};

export interface AuthenticatedRequest {
  installation: Row;
  publicKeyHash: string;
}

/**
 * Verifies an installation request: timestamp freshness, installation existence,
 * active status + liveness, single-use request id (replay defense), and the
 * P-256 signature over the canonical sequence.
 */
export async function authenticateRequest(
  db: Database,
  method: string,
  pathAndQuery: string,
  installationId: string,
  timestampMilliseconds: string,
  requestId: string,
  signature: string,
  exactBody: Uint8Array,
  now = Date.now(),
): Promise<AuthenticatedRequest> {
  const timestamp = Number(timestampMilliseconds);
  if (!Number.isFinite(timestamp)) {
    throw badRequest('malformed timestamp');
  }
  if (Math.abs(now - timestamp) > CONFIG.clockSkewSeconds * 1000) {
    throw unauthorized('request timestamp outside the accepted window');
  }

  const digest = await bodyDigestOf(exactBody);
  const canonical = buildCanonicalSequence(
    method,
    pathAndQuery,
    timestampMilliseconds,
    requestId,
    digest,
  );

  const installation = await db.first('SELECT * FROM installations WHERE id = ?', [installationId]);
  if (!installation) {
    throw notFound('installation not found');
  }
  if (String(installation.status) !== 'active') {
    throw gone('installation is no longer active');
  }
  if (Number(installation.liveness_expires_at) < now) {
    throw gone('installation liveness expired');
  }

  const publicKey = String(installation.public_key);
  const valid = await verifyP256(publicKey, signature, new TextEncoder().encode(canonical));
  if (!valid) {
    throw forbidden('installation signature verification failed');
  }

  await markRequestUsed(db, installationId, requestId, now);

  return { installation, publicKeyHash: String(installation.public_key_hash) };
}

/** Records a request id, rejecting a duplicate (replay). */
async function markRequestUsed(
  db: Database,
  installationId: string,
  requestId: string,
  now: number,
): Promise<void> {
  await db.run('DELETE FROM installation_request_ids WHERE expires_at < ?', [now]);
  try {
    await db.run(
      'INSERT INTO installation_request_ids (installation_id, request_id, consumed_at, expires_at) VALUES (?, ?, ?, ?)',
      [installationId, requestId, now, now + CONFIG.replayWindowSeconds * 1000],
    );
  } catch (error) {
    const message = (error as { message?: string })?.message ?? String(error);
    if (message.includes('UNIQUE constraint failed')) {
      throw unauthorized('request id already used (replay rejected)');
    }
    throw error;
  }
}
