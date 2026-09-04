export const now = (): number => Date.now();
export const uuid = (): string => crypto.randomUUID();

const NOTIF_CAPABLE_AUTHORIZATIONS = new Set(['authorized', 'provisional', 'ephemeral']);

/** A notification-capable installation contributes registrations and chain-stage counts. */
export const isNotificationEligible = (row: Record<string, unknown>, at: number): boolean =>
  String(row.status) === 'active' &&
  Number(row.liveness_expires_at) >= at &&
  NOTIF_CAPABLE_AUTHORIZATIONS.has(String(row.notification_authorization ?? '')) &&
  String(row.notification_alert_setting) === 'enabled' &&
  typeof row.apns_token_hash === 'string';

export interface KeyedConfig {
  appDataKey: string;
}
