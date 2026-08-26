# Multi-Account Implementation Plan

## Status

This document records the approved product behavior and implementation plan for multiple wallet
groups and accounts. It is an implementation specification, not a description of behavior that is
already shipped.

The plan preserves the existing security boundaries: native code remains authoritative for account
identity, connection grants, canonical pending requests, key access, signing, and persistent state;
the Safari popup may select an existing account for a plain connection request but never supplies
signing input or creates key material.

## Goals

- Support multiple wallet groups on one installation.
- Let a seed-backed wallet group derive multiple Ethereum accounts at
  `m/44'/60'/0'/0/{index}`.
- Keep a raw-private-key wallet group restricted to exactly one account.
- Make the address item in the home account menu open an account picker.
- Let the home picker select an account, derive an account in a seed group, create a new seed group,
  import a seed phrase, or import a private key.
- Let users name wallet groups and edit wallet-group and account labels from the home picker.
- Let users remove individual account registrations without reusing seed derivation indexes.
- Scope home balance, Activity, Connected Apps, Settings, authorizations, and private-key export to
  the independently selected home account.
- Let the active plain-connect request select an existing account by pressing the account in the
  Safari popup's sticky action bar.
- Persist a successfully connected popup selection as the default proposed account for future new
  connections without changing the home-selected account.
- Preserve existing connection grants when a different account is connected.
- Keep one active connected account per normalized origin and Safari profile while retaining any
  other account grants for that origin/profile.
- Preserve supported Dawn migration, activity history, hostname grants, network preferences, and RPC
  overrides. Dawn starts with an empty account-bound balance cache.

## Non-Goals

- Returning every wallet account from `eth_accounts`; only the active account connected to the
  requesting origin/profile is exposed.
- Selecting an account from a queued popup request.
- Rebinding SIWE, message, typed-data, transaction, batch, or chain requests after preparation.
- Creating, importing, or deriving accounts from the Safari popup.
- Hiding a removed account while retaining it as a selectable account, or restoring a removed
  account registration automatically.
- BIP-39 passphrases, non-English word lists, custom derivation paths, hardware
  wallets, watch-only accounts, or cross-device key synchronization.
- Per-account chain selection, network metadata, or RPC preferences. Those remain installation-wide.
- Silently adopting orphaned keychain items that are not represented by an authenticated registry
  migration or explicit import.

## Locked Product Decisions

- A wallet group is either seed-backed or private-key-backed.
- New wallet creation generates a seed-backed wallet group and derives account index zero.
- Seed import creates a seed-backed group and derives account index zero.
- Private-key import creates a one-account private-key group.
- Only old Dawn v1 installations are supported migration sources. They become one-account private-key
  groups even when the account was originally imported from a seed phrase because Dawn retained no
  seed from which siblings can be derived.
- Migration from the current single-account rebuild (v2) is explicitly out of scope. Its
  `wallet-address.conf`, `sw2.walletAddress`, normalized `connectedOriginsV2`, singleton balance cache,
  and pending-request files are not migration inputs and receive no upgrade-preservation guarantee.
- Fail-closed compatibility projection for opening a multi-account installation in an older rebuild
  remains in scope. That downgrade-safety boundary is separate from supporting v2 as an upgrade source.
- A seed group stores one protected BIP-39 entropy item. Derived private keys are produced only in
  memory when needed and are not copied into separate persistent keychain items.
- Wallet-group and account labels are editable display metadata. They never identify an account for
  signing, authorization, migration, deduplication, or approval binding.
- Removing a seed-derived account deletes its registry registration, connection state, pending
  authority, and balance cache while retaining the group's seed and monotonic derivation high-water
  mark. The removed derivation index is never reused or restored implicitly.
- The last registered account in a seed group cannot be removed independently; the user must remove
  the wallet group and its seed. Removing a private-key account removes its one-account group and key.
- Forgetting a seed-backed wallet removes the complete group, including its entropy and every
  derived account registration.
- Selecting a home account never dismisses the Accounts sheet. Successful additive create/import
  flows return to the Accounts list and preserve the prior home selection until the user selects an
  account there.
- Home account selection and default connection account selection are independent and persist
  independently.
- A popup account choice becomes the default connection account only after Connect succeeds.
- Existing account grants remain stored when another account is connected to the same origin/profile.
- Only the active global queue-head plain `.connect` request may be rebound from the popup.
- Existing signing and sending requests remain bound to the account active for their origin/profile
  when they were prepared.

## Terminology

### Wallet group

A collection controlled by one secret source:

- A seed group owns protected BIP-39 entropy and one or more ordered derived accounts.
- A private-key group owns one protected secp256k1 private key and exactly one account.

### Home-selected account

The account whose balance and account-scoped containing-app data are visible. It controls the home
blockie, copy-address action, Activity, Connected Apps, Settings, authorizations, and private-key
export. It never changes dapp authorization by itself.

### Default connection account

The account initially proposed when an unconnected origin prepares a new plain connect approval. It
is updated only by successful connect approval and does not change the home-selected account.

### Connection grant

Durable authorization for one account at one normalized origin and Safari profile. Multiple accounts
may retain grants for the same origin/profile.

### Active connected account

The one granted account currently exposed to an origin/profile through `eth_accounts` and used to
validate that origin's signing, sending, chain, capability, and call-status requests.

## Current Boundaries That Must Change

- `WalletStore` stores one address in `wallet-address.conf` and has no group registry.
- `WalletFactory.provision` rejects every create/import operation when one wallet already exists.
- `EthereumSeedPhrase` derives only `m/44'/60'/0'/0/0` and discards seed provenance.
- `SafariWebExtensionHandler` constructs one signer from the same address used by the containing app.
- `WalletService` owns one signer for all operations and therefore cannot serve requests belonging to
  different connected accounts.
- `ConnectedSitesStore` keys normalized grants by origin/profile only, so a second account overwrites
  the first.
- `ConnectedSitesStore` performs unlocked, non-throwing `UserDefaults` read-modify-write operations
  across independently running app and extension processes.
- `ActivityStore` persists `from_address` correctly but global and connected-app queries do not
  consistently filter it.
- `BalanceCache` retains one account snapshot rather than one snapshot per account.
- The registry and picker derive fixed group/account titles from wallet kind and derivation index; they
  have no persisted editable labels or account-level deletion lifecycle.
- The picker dismisses after account selection, derivation, and successful additive group creation or
  import.
- The popup shows a connect account in its body and intentionally omits it from the sticky bar.
- Canonical `payloadDigest` hashes only request ID plus params. Existing `intentDigest` is transport
  retry identity for page-supplied intent, not approval identity, and therefore does not separately
  add a wallet-selected account.
- `eth_accounts` and connect short-circuiting perform separate native `me` and `isConnected` calls,
  allowing an account/grant race.
- The provider implements `chainChanged` but does not maintain account state or emit
  `accountsChanged`.

## Persistence Design

### Wallet registry

Add a versioned, atomic App Group file, `wallet-registry.json`, guarded by an OS advisory lock for
every cross-process read-modify-write.

```swift
struct WalletRegistry: Codable, Sendable {
  let schemaVersion: Int
  let revision: UInt64
  var adoptionState: WalletRegistryAdoptionState
  var groups: [WalletGroup]
  var homeSelectedAddress: String?
  var legacyWalletAddressFallbackRemoved: Bool
}

enum WalletRegistryAdoptionState: String, Codable, Sendable {
  case migrating
  case complete
}

struct WalletGroup: Codable, Sendable, Identifiable {
  let id: UUID
  let kind: WalletGroupKind
  let createdAt: Date
  let seedIdentityAddress: String?
  var label: String
  var nextDerivationIndex: UInt32?
  var accounts: [WalletAccount]
  var lifecycle: WalletGroupLifecycle
}

enum WalletGroupKind: String, Codable, Sendable {
  case seed
  case privateKey
}

struct WalletAccount: Codable, Sendable, Identifiable {
  let address: String
  let derivationIndex: UInt32?
  let createdAt: Date
  var label: String
  var lifecycle: WalletAccountLifecycle

  var id: String { address.lowercased() }
}

enum WalletAccountLifecycle: String, Codable, Sendable {
  case active
  case deleting
}
```

Registry invariants:

- Every address is a valid EIP-55 account and is globally unique case-insensitively.
- Every group and account label is trimmed and nonempty. Labels need not be unique.
- A private-key group has exactly one account with no derivation index and no seed identity.
- A seed group has one or more registered accounts with unique indexes below `2^31`.
- A seed group's immutable `seedIdentityAddress` is its account-zero address. It remains reserved to
  that group even if account zero is later removed, preventing the same seed from being imported as a
  second group. It may equal that group's registered account zero but no address in another group.
- Account indexes are monotonic and never reused.
- `nextDerivationIndex` is greater than every registered index and advances only when account
  registration commits. Deleting an account never lowers it.
- `homeSelectedAddress`, when present, resolves to an active registered account whose group is active.
- `legacyWalletAddressFallbackRemoved` must be true before seed groups, additional accounts, or home
  selection changes are enabled.
- Only `.complete` is usable by ordinary app or extension operations. `.migrating` is a durable,
  resumable barrier while Dawn key, connection, activity, network-preference, and registry adoption are
  incomplete.
- Unknown or malformed registry versions fail loudly; they do not fall back to an arbitrary keychain
  item.
- A monotonically increasing revision lets asynchronous UI and signing work reject stale snapshots.

Advancing the registry schema for labels and account lifecycle must decode the current multi-account
schema through one explicit migration. Existing groups receive deterministic labels such as
`Wallet 1`; existing seed accounts receive `Account {derivationIndex + 1}` and private-key accounts
receive `Account 1`. Existing seed groups derive `seedIdentityAddress` from their required account-zero
registration. The migration preserves IDs, addresses, derivation indexes, creation dates, group
lifecycle, home selection, and `nextDerivationIndex`. This is a migration of the already-authoritative
multi-account registry schema, not adoption of the unsupported singleton rebuild. Unknown schemas
still fail loudly.

New code reads the registry as authority. `sw2.walletAddress` is not a migration input. Startup and
every projection transition remove and verify the absence of any value introduced by a downgraded
build before exposing wallet state; multi-account code never mirrors it. The sole rebuild downgrade
compatibility projection is
`wallet-address.conf`, and it is deliberately fail-closed because older code can sign only
address-keyed private-key items:

- When the home account belongs to a private-key group, write its address to
  `wallet-address.conf`.
- When the home account belongs to a seed group, remove `wallet-address.conf`. Never project a
  seed-derived address whose child key is not persisted under the old address-keyed service.

Registry/projection transitions use an atomic `wallet-registry-transition.json` commit-forward
journal under the registry lock:

1. Atomically persist the previous registry revision (or an explicit absent sentinel), complete next
   registry value, previous file projection, and intended file projection.
2. Apply the projection first. Writes use a same-directory temporary file, file synchronization,
   atomic rename, and parent-directory synchronization; removals synchronize the parent directory.
3. Atomically write the next registry as authority.
4. Remove the transition journal.

Recovery compares the authoritative registry revision with the journal. If the registry is still at
the previous revision, it completes the projection and commits the recorded next registry. If the next
revision is already present, it completes any missing projection and removes the journal. A projection
failure before registry commit restores the previous projection and leaves the previous registry.
Never infer a registry mutation from a mismatched projection without this journal.

Every operation that creates a registry or changes `homeSelectedAddress` must use this one
`commitRegistryTransition` protocol; direct registry-then-projection writes are prohibited. With no
journal, startup derives the one expected projection from the authoritative registry and repairs a
stale projection left by a downgraded build before exposing wallet state, failing loudly if repair
cannot be persisted.

This means downgrading while a seed account is home-selected shows no active rebuild wallet rather
than advertising an address the older signer cannot release. The old App Group `walletAddress` value
remains a legacy migration input and is not new registry authority.

### Protected secret storage

Keep the current private-key service and add a separate seed-entropy service:

```text
private key: service co.za.stephancill.stupid-wallet.keys
             account EIP-55 address

seed entropy: service co.za.stephancill.stupid-wallet.seeds
              account lowercase wallet-group UUID
```

Both item types use:

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- `.userPresence` access control.
- A fresh `LAContext` for every protected release.
- Authentication reuse duration zero.
- No unlocked-secret cache.

Seed groups persist canonical BIP-39 entropy rather than a mnemonic string or each derived private
key. The English mnemonic and 64-byte BIP-39 seed are reconstructed transiently after authenticated
entropy release, then cleared with the derived child key.

This gives seed-backed signing one authentication prompt and one protected item read:

1. Load group entropy with fresh device-owner authentication.
2. Reconstruct the mnemonic and derive the BIP-39 seed.
3. Derive the registered account index.
4. Require the derived address to match the registry account.
5. Sign or export within the same narrow scope.
6. Overwrite entropy, mnemonic bytes where mutable, seed, chain code, and private-key buffers.

Do not enumerate keychain items to construct the registry. `contains` may check whether a registered
item exists without releasing it, but a surviving orphan becomes usable only through explicit import
and authenticated exact-secret verification.

### Connection state

Replace normalized-grant authority in `UserDefaults` with one versioned, atomic App Group file,
`connection-state.json`, guarded by an OS advisory lock.

```swift
struct ConnectionState: Codable, Sendable {
  let schemaVersion: Int
  let revision: UInt64
  var defaultAccount: String?
  var grants: [ConnectionGrant]
  var activeConnections: [ActiveConnection]
  var connectCommits: [ConnectCommit]
}

struct ConnectionGrant: Codable, Sendable, Identifiable {
  let account: String
  let origin: String?
  let legacyDomain: String
  let profileID: String?
  let connectedAt: Date
  let precision: GrantPrecision
}

struct ActiveConnection: Codable, Sendable, Identifiable {
  let origin: String
  let profileID: String?
  let account: String
}

struct ConnectCommit: Codable, Sendable, Identifiable {
  let requestID: UUID
  let requestRevision: UInt64
  let connectionRevision: UInt64
  let origin: String
  let profileID: String?
  let account: String
  let bindingDigest: String
  let result: JSONValue
  let committedAt: Date

  var id: UUID { requestID }
}
```

Connection-state invariants:

- Exact grants are keyed by normalized account, normalized origin, and profile.
- Legacy grants retain domain-only precision and authorize only their stored account.
- At most one account is active for an exact origin/profile.
- An active account must have a matching grant and registered key source.
- `defaultAccount`, when present, resolves to an active registry account.
- Changing `defaultAccount` does not alter any active origin/profile.
- Connecting account B never deletes account A's grant.
- Removing the active grant clears the active mapping instead of silently selecting another account.
- A later account request may reactivate an already granted default account without a new approval;
  otherwise it prepares a new connect approval.
- A registered legacy hostname grant remains immediately usable for its stored account when no exact
  grant exists for that domain. Resolution treats that account as active for the request without
  inventing an exact origin/profile grant.
- Once any exact grant exists for a domain, preserve the current fail-closed policy: no request for
  that domain falls back to a hostname-only grant.
- A connect commit marker is written atomically with its grant, active mapping, and default account;
  it is authoritative for recovery until the matching pending record is durably consumed.

Continue mirroring the legacy `connectedSites` hostname dictionary after a successful authoritative
write. The mirror cannot represent multiple accounts for one domain, so it is best-effort downgrade
compatibility and never authorization truth for new code.

### Account-bound balance cache

Use a versioned dictionary keyed by normalized address in `native-balance-cache.json`. Do not decode
the current-rebuild singleton payload as a migration source; Dawn starts with no cache entries.

Each entry includes account, formatted aggregate balance, and last successful update. A refresh result
may update only the account and registry revision captured when it began.

### Activity database

Keep `from_address` as the canonical activity account. Addresses are stable and globally unique in the
registry, so adding wallet-group IDs to historical rows is unnecessary.

Advance the schema to add indexes suitable for account-scoped queries:

```sql
CREATE INDEX IF NOT EXISTS transactions_account_created
ON transactions(lower(from_address), created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS signatures_account_created
ON signatures(lower(from_address), created_at DESC, id DESC);
```

Rows with an empty or unknown `from_address` remain preserved but are excluded from account-scoped
views unless a retained canonical request proves the account. Never assign them to the home-selected
account by assumption.

Rebuild the signatures table in place so `signature_hash` is no longer unique. New signature event
identity is the canonical `request_id`, enforced by a unique partial index when `request_id` is not
null. Retained legacy rows without a request ID keep their existing row IDs and remain readable; the
migration does not fabricate duplicate historical events. Recording the same deterministic signature
for two new requests inserts two rows, while retrying persistence for one request remains idempotent.

### Pending request compatibility

Add a binding version and account-inclusive canonical binding without making retained JSON records
undecodable.

Binding version 2 hashes the sorted-key canonical JSON encoding of this exact `JSONValue` object:

```swift
.object([
  "version": .number(2),
  "requestId": .string(lowercaseUUID),
  "kind": .string(kind.rawValue),
  "method": .string(exactPersistedMethod),
  "origin": .string(normalizedOrigin),
  "profileId": profileID.map(JSONValue.string) ?? .null,
  "chainId": .string(normalizedDecimalChainID),
  "account": .string(lowercaseAddress),
  "params": canonicalParams,
  "createdAtMilliseconds": .string(createdAtMilliseconds),
  "expiresAtMilliseconds": .string(expiresAtMilliseconds),
])
```

Timestamps are UTC Unix milliseconds encoded as decimal strings, avoiding floating-point and
date-formatter differences. The digest is Keccak-256 of the canonical JSON bytes. Any mutation to a
listed field invalidates approval.

Binding version 2 retains `intentDigest` as the immutable transport-intent digest: a sorted-key
canonical JSON object containing its version, normalized lowercase method, normalized origin, profile
ID or `null`, normalized decimal chain ID, and canonical page params. It excludes request ID,
timestamps, and any separately wallet-selected account. Native prepare continues to deduplicate only
on stable page-session `requestKey` plus this digest. Consequently, a transport retry after popup
rebinding still finds the original request, while another deliberate identical provider call has a
different `requestKey` and creates a second request. The account-inclusive approval binding above is
the authority for review and signing. Every new pending record also carries a revision starting at
zero and incrementing on the one permitted connect-account rebind.

The prepare lock searches all retained statuses, not only queue-visible pending records. A matching
`requestKey` plus `intentDigest` always returns the original pending ID and current status/result; it
never inserts another request after rebind, consumption, rejection, expiry, failure, or connect-marker
recovery. Reuse of a `requestKey` with a different digest is a transport-integrity error and also never
inserts. A deliberate later provider call must mint a new key. Pending records and their retry identity
remain durable; this scope does not delete them. Any future retention cleanup requires a separate
reviewed tombstone protocol serialized with prepare deduplication and must first prove no
page/background completion route can retry the key.

Records created by the multi-account runtime must carry binding version 2. Records from the
unsupported current rebuild are not migration inputs; they are neither decoded for completion or
activity backfill nor terminalized into the new queue. An unknown binding or record schema fails
closed and can never be signed or rebound.

## Core Service Design

### Account and signer resolution

Replace `WalletService`'s assumption that one injected signer owns every operation with a narrow
account resolver:

```swift
protocol AccountResolving: Sendable {
  func account(address: String) throws -> WalletAccountContext
  func signer(address: String) throws -> any Signing
}
```

The production resolver reads a validated registry snapshot and constructs:

- `PrivateKeySigner` for a private-key group account.
- `SeedAccountSigner` for a seed group address and derivation index.

Both the group and account registration must be `.active`. An account marked `.deleting` is absent
from every resolver, public account list, home/default repair candidate, and provider-visible snapshot.

The signer is selected from native authoritative context, never from page-provided account metadata.
Request handling resolves accounts as follows:

- Plain connect preparation: `ConnectionState.defaultAccount`, falling back to the home-selected
  account and then the first registered account only when no valid default exists.
- Plain connect approval: the account persisted on the pending request.
- `eth_accounts`: the active granted account for authoritative sender origin/profile.
- Existing-grant `eth_requestAccounts` or plain `wallet_connect`: the active granted account, or a
  valid already-granted default when no active mapping exists.
- Message, typed-data, SIWE, send, batch, chain switch, capabilities, and call status: the active
  granted account for sender origin/profile.
- Approval by request ID: the request's persisted account, followed by a fresh check that it is still
  active and granted where the method requires a connection.
- Popup list, summary, status, and rejection: no secret-bearing signer lookup unless the operation
  advances to approval.
- Generic RPC passthrough and chain reads: account-independent.

Every signing and sending preparation validates its standard account/from parameter against the
resolved active connected account. Preparation and approval both require the appropriate grant; a
disconnect or active-account change after preparation terminalizes the request instead of signing with
a substitute account.

### Atomic account visibility

Replace the separate JavaScript `me` and `isConnected` native calls with one operation that resolves
the account visible to the sender origin/profile from one cross-store snapshot.

```swift
func visibleAccounts(origin: String, profileID: String?) throws -> [String]
```

It returns either one granted, active, registered account or an empty array. It never returns the home
selection or an ungranted default.

Any operation that reads both account registration and connection state, including
`visibleAccounts`, existing-connect short-circuiting, default-grant reactivation, connected-method
preparation, and disconnect cleanup, acquires the registry lock and then the connection-state lock,
reloads both files, and validates the account and group as active before returning or mutating. The
locks cover only local validation/persistence. Group deletion marks the group `.deleting` before later
connection cleanup, and seed-account deletion similarly marks the registration `.deleting`, so even a
retained active mapping immediately becomes invisible. A signature-producing approval additionally
retains that account's group lifecycle claim while it revalidates active group/account membership,
connection state, and the protected key.

## Containing-App Flows

### Startup and migration

Startup order:

1. Acquire the cross-process registry-adoption claim through synchronous `NSFileCoordinator` write
   coordination on the stable App Group claim URL. A canceled coordination attempt fails closed.
2. Acquire the registry lock, decode and validate the registry and transition journal if present, and
   complete the exact
   commit-forward recovery protocol before exposing wallet state.
3. If no registry exists, inspect only the Dawn v1 address and authenticated migration state. Do not
   inspect or adopt current-rebuild registration, cache, grant, or pending-request state.
4. Resume or roll back an interrupted authenticated Dawn migration rather than treating a
   prematurely registered address as complete.
5. If authentication is necessary, persist the existing old-format migration marker, release the
   registry lock, execute the decrypt/address-match/new-format sign-and-recover proof, reacquire the
   registry lock, and reject if the captured source state changed.
6. Through `commitRegistryTransition`, adopt the proven address into one private-key group, set it
   as home, and persist the registry as `.migrating` with the matching private-key projection.
7. While retaining the registry lock, acquire the connection-state lock, migrate Dawn's hostname-only
   `connectedSites` grants with their stored accounts, and initialize the default to the proven address
   when no valid default exists. Do not ingest `connectedOriginsV2`.
8. Preserve Dawn activity and installation-wide network preferences through their existing App Group
   formats. Start the new account-bound balance cache empty; Dawn has no supported singleton cache.
9. Verify `sw2.walletAddress` is absent as downgrade cleanup, then persist
   `legacyWalletAddressFallbackRemoved = true`. This value is not an address source.
10. Validate registry, connection state, projection, downgrade-fallback absence, activity/network
     compatibility, and the new cache shape, then atomically
     advance the registry to `.complete`.
11. Preserve old key material until the existing explicit migration cleanup policy allows deletion.
12. Release the registry lock and adoption claim, then hydrate only the home-selected account's cache
    and views. Dawn has no `PendingRequests` format to migrate.

Every app and extension request entry first calls the same idempotent `ensureRegistryAdopted`
operation. Initial adoption first persists `.migrating`; under registry-then-connection locks it
resumes Dawn key, legacy-grant/default, activity/network, and downgrade-fallback steps, then commits
`.complete` only after their authoritative files validate. Another process seeing `.migrating`
resumes or fails closed and cannot prepare or decide a request.

The adoption claim must not be a retained App Group `flock`: iOS terminates a containing app with
`0xDEAD10CC` if it is suspended while holding one. Physical-device verification proved that
`NSFileCoordinator` instead gives the containing app a File Coordination suspension assertion while
its accessor runs, excludes the Safari extension, releases normally, and permits a fresh extension
request immediately afterward.

The Dawn `walletAddress` plus authenticated migration state are the only supported pre-registry wallet
identity inputs. A present current-rebuild registration is unsupported and must not be silently
adopted as Dawn state.

### Create a seed wallet group

1. Require a trimmed, nonempty wallet-group name before backup confirmation.
2. Generate supported BIP-39 entropy with `SecRandomCopyBytes`.
3. Encode the English mnemonic and display it in a privacy-sensitive backup flow.
4. Require explicit backup confirmation before registration.
5. Save entropy under the new group ID with `.userPresence` and `ThisDeviceOnly`.
6. Authenticated-load the entropy once.
7. Derive index zero, its address, and a fixed self-test signature.
8. Recover and require the exact address.
9. Atomically register the named group, immutable account-zero seed identity, account zero with the
   default `Account 1` label, and `nextDerivationIndex = 1`.
10. During additive creation, return to the Accounts list without dismissing its sheet or changing
    home selection. During initial setup, select account zero and enter the wallet home as before.
11. Delete the newly inserted entropy if authenticated verification or registry registration fails.

The generated mnemonic exists only in transient UI state and protected entropy. Backgrounding,
cancellation, and completion clear the visible phrase and mutable buffers.

### Import a seed wallet group

1. Require a trimmed, nonempty wallet-group name.
2. Validate English vocabulary, count, and checksum.
3. Recover canonical entropy from the mnemonic.
4. Derive account zero and reject a duplicate address before saving.
5. Save entropy under a new group ID.
6. Authenticated-load and verify account zero with sign-and-recover.
7. Register only after proof succeeds. An additive import returns to the Accounts list without
   dismissing its sheet or changing home selection; initial setup selects account zero and enters home.
8. Preserve the previous home account and all other state on cancellation or failure.

Importing the same seed as an existing group is rejected through account-zero identity. Importing a
seed whose account zero already exists as a private-key group is also rejected; converting that group
is outside this scope.

### Import a private-key group

Retain the current exact-key verification behavior for uninstall-surviving items, but remove the
single-wallet prohibition. Register one private-key group only after authenticated reload and
sign-and-recover proof. Require a group name and assign the account its default `Account 1` label. An
additive import returns to the Accounts list without dismissing the sheet or changing home selection;
initial setup selects the account and enters home. A duplicate address is rejected rather than linked
to two groups.

### Derive an account in a seed group

1. Acquire the group lifecycle claim.
2. Validate that the group is seed-backed and active.
3. Capture its monotonic `nextDerivationIndex` below `2^31`.
4. Authenticated-load the protected entropy.
5. Derive the child, address, and sign-and-recover proof.
6. Handle invalid BIP-32 children without claiming the wrong path; persist the actual next attempted
   index if the derivation policy skips one.
7. Reject any address collision.
8. Atomically append the account and advance `nextDerivationIndex`.
9. Give the account the default label `Account {actualDerivationIndex + 1}` and keep the Accounts
   sheet open. Home selection changes only if the user subsequently selects it.
10. Clear every transient secret buffer and release the claim.

Concurrent derive operations must never allocate the same index.

### Select the home account

1. Validate the account and key-source registration without releasing secret bytes.
2. Use `commitRegistryTransition` to journal the complete next registry and expected compatibility
   projection, apply the projection, and then commit `homeSelectedAddress` plus registry revision.
3. Publish the new home account to the view model only after the journal is removed.
4. Cancel prior balance and account-scoped load tasks.
5. Hydrate the selected account's cached total.
6. Refresh balance, Activity, Connected Apps, Settings, and authorizations for the new account.

This operation does not change the default connection account, grants, active origin accounts,
pending requests, or provider account state.

### Edit wallet and account labels

Label edits are registry-only, revisioned mutations under the registry lock. Trim and validate every
edited label before committing all edits from one editing session in one registry revision. A failed
save leaves the prior labels authoritative and keeps the picker in editing mode with an actionable
error. Label changes do not alter addresses, group IDs, home/default/active selection, grants,
pending-request bindings, activity ownership, compatibility projection, or keychain identifiers.

Native Safari account summaries display the latest labels after the account blockie in the popup
action bar, replacing the shortened address text when a label is available. The full address remains
hover metadata and the account identity, and labels are never included in canonical request bindings.
A label change while a request is pending therefore does not invalidate, rebind, or otherwise mutate
that request.

### Remove an account registration

Use a recoverable account-deletion state because account visibility, pending requests, connection
state, and balance cache span multiple stores:

1. Require destructive confirmation that identifies the account by label and shortened address.
2. For a private-key account, run the existing complete group-deletion flow because its group and
   protected key have no other account.
3. Reject independent removal of the last registered account in a seed group and direct the user to
   Remove Wallet, which deletes the seed group.
4. Acquire the seed group's lifecycle claim, choose a deterministic surviving home account when the
   removed account is home-selected, and use `commitRegistryTransition` to mark the account
   `.deleting`, update home selection and compatibility projection, and commit the next revision.
5. Reconcile or terminalize that account's pending records under the same marker rules as group
   deletion. No protected signing operation beginning after `.deleting` commits may resolve it.
6. Under registry-then-connection locks, atomically remove the account's grants and active mappings
   and repair `defaultAccount` to the surviving home or first active account.
7. Remove the account's balance cache. Preserve activity rows under their canonical address.
8. Remove the inactive account registration from the group without changing `nextDerivationIndex`.

Relaunch resumes an interrupted account deletion. The seed entropy remains protected and usable by
the group's surviving accounts, but the removed derivation path is not presented, selected, signed,
or automatically re-registered. The group's retained account-zero seed identity makes an explicit
re-import of the same seed duplicate group input, not an account-restore mechanism.

### Forget a wallet group

Use a recoverable group-deletion state rather than attempting an all-or-nothing sequence across
keychain, files, pending requests, and activity.

1. Acquire the group lifecycle claim used by secret release and signing.
2. Choose the deterministic surviving home account, or `nil` when this is the last group.
3. Through `commitRegistryTransition`, mark the target group `.deleting`, replace
   `homeSelectedAddress` when it points into that group, apply the fail-closed compatibility
   projection first, and commit the next registry revision. The persisted registry remains valid
   after this step. Release the registry lock while retaining the group claim.
4. For each request belonging to the group, take its per-request claim without a registry lock held
   and check connection state for a connect marker before mutating the record. Reconcile and remove a
   valid marker as an already-committed success; preserve and fail loudly on a conflict; otherwise
   terminalize a pending request with an explicit account-removed error.
5. Delete the group's one seed-entropy item or one private-key item.
6. Acquire registry then connection-state locks and write one atomic connection-state revision that
   removes every group account's grants and active mappings and repairs `defaultAccount` to the
   surviving home account or first surviving account, clearing it if none remain. Release both locks.
7. Remove every group account's balance cache.
8. Remove matching retained migration material only for the proven migrated account.
9. Remove the already-inactive group from the registry.
10. Return to setup only when no groups remain.

Activity remains retained and becomes visible again if the same address is explicitly re-imported.
Relaunch resumes an interrupted `.deleting` group. A committed deletion must win before any protected
operation can release a secret; an operation already holding the lifecycle claim may finish before
deletion commits.

## Home Account Picker

Change the first `AddressMenuButton` menu action from a passive row into an action that dismisses the
menu and presents `AccountPickerView`.

The picker uses a navigation sheet and contains:

- One section per wallet group.
- The editable wallet-group label as each section heading.
- Accounts labeled by their editable account label, with blockie and shortened address.
- A checkmark on the home-selected account.
- `Add Account` inside a seed-group section.
- An add flow offering Create New Wallet, Import Seed Phrase, and Import Private Key.
- No derive action for a private-key group.
- A top-right `Edit` button that enters editing mode, exposes group/account label fields, and provides
  destructive account-removal controls. Dotted underlines identify editable wallet and account labels.
  The button becomes `Done` while editing; the sheet retains its separate close control.

Selecting an account persists and refreshes home state without dismissing the sheet. Failure leaves
the old account and its visible state unchanged and shows the error in the sheet. Adding a derived
account also leaves the sheet open.

`ImportWalletView` must distinguish initial setup from adding a group. It may not dismiss merely
because some wallet already exists. Generated seed creation requires a separate backup/confirmation
view rather than the current immediate random-private-key button. Every additive group flow includes
a wallet-group name field. On success it pops back to the root Accounts list rather than dismissing
the outer sheet; the new account is visible there but is not implicitly home-selected.

Account-bound navigation must use an account snapshot or stable address identity. Switching home
accounts dismisses or reconstructs Settings, Private Key, Activity, and Connected Apps so an already
open destination cannot reveal or mutate the wrong account.

Settings presents `Forget Wallet` for a seed group and explains that its seed and every derived
account will be removed. A private-key group may retain `Forget Account` wording because the group has
exactly one account.

## Account-Scoped Activity and Connected Apps

### Activity

Add account-explicit APIs:

```swift
func activities(account: String, limit: Int = 100) throws -> [ActivityRecord]
func unresolvedTransactions(account: String, limit: Int = 500) throws -> [ActivityRecord]
func activities(for site: ConnectedSite, account: String, limit: Int = 100) throws
  -> [ActivityRecord]
```

Both transaction and signature halves of the union query compare `from_address` case-insensitively.
Connected-app activity requires both account equality and the existing exact origin/profile or legacy
domain rule. Detail-to-connected-app navigation also requires account equality.

Receipt polling may continue across every unresolved account when deliberately invoked as background
maintenance, but visible reads and foreground refresh state are always scoped to the home account.

### Connected Apps

Add account-explicit connection-state APIs:

```swift
func grants(account: String) throws -> [ConnectedSite]
func disconnect(account: String, origin: String, profileID: String?) throws
func disconnectAll(account: String) throws
```

`ConnectedSite.id` includes account. Disconnect removes only the selected account's grant. If that
grant is the active account for the origin/profile, clear the active mapping; preserve all other
account grants. Never remove a legacy mirror entry whose stored address belongs to another account.

## Safari Connect Flow

### New plain connection preparation

1. Background derives authoritative origin from Safari sender context.
2. Native acquires registry then connection-state locks and resolves an active, granted, registered
   account from those same snapshots.
3. If one exists, `eth_requestAccounts` and capability-less `wallet_connect` return it immediately.
4. If no exact active account exists and the domain has no exact grants, a valid legacy hostname grant
   returns its stored registered account immediately under the locked compatibility policy.
5. If no active account exists but the default account already has an exact grant, native may
   reactivate it atomically and return it.
6. Otherwise native chooses the valid default connection account, falling back only as documented,
   and prepares a canonical `.connect` request.
7. The pending request records the proposed account; no grant or default changes yet.

Default selection and any existing-grant reactivation happen while both snapshots are locked.
Preparation releases those locks before RPC work, then reacquires registry, connection, and prepare
locks in order for final revision/account validation and pending check-and-insert.

An already-active origin does not open another connect popup merely to switch accounts. The popup
picker chooses an account only when a plain connect approval already exists. Changing an established
origin's active account without revoking its existing grant would require a separate future entry
point and is outside this scope.

SIWE `wallet_connect` remains `.siwe`, binds its exact EIP-4361 message and account at preparation,
requires signing, and is never popup-rebindable.

### Sticky-bar account picker

Current connect rendering must change from a body `Wallet` row to a sticky account button. Other
active request kinds keep their account in the sticky bar but it remains noninteractive.

Pressing the active plain-connect account:

1. Calls a native account-list action returning public registry summaries only.
2. Renders an in-popup picker grouped by the editable wallet-group label. Each row places its blockie
   before the editable account label with a smaller muted shortened address below, matching the native
   picker proportions. Group headings retain their original capitalization; the full address remains
   canonical rebind data and hover metadata.
3. Offers no create, import, derive, delete, or key-export action.
4. Marks the pending request's current account with a checkmark.
5. Disables decision controls while a selection transition is in flight.
6. Calls native with request ID, the displayed summary revision, and selected existing address.
7. Renders the updated native summary after the transition commits.

The native rebind operation:

- Accepts only the global active queue-head `.connect` record.
- Rejects SIWE and every non-connect kind.
- Requires matching Safari profile, pending status, unexpired record, and caller-reviewed revision.
- Requires the account to resolve to a valid active registry group and available key source.
- Acquires the selected account's group lifecycle claim before the per-request claim, so deletion
  cannot commit between validation and rebinding.
- Acquires the same per-request claim used by approve/reject.
- Rebuilds the record with the new account, new account-inclusive binding digest, and incremented
  revision while preserving `requestKey` and `intentDigest` exactly.
- Does not authenticate, create a grant, change origin active state, change home selection, or change
  the connection default.

Queued connect cards remain collapsed and noninteractive. The queue retains the established global
one-active-request policy and uses creation time plus UUID as a deterministic tie-breaker. When an
earlier request belongs to a different Safari profile, the visible popup must not imply its own first
card is approvable; it shows a non-sensitive waiting state instead.

### Successful connect commit

Connect completion is a recoverable state transition, not independent best-effort writes.

1. Send request ID, decision, and the revision displayed by the popup; never send canonical params.
2. Acquire the request account's group lifecycle claim.
3. Acquire the pending-request claim.
4. Reload the record, acquire the connection-state lock, and look up its request ID before expiry,
   legacy terminalization, or any other pending mutation. If a marker exists, validate the marker and
   record together, reconcile a matching record to consumed, remove the marker in a later state
   revision, and return the committed result. Preserve and fail loudly on any conflict.
5. With no marker, release the connection lock. Terminalize a legacy binding; otherwise verify request
   kind, profile, queue head, expiry, caller-reviewed revision, and account-inclusive binding.
6. Under the wallet-registry lock, verify that the request account remains registered, then release
   that lock; the group claim prevents deletion from committing afterward.
7. Acquire the connection-state lock and recheck that no marker appeared while locks were released.
   If one did, follow step 4 recovery.
8. Otherwise atomically write one new connection-state revision containing the selected account's
   exact grant, that origin/profile's active account, `defaultAccount`, and a `ConnectCommit` whose
   binding digest is the reviewed record's digest and whose result is `[selectedAccount]`.
9. Release the connection-state lock and mark the pending record consumed with the exact committed
   result while retaining the per-request claim.
10. Reacquire the connection-state lock and remove the matching marker only after reloading and
   verifying that consumed record. Failure to remove it is recoverable and leaves the marker intact.
11. Mirror legacy connection metadata best-effort only after both authoritative writes.
12. Return the result to the originating bridge and release claims.

The connection-state commit marker is the recovery authority if the process exits between steps 8
and 9. Request status, approve, and reject paths must check it before deciding a still-pending connect
record: they reconcile that record to consumed and expose the committed result, never apply a later
rejection. A marker may be removed only after the matching consumed pending record is durable; normal
completion or recovery removes it in a later connection-state revision while retaining the request
claim. Pending records are not removed in this scope. If no marker exists, connection state contains
no partial grant/default/active mutation from that request because those fields share one atomic file
write.

Recovery handles every persisted combination explicitly:

- No marker plus a valid pending record follows the ordinary decision path.
- A marker plus the matching pending record, whether pending or already consumed with the same result,
  converges to consumed, removes the now-unnecessary marker, and returns the marker result.
- A marker plus a missing record, a non-consumed terminal record, a different consumed result, or a
  mismatched request revision/account/binding/result is corruption. Preserve both stores and fail
  loudly; never roll back the committed grant/default or sign/re-enqueue.
- A marker's `connectionRevision` must not exceed the current state revision. When equal, the same
  atomic state must contain the marker's exact origin/profile/account grant, active mapping, and
  default. At a later state revision, subsequent valid disconnect or connect operations may have
  changed those fields, so the durable marker remains sufficient evidence of the earlier result.
- A marker without a unique request ID, normalized origin/profile/account, or internally consistent
  `[account]` result makes the whole connection-state decode fail loudly.

Marker lookup and validation precede any pending-record mutation. A marker paired with a legacy
binding is corruption and both stores remain unchanged; with no marker, legacy terminalization
precedes pending expiry, queue checks, or rejection.

Reject also carries the displayed revision so a stale popup cannot reject a differently rebound
account. A revision mismatch returns an explicit stale-review error and forces the popup to reload the
current native summary.

Reject, expiry, popup closure, rebind failure, and every failure before the atomic connection-state
commit leave the previous default unchanged. A pending-record write failure after that commit is
recovered from its marker and therefore retains the newly committed default and result. Retrying after
interruption converges on that same committed result.

## Existing Connected-App Requests

For every wallet-owned method after connection, treat an exact active mapping or the permitted legacy
hostname fallback as the resolved connected account:

- Resolve the active account from authoritative origin/profile connection state.
- Require the account to remain registered and its protected source to be available.
- Validate standard address or `from` params against that account.
- Persist the resolved account on any pending record.
- At approval, require the same origin/profile active account and grant still exist.
- Fail terminally if the app disconnected, changed its active account, or forgot the account before
  approval.

This applies to personal signing, typed data, SIWE, transactions, batches, chain switching,
capabilities, and call-status ownership. It closes the current ambiguity where several signing kinds
can prepare without an exact connection-grant check.

The active account for one origin/profile never follows home selection or a successful connection at
another origin/profile.

## Provider Account Semantics

Add provider account state and `accountsChanged` support.

### `eth_accounts`

Return one account only when native connection state contains a valid active grant for the sender
origin/profile. When the domain has no exact grants, the existing hostname-only compatibility grant
returns its stored registered account without converting its precision. Otherwise return `[]`.

### `eth_requestAccounts` and plain `wallet_connect`

- Return the active granted account without a popup when one exists.
- Preserve seamless authorization for the stored account of a valid hostname-only grant when the
  domain has no exact grants.
- Reactivate an already-granted default account only when no active mapping exists.
- Otherwise create a plain connect approval using the default proposal.
- On approval, return the popup-selected account and update provider account state.

### `accountsChanged`

Emit only when the account array visible to that page changes:

- Successful connection or active-account replacement for that origin/profile.
- Disconnect of its active grant.
- Forgetting its active account.
- Recovery that invalidates an active mapping.

Do not emit for:

- Home-only account changes.
- Default-connection changes caused by another origin.
- Popup selection before approval.
- Rejected, expired, or failed connect requests.
- Grants or active changes in another origin or Safari profile.

The originating provider can update directly from a successful request result. Other matching tabs
refresh through the background/bridge account-state route. The installed iOS SDK has no containing-
app equivalent of macOS `SFSafariApplication.dispatchMessage`, so app-driven deletion cannot directly
push JavaScript. First verify focus, `pageshow`, and visibility refresh when returning to Safari. Add
bounded polling only while a page is visible if that lifecycle proof is insufficient.

Fix `wallet_disconnect` result parsing while this route is changed; the current background code checks
the outer native envelope instead of the nested success value.

## Concurrency and Lock Ordering

Introduce explicit cross-process claims rather than relying on independently created Swift actors.

Required lock domains:

- Registry adoption/migration claim.
- Wallet registry mutation and home selection.
- One group lifecycle claim spanning seed/private-key release, derivation, and deletion.
- Connection-state mutation.
- Pending prepare deduplication.
- Per-request rebind/approve/reject claim.
- Existing account/chain transaction-submission claim.

The lock order is fixed. Any operation holding more than one domain acquires only in this order:

1. Registry-adoption claim during migration/readiness checks.
2. Group lifecycle claims, sorted by group UUID when more than one group is involved.
3. Per-request claim for pending transitions.
4. Wallet-registry lock when validating or mutating membership.
5. Connection-state lock when resolving or committing grants/default/active state.
6. Pending-prepare deduplication lock.
7. Transaction submission claim for nonce-bearing RPC work.

Do not hold registry or connection-state locks during network RPC calls or interactive authentication.
Capture a revision, release state locks, perform slow work, reacquire in the same order, and reject if
the revision changed. Never acquire an earlier domain while retaining a later one. The adoption claim
and group claims may span their required authentication, and a group claim may span network submission;
registry and connection locks may span neither. Prepare resolves and performs RPC work before taking
the prepare lock, then acquires any required registry/connection locks ahead of the prepare lock for
the final check-and-insert. Tests must exercise every pair of
concurrently reachable operations. When an operation reads a request to discover its group before it
can claim that request, it acquires the discovered group claim, then the request claim, then reloads;
an account/group change causes release and retry rather than continuing under the wrong claim.

## Migration Plan

### Current rebuild wallet (v2)

- Unsupported as a migration source.
- Do not inspect or adopt `wallet-address.conf`, `sw2.walletAddress`, `connectedOriginsV2`, the
  singleton native-balance cache, or retained pending-request files when no registry exists.
- Do not add fallback behavior that silently turns an unsupported v2 installation into a partial
  multi-account installation. Its retained keychain item remains orphaned unless explicitly imported
  through a future reviewed recovery flow.

### Old Dawn-format wallet

- Preserve the existing old address/ciphertext/Secure Enclave lookup and authenticated proof.
- Complete or safely resume pending migration before registry adoption.
- Create one private-key group only after the new-format sign-and-recover proof succeeds.
- Retain old material under the existing cleanup policy.

### Existing seed-imported wallet

Treat it identically to another existing private-key wallet. The old application stored only account
zero's private key. Do not label it seed-backed or permit sibling derivation.

### Existing connection grants

- Preserve Dawn `connectedSites` hostname-only grants with legacy precision and their stored address.
- Never assign a legacy grant to the current home or default account.
- Preserve grants for addresses not currently registered as dormant records; they cannot become
  active or sign until that exact account is explicitly re-imported.
- Do not ingest `connectedOriginsV2`; that current-rebuild format is outside migration scope.

### Existing activity

Keep every Dawn row. Account-scoped views include rows with a matching `from_address`; rows without a
provable account remain retained but do not appear in an account-scoped view. Current-rebuild pending
records are not used to backfill them.

### Existing pending requests

Dawn has no supported `PendingRequests` format. Current-rebuild pending files are not migrated or used
for activity backfill. Account-inclusive binding version 2 remains the required format for requests
created by the multi-account runtime; that protocol version is unrelated to the unsupported wallet-v2
migration source.

## File-Level Change Map

### WalletCore

- `WalletStore.swift`: replace singleton authority with registry access, migration projection, revision,
  locks, group lifecycle, and separate home selection.
- New `WalletRegistry.swift`: value types, validation, atomic persistence, migration, and mutations.
- `WalletFactory.swift`: create/import group operations, derive-account operation, duplicate handling,
  labels, account/group deletion, and rollback/recovery.
- `BIP39.swift`: entropy encoding/decoding, mnemonic generation, arbitrary account index derivation,
  and buffer clearing.
- `KeychainKeyStore.swift`: retain private-key items and add reusable protected-data mechanics without
  weakening `.userPresence` behavior.
- New `KeychainSeedStore.swift`: entropy items keyed by group ID.
- `Signing.swift`: account resolver plus private-key and seed-account signers.
- `BalanceCache.swift`: multi-account schema without current-rebuild singleton decoding.
- `ConnectedSitesStore.swift`: replace runtime authority with atomic connection state, account-specific
  grants, active mappings, default account, Dawn hostname-grant migration, and legacy mirror.
- `ActivityStore.swift`: account predicates, indexes, repeated-signature event identity, and migration.
- `ApprovalRequest.swift`: account-inclusive binding and intent digest versions.
- `PendingWalletRequest.swift`: current account-inclusive binding/revision and atomic connect rebind;
  no current-rebuild request migration.
- `WalletService.swift`: operation-specific account resolution, exact grant checks, visible accounts,
  connect rebind/commit, account-scoped activity, and disconnect semantics.
- `TransactionSubmissionLock.swift`: retain account/chain nonce isolation and integrate documented lock
  ordering with account lifecycle claims.
- `AuthorizationService.swift`: resolve and revalidate the selected home account in Settings while
  Safari requests use their origin-active account.

### Containing app

- `WalletViewModel.swift`: registry state, home selection, labels, group operations, task cancellation,
  revision guards, account-scoped balance, and account/group deletion recovery.
- `ContentView.swift`: active address-menu action, picker presentation, account-scoped destinations,
  and selection identity.
- New `AccountPickerView.swift`: grouped account list, persistent edit mode, label fields, removal, and
  add-flow navigation that returns to the list.
- `SetupView.swift`: generated seed-group creation instead of immediate random private key.
- `ImportWalletView.swift`: initial versus add-group modes and success-driven dismissal.
- New seed backup view: generated mnemonic display, confirmation, privacy clearing, and cancellation.
- `SettingsView.swift`: group-aware deletion wording and seed-derived private-key export.
- `ActivityView.swift`: explicit home account and account-scoped service APIs.
- `ConnectedAppsView.swift`: explicit account grants, details, activity, and disconnect.
- `AuthorizationsView.swift`: account snapshot and stale-selection handling.

### Safari native extension

- `SafariWebExtensionHandler.swift`: remove global home signer construction; dispatch account-list,
  visible-account, connect-rebind, and account-specific approval actions through the core. Public
  account summaries include the latest group/account labels without treating them as identity.

### Safari JavaScript

- `popup.js`: sticky connect-account button, existing-account picker, native rebind, rerendering,
  disabled transition state, and structured errors.
- `popup.css`: sticky picker controls, selected state, focus treatment, and compact account list.
- `background.js`: atomic visible-account route, popup account actions, scoped account propagation,
  and correct disconnect response.
- `bridge.js`: account-state bootstrap/refresh and origin-tab event delivery.
- `provider.js`: account state plus `accountsChanged` behavior.
- `manifest.json`: version bump for Safari cache invalidation; add no permission unless lifecycle proof
  requires one.

### Tests and documentation

- `WalletFactoryTests.swift`: groups, labels, duplicate imports, derivation, rollback, and account/group
  deletion recovery.
- `SeedPhraseTests.swift`: entropy/mnemonic vectors and account indexes.
- `MigrationTests.swift`: Dawn migration states, conflicts, authenticated proof, and retained secrets.
- `ConnectedSitesTests.swift`: Dawn hostname migration, multiple accounts, active/default separation, and
  concurrent updates.
- `ActivityStoreTests.swift`: account filters, migration, repeated signatures, and connected-app scope.
- `ApprovalTests.swift`: account-inclusive binding, rebind restrictions, races, and connect commit.
- `TransactionSubmissionTests.swift`, `SIWETests.swift`, `EIP5792Tests.swift`, and
  `AuthorizationServiceTests.swift`: active-account and grant revalidation.
- JavaScript provider/background/popup tests: picker, no-create boundary, account events, scoped tabs,
  and direct-native/worker fallback.
- `docs/engineering-handover.md`: current approved scope and architecture.
- `docs/implementation-notes.md`: chronological implementation and verification entries.
- `skills/stupid-wallet-debugging/SKILL.md`: update only when implementation/debugging discovers
  reusable account-state inspection or failure signatures.

## Implementation Gates

### Gate A: Registry and migration

Status: complete on 2026-08-25.

Exit conditions:

- Versioned registry validates both group kinds and separate home selection.
- A durable `.migrating` barrier prevents app and extension request handling until Dawn key,
  connection, activity/network, downgrade-fallback, and registry adoption validates as `.complete`.
- Existing Dawn v1 installations adopt exactly one private-key group. Current rebuild v2 installations
  are explicitly unsupported migration sources.
- Conflicting or interrupted state fails or recovers deterministically.
- Registry/projection interruption commits forward exactly, and the rebuild UserDefaults fallback is
  proven absent before multi-account operations are enabled.
- Old key material is not deleted.
- The new account-bound balance cache starts empty for Dawn migration.
- Atomic connection-state authority migrates Dawn hostname grants without changing their stored
  accounts or authorization precision.
- A real Dawn v1 installation upgrades in place on a physical device, and real containing-app and
  Safari-extension processes cannot overlap adoption without either process being terminated.

### Gate B: Seed groups and account lifecycle

Status: complete on 2026-08-26. Hermetic implementation includes canonical BIP-39 entropy and
arbitrary account derivation, protected seed storage by group UUID, empty-install authority bootstrap,
suspension-safe group lifecycle coordination, additive seed/private-key registration, serialized
monotonic derivation, duplicate rejection, rollback before registration, registry-resolved seed
signing/export, and resumable `.deleting` cleanup. Deletion reconciles valid Gate F connect-commit
markers before account cleanup and fails loudly on marker/record conflicts. Physical-iPhone acceptance
proved generated-backup cancellation without partial registration, protected seed import and monotonic
sibling derivation, seed-derived export and Safari signing behind on-device Face ID, and complete group
deletion while preserving an independent private-key group.

Exit conditions:

- Generated and imported BIP-39 entropy produces independent known addresses for indexes zero and one.
- Seed entropy is protected by `.userPresence` and `ThisDeviceOnly` on a physical device.
- Derivation is serialized and indexes are monotonic.
- Private-key groups reject additional accounts.
- Create/import/derive rollback leaves no visible partial group.
- Group deletion is recoverable and cannot race signing after committed removal.

### Gate C: Account-scoped connections and activity

Status (2026-08-26): hermetically complete. Runtime authorization reads use registry-then-connection
locking; account grants, active/default state, provider versus exact-row disconnect, account-filtered
activity, repeated-signature identity, containing-app deletion, serialized SQLite migration, strict
known-schema validation, and a real child-process grant update are covered. Provider disconnect also
preserves native structured failures through the JavaScript envelope. Physical migration and Safari
lifecycle evidence remain governed by their existing Gate A/B and later provider gates.

Exit conditions:

- Multiple accounts retain grants for one origin/profile.
- Default and active connection accounts persist separately from home selection.
- Dawn hostname-grant migration preserves stored addresses and precision.
- Disconnect and forget remove only matching account state.
- Activity and connected-app details cannot mix account rows.
- Repeated deterministic signatures persist as separate canonical request events.
- Cross-process grant updates are not lost.

### Gate D: Containing-app account UX

Status: complete on 2026-08-26. The containing app now uses the registry-backed group manager for
generated seed creation, seed/private-key import, derivation, persisted home selection, and group
deletion. Simulator acceptance covered additive groups, sibling derivation, relaunch persistence,
account-scoped views, seed-derived export, and the independence of home selection from connection
authority. Gate B's physical protected-seed acceptance completed on 2026-08-26.

Exit conditions:

- Address menu opens the picker.
- Existing account selection updates home UI and persists across launch.
- Create/import/derive flows work without replacing existing groups.
- Balance, Activity, Connected Apps, Settings, authorizations, and private-key export use the home
  account only.
- Home selection does not change connection default or provider-visible accounts.

### Gate E: Account-specific Safari request policy

Status: hermetically complete on 2026-08-26. Safari resolves provider-visible accounts from one
validated registry/connection snapshot, and production request handling resolves every non-connect
wallet-owned operation from the authoritative origin/profile active account. Prepare validates standard
account parameters before persistence; approval revalidates the same account and resolves its protected
signer from the persisted request. Cross-account requests retain one deterministic global queue, and
active-account replacement terminalizes immutable signing and SIWE records instead of substituting an
account. Physical seed-account Safari signing and foreground Face ID completed on 2026-08-26. Mac
Safari compatibility acceptance and the remaining physical cross-profile/device-lock checks also
completed that day; Gate H is closed.

Exit conditions:

- `eth_accounts` resolves account and grant atomically.
- Every signing/sending method validates active origin/profile account at prepare and approve.
- Mismatched `from`/address params fail without signing.
- Requests from different connected accounts coexist in the global queue and resolve the correct
  protected signer.
- SIWE and all non-connect requests remain immutable.

### Gate F: Popup connect account picker

Status: complete on 2026-08-26, including physical-iPhone acceptance. Native summaries and popup decisions carry the reviewed request
revision; only the active plain-connect request can rebind to an available registered account under the
group/request claims; and approval atomically writes the grant, active account, future default, and
connect marker before pending consumption. Status, decisions, and group deletion reconcile valid
markers to the committed result. Simulator acceptance listed grouped private-key and seed accounts,
rebound to a seed account, rerendered that account, and completed the connection. Physical Safari later
listed the private-key group plus three seed accounts, rebound a distinct-origin connect to a seed
account, committed it, and used that account for an authenticated signing request while Safari remained
foregrounded.

Exit conditions:

- Only the active plain-connect sticky account is interactive.
- Picker lists registered, available existing accounts and no creation controls.
- Native rebind is claimed, revisioned, account-bound, and profile-bound.
- Approve and reject require the revision displayed by the popup, so stale review cannot decide a
  rebound account.
- Rebind racing approve/reject has exactly one outcome.
- Rejection and failure do not change the default.
- Successful approval commits grant, active account, default, and request result recoverably.

### Gate G: Provider account lifecycle

Status: complete on 2026-08-26. The provider now owns a deduplicated account snapshot initialized
from native `visibleAccounts`; successful connection and disconnect update the originating provider
directly, while the background worker refreshes only tabs whose top-level origin matches the
authoritative sender. The isolated bridge refreshes on initial injection, `pageshow`, window focus,
and visible `visibilitychange`. Simulator and physical-iPhone evidence proved a retained connection
after Safari relaunch and an app-side disconnect becoming visible immediately when Safari regained
focus without a page reload. Two physical same-origin tabs also converged after Connect, while changing
only the containing-app home account left the dapp account unchanged. These lifecycle signals were
sufficient, so no polling was added.

Exit conditions:

- Provider account state matches native `eth_accounts` after connect, disconnect, relaunch, and account
  removal.
- `accountsChanged` is scoped to the correct origin/profile and is not emitted for home/default-only
  changes.
- Other tabs for the same origin/profile converge after successful connect.
- Safari return-to-page lifecycle is proven; polling is added only if required by evidence.

### Gate H: Upgrade and device acceptance

Status: complete on 2026-08-26. The physical-iPhone multi-account lifecycle, Safari
foreground-authentication, cross-profile isolation, device-lock recovery, and Mac compatibility
Safari account model are complete. Gate A supplies the real Dawn in-place upgrade proof, and a second
real Dawn-to-current upgrade was completed through TestFlight on Apple Silicon Mac. Mac Safari proved
grouped account selection, a derived seed-account connection, same-origin bootstrap, rejection,
durable request completion, independently recovered signing, and generic RPC passthrough without
platform-specific web code. On the physical iPhone, one exact origin retained different active
accounts in Personal and a disposable second Safari profile; a signing request and its badge were
visible only in the requesting profile. A fresh protected signing request remained pending across a
device auto-lock interval, released no result while locked, recovered unchanged, and could be
rejected normally after reconnection.

Exit conditions:

- A real old release upgrades in place to one group without address or signing identity change.
- Physical-device generated seed, import, derive, sign, private-key export, and complete group deletion
  behave as documented.
- Physical-device Safari proves connection selection, grant retention, active-account signing, and
  foreground authentication.
- Physical-device Safari proves exact-origin account, event, badge, and pending-request isolation
  across profiles.
- A protected pending request releases no result while the device is locked and recovers for a normal
  terminal decision after unlock.
- Mac compatibility Safari proves the same account model without platform-specific web behavior.

### Gate I: Account labels and picker editing

Status: core behavior implemented and simulator-verified on 2026-08-26. The Done transition resigns
focused in-place label fields before registry publication so SwiftUI does not remove or update a
first-responder list header during a collection-view batch update. Full account-deletion fault
injection and physical-device acceptance remain before this gate is complete.

Exit conditions:

- Current multi-account registries migrate to deterministic nonempty group/account labels without
  changing IDs, addresses, derivation indexes, home selection, or secret storage, and seed groups gain
  a retained account-zero identity that prevents duplicate seed-group import after account removal.
- The Accounts sheet has a top-right Edit/Done control for editing group/account labels and removing
  accounts with destructive confirmation.
- Label edits persist across relaunch and never affect signing identity, grants, activity ownership,
  or pending-request bindings.
- Selecting or deriving an account keeps the Accounts sheet open.
- Create/import group flows require a group name and return to the Accounts list without dismissing
  it or implicitly changing home selection.
- Seed-account deletion is resumable, removes only that registration and its live account-bound state,
  preserves activity and the group seed, and never reuses its derivation index.
- Removing a private-key account deletes its complete one-account group; removing the final seed
  account requires complete wallet-group deletion.

## Verification Matrix

### Migration test setup

Migration acceptance starts from state produced by the shipping application, not by directly writing
fixtures into its App Group or keychain:

- On a dedicated physical test device, install the old Dawn-format release under the production app,
  extension, App Group, and keychain identities. In that app, create or import a disposable test wallet
  and exercise each state being migrated, including a connected test site and representative activity
  when those semantics are under test.
- Install the new build over the prepared Dawn installation without uninstalling the old build,
  clearing Safari data, or resetting App Group, UserDefaults, keychain, or Secure Enclave state first.
- Use only disposable test accounts with no real assets. Record the expected migration assertions, but
  never record seed phrases, private keys, personal wallet addresses, device identifiers, or sensitive
  signing payloads.
- Keep synthetic fixtures for deterministic unit and fault-injection coverage, but do not treat them as
  proof of shipped persistence, entitlement, access-group, authentication, or Secure Enclave migration
  semantics.

### Hermetic coverage

- Registry encoding, validation, revision, lock exclusion, corruption, and migration.
- BIP-39 entropy/mnemonic round trips and BIP-32 indexes zero, one, and maximum valid boundaries.
- Concurrent derive requests and invalid-child handling.
- Registry label-schema migration, label validation, concurrent edits, and labels excluded from
  canonical request identity.
- Seed-account deletion interruption at registry, pending, connection, cache, and final-registration
  boundaries; deleted indexes remain below an unchanged monotonic high-water mark.
- Duplicate seed/private-key/address imports.
- Seed/private-key item absence and orphan non-adoption.
- Fault injection before and after journal, projection, registry, adoption-state, connection-state,
  commit-marker, and pending-request writes/removals.
- Separate persisted home/default/active account state across relaunch.
- Two accounts granted to the same origin/profile.
- Exact origin and Safari-profile separation for each account.
- Seamless hostname-only authorization for its stored account until an exact grant exists.
- Account-scoped Activity unions, limits, receipt polling, and detail navigation.
- Provider retry before approval, after rebinding, after approval, and after commit-marker recovery
  resolves the original request; reuse of its key with changed intent fails, while the same intent
  with a newly minted key creates a distinct request.
- Global queue order and cross-profile invisible-head behavior.
- Plain-connect-only rebind and all prohibited kinds.
- Rebind versus approve/reject races through direct-native and worker-fallback paths.
- Stale popup revisions cannot approve or reject a rebound account.
- Signing request address mismatch, grant loss, active-account replacement, and account deletion.
- Connect commit interruption and every marker/pending/revision mismatch outcome, including ordered
  marker-plus-record cleanup.
- `accountsChanged` positive and negative cases.

### Simulator coverage

- Exercise synthetic Dawn registry adoption and corruption handling; real Dawn key migration remains a
  physical-device acceptance test.
- Create a seed group, confirm backup, derive account one, import a private-key group, and switch home.
- Edit group/account labels, relaunch, and verify they persist while account addresses and connections
  remain unchanged.
- Select an account and verify the Accounts sheet remains open; create a named group and verify the
  flow returns to the Accounts list without changing home selection.
- Remove a non-final seed account and verify its sibling accounts remain usable and the next derived
  account does not reuse the removed index.
- Verify different home balances and account-scoped Activity/Connected Apps.
- Connect one site to account A, then use a second new site to select account B in its connect popup.
- Verify that the first site's account-A grant and active account remain intact, home selection remains
  unchanged, and a third new site proposes B.
- Seed a production-shaped same-origin state with grants for A and B, verify its explicit active
  account is honored, and verify removing one grant preserves the other without silently switching it.
- Sign and send from the two active sites and confirm the account bound to each origin.
- Exercise popup closure, rejection, worker suspension, app backgrounding, and account-event refresh.
- Reinstall and relaunch on the preferred simulator after every implementation slice that changes iOS
  app code.

### Physical-device coverage

- User-presence protection for seed entropy and private-key items.
- Generated phrase backup clearing and cancellation.
- Seed import, account derivation, private-key export, signing, and complete group deletion.
- Individual seed-account removal while a sibling remains signable, followed by derivation that skips
  the removed index.
- App/extension registry and connection-state sharing.
- Popup account selection while Safari remains foregrounded.
- Existing-grant signing from two accounts and exact recovered-signer verification.
- Face ID/passcode cancellation and device-lock behavior for seed-backed signing.
- Real old-version state prepared through the old app UI, followed by in-place upgrade and retained
  identity without uninstalling or clearing shared state.

### Standard verification ladder

- Format changed Swift with repository `swift format` configuration.
- Format and lint changed JavaScript with the existing Oxc tooling.
- Run `node --check` and the JavaScript tests.
- Run the complete Swift test suite.
- Run `stupid-app doctor` after persistence, entitlements, extension, or project-shape changes.
- Run `stupid-app build` after Swift, resources, plist, entitlement, or project configuration changes.
- Reinstall and launch on the preferred simulator after iOS app changes.
- Record public-safe commands and outcomes in implementation notes.

## Final Acceptance Criteria

- An installation can hold multiple seed and private-key wallet groups without secret or metadata
  crossover.
- Supported Dawn v1 users retain their exact account and history in one private-key group. Current
  rebuild v2 installations have no migration guarantee.
- Seed groups derive deterministic sibling accounts without persisting child keys.
- Wallet groups and accounts have editable labels that never replace address/group identity.
- The home picker controls only containing-app account scope.
- Account selection keeps the home picker open, and named group creation returns to that picker.
- Activity and Connected Apps show only the home-selected account.
- A new connect popup proposes the persisted default connection account.
- The active connect account can be changed from the sticky bar using existing accounts only.
- Rejecting or abandoning that request does not change the default.
- Approving atomically preserves the grant, sets the origin/profile active account, updates the future
  default, and returns that account.
- Existing grants for every other account remain intact.
- Existing connected apps continue using their own active accounts regardless of home or default
  changes.
- Every signature, authorization, and transaction uses the account bound to the requesting
  origin/profile and canonical pending record.
- No non-connect request can be rebound from the popup.
- Provider account results and events never expose an ungranted account or cross an origin/profile.
- Forgetting one wallet group cannot delete, disconnect, hide, or sign with another group.
- Removing one seed account registration cannot remove its siblings or seed, and its derivation index
  is never reused.
