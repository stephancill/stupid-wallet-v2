# Wallet Backend And Push Notifications Plan

## Status

This is the broader design reference for wallet-activity push notifications. The first implementation
subset and its locked defaults are defined in
`docs/wallet-backend-push-notifications-mvp-plan.md`. Broader functionality remains subject to review,
and none of this document describes shipped behavior.

The maintained architecture in `docs/engineering-handover.md` remains authoritative. Existing signing,
migration, account, and persistence decisions remain unchanged unless the approved MVP plan explicitly
adds a separate notification boundary.

## Reference Snapshot

The plan was prepared against:

- Stupid Wallet version `1.0.0` build `98`, minimum iOS 17, with multiple wallet groups and accounts.
- `stupid-app` `0.0.13`.
- Stupid Wallet Webhooks `main` commit
  `781843eb18093a391870dbe67a94d228ff834891`.
- The public API at `https://wallet-webhooks.stupidtech.net`.

The webhook service already detects one activity bundle per
`(chainId, transactionHash, trackedAddress)`, signs deliveries with HMAC-SHA256, retries at least once,
and emits compensating `activity.reverted` deliveries for shallow reorgs in current source. It does not
provide historical backfill, token metadata, prices, internal transfers, or guaranteed APNs delivery.

## Goals

- Notify a user when an explicitly enabled active wallet account has new supported onchain activity.
- Keep the backend address model ownership-neutral so a later watch-only feature can monitor addresses
  that are not wallet accounts without changing backend authentication or event identity.
- Use Stupid Wallet Webhooks as the upstream EVM activity detector rather than adding a second scanner.
- Keep every webhook API key, webhook signing secret, and APNs provider credential off the device.
- Authenticate the installation that owns notification settings without asking the backend to prove or
  infer ownership of each address.
- Let enrollment, token rotation, event synchronization, preference changes, and cleanup run without
  accessing a wallet key or presenting Face ID/passcode.
- Support multiple wallet accounts and multiple installations without changing wallet registry,
  home-account, connection-grant, signing, or Safari-profile authority.
- Treat APNs as a best-effort hint and provide an authenticated cursor feed for missed, delayed,
  reordered, or duplicate notifications.
- Preserve local wallet and account deletion when the network or backend is unavailable.
- Process shallow reorg compensation without conflating an orphaned observation with an EVM-reverted
  transaction.
- Keep push and backend state out of the canonical wallet registry.
- Minimize lock-screen disclosure by default.

## Non-Goals

- Using the backend for signing, transaction approval, key backup, key recovery, wallet synchronization,
  connection grants, RPC selection, or transaction broadcast.
- Giving the backend any seed phrase, private key, derived child key, keychain item, or
  LocalAuthentication output.
- Treating a push notification as proof that an event is canonical or finalized.
- Historical activity backfill before a subscription's activation block.
- Token images, portfolio values, internal traces, or ERC-1155 in the first implementation. Bounded
  fungible symbols, decimals, and public USD prices are used only to construct notification subjects.
- User-entered watch-only addresses in the first implementation. The architecture must permit this later
  without treating an address registration as an ownership, authorization, or identity claim.
- Proving address ownership to the notification backend.
- Requiring Sign in with Apple, email accounts, passwords, or a user-visible backend account.
- Giving the Safari extension the installation private key, event-feed access, enrollment mutation
  authority, or any broad backend credential. It may hold only a revocable capability that renews the
  unchanged liveness of an already-active installation after trusted popup use.
- Synchronizing notification preferences between independently installed devices.
- Exactly-once push delivery.

## Proposed Product Decisions

- Notifications are initially opt-in per active wallet account. Enabling an account covers every chain
  currently configured in `NetworkStore`; `includeInBalance` remains unrelated.
- The first app UI can select only accounts from the validated `WalletRegistry`; it does not accept an
  arbitrary address.
- The backend stores a canonical public address and never stores an ownership claim. Its protocol and
  event model deliberately also work for a future user-entered watch address.
- The app sends the backend a complete, revisioned inventory of configured chains whenever that
  inventory changes and during reconciliation.
- A chain remains staged until at least five distinct notification-capable installations report it as
  configured. It then becomes globally webhook-enabled and stays enabled unless an operator disables it.
- Adding or changing an account notification requires installation authentication only. It never
  releases an Ethereum key, creates an Ethereum signature, or presents a wallet-authentication prompt.
- Each installation owns a separate backend-authentication key that cannot sign Ethereum payloads.
- App Attest strengthens enrollment when supported but is not the only authentication mechanism.
- An iOS or iPadOS app running on Apple Silicon Mac may enroll without App Attest because Apple reports
  `DCAppAttestService.isSupported == false` for that environment.
- Removing a local wallet account removes its notification enrollment through the account cleanup
  outbox. A future explicit watch of the same address would be a separate local source and would retain
  the effective backend registration.
- Only installations with at least one enrolled account, current notification authorization, and an
  active APNs token contribute registrations or chain-staging counts.
- Explicit in-app disablement or a client-observed denied system authorization removes active backend
  state immediately. A permanent APNs token failure does the same for that token.
- APNs does not reliably report notification-setting changes or app deletion, so a renewable liveness
  window remains the fallback for installations that can no longer report cleanup.
- Opening the Safari toolbar popup triggers a coalesced liveness renewal for an already-active
  installation. Popup activity cannot create or revive an installation, change enrollment state, or
  extend the backend's freshness limit for the containing app's last notification-settings check.
- The backend enforces per-installation and global unique address-chain budgets and rejects new work
  before exhausting upstream capacity; existing registrations are not silently evicted to admit new ones.
- Final notification presentation uses the account blockie as a Communication Notification avatar, an
  enriched event subject describing what happened, and the message line `<account label> • <chain>`.
  The subject may disclose a rounded USD amount and bounded fungible asset symbol; categorical fallback
  copy remains available when public metadata resolution fails.
- The containing app fetches the authenticated event feed after launch, foregrounding, notification
  selection, and successful enrollment reconciliation.
- Remotely observed activity uses a separate local persistence model rather than forcing it into the
  current sender-centric `transactions` table.

## Terminology

### Installation

One installed copy of the containing app with one backend installation ID, one installation
authentication key, and at most one active APNs token for an APNs environment.

### Address registration

A server record directing one authenticated installation to receive activity for one public EVM address
on one or more explicit chains. In the first app release, every registration originates from an active
wallet account. The record does not assert address ownership and does not authorize signing, sending,
exporting, or changing wallet state.

### Account notification enrollment

An opt-in for one active wallet account. Its effective chain set is the installation's complete
configured-chain inventory intersected with globally webhook-enabled chains.

### Upstream subscription

One Stupid Wallet Webhooks subscription for one `(address, chainId)` routed to the backend's shared
webhook endpoint. Multiple installations may reference one upstream subscription.

### Installation event

One verified upstream activity observation made available to one installation through its cursor feed.
An APNs request is a best-effort notice that this event exists.

### Installation liveness window

A bounded server expiry renewed only while the app observes notification authorization, has an active
APNs token, and retains at least one account enrollment. Expiry deletes the installation, disables
fanout, removes it from chain-staging counts, and allows eventual upstream cleanup when no direct signal
is available.

### Popup liveness capability

A second P-256 key scoped only to extending the liveness of one existing installation without changing
any server state. It cannot create or revive an installation, update notification settings, replace an
APNs token, mutate addresses or chains, read events, or authenticate another route. The containing app
creates it in the existing shared keychain access group so the native Safari extension can use it when
the user opens the toolbar popup. The backend stores its public key and removes the association whenever
the installation is deleted.

### Configured-chain inventory

The complete revisioned set of chains in one installation's `NetworkStore`. It is independent of
`includeInBalance` and is replaced atomically on the backend rather than incrementally patched.

### Webhook chain stage

The server-owned state for one chain: `staged`, `enabling`, `active`, `unsupported`, `error`, or
`operatorDisabled`. A staged chain becomes active after five distinct eligible installations configure
it. Activation is sticky; falling below five later does not deactivate it.

## Trust Boundaries

### Containing app

The containing app remains authoritative for:

- The installation's desired account-notification enrollments.
- Local activity persistence and display.
- Whether an active wallet account should remain enrolled.

`WalletRegistry` remains authoritative for which accounts the first app UI may enroll. The backend does
not receive registry identity or use the registration as evidence of address ownership.

### Wallet backend

The new backend is authoritative only for:

- Installation authentication and replay prevention.
- Address-registration and account-enrollment state.
- Per-installation configured-chain inventories and global webhook chain stages.
- Mapping active address registrations to shared upstream subscriptions.
- Verifying upstream webhook deliveries.
- Persisting a bounded event feed.
- APNs fanout, retries, token invalidation, and operational state.

The backend cannot authorize or perform a wallet signature or transaction.

### Safari extension

The Safari extension remains outside enrollment, notification-settings, APNs-token, event-feed, and
wallet authority. A user-opened toolbar popup may send one coalesced request using the popup liveness
capability. The request can only extend the unchanged liveness of an existing installation within the
freshness ceiling established by the containing app's last signed notification-settings report. Page
JavaScript cannot invoke this path, and ordinary provider traffic, background-worker startup, popup
polling, and notification delivery do not count as popup use.

### Stupid Wallet Webhooks

The upstream service is authoritative for its scanner observation and reorg feed. Its customer API key
and webhook HMAC secret are backend-only credentials.

### APNs

APNs is an untrusted, best-effort delivery channel for notification hints. Delivery, order, and timing
are not correctness guarantees. Notification payloads do not mutate wallet state.

## System Architecture

```text
Stupid Wallet containing app
    |-- installation-authenticated API requests
    |-- active wallet-account addresses and configured-chain snapshot
    |-- APNs device-token registration
    v
Wallet Backend Worker
    |-- D1: installations, chain inventories/stages, addresses, events, cursors, outbox
    |-- Queue: upstream reconciliation
    |-- Queue: APNs fanout and retry
    |-- Secrets: upstream API key/HMAC secret and APNs provider key
    |
    | customer API                         signed webhook callback
    v                                      ^
wallet-webhooks.stupidtech.net ------------+
    |
    v
evm.stupidtech.net and supported EVM chains

Wallet Backend Worker -- authenticated APNs request --> Apple Push Notification service
Stupid Wallet containing app <-- best-effort push hint -- Apple Push Notification service

Safari toolbar popup -- narrowly scoped liveness capability --> Wallet Backend Worker
```

The preferred deployment is a separate Worker and domain, for example
`wallet-api.stupidtech.net`. Do not add mobile-installation authentication routes to the
customer-facing `/v1` API at `wallet-webhooks.stupidtech.net`.

## Authentication Design

### Why installation authentication is sufficient

- EVM addresses and their supported onchain activity are public data. Subscribing to an address does
  not require or imply control of its private key.
- An installation key proves continuity and authorization to mutate one installation's notification
  registrations, read its event feed, rotate its APNs token, and delete its backend state.
- The backend must never represent an address registration as proof of ownership or use it for signing, recovery,
  account access, or another privileged operation.
- App Attest, when available, indicates that enrollment came from a genuine copy of the app on genuine
  Apple hardware and helps control automated subscription abuse.

The APNs device token is a routing address, not an authentication credential.

### Installation authentication key

The containing app creates one P-256 signing key with these properties:

- Generated through Security and backed by Secure Enclave when available.
- Stored as a permanent application key with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- No `.userPresence` access control, because authenticated background reconciliation must not present
  UI or release the wallet key.
- Distinct key tag and service from every wallet key and seed item.
- Never shared with the Safari extension.
- Never exported; only its public key is sent to the backend.

The key signs backend requests only. The backend accepts P-256 signatures and has no code path that
interprets one as an Ethereum signature.

### Popup-triggered renewal authentication

Before installation creation, the containing app creates a second P-256 signing key through Security,
backed by Secure Enclave when available, and stores it as a permanent, non-synchronizable
`AfterFirstUnlockThisDeviceOnly` key in the existing shared app/Safari keychain access group under a
distinct tag. Installation creation associates its public key with the installation. It is not the
app-only installation P-256 key and grants no access to any other backend operation.

When the toolbar popup is opened by the user, popup-owned code asks the native Safari handler to send a
bounded liveness request. The WebExtension layer must accept the trigger only from the popup extension
page, never from page content, the isolated bridge, or an ordinary provider request. Coalesce repeated
popup refreshes locally and rate-limit them on the backend so one popup session does not generate a
renewal for every status poll.

The popup key signs a fixed canonical action, installation ID, random request ID, timestamp, and empty
body digest. The backend verifies that signature and replay window only when the installation already
exists and remains active. A successful request extends `liveness_expires_at` without modifying
addresses, chains, APNs state, notification settings, or event cursors, and never beyond
`notification_settings_valid_until`, which only a containing-app request signed by the app-only
installation key can advance. Deletion removes the popup public-key association transactionally. A stale
key cannot recreate a cleaned-up installation.

### Device-bound reinstall continuity

The installation key itself is the pseudonymous device-bound identifier. Store both its keychain
reference and the backend installation ID in a dedicated containing-app-only keychain access path with
non-synchronizable `ThisDeviceOnly` accessibility. The current entitlements do not provide that proven
app-only path, so its access group and profile authorization are an implementation gate. Do not use the
APNs token or
`UIDevice.identifierForVendor` as installation identity:

- APNs tokens are routing values and can change after reinstall, restore, device reset, system events,
  or OS updates.
- Apple documents that `identifierForVendor` changes after all apps from the vendor are removed and one
  is later reinstalled, and it can also change for development or ad hoc installs.
- A non-synchronizable `ThisDeviceOnly` key does not move through backup or iCloud to another device.

Current iOS releases commonly retain keychain items across uninstall and reinstall, allowing the
reinstalled app to sign a challenge, recover the existing backend installation identity, and register
its current APNs token while that active server record still exists. Active account enrollments can be
recovered only if they have not already been cleaned up. Once notification disablement, permanent token
invalidation, or liveness expiry deletes the server installation, later re-enable creates a new backend
installation even if the local key remains. Apple does not specify uninstall persistence as a Keychain
API guarantee, so this is best-effort continuity rather than an invariant. If either the key or
installation ID is missing, the app creates a new installation and the old one becomes inactive through
APNs invalidation or liveness expiry.

App Attest remains an installation-integrity signal, not the durable device identifier. If its key ID
does not survive reinstall, the retained P-256 installation key authenticates a bounded re-attestation
flow that associates a new valid App Attest key with the same installation.

For simulator tests, use a development-only software P-256 implementation against a separate local or
development backend. A production backend must reject the development trust namespace.

### Installation request signatures

Every authenticated request carries:

```text
x-wallet-installation: <installation id>
x-wallet-request-id: <UUID>
x-wallet-timestamp: <Unix milliseconds>
x-wallet-signature: v1,<base64url P-256 signature>
```

The signed bytes are one documented canonical byte sequence:

```text
v1\n
<UPPERCASE METHOD>\n
<path and canonical query>\n
<timestamp>\n
<request id>\n
<base64url SHA-256 of exact body bytes>
```

The client serializes the body once, hashes those exact bytes, signs the canonical sequence, and sends
the same body bytes. The backend verifies the signature, bounded clock skew, active installation state,
and single-use request ID. Request IDs are retained for at least the accepted replay window.

Concurrent valid requests may arrive out of order, so replay protection must not rely on a single
strictly increasing client counter.

### App Attest

Where `DCAppAttestService.isSupported` is true:

1. Generate one App Attest key per installation.
2. Request a server challenge.
3. Bind the installation ID and installation public-key hash into `clientDataHash`.
4. Send the attestation object to the backend.
5. Validate the Apple certificate chain, nonce, app identifier, key ID, environment, and receipt on the
   backend.
6. Store the attested public key, receipt metadata, and assertion counter.
7. Require valid attestation during installation creation and App Attest assertions for later sensitive
   operations under the approved enforcement policy.

App Attest verification is server-side only. It requires a focused Cloudflare Workers compatibility
spike for CBOR, X.509 chain validation, Apple's root, authenticator-data parsing, and P-256 verification.
Do not adopt an unreviewed package solely to shorten this step.

Unsupported App Attest is handled explicitly:

- Physical iPhone production: expected to be supported; an unexpected unsupported result is a risk
  signal and may block new enrollment after rollout evidence is complete.
- Apple Silicon Mac iOS compatibility app: installation-key authentication is accepted and recorded as
  `installation_key_only` under a separately rate-limited policy.
- Simulator: development backend only.
- Network or Apple service failure: retain the same App Attest key and challenge for a bounded retry;
  do not generate keys repeatedly.

### Installation key rotation

Ordinary rotation requires a valid request signed by the current installation key and binds the new
public-key hash into the signed body. If the key is lost, the app creates a new installation identity
and recreates its locally persisted account enrollments; the old installation expires through its
liveness window. App Attest, if supported, is repeated for the new installation identity.

There is no unauthenticated key-replacement endpoint.

## Backend API

All JSON bodies and responses are versioned and validated with Zod. Unknown versions and unknown enum
values fail loudly.

### Public bootstrap routes

```text
POST /v1/installations/challenge
POST /v1/installations
```

`POST /v1/installations/challenge` is unauthenticated but rate-limited. It accepts the canonical
installation public key and backend environment, then returns a provisional installation ID, challenge
ID, random nonce, server time, and expiry.

`POST /v1/installations` consumes that challenge and includes:

- Installation public key.
- Installation-key signature over the server challenge and canonical registration body.
- APNs environment and current token when available.
- App version and build metadata.
- Optional App Attest key ID and attestation object.

The response returns the installation ID, trust mode, liveness expiry, and initial event cursor. It
never returns an upstream API key, webhook secret, APNs provider credential, or wallet secret.

### Authenticated installation routes

```text
GET    /v1/installations/:installationId
PUT    /v1/installations/:installationId/push-token
PUT    /v1/installations/:installationId/notification-status
PUT    /v1/installations/:installationId/chains
DELETE /v1/installations/:installationId
POST   /v1/installations/:installationId/renew
POST   /v1/installations/:installationId/liveness
POST   /v1/installations/:installationId/key-rotation
```

Push-token updates replace the previous token atomically. Notification-status updates carry the exact
authorization and alert settings most recently observed through `UNUserNotificationCenter`. Store APNs
development and production tokens in separate backend environments; never try both APNs environments as
fallback.

The chains route replaces the installation's complete configured-chain set under a monotonic revision.
The backend rejects stale revisions and derives global distinct-installation counts from the canonical
rows. Incremental add/remove messages are not authoritative because one may be lost or reordered.

The renew request carries the complete bounded set of account addresses and configured chains the
installation still desires. It is accepted only when the client reports current notification
authorization and an active APNs token. It renews only that complete state, so an omitted registration
or chain expires even if an explicit delete was lost. Add/update/delete APIs still provide immediate
state changes and idempotent offline reconciliation.

The liveness route accepts only a valid popup-key signature and an idempotent request ID. It extends the
existing installation without accepting a desired-state body and without extending the containing
app's notification-settings freshness ceiling. Return success for duplicate request IDs, reject expired
or unrecognized key associations, and return not found after installation cleanup; never recreate state
from this route.

### Address-registration routes

```text
POST   /v1/installations/:installationId/addresses
GET    /v1/installations/:installationId/addresses
PUT    /v1/installations/:installationId/addresses/:address
DELETE /v1/installations/:installationId/addresses/:address
```

All address-registration operations require installation authentication. The backend validates a
canonical 20-byte EVM address, per-installation address quotas, and request size before creating upstream
work. It neither requests nor accepts an Ethereum signature. The initial app invokes these routes only
for active registry accounts; that client-side product restriction is not represented as a backend
ownership claim. Each enabled account is automatically expanded across the installation's configured
chains after the chain becomes globally active.

Create and update responses report each chain as `staged`, `enabling`, `active`, `unsupported`, or
`error`. An idempotency key makes a timed-out create or update safe to repeat.

### Event feed

```text
GET /v1/installations/:installationId/events?cursor=<opaque>&limit=<bounded>
```

The result contains ordered installation events plus an opaque next cursor. A cursor advances only
past events included in the response. A client may safely repeat a cursor after timeout.

The feed includes both `activity.observed` and `activity.reverted`. Event identity and state must be
unambiguous even when a compensating event references the same upstream observation.

### Internal upstream webhook route

```text
POST /internal/v1/wallet-activity
```

This route reads the exact body bytes before parsing, verifies the upstream timestamp and HMAC in
constant time, checks the replay window, and deduplicates the delivery transactionally.

It is not authenticated by installation credentials and is not exposed as a mobile API.

## Backend Persistence

Use D1 as the canonical control plane. Use migrations and `STRICT` tables. Logical tables are:

```text
installations
installation_challenges
installation_request_ids
popup_liveness_request_ids
app_attest_keys
installation_chains
webhook_chain_stages
installation_addresses
upstream_subscriptions
upstream_operations
activity_events
installation_events
apns_deliveries
```

### Installations

Important fields:

```text
id
public_key
public_key_hash
popup_liveness_public_key
popup_liveness_public_key_hash
trust_mode
status
apns_token_ciphertext
apns_token_hash
apns_environment
notification_authorization
notification_alert_setting
notification_settings_observed_at
notification_settings_valid_until
push_token_invalidated_at
app_version
app_build
liveness_expires_at
created_at
last_seen_at
revoked_at
```

APNs tokens are routing identifiers but are sensitive and linkable. Store a keyed hash for lookup and
an application-encrypted value for delivery. Never log the token.

An installation exists in backend persistence only while its latest reported settings permit the
selected alert presentation, its APNs token is active, at least one account is enrolled, and its
liveness window has not expired. Only such notification-capable installations contribute to chain
staging or address-registration reference counts. Explicit disablement of the last account,
client-observed loss of required notification authorization, permanent invalidation of the current APNs
token, or liveness expiry removes the installation and its active server state after idempotent upstream
cleanup; the backend does not retain a dormant credential record for later re-enable.

The popup liveness public key is not secret but remains installation-linked metadata. Verify its
signatures over the exact canonical request, apply per-installation and global rate limits, and delete it
with the installation. Bind popup liveness request IDs to the installation and retain them only for the
idempotency window.

### Installation chains

Use one row per `(installationId, chainId)` plus a per-installation inventory revision. A complete signed
snapshot replaces all rows atomically. Chain names, RPC URLs, custom RPC state, and
`includeInBalance` are not uploaded.

### Webhook chain stages

Use one row per chain with:

```text
chain_id
eligible_installation_count
status
activated_at
operator_disabled_at
last_error
updated_at
```

Count distinct notification-capable installations, not addresses or wallet accounts. When the count
first reaches five, atomically transition `staged` to `enabling` and enqueue chain activation work.
Successful capability checks make the stage `active`; unsupported or failed checks remain visible.
Once active, a chain remains active when the count later falls below five unless an operator explicitly
disables it.

### Installation addresses

Important fields:

```text
installation_id
address
chain_id
status
created_at
renewed_at
revoked_at
```

Use one row per effective `(installationId, address, chainId)` derived from enrolled account addresses,
the installation's configured-chain inventory, global chain stage, active APNs token, notification
settings, and liveness state. Address identity is case-insensitive and stored canonically. Account
labels, future watch labels, wallet-group IDs, derivation indexes, home selection, ownership claims, and
Safari grants are not uploaded.

### Upstream subscriptions and outbox

Use one row per `(address, chainId)` with:

```text
ref_count
upstream_subscription_id
status
active_from_block
last_error
updated_at
```

Changes to address registrations and the corresponding `upstream_operations` outbox entry commit in one D1
transaction. A queue consumer applies create/delete operations to Stupid Wallet Webhooks. A scheduled
reconciler retries unapplied operations and compares local desired state with upstream state.

An upstream API failure does not roll back a valid address registration. The registration reports `pending`,
`active`, `unsupported`, or `error` until reconciliation converges.

### Activity events

Store the verified upstream event using a stable local identity that distinguishes transition type.
The current upstream source uses the same observation ID and `webhook-id` header for
`activity.observed` and `activity.reverted`, while its delivery ledger distinguishes event type.
Before launch, do one of:

1. Change upstream delivery IDs and documentation so every transition has a distinct webhook delivery
   identity while retaining the referenced observation ID in the body.
2. Define backend uniqueness as `(upstreamWebhookId, eventId, eventType)` and update public upstream
   documentation that currently says to deduplicate only on `webhook-id`.

The preferred fix is distinct delivery identity plus explicit `observationId`, because it lets generic
webhook consumers follow the documented header-only deduplication rule.

### Installation events

Create one row per matching active installation address. Its payload is a versioned projection of the
verified upstream event, not arbitrary APNs content. Keep enough history to recover from missed pushes
and ordinary offline intervals. Retention is a product decision and must be stated before launch.

## Stupid Wallet Webhooks Integration

Provision one dedicated production account and one shared webhook endpoint. The account API key and
one-time signing secret are stored only as Worker secrets.

The backend calls:

```text
POST   /v1/subscriptions
GET    /v1/subscriptions
DELETE /v1/subscriptions/:subscriptionId
GET    /v1/chains/:chainId
GET    /v1/webhook-deliveries
```

### Chain staging and activation

The backend maintains two separate chain concepts:

- **Configured on installation:** present in that installation's latest complete `NetworkStore`
  snapshot.
- **Webhook active:** the chain has previously reached five distinct notification-capable
  installations, passed upstream capability resolution, and has not been operator-disabled.

For an enrolled account, the effective notification chains are all configured installation chains that
are webhook active. There is no separate per-account chain picker in the first implementation.

When a configured chain is added or restored, the app increments its local inventory revision and queues
a complete signed snapshot. When a chain is removed, the next snapshot omits it. The backend replaces
the installation mapping transactionally, recalculates affected distinct-installation counts, and
creates or removes that installation's effective address registrations. Lost or reordered snapshots
cannot resurrect a removed chain because stale revisions fail.

A chain below five eligible installations remains `staged`; account settings show it as configured but
not yet available for activity notifications. The fifth eligible installation triggers one idempotent
activation operation. After successful activation, all eligible enrolled accounts on installations that
have that chain configured become effective subscription references. Activation is sticky to avoid
threshold flapping; later count reductions remove only no-longer-desired installation/address
references, not global chain eligibility.

Requirements before production use:

- Increase the dedicated account's subscription quota beyond the default 1,000 based on the rollout
  cap. Four chains consume four upstream subscriptions per unique address.
- Keep the first product chain set within the 20-distinct-chain account quota, or approve an operator
  override.
- Verify the deployed service matches the inspected source commit and that `activity.reverted` is live
  end to end. Current source wires reverted delivery from `ScannerShard`, while older implementation
  notes still describe it as deferred.
- Resolve the observed/reverted webhook identity contract described above.
- Monitor scanner lag, upstream delivery latency, dead letters, and unsupported chains.
- Display that enrollment starts at the subscription activation block and does not backfill history.

Do not create one upstream webhook per device. One shared endpoint plus backend fanout keeps upstream
subscriptions and signing-secret management bounded.

## APNs Delivery

### Provider authentication

Store the APNs `.p8` private key, key ID, and issuer/team ID as backend secrets. Generate short-lived
ES256 provider JWTs and send with:

```text
apns-topic: co.za.stephancill.stupid-wallet
apns-push-type: alert
authorization: bearer <provider JWT>
```

Development builds use `api.sandbox.push.apple.com`. TestFlight and App Store builds use
`api.push.apple.com`. Environment mismatch fails loudly and never triggers a cross-environment retry.

### Payload

The server payload is deliberately small and requests Notification Service Extension processing:

```json
{
  "aps": {
    "mutable-content": 1,
    "alert": {
      "title": "Received $5 of USDC",
      "body": "Open stupid wallet to view activity."
    },
    "thread-id": "<opaque address thread>"
  },
  "eventId": "<backend installation event id>",
  "addressRegistrationId": "<opaque installation-scoped id>",
  "chainId": "<decimal chain id>",
  "eventKind": "<bounded event classification>",
  "subject": "<bounded enriched subject or categorical fallback>",
  "schemaVersion": 1
}
```

The final presentation is:

```text
avatar:       account blockie
title:        <enriched action subject>, or categorical fallback
message line: <account label> • <chain>
```

The standard app icon remains present. The blockie is supplied locally as the Communication
Notification sender image, not sent by APNs.

Add a containing-app Notification Service Extension. It receives the bounded payload, resolves the
opaque registration ID against shared local notification state, obtains the local account address and
label, resolves the chain name from local network metadata, generates the existing deterministic
blockie locally, and creates an incoming `INSendMessageIntent`. It keeps the subject action-only and puts
account/chain context in both intent content and notification body. The
extension receives no
installation private key, wallet key, seed, backend credential, full address from APNs, or signing
authority.

The backend validates the event classification, resolves fungible symbol/decimals/USD price from
DeFiLlama through a 10-minute D1 cache, and constructs a subject. Priced bidirectional effects become a
swap summary; otherwise the highest-value priced leg becomes `Received/Sent <$value> of <symbol>`.
Failed resolution, reorgs, and transaction failures retain the categorical title. If the service
extension times out or local mapping is unavailable, iOS displays the same action-only backend subject
from the original payload.

Do not put a full address, raw calldata, signature, token contract, counterparty, account label, or
backend credential into the base APNs payload. The approved enriched subject is the narrow exception for
a rounded USD amount and bounded asset symbol. Any later detailed preview mode requires an explicit
privacy review.

Use an opaque thread identifier rather than the registered address. Do not collapse separate activity
events into one APNs collapse identifier in the first implementation.

### APNs retries and invalidation

- Treat APNs success as acceptance, not proof of display.
- Retry network failures, 429, and 5xx with bounded exponential backoff.
- Respect bounded retry hints.
- On `410 Unregistered`, stop sends immediately and delete the installation through the same idempotent
  cleanup path used by explicit disablement. Apply a response only if it refers to the currently active
  token version; a delayed failure for a replaced token must not invalidate its replacement. Use the
  response timestamp as additional ordering evidence where the APNs client exposes it.
- Treat `BadDeviceToken` and `DeviceTokenNotForTopic` as non-retryable token/configuration failures. Clear
  the unusable current token through the same conditional cleanup path, alert operations, and do not
  reinterpret either response as proof of app deletion or notification disablement. An expired APNs
  provider authentication token is a provider-credential failure and must never delete device state.
- Do not use APNs `200` as proof that the notification reached or was displayed by the device.
- Retain APNs delivery metadata without retaining secret-bearing request headers.

### Notification settings and cleanup signals

The plan relies on the containing app reading notification authorization and presentation settings
through `UNUserNotificationCenter.notificationSettings()`. APNs does not provide a reliable server-side
signal that the user turned notifications off. In particular, disabling notifications does not
necessarily change the device token or cause a `410`, and Apple states that `410` is token invalidation
rather than an uninstall signal.

A user-opened Safari toolbar popup is a positive installation-activity signal and triggers a scoped
liveness renewal. It is not evidence that notification authorization remains enabled. The backend
therefore caps popup renewal at `notification_settings_valid_until`; only a containing-app settings
check authenticated by the P-256 installation key advances that ceiling.

Use cleanup signals in this order:

1. Explicit in-app disablement sends an authenticated delete and clears active backend registrations.
2. On launch and foreground entry, the app reads current notification settings. If the required alert
   authorization is unavailable, it reports the state and deletes active registrations.
3. A permanent APNs response for the current token deletes the installation and removes it from active
   counts and fanout.
4. The liveness window deletes state when the app is deleted, never foregrounds after a Settings change,
   loses network access permanently, or receives no activity capable of producing an APNs failure.

Only a currently notification-capable installation is counted toward the five-installation chain gate.
After cleanup, no server-side installation credential, APNs token, address reference, chain-count
contribution, or pending fanout remains. A locally retained P-256 key is not backend tracking; later
re-enable performs fresh installation creation.

### Background delivery

Correctness does not depend on silent pushes or background execution. The event feed converges when the
app next runs. A later content-available optimization must be separately tested against iOS delivery
limits and must not replace the cursor feed.

## Containing-App Integration

### App entry and notification delegate

Add an app-only notification coordinator and `UIApplicationDelegateAdaptor` at
`Sources/StupidWallet/StupidWallet.swift` to own:

- Notification authorization state.
- APNs registration callbacks and token changes.
- Foreground presentation policy.
- Notification selection and deep-link routing.
- Triggering authenticated event reconciliation.

Do not put APNs callbacks in `StupidWalletSafari`.

### User flow

Add a Notifications destination under Settings for the current home-selected account. The first flow:

1. Explain supported activity, no-backfill behavior, privacy implications, and the planned notification
   presentation.
2. Display the exact active registry account that will be enrolled.
3. Explain that enrollment covers every chain configured in Networks; staged chains are not active until
   the global five-installation gate is met.
4. Request system notification authorization only after the explicit user action.
5. Register with APNs.
6. Create or load the installation authentication key and installation ID from the app-only keychain,
   then register or recover the backend installation.
7. Attest or re-attest when supported under the approved policy.
8. Send the complete configured-chain inventory and create the account address registration through
   installation authentication.
9. Display per-chain `staged`, `enabling`, `active`, `unsupported`, or `error` state.

No step releases a wallet key or presents a wallet-signing confirmation. Home selection chooses which
account's notification settings are displayed; switching home accounts does not mutate another
account's enrollment.

### Local notification state

Add a versioned, atomic `NotificationRegistrationStore` in `StupidWalletCore`, separate from
`WalletRegistry`, containing only non-secret state:

```text
installation public-key hash
APNs environment
APNs token hash
last observed notification authorization and alert settings
account notification enrollments
local enrollment source kind and stable wallet account ID
configured-chain inventory revision and last acknowledged snapshot
pending reconciliation operations
last successful reconciliation
last public-safe error
```

The installation private key and backend installation ID remain in non-synchronizable `ThisDeviceOnly`
app-only keychain items so current iOS behavior can provide best-effort reinstall continuity. The APNs
token may remain in app memory/keychain as required for registration but must not be written to public
logs or documentation.

The store may live in the App Group because `WalletCore` owns durable stores, but the Safari extension
never reads it. The popup liveness private key is held separately in the shared keychain and is the only
backend credential available to the Safari extension.

Persist the event cursor with observed activity in SQLite so applying one validated feed page and
advancing its cursor remain one transaction.

### Registry reconciliation

Run notification reconciliation only after `WalletRegistryAdoption.ensureAdopted()` returns a complete
registry. Reconcile:

- On successful initial app load.
- After account or group creation and deletion.
- After notification enrollment changes.
- After every `NetworkStore` add, record, restore, or remove operation.
- After APNs token changes.
- On app foregrounding.
- After authenticated backend responses indicate stale registration.
- On a user-opened Safari toolbar popup, through the separate capability-scoped liveness route. This
  trigger extends unchanged liveness only; it does not run registry reconciliation from the extension.

The desired set is every explicitly enrolled active wallet account crossed with every configured chain,
not only `homeSelectedAddress`. Account identity remains local; the backend receives only canonical
addresses and decimal chain IDs. `includeInBalance` changes do not alter the configured-chain inventory.

Every synchronization sends the complete normalized chain-ID set with a monotonic local revision. The
server response returns the accepted revision and stage for each chain. The app retains an outbox entry
until that exact revision is acknowledged, so interrupted add/remove operations converge.

### Notification disablement and account deletion

Disabling notifications writes an idempotent backend-delete operation to the notification outbox and
removes the account from desired notification state. If the backend is unavailable, the outbox survives
and the server liveness window eventually expires. Historical observed activity follows the
approved retention policy and is not silently erased.

When account deletion starts:

1. Mark the local account inactive through the existing registry lifecycle.
2. Remove its wallet-account notification source and add idempotent backend-delete operations for its
   effective configured chains when no other local source requires each `(address, chainId)`.
3. Continue existing pending-request, connection, cache, secret, and registry cleanup.
4. Attempt backend reconciliation after local deletion succeeds.

Network cleanup never blocks secret deletion or final registry removal. The source-aware local model is
the compatibility seam for a future explicit watch: deleting an account would remove only its
`walletAccount` source, while a later `watchedAddress` source for the same address could retain the
effective backend registration. The first implementation creates only `walletAccount` sources.

### Future watch-only extension

User-entered watch addresses are deferred. The first implementation must not add an address-entry UI,
no-wallet watch flow, watch labels, or watch-specific navigation. It preserves this later extension by:

- Keeping backend authentication installation-based and address ownership-neutral.
- Keying backend registrations and events by canonical `(address, chainId)` rather than wallet-group or
  account IDs.
- Keeping local enrollment sources distinct from the effective deduplicated backend registration.
- Keying observed activity by tracked address, chain, transaction, and observation identity.
- Never requiring an Ethereum signature merely to receive public activity.

A future implementation can add a `watchedAddress` local source and UI while reusing the backend API.
When a wallet-account source and watched-address source overlap, the app sends one effective backend
registration and removes it only after the final local source is removed.

### APNs token lifecycle

Register with APNs on every appropriate app launch after notification opt-in. Apple may return a new
token. Compare its keyed/local hash and update the backend through installation authentication when it
changes. Do not cache one token as a permanent device identity.

## Remote Activity Persistence

### Why the existing transaction table is insufficient

`ActivityStore` currently assumes locally initiated wallet activity:

- `transactions.tx_hash` is globally unique without chain or tracked-account identity.
- `from_address` is used as the account-scoping field.
- `app_id` and origin are required.
- One transaction can involve two separately enrolled wallet accounts and therefore produce two upstream
  bundles.
- The same hash is not a safe cross-chain identity.
- `ActivityStatus.reverted` already means failed EVM execution, not an orphaned block.

Forcing incoming observations into this table would either lose one tracked-account view, invent a
dapp origin, or overwrite locally submitted metadata.

### Separate observed activity table

Add a separate table, for example `observed_activity`, keyed by the backend event/observation identity
and constrained by `(chain_id, transaction_hash, tracked_address, block_hash)`.

Do not upsert remote observations directly into the existing `transactions` table. That table's shipped
contract has global `tx_hash` uniqueness, a required dapp `app_id`, and sender-account scoping. Safely
sharing it would require a table rebuild and would still combine remote observation/reorg state with
local submission lifecycle. Keeping `observed_activity` separate preserves installed rows and lets query
code merge a matching local and remote record without either store overwriting the other's authority.

Persist typed fields needed for rendering and reconciliation:

```text
event_id
observation_id
chain_id
tracked_address
block_number
block_hash
block_timestamp
transaction_hash
transaction_from
transaction_to
transaction_status
transaction_nonce
transaction_value
initiated_by_tracked_address
effects_json
observation_state
created_at
updated_at
```

`observation_state` is `observed` or `reorged`. Transaction execution status remains `success` or
`reverted`. These states must never share one enum value.

Validate all addresses, hashes, quantities, enum values, and effect shapes before persistence. Preserve
raw uint256 values as strings.

### Local and remote merge

Account Activity queries merge local transactions, local signatures, and observed activity for enrolled
registry accounts. When a local transaction and an observed sender bundle have the same chain, hash,
and tracked address:

- Render one logical activity row.
- Preserve local request ID, origin, profile, calldata, call-bundle ID, and signing metadata.
- Enrich it with upstream effects and block observation state.
- Never let a remote payload replace canonical local request data with missing or conflicting values.

Incoming activity without a local transaction remains a network-observed account row and has no dapp
origin or Safari profile. The schema uses tracked-address identity rather than requiring wallet-only
metadata, preserving compatibility with a future watch-only activity surface.

### Feed ingestion

On reconciliation:

1. Authenticate the event-feed request with the installation key.
2. Fetch from the last durable cursor.
3. Validate the complete response and enrolled-account address membership.
4. Persist events and the next cursor atomically, or persist neither.
5. Apply reorg transitions idempotently.
6. Refresh visible activity.

An event for an address that is no longer enrolled may complete a previously fetched page but must not
recreate a notification enrollment or wallet account. It may be retained only under the approved
historical-retention policy.

## Failure And Recovery Policy

### Backend unavailable

- Existing wallet, Safari, signing, RPC, balance, and local activity behavior remains available.
- Notification settings show an actionable unavailable state.
- Local desired state and cleanup operations remain durable.
- Reconciliation retries on later foreground entry with bounded backoff.

### Upstream subscription unavailable

- Address registration remains valid.
- Per-chain enrollment state reports pending, unsupported, or error.
- Do not claim notifications are active until upstream returns an activation block.

### APNs unavailable or denied

- Backend address registrations may remain disabled locally or be removed according to explicit user choice.
- The event feed may be used for foreground synchronization only if the user kept notifications enabled.
- Denied system authorization never triggers repeated system prompts.

### Lost installation key

- Do not accept unsigned recovery.
- Create a new installation identity.
- Recreate the new installation's account enrollments from local desired state.
- Let the old installation liveness window expire; do not provide unauthenticated access to its feed or
  state.

### Clock skew

- Backend responses include server time.
- Request signatures use a bounded skew window.
- A rejected skew response may adjust the request timestamp once using server time; it does not disable
  replay checks.

### Duplicate and reordered delivery

- Upstream webhook ingestion is idempotent.
- APNs may duplicate or reorder notifications.
- The cursor feed and local event identity provide convergence.

### Reorg

- Persist a compensating reorg transition even if its original push was not displayed.
- A reorg push may use generic text or no visible alert; the next feed synchronization must still
  update local state.
- Never translate a reorg into transaction execution status `reverted`.

## Privacy And Security Requirements

- Never upload wallet labels, future watch labels, seed identities, derivation indexes, connected sites, Safari
  profile IDs, signing requests, balances, RPC overrides, or private keys.
- Never log APNs tokens, installation signatures, App Attest objects, complete addresses tied to an
  installation, or complete event payloads in ordinary logs.
- Treat the installation-to-address mapping as sensitive even though addresses are public.
- Never present a backend address registration as evidence that the user owns, controls, or is affiliated
  with the address.
- Encrypt APNs tokens at the application layer and keep encryption keys in Worker secrets.
- Keep D1, queue, and API payloads versioned and Zod-validated.
- Use constant-time comparison for webhook HMACs and fixed-format parsing for installation signatures.
- Rate-limit installation creation by network source, installation key hash, APNs token hash, App Attest
  identity where supported, and backend environment.
- Enforce hard per-installation registered-address and address-chain limits before creating upstream work.
- Enforce a global unique address-chain admission budget, queue-depth limits, and an operator circuit
  breaker that can reject new registrations without interrupting existing wallet or event-feed behavior.
- Use App Attest as an anti-automation signal where supported, but retain server-side quotas because
  attestation does not eliminate abusive genuine devices.
- Keep challenge expiry short and challenges single-use.
- Store only public-safe, bounded error descriptions.
- Define event and address-registration retention before launch and expose it in product privacy documentation.
- Support explicit account-notification disablement and complete installation-backend deletion from the app.
- Do not use remote data in signing, approval, key migration, connection grants, RPC override selection,
  or account lifecycle authority.

## Entitlements And Signing Tooling

The containing app currently declares no push or App Attest entitlement. The Safari extension should
not gain either capability. The blockie thumbnail requires a new bundled Notification Service Extension
with its own bundle identifier and App Group access, but no push, App Attest, or keychain-sharing
entitlement.

Required app capabilities include:

```text
Push Notifications
App Attest, when adopted
```

Required source/runtime work includes:

- APNs entitlement handling for development and distribution.
- App Attest environment handling for development and production.
- Notification authorization usage and delegate code.
- Notification Service Extension packaging, shared blockie rendering, and App Group access.
- Optional `UIBackgroundModes` only if a later tested silent-push design requires it; it is not needed
  for the correctness model in this plan.

`stupid-app 0.0.13` currently enables only App Groups and AutoFill Credential Provider from source
entitlements. It passes other source entitlements through profile authorization but does not derive
environment-specific values such as `aps-environment`. Before the wallet adds environment-valued
entitlements, update `stupid-app` to:

- Recognize and enable the App Store Connect `PUSH_NOTIFICATIONS` bundle capability.
- Verify the correct App Attest capability setup path supported by App Store Connect or document the
  required manual portal step.
- Derive or reconcile `aps-environment` correctly for development versus distribution profiles.
- Derive or reconcile the App Attest environment without signing a development value into TestFlight.
- Preserve the open entitlement pass-through and fail loudly when the profile does not authorize a
  requested capability.
- Derive requested capabilities per bundle rather than unioning every app/extension entitlement onto
  every configured bundle ID; Push Notifications belongs only to the containing app.
- Add profile, native-signature, archive, and release tests for both environments.

The tracked `Mac/` Xcode compatibility project compiles the same app source but has separate project and
entitlement configuration. Update and verify it packages the Notification Service Extension for local
Apple Silicon Mac testing without making it a second release authority.

## Implementation Gates

### Gate 0: Approve Product And Privacy Decisions

Work:

- Review and approve or revise this draft.
- Choose the production backend domain.
- Choose hard address-registration quotas and the liveness-window duration.
- Approve a separate notification-content specification for event titles, amount/asset disclosure,
  localization, reorg copy, and fallback presentation.
- Approve App Attest enforcement behavior after its platform spike.

Exit conditions:

- This plan and `docs/engineering-handover.md` agree on approved scope and trust boundaries.
- Privacy disclosure and retention decisions are explicit.
- No open decision can change API or persisted identity beneath a later gate.

### Gate 1: Upstream Contract And Provisioning

Work:

- Resolve observed/reverted webhook delivery identity and documentation.
- Verify reverted fanout on the deployed service with a controlled reorg.
- Provision a dedicated backend customer account, API key, and shared webhook.
- Increase subscription and chain quotas for the bounded rollout.
- Add backend-safe delivery-ledger monitoring.

Exit conditions:

- Exact-body HMAC verification passes independent vectors.
- Duplicate observed and reverted deliveries converge correctly.
- A controlled shallow reorg produces the expected compensating backend event.
- No upstream credential exists in app source, app resources, logs, or build artifacts.

### Gate 2: Signing-Tool And Capability Foundation

Work:

- Add Push Notifications capability support to `stupid-app`.
- Add the reviewed App Attest capability/environment path.
- Regenerate development and distribution profiles.
- Add app-only entitlements and runtime imports.
- Add and package the Notification Service Extension with App Group access only.
- Update the local Mac compatibility entitlements.

Exit conditions:

- `stupid-app doctor` reports no capability or profile failure.
- Development artifacts contain the sandbox APNs environment.
- TestFlight/archive artifacts contain the production APNs environment.
- App and extension marketing/build versions remain in lockstep.
- The Safari extension does not contain push or App Attest entitlements.
- The Notification Service Extension contains neither push nor wallet keychain entitlements and can read
  only the local display mapping required to render content.

### Gate 3: Backend Authentication

Work:

- Scaffold the separate Cloudflare Worker, D1 migrations, and environment separation.
- Implement challenge creation and consumption.
- Implement installation P-256 request verification and replay storage.
- Implement installation creation, address-registration CRUD, quotas, liveness, and key rotation.
- Register, verify, rate-limit, and remove the capability-scoped popup liveness public key.
- Implement keychain-identity challenge recovery and bounded App Attest re-attestation after reinstall.
- Complete the App Attest server-validation spike and implement the approved enforcement policy.

Exit conditions:

- Invalid-address, changed-public-key, expired, replayed, mutated-body, and over-quota requests fail.
- Backend protocol tests can register an address without an ownership proof, but one installation cannot
  read or mutate another installation's registrations or feed.
- No backend operation requires or accepts an Ethereum signature.
- Mac installation-key-only enrollment follows the explicit policy and separate rate limits.
- Production rejects simulator/development trust artifacts.
- Per-installation and global admission limits fail deterministically without partially creating a
  registration or upstream operation.
- A retained installation key recovers the same backend identity, while a missing key creates a new one
  without trusting `identifierForVendor` or an APNs token as identity.
- Popup-key requests can extend only an existing installation, cannot exceed notification-settings
  freshness, and cannot access or mutate any other resource.

### Gate 4: Upstream Reconciliation And Event Feed

Work:

- Implement reference-counted `(address, chainId)` desired state.
- Implement revisioned complete per-installation chain inventories.
- Implement distinct eligible-installation counting and sticky activation at five installations.
- Implement transactional upstream outbox and queue consumer.
- Implement scheduled reconciliation and operator visibility.
- Implement signed webhook ingestion, deduplication, event fanout, and cursor feed.
- Implement installation liveness expiry and upstream reference cleanup.

Exit conditions:

- Multiple installations for one address/chain produce one upstream subscription.
- Four eligible installations leave a chain staged; the fifth triggers one idempotent activation.
- Multiple accounts on one installation count once, and falling below five after activation does not
  deactivate the chain.
- A stale chain snapshot cannot resurrect a chain removed from `NetworkStore`.
- Removing one installation address registration retains the subscription while another reference exists.
- Last-reference removal eventually deletes the upstream subscription.
- Partial D1/queue/upstream failures reconcile without negative reference counts or lost desired state.
- High-fanout activity and queue pressure remain bounded, and the circuit breaker prevents new unique
  upstream subscriptions while preserving existing registrations.
- Feed cursors replay safely after timeout and preserve observed/reorg ordering.

### Gate 5: APNs Delivery

Work:

- Configure APNs provider credentials as Worker secrets.
- Implement provider JWT generation, APNs queue consumer, retries, and token invalidation.
- Implement bounded mutable payloads and the approved event-title mapping.
- Implement Notification Service Extension subtitle and blockie attachment rendering.
- Add delivery metrics without sensitive logging.

Exit conditions:

- Development pushes reach a physical development installation through sandbox APNs.
- TestFlight pushes reach the production APNs token for the production bundle topic.
- Wrong-environment tokens fail without fallback.
- Duplicate queue messages do not create duplicate backend event records.
- APNs `410`, `429`, and 5xx behavior is deterministic and tested.
- Permanent token invalidation stops fanout and chain-count contribution immediately without being
  misreported as proof of uninstall or disabled settings.
- The final notification uses a blockie thumbnail and `<account label> • <chain>` subtitle when local
  display state is available, and a reviewed generic fallback when extension processing fails.

### Gate 6: Containing-App Enrollment And Reconciliation

Work:

- Add the notification delegate/coordinator.
- Add installation-key storage and request signing.
- Add the shared-keychain popup liveness capability store and popup-owned renewal trigger.
- Add `NotificationRegistrationStore` and outbox.
- Add Settings UI for the current active wallet account, all-configured-chain behavior, content privacy,
  and per-chain stage/status.
- Add App Attest client behavior where supported.
- Reconcile after account lifecycle changes, enrollment changes, every network add/remove/restore,
  notification-setting checks, token changes, installation recovery, foregrounding, and user-opened
  Safari toolbar popup activity.

Exit conditions:

- System permission is requested only after explicit user action.
- An active wallet account can enable and disable notifications across all configured chains.
- Enrollment and APNs token changes perform no wallet-key read, Ethereum signature, or biometric prompt.
- Home-account switching does not alter another account's enrollment.
- Multiple active accounts retain independent notification enrollment while sharing the installation's
  configured-chain inventory.
- A network addition/removal converges to the same complete server chain set after retries.
- Client-observed denied notification authorization removes active server registrations.
- Opening the toolbar popup renews unchanged liveness once per coalescing interval without accessing the
  installation key, reading the event feed, or mutating enrollment.
- Safari request handling and signing behavior are unchanged.

### Gate 7: Observed Activity And Deep Linking

Work:

- Add the separate observed-activity schema and strict migration; do not rebuild or directly upsert into
  the shipped `transactions` table.
- Implement feed validation, atomic cursor persistence, and reorg transitions.
- Merge local and observed rows for display without overwriting local canonical metadata.
- Route notification selection to the matching activity when available.

Exit conditions:

- Incoming native, ERC-20, ERC-721, outgoing, self, zero-value, and EVM-reverted activity render with
  correct tracked-address direction.
- One transaction involving two enrolled accounts creates two account views without collision.
- A locally submitted transaction plus remote observation renders once with retained local metadata.
- The same hash on two chains does not collide.
- Reorged activity is distinct from EVM-reverted execution.
- A missed push is recovered from the cursor feed.

### Gate 8: Account Lifecycle And Failure Acceptance

Work:

- Integrate notification cleanup and outbox recovery into account/group lifecycle deletion.
- Add liveness-expiry and stale-installation operational tests.
- Exercise backend, upstream, and APNs outages.
- Verify Apple Silicon Mac behavior.

Exit conditions:

- Offline account and group deletion completes locally and queues remote notification cleanup.
- Relaunch resumes local cleanup and backend reconciliation.
- Installation liveness expiry stops events for an abandoned installation.
- Another installation for the same address remains active.
- Account deletion removes only its wallet-account notification source and does not preclude a future
  independent watch source for the same address.
- Mac enrollment, event sync, and push behavior follow the approved support policy.
- No backend failure blocks wallet startup, signing, export, migration, or deletion.

### Gate 9: Bounded Production Rollout

Work:

- Enable the feature for a bounded TestFlight cohort.
- Monitor upstream lag, webhook delivery, event-feed latency, APNs responses, liveness churn, and
  D1/Queue cost.
- Confirm privacy text and support diagnostics.
- Exercise disablement and complete backend data deletion.

Exit conditions:

- The bounded cohort meets the approved delivery and reliability objectives.
- Cost per active address-chain and installation is measured.
- Operators can distinguish upstream lag, webhook failure, backend fanout failure, APNs rejection, and
  device-side sync failure without sensitive logs.
- A rollback can stop new enrollment and APNs fanout without affecting wallet operation.

## Test Matrix

### Authentication

- Valid installation enrollment for an active wallet account without an Ethereum signature.
- Mutated installation ID, public-key hash, timestamp, challenge, or registration body.
- Consumed and expired installation challenge.
- Replayed installation request ID.
- Mutated exact body bytes after signing.
- Concurrent installation requests arriving out of order.
- Authorized and unauthorized installation-key rotation.
- Reinstall with retained P-256 key/installation ID and reinstall with either item missing.
- Changed `identifierForVendor` has no effect on backend identity.
- Cross-installation registration and feed access.
- Invalid address, duplicate registration, and quota exhaustion.
- App Attest development/production mismatch.
- App Attest unsupported Mac policy.
- Valid, invalid, cross-installation, stale, and removed popup liveness key associations.
- A popup-key signature cannot call enrollment, token, chain, address, event-feed, or deletion routes.

### Subscription lifecycle

- One installation, one address, one chain.
- One installation, multiple wallet accounts and chains.
- Hermetic backend registration for an arbitrary address without claiming ownership, while the app UI
  exposes no arbitrary-address entry.
- Multiple installations sharing one address/chain.
- Removing one and the last reference.
- Unsupported chain and later retry.
- Upstream quota response.
- D1 commit followed by queue failure.
- Upstream create followed by response loss.
- Liveness renewal, expiry, and explicit revocation.
- Popup renewal extends an active installation within the settings-freshness ceiling, but cannot revive a
  deleted installation or advance stale notification authorization.
- Complete chain-inventory replacement with stale, duplicate, missing, and reordered revisions.
- Four-to-five installation activation, multiple accounts counting once, and sticky eligibility below five.
- Configured chain removal deletes only that installation's effective references.

### Webhook and event feed

- Exact-body HMAC vectors.
- Timestamp outside replay tolerance.
- Duplicate observed delivery.
- Observed then reverted delivery for one observation.
- Reorg followed by the same transaction in a new block.
- Feed pagination, repeated cursor, and interrupted response.
- Event retained while APNs is unavailable.
- Event for two enrolled accounts in one transaction.
- Remote observation persists separately from a matching local transaction and query merging renders one
  logical row without overwriting either record.

### APNs

- Token registration and rotation.
- Development and production endpoint separation.
- Blockie attachment, event title, local account-label/chain subtitle, and extension-timeout fallback.
- User denial and later Settings enablement.
- APNs success, bad token, unregistered token, rate limit, and server failure.
- APNs `200` does not mark an event delivered or displayed.
- Disabled system authorization produces no assumed APNs failure signal; foreground reconciliation
  reports it, while a dormant installation expires through liveness.
- Permanent token invalidation immediately removes active fanout and chain-count contribution.
- Duplicate and reordered pushes.
- Notification selection before and after local event synchronization.

### Wallet regression

- Dawn migration before notification reconciliation.
- Multiple wallet groups and derived accounts.
- Home-account switching.
- Safari connect and protected signing.
- One user-opened toolbar popup produces at most one renewal per coalescing interval; page messages,
  provider traffic, worker startup, and popup status polling produce none.
- Account and complete-group deletion while offline, including eventual remote cleanup.
- App launch with backend unavailable.
- Enrollment performs no Face ID/passcode prompt or protected wallet-key read.
- Existing signing paths still perform exactly their required protected key reads and are unaffected by
  notification state.

## Operational Metrics

Record public-safe aggregate metrics for:

```text
active_installations
notification_capable_installations
active_address_registrations
active_address_registrations by chain
configured_installations by chain
webhook_chain_stages by status
webhook_chain_activations
upstream_subscription_ref_count
upstream_reconciliation_age
upstream_create/delete failures
verified_webhook_events by type and chain
webhook_signature failures
event_fanout_count
event_feed_lag
apns_attempts by response class and environment
apns_queue_age
invalidated_apns_tokens
notification_status_cleanup
installation_liveness_expirations
popup_liveness_attempts by outcome
authentication failures by reason
app_attest trust modes
```

Never use full wallet addresses, APNs tokens, installation IDs, signatures, or event payloads as metric
labels.

## Broader-Scope Open Decisions

The MVP plan locks the initial domain, repository location, quotas, liveness, retention, categorical
content, extension identifier, composite webhook deduplication, and platform scope. Revisit these only
after MVP evidence. Broader scope still requires decisions on:

1. Whether App Attest becomes a collected risk signal or an enforced admission requirement.
2. Apple Silicon Mac enrollment and visible notification delivery.
3. Amount, asset, counterparty, localization, grouping, and user-selectable preview behavior.
4. Migration from composite `(webhookId, eventType)` deduplication if upstream introduces unique delivery
   IDs.
5. Higher quotas or longer retention for a production expansion beyond the bounded cohort.

## Recommended First Work

Follow Gate 0 in `docs/wallet-backend-push-notifications-mvp-plan.md`: freeze the shared Swift/TypeScript
contracts and sanitized fixtures before changing capabilities, provisioning, or runtime code.
