# Wallet Backend And Push Notifications MVP Implementation Plan

## Status

Approved MVP scope as of 2026-09-04. This document turns the broader architecture in
`docs/wallet-backend-push-notifications-plan.md` into an ordered implementation plan. The broader plan
remains the security and future-scope reference; this document controls what ships in the first usable
release.

No backend, entitlement, APNs, keychain, notification-extension, or app behavior described here is
implemented yet.

## MVP Outcome

An iPhone or iPad user can explicitly enable notifications for an active wallet account. The app enrolls
that public address on every configured, globally active chain without reading a wallet key or presenting
device authentication. A first-party Cloudflare Worker consumes signed wallet-activity webhooks, sends a
privacy-limited APNs hint, and exposes an authenticated cursor feed. The app persists missed or delivered
events, handles reorgs, and cleans up enrollment after disablement, account deletion, permanent APNs
failure, or liveness expiry.

The MVP is complete only when this flow works through a production APNs environment on a physical iPhone
or iPad and missed-push recovery is proven from the cursor feed.

## Locked MVP Decisions

### Repository and deployment

- Add the backend to this repository under `WalletBackend/`.
- Deploy it as an independently configured Cloudflare Worker at `wallet-api.stupidtech.net`.
- Keep backend deployment, secrets, D1 databases, queues, and migrations separate from `stupid-app`
  application builds even though the source shares one repository.
- Use TypeScript, Hono, Zod, D1, Cloudflare Queues, scheduled Workers, Web Crypto, Bun, and the repository's
  configured backend lint/format/test scripts.
- Never place upstream API keys, webhook secrets, APNs credentials, or backend tokens in app resources.

### Enrollment and accounts

- Initial UI enrolls only active accounts from the validated `WalletRegistry`.
- Enabling an account covers every chain currently configured in `NetworkStore`.
- `includeInBalance` does not affect notification enrollment.
- The backend stores canonical address/chain registrations without asserting address ownership.
- Enrollment uses installation authentication only. It performs no Ethereum signature, wallet-key read,
  Face ID, or passcode prompt.
- Arbitrary watched-address UI is deferred, but backend records remain ownership-neutral.

### Installation authentication

- The containing app owns one non-synchronizable, `ThisDeviceOnly` P-256 installation key in a dedicated
  app-only keychain access group.
- A second non-synchronizable P-256 popup-liveness key lives in the existing app/Safari shared keychain
  group and can authenticate only the liveness endpoint.
- The installation key signs enrollment, token, notification-status, chain, account, cursor-feed,
  renewal, rotation, and deletion requests.
- App Attest enforcement and collection are deferred. D1 retains a nullable trust-mode field so adding it
  later does not require changing installation identity.
- APNs tokens and `identifierForVendor` are never authentication identities.

### Lifecycle defaults

- Installation liveness window: 30 days.
- Containing-app notification-settings freshness: 90 days.
- Popup renewal coalescing: at most once per 24 hours per installation.
- Foreground full-state renewal: when liveness has 14 days or less remaining.
- Settings are read on every initial load and foreground entry. A signed settings update is also sent
  when authorization changes or settings freshness has 30 days or less remaining.
- Backend event-feed retention: 30 days.
- Explicit disablement removes the installation immediately when its final account enrollment is removed.
- Backend cleanup removes installation events and credentials. Shared activity events remain only while
  another installation references them and never beyond the 30-day retention limit.
- The local observed-activity database follows the app's existing local activity-retention behavior.

### Quotas

Per installation:

- At most 25 enrolled addresses.
- At most 25 configured chains.
- At most 250 effective address-chain pairs.
- Reject an over-limit full snapshot atomically; never apply a partial desired state.
- Apply separate bounded request-rate limits to installation creation, mutation, event reads, and popup
  liveness.

### Chain activation

- Count distinct notification-capable installations with a configured chain.
- Multiple accounts on one installation count once.
- A chain is staged below five qualifying installations.
- The fifth qualifying installation triggers one idempotent upstream capability/activation operation.
- Successful activation is sticky unless an operator disables the chain.
- A later drop below five removes stale installation references but does not deactivate the chain.

### Webhook identity compatibility

- Deduplicate deliveries by `(webhookId, eventType)` for the MVP because the upstream service currently
  reuses one webhook ID for `activity.observed` and `activity.reverted`.
- Preserve the upstream observation ID separately so the reverted event can transition the matching
  observation.
- Document this as an explicit compatibility contract and retain a fixture for both event types sharing
  one webhook ID.
- A future unique upstream delivery ID may replace this only through a reviewed migration.

### Platforms

- iPhone and iPad are the MVP notification platforms.
- Hide or disable notification enrollment for the iOS app running on Apple Silicon Mac.
- Mac push delivery, Mac enrollment, and Mac popup-liveness acceptance are deferred.
- Existing wallet and Safari behavior on Mac must remain unchanged.

## Notification Content Contract

The base APNs payload contains only:

- `eventId`.
- Opaque installation-scoped `addressRegistrationId`.
- Decimal `chainId`.
- One bounded `eventKind`.
- Payload schema version.
- `mutable-content: 1`, categorical fallback title, generic body, and opaque thread identifier.

It contains no account label, full address, amount, asset symbol, token contract, counterparty, calldata,
signature, or backend credential.

The Notification Service Extension resolves local display state and uses an incoming
`INSendMessageIntent` to render:

```text
avatar:       locally generated account blockie (`INPerson.image`)
title:        categorical event title
message line: <account label> • <chain>
```

The message line is assigned to both `INSendMessageIntent.content` and the mutable notification `body`
before `updating(from:)`; the communication layout must not rely on `subtitle`, which may be omitted.

MVP event kinds and English titles are:

| Event kind | Title |
| --- | --- |
| `nativeReceived` | Received funds |
| `nativeSent` | Sent funds |
| `tokenReceived` | Token received |
| `tokenSent` | Token sent |
| `nftReceived` | NFT received |
| `nftSent` | NFT sent |
| `transactionSent` | Transaction sent |
| `transactionFailed` | Transaction failed |
| `activityReverted` | Activity reverted |
| `activityDetected` | Wallet activity |

Use the generic kind when one event has conflicting effects or cannot be classified without guessing.
Reorg and failed-execution states take precedence over transfer classifications. Amounts, symbols,
counterparties, localization, and user-selectable preview detail are post-MVP.

If interaction donation, content updating, or extension processing fails or times out, iOS shows the
categorical title with locally resolved account/network context when available, otherwise the base
categorical title and generic body. The containing app declares Communication Notifications and Siri,
and lists `INSendMessageIntent` in `NSUserActivityTypes`; the extension itself retains only App Group
access.

## Repository Layout

Add these backend paths:

```text
WalletBackend/
  package.json
  bun.lock
  tsconfig.json
  wrangler.jsonc
  migrations/
  src/
    index.ts
    config.ts
    auth/
    api/
    apns/
    database/
    events/
    queues/
    upstream/
  test/
    fixtures/
```

Add these app boundaries:

```text
Sources/StupidWalletCore/
  NotificationRegistrationStore.swift
  NotificationInstallationClient.swift
  NotificationActivityStore.swift
  NotificationModels.swift

Sources/StupidWallet/
  NotificationCoordinator.swift
  NotificationSettingsView.swift

Sources/StupidWalletSafari/
  PopupLivenessCoordinator.swift

Sources/StupidWalletNotificationService/
  NotificationService.swift
  BlockieRenderer.swift

NotificationServiceExtension/
  Info.plist
  NotificationService.entitlements
```

Exact file boundaries may be combined when doing so keeps the implementation smaller. Do not duplicate
validation, blockie generation, chain naming, or canonical request signing across targets.

The Notification Service Extension product is `StupidWalletNotificationService`. Its bundle identifier
must remain prefixed by the existing containing-app identifier for App Store embedding compatibility;
use `co.za.stephancill.stupid-wallet.notification-service`. This is a compatibility exception for the
existing product identity, not a new standalone reverse-DNS namespace.

## Backend MVP Components

### HTTP API

Implement only these public mobile routes:

```text
POST   /v1/installations/challenges
POST   /v1/installations
GET    /v1/installations/:installationId
PUT    /v1/installations/:installationId/push-token
PUT    /v1/installations/:installationId/notification-status
PUT    /v1/installations/:installationId/chains
POST   /v1/installations/:installationId/addresses
DELETE /v1/installations/:installationId/addresses/:address
POST   /v1/installations/:installationId/renew
POST   /v1/installations/:installationId/liveness
GET    /v1/installations/:installationId/events
DELETE /v1/installations/:installationId
```

Implement one webhook route:

```text
POST /internal/v1/wallet-activity
```

Every installation-key request uses the canonical signature contract from the broader plan: exact method,
path/query, timestamp, random request ID, installation ID/public-key identity, and exact body digest.
Validate all bodies with Zod before persistence. Preserve structured errors and fail atomically.

The popup liveness route accepts only a signature from the associated popup key over its fixed action,
installation ID, timestamp, request ID, and empty body digest. It can update only `liveness_expires_at`,
never beyond `notification_settings_valid_until`.

### D1 control plane

Use strict migrations and include only data required by the broader plan:

- Installations, authentication challenges, request replay IDs, and popup replay IDs.
- Configured installation chains and sticky global chain stages.
- Installation addresses and effective address-chain registrations.
- Reference-counted upstream subscriptions and transactional upstream-operation outbox.
- Verified activity events and per-installation cursor events.
- APNs attempts and token-version metadata.

All desired-state and outbox writes that must agree commit in one D1 transaction. APNs tokens are stored
as an encrypted delivery value plus keyed lookup hash. Secrets and complete event payloads never appear in
logs or metric labels.

### Queues and schedules

Use separate queues for:

- Upstream subscription create/delete and chain activation.
- APNs delivery and bounded retry.

Use scheduled reconciliation for unapplied outbox work, reference-count repair, 30-day event pruning, and
expired-installation cleanup. Queue handlers and scheduled work are idempotent.

### Upstream webhook ingestion

The webhook path must:

1. Read exact request bytes before parsing.
2. Verify timestamp and HMAC in constant time.
3. Enforce the replay window.
4. Validate the payload.
5. Deduplicate transactionally by `(webhookId, eventType)`.
6. Persist the canonical event and installation fanout rows.
7. Enqueue APNs work.
8. Return `2xx` without waiting for APNs.

### APNs delivery

- Use token-based APNs provider authentication through Web Crypto.
- Keep development and production environments separate with no fallback between them.
- Treat APNs success as acceptance only.
- Retry transport failures, `429`, and `5xx` with bounded backoff.
- On `410 Unregistered`, delete only if the response applies to the current token version.
- Treat provider-token failure as an operational credential error, never a device deletion signal.
- Keep the event available from the cursor feed regardless of push outcome.

## App MVP Components

### Entitlements and packaging

Before editing wallet entitlements, update `stupid-app` so capabilities are derived per bundle and Push
Notifications correctly reconciles development and distribution `aps-environment` values.

The containing app receives Push Notifications, Communication Notifications, Siri, and the dedicated
app-only keychain access group. The
Safari extension receives no push entitlement and retains only its existing shared keychain access. The
Notification Service Extension receives the existing App Group only; it receives no push, App Attest, or
keychain-sharing entitlement.

App Attest entitlements and implementation are not part of MVP.

### Local enrollment state

`NotificationRegistrationStore` is a versioned atomic App Group store for non-secret desired state,
including account enrollment sources, configured-chain revision, acknowledged snapshot, APNs token hash,
notification settings, liveness expiries, and cleanup outbox operations.

Store the installation private key and installation ID in the dedicated app-only keychain group. Store
the popup-liveness private key in the existing app/Safari shared keychain group under a distinct tag.
Neither key uses `.userPresence`; neither can sign Ethereum payloads.

### Reconciliation triggers

Run a full containing-app reconciliation:

- After successful registry adoption on initial load.
- After account or wallet-group creation/deletion.
- After notification enrollment changes.
- After every `NetworkStore` add, record, restore, or remove.
- After APNs token registration/rotation.
- After a backend stale-state response.
- On foreground when liveness has 14 days or less remaining.
- On foreground when settings freshness has 30 days or less remaining.
- Immediately when observed notification authorization changes.

Read notification settings on every foreground even when no network call is due. If required alert
authorization is unavailable, enqueue authenticated installation deletion immediately.

Opening the Safari toolbar popup triggers a liveness request when no successful popup renewal has occurred
in the preceding 24 hours. Only popup-owned extension code can trigger it. Page messages, provider calls,
worker startup, and popup polling do not. Failure does not block the popup or signing flow; a later popup
may retry, and ordinary containing-app reconciliation remains authoritative.

### Account and installation deletion

- Disabling one account removes only that source and its effective references.
- Disabling the final account queues complete installation deletion.
- Account/group deletion commits local wallet lifecycle first and queues idempotent notification cleanup.
- Backend unavailability never blocks local account or group deletion.
- Cleanup survives termination and retries after launch/foreground.
- A permanent current-token APNs failure or liveness expiry runs the same backend deletion workflow.

### Event synchronization and local activity

Add `observed_activity` and `notification_sync_state` through the next strict `ActivityStore` migration.
Do not rebuild or write remote rows into the shipped `transactions` table.

For each cursor page:

1. Authenticate with the installation key.
2. Validate the complete page, event enums, addresses, hashes, quantities, effects, and enrolled-address
   membership.
3. In one SQLite transaction, upsert observed/reorg state and advance the cursor.
4. Merge matching local and observed transactions only in queries/view models.
5. Preserve all local request, origin, profile, calldata, and signing metadata.

A notification tap launches the app, runs cursor synchronization, and opens the matching event when it is
available. If the event has expired or cannot be fetched, show the ordinary Activity screen rather than
inventing details from the APNs payload.

## Ordered Implementation Gates

### Gate 0: Freeze Contracts And Fixtures

Work:

- Freeze canonical request signatures, API schemas, error codes, D1 identities, event kinds, cursor
  semantics, liveness defaults, and quotas.
- Capture sanitized observed/reverted webhook fixtures sharing one webhook ID.
- Add independent P-256 and HMAC vectors usable by Swift and TypeScript tests.

Exit conditions:

- Swift and TypeScript decode the same valid fixtures and reject the same invalid fixtures.
- No unresolved decision can change installation identity, event identity, or persisted schema.

### Gate 1: Tooling And Bundle Foundation

Work:

- Add per-bundle Push Notifications capability/profile handling to `stupid-app`.
- Add the notification-service SwiftPM product and `stupid-app.yml` extension configuration.
- Provision the containing app, Safari extension, and notification-service profiles/entitlements.

Exit conditions:

- `stupid-app doctor` passes.
- Development build carries sandbox APNs only on the containing app.
- Distribution archive carries production APNs only on the containing app.
- The notification service is embedded and signed with App Group access but no keychain or push
  entitlement.
- Existing app/Safari signing and Mac packaging remain valid.

### Gate 2: Backend Authentication And Desired State

Work:

- Scaffold `WalletBackend/`, D1 migrations, environment bindings, and tests.
- Implement installation challenge/create/recovery, exact-request signatures, replay defense, quotas,
  full chain snapshots, addresses, renewal, popup liveness, and deletion.
- Implement liveness/settings ceilings and scheduled expiry.

Exit conditions:

- Cross-installation, replay, mutation, stale snapshot, quota, popup-scope, and deletion tests pass.
- No route accepts an Ethereum signature or ownership claim.
- Deletion makes both installation and popup keys unable to revive state.

### Gate 3: Upstream Subscription And Event Feed

Work:

- Implement chain staging at five distinct eligible installations.
- Implement reference-counted subscriptions and transactional outbox processing.
- Implement signed webhook ingestion with composite deduplication.
- Implement 30-day event retention and authenticated cursor pagination.

Exit conditions:

- Four installations remain staged; the fifth activates once.
- Shared subscriptions survive removal of one reference and disappear after the last.
- Observed and reverted deliveries sharing one webhook ID both apply exactly once.
- Queue loss, duplicate delivery, response loss, and scheduled reconciliation converge.

### Gate 4: APNs And Notification Rendering

Work:

- Implement APNs token provider authentication, queue delivery, retry, and current-token invalidation.
- Implement bounded event classification and payload generation.
- Share the deterministic blockie renderer with the Notification Service Extension.
- Resolve local label/chain state from the opaque registration ID.

Exit conditions:

- Sandbox push reaches a physical development installation.
- Production push reaches a TestFlight installation.
- The rendered title, left-side blockie avatar, and `<account label> • <chain>` message line match the
  Communication Notifications contract.
- No amount, full address, label, token contract, or counterparty appears in the base payload.
- Extension timeout renders the generic fallback.

### Gate 5: App Enrollment, Reconciliation, And Popup Liveness

Work:

- Add key stores, APNs coordinator, settings UI, desired-state store, cleanup outbox, and API client.
- Wire all reconciliation triggers and popup-owned liveness messages.
- Hide enrollment on Apple Silicon Mac.

Exit conditions:

- Enable/disable and token rotation require no wallet-key access or authentication prompt.
- All configured chains synchronize with monotonic replacement semantics.
- Popup open renews at most once per 24 hours and cannot mutate or revive state.
- Page/provider traffic cannot trigger popup liveness.
- Offline account deletion succeeds locally and later cleans up remotely.

### Gate 6: Cursor Activity And Reorgs

Work:

- Add the strict observed-activity/cursor migration.
- Implement feed ingestion, query-time local/remote merge, Activity UI rows, and notification selection.

Exit conditions:

- Incoming, outgoing, self, token, NFT, failed-execution, and reorg fixtures render correctly.
- A local send plus matching observation renders once without losing local metadata.
- One transaction affecting two accounts creates two account views without collision.
- A missed or duplicate push converges through the event feed.

### Gate 7: Failure And Physical Acceptance

Work:

- Exercise backend, D1, queue, upstream, APNs, and network failures.
- Exercise disablement, expired liveness, stale notification settings, reinstall, and token replacement.
- Run the complete flow on physical iPhone and iPad.

Exit conditions:

- No notification failure blocks wallet startup, signing, export, migration, account deletion, or Safari
  approval.
- Delayed APNs failure for an old token does not delete its replacement.
- Explicit disablement and liveness expiry remove backend state and upstream references.
- Reinstall recovers an existing active installation only when retained keychain/server state permits;
  otherwise it creates a new installation safely.
- Existing Safari signing regression suite and physical approval flow remain unchanged.

### Gate 8: Bounded MVP Rollout

Work:

- Deploy a development backend, then a production backend with separate resources and secrets.
- Enable a bounded TestFlight cohort.
- Observe webhook, queue, APNs, cursor, liveness, quota, and cleanup metrics.
- Exercise the operator kill switches for new enrollment and APNs fanout.

Exit conditions:

- Delivery and missed-push recovery meet the approved acceptance checks.
- Operators can distinguish upstream, webhook, queue, APNs, and device-sync failures without sensitive
  logs.
- Complete installation deletion is demonstrated in production-safe testing.
- Rollback disables notifications without affecting wallet operation.

## Required Verification Commands

Use the repository's final configured scripts, but the implementation must include equivalent checks:

```text
cd WalletBackend && bun run format:check
cd WalletBackend && bun run lint
cd WalletBackend && bun run typecheck
cd WalletBackend && bun run test
swift format lint --recursive Sources Tests
swift test
stupid-app doctor
stupid-app build
stupid-app run --simulator --udid <preferred-simulator>
```

Run credentialed webhook, APNs, TestFlight, and physical-device checks separately. Never put credentials,
tokens, installation IDs, personal wallet addresses, or complete sensitive payloads in fixtures,
implementation notes, or command output committed to the repository.

## Explicitly Deferred

- Arbitrary watched-address UI.
- App Attest collection or enforcement.
- Apple Silicon Mac enrollment, push delivery, and popup liveness.
- Amounts, symbols, prices, counterparties, decoded calldata, and rich notification previews.
- User-configurable notification categories, sounds, grouping, or preview privacy.
- Silent-push correctness or required background refresh.
- Historical activity backfill before enrollment.
- Token metadata and internal-transfer indexing not supplied by the upstream service.
- A standalone operator dashboard; MVP uses Cloudflare deployment controls and public-safe aggregate
  observability.
- Compatibility behavior without a shipped format or current upstream contract.

Deferred work must not weaken or bypass the MVP's installation authentication, cursor authority, cleanup,
origin-independent wallet safety, or privacy boundaries.
