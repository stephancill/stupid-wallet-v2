import { CONFIG } from '../config';
import type { Database } from '../database';
import { keyedHash, sha256Base64Url } from '../crypto';
import { badRequest, gone } from '../errors';
import { now } from './util';

export interface Challenge {
  challengeId: string;
  installationPublicKeyHash: string;
  nonce: string;
  serverTime: number;
  expiresAt: number;
  provisionalInstallationId: string | null;
}

/** Create a challenge bound to an unauthenticated P-256 public key. */
export async function createChallenge(
  db: Database,
  appDataKey: string,
  publicKey: string,
  _packageName: string,
  environment: string,
  at = now(),
): Promise<Challenge> {
  void CONFIG;
  const challengeId = `chg_${crypto.randomUUID()}`;
  const nonce = await sha256Base64Url(crypto.randomUUID());
  const expiresAt = at + 15 * 60 * 1000;
  const publicKeyHash = await keyedHash(appDataKey, publicKey);
  await db.run(
    `INSERT INTO installation_challenges
       (challenge_id, installation_public_key, installation_public_key_hash,
        nonce, backend_environment, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [challengeId, publicKey, publicKeyHash, nonce, environment, expiresAt, at],
  );
  return {
    challengeId,
    installationPublicKeyHash: publicKeyHash,
    nonce,
    serverTime: at,
    expiresAt,
    provisionalInstallationId: `inst_${crypto.randomUUID()}`,
  };
}

/** Consume a challenge; returns the stored public key hash when the key matches. */
export async function consumeChallenge(
  db: Database,
  challengeId: string,
  expectedPublicKey: string,
  appDataKey: string,
  at = now(),
): Promise<string> {
  const row = await db.first('SELECT * FROM installation_challenges WHERE challenge_id = ?', [
    challengeId,
  ]);
  if (!row) throw gone('challenge not found');
  if (Number(row.expires_at) < at) throw gone('challenge expired');
  if (row.consumed_at !== null) throw gone('challenge already used');

  const providedHash = await keyedHash(appDataKey, expectedPublicKey);
  if (providedHash !== String(row.installation_public_key_hash)) {
    throw badRequest('challenge public key mismatch');
  }

  await db.run('UPDATE installation_challenges SET consumed_at = ? WHERE challenge_id = ?', [
    at,
    challengeId,
  ]);
  return String(row.installation_public_key_hash);
}
