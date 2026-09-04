import { CONFIG } from '../config';
import type { Database } from '../database';
import { aesGcmEncrypt, keyedHash } from '../crypto';
import { notFound } from '../errors';
import type { KeyedConfig } from './util';
import { now, uuid } from './util';

export interface CreateInstallationInput {
  publicKey: string;
  popupLivenessPublicKey?: string;
  appVersion?: string;
  appBuild?: string;
  apnsEnvironment?: 'development' | 'production';
  apnsToken?: string;
  notificationAuthorization?: string;
  notificationAlertSetting?: string;
  trustMode?: string;
}

export async function createInstallation(
  db: Database,
  conf: KeyedConfig,
  input: CreateInstallationInput,
): Promise<string> {
  const at = now();
  const id = `inst_${uuid()}`;
  const publicKeyHash = await keyedHash(conf.appDataKey, input.publicKey);
  const popupHash = input.popupLivenessPublicKey
    ? await keyedHash(conf.appDataKey, input.popupLivenessPublicKey)
    : null;
  const popupKey = input.popupLivenessPublicKey ?? null;
  const tokenHash = input.apnsToken ? await keyedHash(conf.appDataKey, input.apnsToken) : null;
  const tokenCiphertext = input.apnsToken
    ? await aesGcmEncrypt(conf.appDataKey, new TextEncoder().encode(input.apnsToken))
    : null;

  const liveness = at + CONFIG.installationLivenessSeconds * 1000;
  const authorization = input.notificationAuthorization ?? null;
  const alertSetting = input.notificationAlertSetting ?? null;
  const observedAt = authorization !== null ? at : null;
  const validUntilValue = observedAt !== null ? at + CONFIG.settingsFreshnessSeconds * 1000 : null;

  await db.run(
    `INSERT INTO installations
      (id, public_key, public_key_hash, popup_liveness_public_key, popup_liveness_public_key_hash,
       trust_mode, status, chain_inventory_revision,
       apns_token_hash, apns_token_ciphertext, apns_environment, apns_token_version,
       notification_authorization, notification_alert_setting,
       notification_settings_observed_at, notification_settings_valid_until,
       app_version, app_build, liveness_expires_at, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?, ?, 'active', 0, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      id,
      input.publicKey,
      publicKeyHash,
      popupKey,
      popupHash,
      input.trustMode ?? 'installation_key_only',
      tokenHash,
      tokenCiphertext,
      input.apnsEnvironment ?? null,
      authorization,
      alertSetting,
      observedAt,
      validUntilValue,
      input.appVersion ?? null,
      input.appBuild ?? null,
      liveness,
      at,
      at,
    ],
  );
  return id;
}

export const getInstallation = async (
  db: Database,
  id: string,
): Promise<Record<string, unknown> | null> =>
  db.first('SELECT * FROM installations WHERE id = ?', [id]);

export const requireInstallation = async (
  db: Database,
  id: string,
): Promise<Record<string, unknown>> => {
  const row = await getInstallation(db, id);
  if (!row) throw notFound('installation not found');
  return row;
};

export async function updatePushToken(
  db: Database,
  conf: KeyedConfig,
  installationId: string,
  environment: 'development' | 'production',
  token: string,
): Promise<void> {
  await requireInstallation(db, installationId);
  const tokenHash = await keyedHash(conf.appDataKey, token);
  const ciphertext = await aesGcmEncrypt(conf.appDataKey, new TextEncoder().encode(token));
  await db.run(
    `UPDATE installations SET apns_token_hash = ?, apns_token_ciphertext = ?, apns_environment = ?,
        apns_token_version = apns_token_version + 1, push_token_invalidated_at = NULL,
        notification_settings_observed_at = ?, last_seen_at = ?
     WHERE id = ?`,
    [tokenHash, ciphertext, environment, now(), now(), installationId],
  );
}

export async function updateNotificationStatus(
  db: Database,
  installationId: string,
  status: { authorization: string; alertSetting: string; observedAt: number },
): Promise<void> {
  await requireInstallation(db, installationId);
  const at = now();
  const validUntil = status.observedAt + CONFIG.settingsFreshnessSeconds * 1000;
  const liveness = Math.max(
    status.observedAt + CONFIG.installationLivenessSeconds * 1000,
    validUntil,
  );
  await db.run(
    `UPDATE installations
       SET notification_authorization = ?, notification_alert_setting = ?,
           notification_settings_observed_at = ?, notification_settings_valid_until = ?,
           liveness_expires_at = ?, last_seen_at = ?
     WHERE id = ?`,
    [
      status.authorization,
      status.alertSetting,
      status.observedAt,
      validUntil,
      liveness,
      at,
      installationId,
    ],
  );
}

/** Popup liveness extension: extends an active installation up to its settings ceiling. */
export async function extendLiveness(
  db: Database,
  installationRow: Record<string, unknown>,
  at: number,
): Promise<void> {
  const ceiling =
    Number(installationRow.notification_settings_valid_until) ||
    Number(installationRow.liveness_expires_at);
  const proposed = at + CONFIG.installationLivenessSeconds * 1000;
  const current = Number(installationRow.liveness_expires_at);
  const target = Math.min(proposed, Math.max(ceiling, current));
  await db.run('UPDATE installations SET liveness_expires_at = ? WHERE id = ?', [
    target,
    String(installationRow.id),
  ]);
}
