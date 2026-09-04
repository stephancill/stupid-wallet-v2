import type { D1Database, Queue } from '@cloudflare/workers-types';

/** Immutable backend configuration drawn from locked MVP decisions. */
export const CONFIG = {
  /** Seconds accepted around x-wallet-timestamp. */
  clockSkewSeconds: 300,
  /** Replay window for authenticated requests, in seconds. */
  replayWindowSeconds: 300,
  /** Installation liveness window before automatic cleanup. */
  installationLivenessSeconds: 30 * 24 * 60 * 60,
  /** Containing-app notification-settings freshness ceiling. */
  settingsFreshnessSeconds: 90 * 24 * 60 * 60,
  /** Popup liveness request replay/idempotency window. */
  popupReplaySeconds: 24 * 60 * 60,
  /** Foreground renewal threshold. */
  foregroundRenewalThresholdSeconds: 14 * 24 * 60 * 60,
  /** Per-installation quotas. */
  quotas: {
    maxAddresses: 25,
    maxChains: 25,
    maxEffectivePairs: 250,
  },
  /** Distinct installations that promote a chain from staged to active. */
  chainActivationThreshold: 5,
  /** Backend event-feed retention. */
  eventRetentionSeconds: 30 * 24 * 60 * 60,
  /** Upstream chain-activation operation idempotency TTL. */
  chainActivationIdempotencySeconds: 24 * 60 * 60,
  /** Bounded APNs retry schedule (ms between attempts). */
  apnsRetryBackoffMs: [1000, 5000, 15000, 60000],
  /** Bounded request-rate limits (requests per window per key). */
  rateLimits: {
    installationCreate: { windowSeconds: 60, max: 10 },
    installationMutation: { windowSeconds: 60, max: 60 },
    eventRead: { windowSeconds: 60, max: 120 },
    popupLiveness: { windowSeconds: 60, max: 10 },
    challenge: { windowSeconds: 60, max: 20 },
    webhook: { windowSeconds: 60, max: 300 },
  },
} as const;

export interface Env {
  DB: D1Database;
  ENVIRONMENT: string;
  /** AES-GCM 256-bit key (base64) for APNs token delivery values + keyed hashes. */
  APP_DATA_KEY: string;
  /** Upstream Stupid Wallet Webhooks API key. */
  UPSTREAM_API_KEY: string;
  /** Upstream webhook HMAC-SHA256 shared secret. */
  UPSTREAM_WEBHOOK_SECRET: string;
  /** APNs provider .p8 private key (base64 DER PKCS8). */
  APNS_KEY: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  /** APNs topic = containing-app bundle identifier. */
  APNS_TOPIC: string;
  UPSTREAM_QUEUE: Queue;
  APNS_QUEUE: Queue;
}

export type Db = D1Database;
