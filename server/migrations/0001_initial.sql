-- Stupid Wallet backend D1 control-plane schema (MVP).
-- Timestamps are Unix milliseconds. Tables use explicit NOT NULL on required fields.

CREATE TABLE installations (
  id TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,               -- base64url SPKI DER of installation P-256 public key
  public_key_hash TEXT NOT NULL UNIQUE,   -- base64url SHA-256 of public_key
  popup_liveness_public_key TEXT,         -- base64url SPKI DER
  popup_liveness_public_key_hash TEXT UNIQUE,
  trust_mode TEXT NOT NULL DEFAULT 'installation_key_only',
  status TEXT NOT NULL DEFAULT 'active',  -- active | deleting
  chain_inventory_revision INTEGER NOT NULL DEFAULT 0,
  apns_token_hash TEXT,
  apns_token_ciphertext TEXT,
  apns_environment TEXT,
  apns_token_version INTEGER,
  notification_authorization TEXT,          -- authorized | denied | notDetermined | provisional | ephemeral
  notification_alert_setting TEXT,          -- enabled | disabled | notSupported
  notification_settings_observed_at INTEGER,
  notification_settings_valid_until INTEGER,
  push_token_invalidated_at INTEGER,
  app_version TEXT,
  app_build TEXT,
  liveness_expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER
);

CREATE TABLE installation_challenges (
  challenge_id TEXT PRIMARY KEY,
  installation_public_key TEXT NOT NULL,
  installation_public_key_hash TEXT NOT NULL,
  nonce TEXT NOT NULL,
  backend_environment TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE installation_request_ids (
  installation_id TEXT NOT NULL,
  request_id TEXT NOT NULL,
  consumed_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (installation_id, request_id)
);

CREATE TABLE popup_liveness_request_ids (
  installation_id TEXT NOT NULL,
  request_id TEXT NOT NULL,
  consumed_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (installation_id, request_id)
);

CREATE TABLE installation_chains (
  installation_id TEXT NOT NULL,
  chain_id TEXT NOT NULL,                  -- decimal chain id
  revision INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (installation_id, chain_id)
);

CREATE TABLE installation_enrollments (
  installation_id TEXT NOT NULL,
  address TEXT NOT NULL,                   -- canonical lowercase address
  source_count INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (installation_id, address)
);

CREATE TABLE webhook_chain_stages (
  chain_id TEXT PRIMARY KEY,
  eligible_installation_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'staged',   -- staged | enabling | active | unsupported | error | operatorDisabled
  activated_at INTEGER,
  operator_disabled_at INTEGER,
  last_error TEXT,
  updated_at INTEGER NOT NULL
);

CREATE TABLE installation_addresses (
  installation_id TEXT NOT NULL,
  chain_id TEXT NOT NULL,
  address TEXT NOT NULL,                   -- canonical lowercase address
  source_count INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | active | unsupported | error
  created_at INTEGER NOT NULL,
  renewed_at INTEGER,
  revoked_at INTEGER,
  PRIMARY KEY (installation_id, chain_id, address)
);

CREATE TABLE upstream_subscriptions (
  address TEXT NOT NULL,
  chain_id TEXT NOT NULL,
  ref_count INTEGER NOT NULL DEFAULT 0,
  upstream_subscription_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | active | unsupported | error
  active_from_block INTEGER,
  last_error TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (address, chain_id)
);

CREATE TABLE upstream_operations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,                       -- create_subscription | delete_subscription | activate_chain
  address TEXT,
  chain_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending',   -- pending | processing | done | failed
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE activity_events (
  event_id TEXT PRIMARY KEY,                -- backend canonical id
  observation_id TEXT NOT NULL,
  webhook_id TEXT NOT NULL,
  event_type TEXT NOT NULL,                 -- activity.observed | activity.reverted
  chain_id TEXT NOT NULL,
  address TEXT NOT NULL,                    -- tracked address
  event_kind TEXT NOT NULL,
  block_number INTEGER,
  block_hash TEXT,
  block_timestamp INTEGER,
  transaction_hash TEXT,
  transaction_from TEXT,
  transaction_to TEXT,
  transaction_status TEXT,
  transaction_nonce INTEGER,
  transaction_value TEXT,
  initiated_by_tracked_address INTEGER,
  effects_json TEXT,
  created_at INTEGER NOT NULL,
  UNIQUE (webhook_id, event_type)
);

CREATE TABLE installation_events (
  installation_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  cursor_seq INTEGER NOT NULL,
  address TEXT NOT NULL,
  address_registration_id TEXT NOT NULL,
  event_kind TEXT NOT NULL,
  chain_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (installation_id, cursor_seq),
  UNIQUE (installation_id, event_id)
);

CREATE TABLE apns_deliveries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  installation_id TEXT NOT NULL,
  installation_event_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | accepted | failed | unregistered
  attempts INTEGER NOT NULL DEFAULT 0,
  next_retry_at INTEGER,
  last_status_code INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (installation_id, installation_event_id),
  FOREIGN KEY (installation_id) REFERENCES installations(id) ON DELETE CASCADE
);

CREATE INDEX idx_installation_events_cursor ON installation_events (installation_id, cursor_seq);
CREATE INDEX idx_activity_events_chain ON activity_events (chain_id, block_timestamp);
CREATE INDEX idx_addresses_by_subscription ON installation_addresses (address, chain_id);

CREATE TABLE rate_limits (
  limit_key TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (limit_key, window_start)
);

CREATE TABLE counters (
  name TEXT PRIMARY KEY,
  value INTEGER NOT NULL
);