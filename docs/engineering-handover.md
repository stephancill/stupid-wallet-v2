# Engineering Handover

## Document Purpose

This document is the maintained engineering source of truth for the Stupid Wallet
rebuild. Read it completely before planning or changing code. Update it whenever
implementation changes the scope, architecture, security model, supported RPC behavior,
compatibility, acceptance gates, known risks, or recommended next work.

Historical work belongs in `docs/implementation-notes.md`. This document describes the
project as it exists now and the decisions that constrain its next implementation steps;
it should not preserve obsolete plans.

## Current Status

The repository now contains the application plus a full prototype of the signing
confirmation stack (a prototype, not yet gate-proven):

- Product: `StupidWallet` (SwiftUI), deployment target iOS 17.0.

## Wallet Backend MVP (Gates 0-3)

The approved notification MVP (`docs/wallet-backend-push-notifications-mvp-plan.md`) now has a
verifiable backend foundation under `server/` (developer rename of the plan's `WalletBackend/` label).
It is a TypeScript + Hono + Zod + D1 + Queues + Bun Cloudflare Worker intended to deploy at
`wallet-api.stupidtech.net`, with strict migration SQL, installation-key authentication and replay
defense, chain staging at the five-installation gate, reference-counted upstream subscriptions and an
outbox, signed webhook ingestion with `(webhookId, eventType)` composite deduplication, a durable
authenticated cursor event feed, and bounded APNs/upstream clients. Hermetic vitest suites run the
same schema on in-memory SQLite. Remaining MVP gates (entitlement/profile tooling, the Swift app and
Notification Service Extension, production APNs and physical-device proof) are still pending.

Multiple wallet groups and accounts are approved next-scope, and Gates A through H are complete. Gate
I is implemented hermetically and on the simulator: wallet-group/account labels are editable (with
focused fields resigned before Done publishes registry changes),
individual account-registration removal is recoverable, and the Accounts sheet remains open across
selection and returns from named additive group flows. Full account-deletion fault injection and
physical-device acceptance remain before Gate I is closed. The shared
plan now supports migration only from the old Dawn v1 application. Migration from the current
single-account rebuild (v2) is explicitly out of scope: its address registration, normalized grants,
singleton cache, and pending-request records receive no upgrade-preservation guarantee. Fail-closed
projection for downgrading a multi-account installation remains required and is not an upgrade input.
The Gate A implementation matches that scope: pre-registry identity resolution inspects only Dawn,
and authenticated Dawn key proof writes no rebuild registration artifact before registry adoption.
The outer adoption claim uses `NSFileCoordinator` on a stable App Group URL rather than retaining an
App Group advisory lock while either process may be suspended.

The shared core contains the wallet-registry foundation: versioned group/account/home value types, strict
snapshot and monotonic-transition validation, a dedicated cross-process advisory lock, durable atomic
file replacement/removal, a `.migrating` readiness barrier, and projection-first commit-forward
recovery through `wallet-registry-transition.json`. Registry creation and updates maintain the
fail-closed `wallet-address.conf` compatibility projection, including removing it for a seed-backed
home account. It also contains the migration-authoritative atomic connection-state foundation (`connection-state.json`
with a dedicated advisory lock): account-specific exact and legacy hostname grants, one active account
per origin/profile, a separately persisted connection default, durable connect-commit markers, strict
cross-field validation, revision-checked updates, Dawn hostname-grant migration that preserves each
stored account and precision, and a best-effort `connectedSites` legacy mirror.
`connectedOriginsV2` is not read during migration. The account-bound `BalanceCache` persists a
versioned per-account dictionary and rejects the unsupported singleton payload instead of converting
it. Gate A also contains `WalletRegistryAdoption`, the idempotent `ensureAdopted()` orchestrator that
adopts only authenticated Dawn installations into one private-key group behind the durable
`.migrating` barrier, initializes Dawn hostname grants and an empty account cache, removes and verifies
`sw2.walletAddress` as downgrade residue, and commits `.complete`. It also resumes interrupted
`.migrating` registries. Every adopted entry revalidates the complete registry, private-key source,
exact compatibility projection, connection state against active registry membership, account-bound
cache, and removed fallback. Current-rebuild pending records are neither terminalized nor used for
activity backfill. New pending requests carry the approved account-inclusive binding version 2 plus a
required monotonic revision; unsupported bindings are omitted from review/status and cannot be
approved or rejected. The barrier is wired into the request entries: the Safari handler and the containing-app
view model run `ensureAdopted()` before handling, and the
`WalletService` used by the extension is registry-gated and fails closed while `.migrating`. The containing app gates
its root content and account toolbar behind an explicit initial-load state, then publishes wallet or
setup state only after adoption succeeds and reads the validated registry home; the Safari extension
also constructs its singleton signer from that registry rather than the removed UserDefaults
fallback. Gate C is hermetically complete. `ConnectedSitesStore` now uses `connection-state.json` as
its runtime authority and resolves account visibility under registry-then-connection locking. It
retains multiple account grants for one origin/profile, keeps active and default connection accounts
separate, and provides distinct provider and exact-row disconnect semantics. Provider disconnect also
removes an effective same-account Dawn hostname fallback, while exact-row deletion retains separately
persisted hostname grants. Account-scoped activity queries and connected-app details cannot mix rows, repeated
deterministic signatures persist as separate request events, and group deletion removes only the
deleted accounts' connection state through the recoverable lifecycle. SQLite migration is serialized,
supports Dawn versions 1/2 and shipped rebuild versions 3/4/6/7/8/9, and validates known table,
column, foreign-key, uniqueness, and current-index shapes before mutation. A child-process test proves
an external grant update is retained by the next mutation. `wallet_disconnect` now rejects with the
native structured error when durable revocation fails instead of resolving a false success. The locked
behavior, migration,
account-resolution boundaries, popup connection picker, ordered implementation gates, and acceptance
criteria are specified in
`docs/multi-account-implementation-plan.md`. The containing app now exposes the Gate D multi-account
model. Gate E is hermetically complete: the Safari worker requests one native visible-account snapshot
for `eth_accounts` and existing-connect short-circuiting; production `WalletService` resolves
non-connect wallet-owned operations from the origin/profile active account, validates standard account
parameters before persistence, revalidates that account before approval, and resolves the protected
signer from the persisted account. Requests for different accounts retain one deterministic global
queue, while active-account replacement fails immutable signing and SIWE records rather than rebinding
them. Gate F is hermetically and simulator complete: a plain connect proposes the persisted connection
default; the active popup card lists grouped available accounts and performs a claimed,
revision-checked rebind; stale approve/reject decisions fail closed; and approval recoverably commits
the exact grant, active account, future default, and result before consuming the pending record.
Gate G is complete: the MAIN-world provider retains a deduplicated account snapshot and emits
`accountsChanged` only when its one-account-or-empty view changes. The worker resolves bootstrap and
refresh snapshots through native `visibleAccounts`, sends payload-free refresh notices only to tabs
matching the authoritative sender origin, and has each receiver resolve its own Safari-profile-bound
native snapshot. The isolated bridge refreshes on initial injection,
`pageshow`, focus, and visible `visibilitychange`; simulator return-to-page evidence proved this is
sufficient for containing-app revocation, so no polling was added. Physical iPhone Wi-Fi acceptance
then proved LAN provider injection, automatic same-origin two-tab convergence after Connect, app-side
disconnect on Safari return, retained account bootstrap after force-quitting Safari, and no provider
change after selecting a different containing-app home account.

Gate B is complete, including physical-device acceptance.
`EthereumSeedPhrase` generates canonical entropy, round-trips every supported English BIP-39 size, and
derives arbitrary accounts under `m/44'/60'/0'/0/{index}` while returning the actual valid index if
BIP-32 child derivation must skip. `KeychainSeedStore` stores one protected entropy item per lowercase
group UUID under the dedicated seed service, with the same user-presence, ThisDeviceOnly,
fresh-context, and noninteractive existence-probe policy as private keys. Empty installations now
bootstrap an empty complete registry plus revision-zero connection state under the adoption claim;
unsupported rebuild registration still remains untouched and is not adopted. A suspension-safe
`WalletGroupLifecycleCoordinator` serializes secret-bearing operations through `NSFileCoordinator`.
`WalletGroupManager` adds verified seed or private-key groups, rejects duplicate identities, derives
and atomically appends monotonic seed accounts, rolls back newly inserted secrets before registration,
and deletes a complete group through a persisted `.deleting` barrier. Deletion terminalizes matching
pending requests, removes the protected source, grants/active mappings, account caches, exact migration
material, and the registry group, and adoption resumes interrupted deletion before exposing state.
`WalletAccountResolver` resolves active registry accounts under the same group claim, derives seed
children transiently for signing or export, verifies the derived address, and never persists a child
key. The Safari home-account signer and Settings private-key export now use this resolver. Group
deletion reconciles a valid Gate F connect-commit marker to the already-committed consumed result before
connection cleanup and fails loudly on a marker/record conflict. Physical iPhone acceptance proved
generated-backup cancellation without partial registration, protected seed import, monotonic sibling
derivation, seed-derived private-key export, Safari popup account selection and signing behind on-device
Face ID, and complete group deletion while retaining an independent private-key group. Gate D is complete: the address menu opens a grouped account picker;
generated seed creation requires explicit backup confirmation; seed/private-key imports and sibling
derivation add groups/accounts without replacement; home selection persists through the journaled
registry transition; and balance, Activity, Connected Apps, Settings, authorizations, and private-key
export use stable home-account identity. Home selection never mutates connection default, grants, or
provider-visible active accounts.

The macOS direction is the same iOS build running through Apple Silicon's iPhone/iPad-app
compatibility environment, not a native macOS or Mac Catalyst target. Distribution uses
the iOS TestFlight build. The current `stupid-app run --mac` rejects extension-bearing projects
because its LaunchServices-only installer cannot create the plugin registration needed for native
messaging. By owner decision, local Mac native-messaging testing routes through **Xcode's "My Mac
(Designed for iPad)"** install via the tracked XcodeGen project at `Mac/` (`Mac/project.yml` →
`Mac/StupidWalletMac.xcodeproj`) that compiles the existing `Sources/`; it is the build/install
authority for the Mac-testing path only, and `stupid-app` remains the authority elsewhere.
That entitled install now works end to end on the Mac: the extension plugin spawns, native
messaging delivers, connect is consumed, and generated signatures recover to the registered
account. Popup propagation and immediate badge clearing after rejection are also proven. Full
transaction broadcast on the Mac is the remaining network-verified item. The resolved stale-image,
duplicate Safari-row, and request-propagation investigation is in
`docs/macos-safari-request-propagation-handover.md`; the installation boundary and remaining
acceptance workflow are in
`docs/macos-safari-extension-install-handover.md`.

Gate 0 (project and documentation baseline) exit conditions are met: production app,
extension, App Group, and keychain identities are restored in configuration and
entitlements; `stupid-app doctor` reports zero failures; and the app builds and launches
on the preferred simulator.

Gate 1 (Safari extension packaging spike) exit conditions are met on a physical device:
the extension enables in Safari, MAIN-world EIP-6963 discovery works on the prototype
dapp, the toolbar popup opens under user control and renders the native request card,
native messaging returns structured responses, and a native Face ID prompt is invoked
while Safari stays foregrounded.

Gate 2 (JSON and RPC core) exit conditions are met: `JSONValue` round-trips every JSON
type including nested `null`; `MethodPolicy` is the one authoritative native method
classifier (with a regression suite for handled, denied, and passthrough methods and a
casing fix); `RPCClient` preserves arbitrary results, `null`, and structured errors;
`RPCResolver` defaults every chain to `https://evm.stupidtech.net/v1/{chainId}`; and
`RPCOverrideValidator` rejects malformed, insecure, unreachable, and wrong-chain
endpoints. `WalletService.passthrough` tunnels unhandled methods through the one resolver.

Gate 3 (key and Ethereum primitives) exit conditions are met: vendored `libsecp256k1`
(v0.5.1) builds as the `CSecp256k1` SwiftPM C target; project-owned Keccak-256, RLP,
EIP-191, EIP-712 struct hashing, and legacy/EIP-1559 transaction serialization; key
generation, address derivation, EIP-55, sign, and recovery through the vendored target —
all verified against independent vectors. Legacy and EIP-1559 signing preimages, hashes,
and complete signed raw transactions now match viem byte-for-byte; this corrected the
earlier type-2 preimage, which incorrectly included empty signature fields. New-format key
storage in the shared keychain (`KeychainKeyStore`,
`.userPresence` + `ThisDeviceOnly`) was proven on a physical device: Face ID/passcode
released a self-test key on an on-device generate → save → reload-with-authentication →
re-derive → sign+recover run.

EIP-712 unsigned integer encoding accepts the full 256-bit value range and enforces each
declared `uintN` width without converting through host `Int`. A Permit2 vector containing
maximum `uint160` allowance and `uint48` fields matches viem's digest. Popup approval errors
extract structured native/RPC `message` text rather than rendering `[object Object]`.

Gate 4 (upgrade migration) exit conditions are met on a physical device: an old-format
wallet installed on the iPhone was upgraded in place by the new app, the recovered
address matched the old wallet, and a new-format authenticated signature verified against
it. The migration state machine plus `SecurityWalletBackend` read the old persisted
format (address in defaults, ECIES ciphertext in a generic-password item, Secure Enclave
P-256 decrypt with `.eciesEncryptionCofactorVariableIVX963SHA256AESGCM`), required an
authenticated sign-and-recover proof before completion, and retained old material until
explicit cleanup. Legacy keychain reads now bind the exact production access group and Dawn's empty
generic-password service rather than issuing a wildcard query across entitled groups. A duplicate
decrypt was removed so a successful run shows exactly two Face ID/passcode
prompts. If an attempt is interrupted after saving the new protected key, the pending marker resumes at
authenticated new-format verification; a crash before that marker may encounter `errSecDuplicateItem`,
which is accepted only so the same authenticated sign-and-recover proof can decide whether to continue.
Cancelling that prompt or attempting recovery without an enabled device passcode leaves migration
incomplete and old material untouched. The containing app identifies authentication as cancelled or
unavailable and instructs the user to enable a passcode and retry; it does not offer replacement-wallet
creation around the blocked registry.

Gate 5 (canonical approval protocol) exit conditions are met, including the grant +
standard-params work:
- Pending requests move into the shared App Group
  (`PendingRequestStore.defaultAppGroup = group.co.za.stephancill.stupid-wallet`), so the
  app and extension read/write the same durable records and pending requests survive
  service-worker suspension.
- The canonical review surface (`RequestKind`, `WalletPendingRequest.kind` and
  `payloadDigest`) renders per-kind native summaries via `ApprovalSummary.title/rows` for
  connect, message, typed-data, send, and add-chain requests. The Safari popup follows the
  old app's request-information hierarchy with site context, request-specific sections,
  account context, and action-specific buttons, while remaining an extension-owned renderer
  of native display-safe values. The active request's Reject/primary-action footer stays fixed
  at the bottom while details scroll and includes the blockie-prefixed signing account to the left
  of the actions; there is no duplicate wallet-brand header inside the
  Safari-owned popup. Typed-data summaries include primary type, domain fields, and ordered
  root message fields. Transaction details remain raw canonical destination, value,
  display-only estimated network fee, and full calldata. Calldata is initially clamped to three
  lines and expands in place when selected. Exact 20-byte address values throughout the review use
  a `blo` 2.0-compatible deterministic squircle blockie plus `0x1234...abcd` text, while retaining
  the full address as hover metadata. Native-value quantities are formatted in the network currency
  rather than shown as
  hexadecimal, and explicit add-network Chain IDs are decimal; nonce, gas limit, and raw
  fee fields are not exposed in the popup, while simulation and calldata decoding remain
  deferred. Generic chain rows resolve through the shared `NetworkStore` and display the
  persisted network name, falling back to `Chain N` for unknown metadata; explicit add-network
  Chain ID fields remain numeric. Atomic batches use the same bordered per-call detail table as
  single transactions, without ABI decoding, while retaining canonical target, formatted value,
  and raw calldata. The batch summary omits redundant Execution and Authorization rows. Each table
  stacks a compact To field plus Value and Data only when they are non-zero/non-empty, with labels
  above their values
  and clear spacing between fields. Target, value, and data use the same regular foreground
  typography. Popup values use regular system typography rather than
  switching hexadecimal fields to monospace. `WalletService.Summary` carries `kind`, `title`,
  ordered `rows`, a `queued` flag, and the active-head queue. Queued request cards start collapsed
  and their headings expand or collapse display details; expanding one never makes it approvable.
- Approval is bound to request ID, kind, method, origin, chain, `payloadDigest` (keccak
  of the request ID + canonical sorted-key params), expiry, and unconsumed state. On
  approve, native code reloads the canonical record, rejects if expired/queued/non-pending,
  recomputes the digest and rejects `bindingMismatch` on any mutation, recomputes the
  signable digest (`RequestExecutor`), authenticates, signs, and atomically consumes.
- One active approval at a time in creation order: only the oldest pending record can be
  approved; earlier ones throw `queued`. Reject marks `rejected`, maps to EIP-1193 `4001`
  in the handler, and never invokes signing.
- Signing is now real: `Signing` is an injected protocol; production uses
  `KeychainSigner` (loads the shared-key new-format key and signs through the vendored
  secp256k1). `UnavailableSigner` reports not-ready loudly when no key exists.
- Durable connection grants replicate the legacy model: `ConnectedSitesStore` reads/writes
  the shared App Group `UserDefaults` key `connectedSites`
  (`[hostname: {address, connectedAt}]`, same shape as the old app) so shipped users' prior
  connections carry over with no migration. Approving a `.connect` request establishes the
  grant; `eth_accounts` returns `[]` without a grant, `eth_requestAccounts`/`wallet_connect`
  short-circuit to the account when a grant exists, and `wallet_disconnect` revokes it.
  Native actions: `isConnected`, `listSites`, `disconnectSite`.
- Native handling accepts standard EIP-1193 params throughout: `personal_sign` as
  `[messageHex, address]`, `eth_signTypedData_v4` as `[address, jsonString]` (unwrapped to
  the EIP-712 object), and add/switch chain methods as `[chainObject]` reading the standard
  `chainId` key.
- Error mapping in `SafariWebExtensionHandler` covers not-found (4100), already-consumed/
  expired/auth-cancelled (4001), queued/binding-mismatch (‑32000/‑32602), and
  not-ready (4900). Denied methods never prepare.

- The physical-device wagmi flow was completed through the Safari popup for connect,
  message, typed-data, and send approvals. Reconnect after a grant did not enqueue a
  duplicate approval, rejection returned `4001`, and concurrent requests followed the
  documented queue order.

Gate 6 is underway. `eth_sendTransaction` persists and binds the normalized dapp intent
without snapshotting missing nonce, gas limit, or legacy/EIP-1559 fee fields. The popup
shows one display-only Network Fee estimate from `eth_estimateGas` and the effective fee cap,
formatted in the known chain's native currency; estimation failure is shown explicitly and
does not mutate the canonical request. Approval revalidates the bound intent, resolves each
missing field through the shared resolver immediately before authentication/signing, and
stores those values separately from the immutable approved params/digest. This prevents quick
successive approvals from signing the same stale pending nonce while preserving explicit
dapp-provided limits. Approval signs a canonical legacy or type-2 raw transaction, submits it
with `eth_sendRawTransaction`, and resolves to the 32-byte transaction hash. Structured
node/transport submission failures become durable terminal request errors so polling does not
strand the dapp promise. Approval/rejection
uses an OS advisory lock across handler/store instances, binds the current signer back to
the persisted account, revalidates transaction semantics at approval, rejects unsupported
or ambiguous fields, and verifies the node-returned hash against the signed raw bytes.
Hermetic submission tests pass and the build is installed on the physical iPhone. A funded
simulator wallet completed a zero-value self-transfer on Base through the full dapp → popup
→ authenticated signer → `eth_sendRawTransaction` path: the returned hash matched the raw
transaction, the node recovered the expected simulator signer, and the receipt succeeded
with 21,000 gas used. Physical-device broadcast remains separate from this simulator proof.

Active chain state is no longer a JavaScript/build constant. `ChainStore` persists the
normalized decimal chain ID in the shared App Group (mainnet on first run), and native code
is authoritative for `eth_chainId`, `net_version`, approval binding, transaction
preparation, and passthrough routing. `wallet_switchEthereumChain` requests from a currently
connected origin are validated and applied immediately without a popup or biometric prompt;
`wallet_addEthereumChain` remains a canonical approval and does not switch. Automatic
switches serialize the one atomic chain-state write under the global advisory lock. The
write-ahead journal remains for recovery of already-persisted approval-era switch records.
Stale queued approvals fail terminally with `4901`, and the worker broadcasts the canonical
native chain to every tab after a switch or recovery. Every successful switch also records
the target in the shared `NetworkStore`; known chain 137 is displayed as Polygon and an
otherwise unknown switched chain receives a `Chain N` name. Confirmed
`wallet_addEthereumChain` metadata records its supplied name. If the Stupidtech default does
not return the requested `eth_chainId`, approval validates and saves the first supplied RPC URL
as the fallback unless the user already selected an override.

Gate 6 activity persistence is implemented. `ActivityStore` extends the existing shared
App Group `Activity.sqlite` schema in place so installed transaction and signature history
is retained. New transaction rows bind the canonical request ID, hash, chain, account,
origin, and nonce, then move through submitted/pending/confirmed/reverted/dropped/replaced
states. Receipt polling uses the same `RPCResolver`; a missing receipt remains non-terminal
while the node knows the transaction or during a propagation grace period, then the latest
account nonce distinguishes dropped from replaced. New signature rows retain a digest, the exact
signed message or typed-data JSON, the complete resulting signature, and request metadata. New
transaction rows retain the canonical calldata alongside their existing metadata. Transaction and
signature rows also retain the native Safari profile identifier so connected-app activity can be queried by exact
normalized origin and profile; legacy hostname-only app details query by domain. The app
exposes a minimal activity list, polls while its activity task is foreground-active, and
supports manual refresh. Global activity and connected-app details render their persisted activity
before receipt polling, then update the visible rows with refreshed transaction statuses so slow
RPCs do not block either initial screen. A funded
Base simulator self-transfer was recorded as submitted, mined,
refreshed to confirmed with its block number, and rendered in the app; configured and
independent RPCs agreed on receipt success and 21,000 gas used.

The Gate 6 containing-app shell now follows the shipped app's SwiftUI screen hierarchy and
presentation: the lowercase welcome and import screens; centered large native balance with
an anchored details popover; top-trailing Copy Address icon beside the account blockie menu popover,
which uses a continuous-corner squircle and begins with a regular account-switch row that leads with a
squircle blockie beside the account name (or shortened address), followed by a small muted
`arrow.left.arrow.right` trailing symbol, then Activity,
Connected Apps, and Settings actions; Settings sheet; Connected Apps list/detail/disconnect
with origin/profile-filtered activity; reciprocal navigation from an activity detail to its
currently connected app detail;
Networks list and RPC detail/editor; authenticated
Private Key reveal; and Activity list/detail. The implementation keeps the old native
labels, spacing, forms, inset-grouped lists, typography, and SF Symbols while using the new
core boundaries. Networks now has one unified configured-network list, a manually populated
Add Network sheet, per-network deletion, and a per-network Include in Total Balance setting.
Deletion clears the network's custom RPC state; deleting the selected network selects the first
remaining configured network when one exists. The home balance is
the full-width sum of native wei balances from every included network; individual RPC
failures do not discard successful balances, while a complete included-network outage is
shown as unavailable. Expanding the aggregate balance lists every included network with a
non-zero balance as an individual row, using the same fetch results as the total. Rows are
ordered by descending full-width wei balance and render as compact left-aligned network and balance
rows without a separator bullet.
Zero and unavailable balances are omitted; when no non-zero rows exist, the expansion
affordance is hidden and disabled. Activity details show persisted transaction calldata and signed
message content as multiline text. Existing stored content remains readable; migration does not use
unsupported current-rebuild pending records to fill missing activity fields. EIP-712 activity follows
the old app's readable hierarchy: known Domain fields in fixed
order and alphabetized root Message fields, with nested objects and arrays pretty-printed. Invalid
typed-data JSON falls back to exact raw content. Long-pressing anywhere on a structured EIP-712
message opens the compact Copy edit menu and copies the complete original JSON rather than one
display field. Signature details also display the complete signature in a middle-truncated row;
long-pressing it opens the same compact Copy edit menu. Method, status, signature, account, network,
and timestamp share one Signature section rather than splitting verification metadata into a
second section. Activity list and detail content uses regular system typography throughout;
hashes, addresses, signatures, and typed-data hex values are not monospaced.

Settings begins with an Apple Settings-style identity row for the currently selected account: a large
blockie, editable account label, and muted shortened address. Account removal is available only from
the Accounts screen's edit-mode removal flow. The separate
destructive Forget Account/Wallet section and confirmation are no longer shown in Settings. The
Accounts removal confirmation warns when the protected source will be removed and requires an
explicit destructive choice. Confirming group removal runs the recoverable group-deletion lifecycle,
which terminalizes matching pending requests, removes the exact protected source, account caches,
migration material, and only that group's grants/active mappings, then repairs home and connection
defaults. Secret-deletion and registry failures do not silently clear visible authority. Activity and
network preferences are retained.

Import Wallet follows the containing app's native inset-grouped form design: title-case navigation,
separate wallet-group-label and recovery-phrase/private-key sections, concise accepted-format guidance, a
standard full-row import action with progress state, and section-scoped errors. The secret field uses
regular system typography, remains visible for review, disables capitalization and correction, and is
marked privacy-sensitive. A successful recovery-phrase import navigates directly to the imported seed
group's Add Accounts discovery screen so the user can choose additional accounts before returning to
Accounts; backing out keeps the already imported account zero and closes the import flow. A private-key
import retains the immediate completion path because it has no derived-account discovery step.
Seed import defers publishing the updated view-model home state until discovery exits so initial setup
cannot replace its navigation stack before the selector appears; the registry and protected seed are
already durable during that interval.

For seed-backed wallet groups, tapping Add Account navigates to an authenticated account-discovery
screen. It initially shows ten available accounts with their default account labels, blockies,
shortened addresses, and multi-selection controls; Load More authenticated-loads ten additional previews
while retaining the selection. Preview generation keeps only public addresses in memory after
zeroizing temporary child keys and entropy; it persists neither previews, an extended public key, nor
secret material. Confirming a selection performs one fresh authenticated seed read, verifies every
selected child, and appends the ascending selection in one atomic registry update. The high-water mark
advances beyond the highest selected child, so unselected lower previews are intentionally skipped and
never reused. Long-pressing Add Account is the shortcut for deriving only the current monotonic next
index. Stale or lower selections fail closed.

The home account-menu switcher row uses the same squircle blockie as native account rows and places
the muted shortened address beneath the account label. Accounts omits disclosure chevrons from its
Add Account, Create New Wallet, and Import Wallet rows; additive navigation labels retain the same
blue tint as other account actions. Its sheet toolbar uses the native close-role control on iOS 26
and the text Close control on older supported systems. The discovery screen presents Load More as a
standalone tinted action without an inset-grouped pill background.

The aggregate native balance uses an account-bound, atomically written App Group cache.
The containing app hydrates the last successful formatted total during initialization, keeps
that stale value visible while revalidating all included networks, and replaces it only after
at least one network succeeds. A transient complete outage retains the stale total; without a
cached or previously successful value, the UI reports the balance as unavailable. Forgetting
the matching account removes its cached total.

`RPCOverrideStore` atomically persists one validated endpoint per decimal chain ID in the
App Group. Both the app and Safari handler construct their resolver from this store, and
the editor displays exactly one effective endpoint per chain. The user may replace it or
enter the Stupidtech endpoint explicitly; the editor requires HTTPS (except explicit loopback
development), reachability, and an exact `eth_chainId` match before saving. Network details do
not expose a separate restore-default action.
An approved add-chain request may also save its displayed first `rpcUrls` entry only when
the Stupidtech endpoint fails exact-chain validation and no existing override is present;
the suggestion must pass the same endpoint validation. If neither the default, an existing
override, nor a valid supplied fallback can serve the requested chain, approval fails before
the network metadata is recorded.
`NativeBalanceService` uses that same resolver and
formats and adds full-width 256-bit quantities without a BigInt dependency. `NetworkStore`
atomically persists custom metadata, imports legacy `customChains` names for visibility, and
continues to read and mirror the old `excludedFromBalance` preference so installed users
retain their Include choices. Manual network addition validates the entered RPC's exact
chain identity before saving it as a deliberate override. Raw private-key import
strictly validates a 32-byte secp256k1 scalar. Private-key reveal uses a fresh
operation-specific authentication prompt, is privacy-sensitive, clears after 60 seconds,
on actual backgrounding, and on navigation away, and copies only to a local expiring pasteboard.
The LocalAuthentication prompt's temporary `.inactive` scene phase does not clear a successful reveal.
Automatic old-format migration is attempted only when old material exists and no active
new-format wallet is registered. New wallet creation, raw private-key import, and BIP-39
English seed-phrase import all use one provisioning path: derive the EIP-55 account, save
the `.userPresence` key, authenticate a reload, sign and recover a fixed self-test digest,
and register the shared address only after proof succeeds. Cancellation, verification
failure, or App Group registration failure deletes the newly saved key. Seed import
validates the BIP-39 vocabulary and checksum, derives the 64-byte seed with
PBKDF2-HMAC-SHA512, and derives `m/44'/60'/0'/0/0` with project-owned BIP-32 logic backed by
CryptoKit and the existing vendored libsecp256k1 target. The standard Hardhat mnemonic
matches its independently known first private key and address.

If the active-wallet registration is absent but `SecItemAdd` finds a new-format item for
the imported account, provisioning treats it as keychain state retained across uninstall.
It never replaces or deletes that item: it authenticates the existing key, requires an
exact match with the imported secret, repeats the sign-and-recover proof, and only then
restores the shared address registration. A mismatch or cancelled authentication leaves
the existing item untouched and fails the import.

This retained-item recovery path is proven on a physical iPhone: the previously failing
private-key import authenticated and completed after an in-place install of the fix.

All production device key and seed stores explicitly select the preserved shared keychain access group.
Simulator and macOS package-test builds omit that explicit group because their ad-hoc/test processes do
not carry the production entitlement; iOS device and iOS-on-Mac builds use the production group.
The containing app and Safari extension both declare `NSFaceIDUsageDescription` because either process
can request access to `.userPresence`-protected wallet material. The authorization policy remains device
owner authentication, so the system may use Face ID or the device passcode rather than requiring
biometrics exclusively.

New connected-site approvals now persist a V2 grant keyed by normalized scheme, hostname,
effective port, and Safari profile identifier when `SFExtensionProfileKey` is present.
Canonical pending requests also persist that native profile identifier; list, summary,
status, approve, and reject operations are profile-filtered, and approval rejects a profile
change as a binding mismatch. The profile identifier comes only from Safari's native
extension context and is never accepted from page JavaScript. The old hostname dictionary
continues to be mirrored for old-app readability. By explicit product-owner decision,
pre-existing hostname-only entries remain authorization grants until that site reconnects
or is disconnected; once a domain has any V2 grant, requests must match its exact V2
origin/profile rather than falling back to the hostname entry.
- `StupidWalletCore`: shared value types, method classification, origin normalization,
  a canonical pending-request store, real `Signing` (KeychainSigner) plus fresh-`LAContext`
  keychain access as the single device-owner authentication boundary.
- `StupidWalletSafari`: a native Safari Web Extension handler (`NSExtensionRequestHandling`)
  that bridges flat JSON envelopes to `StupidWalletCore`.
- A Safari Web Extension resource set (`manifest.json`, MAIN-world `provider.js`,
  isolated-world `bridge.js`, MV3 `background.js`, and `popup.html`/`css`/`js`) packaged at
  the appex root through `stupid-app.yml` `extensions:`/`resources:`.
- EIP-6963 discovery follows the full request/announce handshake: the MAIN-world provider
  announces during initialization and re-announces whenever a dapp dispatches
  `eip6963:requestProvider`. Each page session uses a UUIDv4 provider identifier and frozen
  provider metadata. The current manifest is `0.1.53`; the EIP-6963 reannounce behavior introduced
  in `0.1.20` invalidated the earlier one-shot discovery script, which could be missed when an MIPD
  consumer initialized after the wallet. Provider session UUID generation uses
  `crypto.getRandomValues` when secure-context-only `crypto.randomUUID` is unavailable, preserving
  injection on LAN-hosted HTTP development fixtures.
- One hand-drawn upward-arrow identity is used for the containing-app icon, Safari extension
  icons, EIP-6963 provider discovery, and the in-page request hint. The canonical 1024-point
  app asset is `Resources/AppIcon.png`; generated browser sizes remain in the extension
  resource set. Safari's action uses dedicated transparent 16-, 19-, 32-, and 38-pixel
  black toolbar icons. Safari may apply its system-blue active-state tint because the artwork is
  intentionally monochrome; preserving the black-and-white identity takes precedence over
  avoiding that platform tint.
- A compact in-page, non-authoritative Safari notice plus a toolbar badge as the request
  prompt. The notice tells the user to open `stupid wallet` from Safari and remains
  non-interactive; review and approval stay exclusively in the toolbar popup.
- `PrototypeDapp/` — a wagmi v3 + viem + React + Vite test dapp (`bun create wagmi
  --template vite-react`) exercising connect, `personal_sign`, `eth_signTypedData_v4`,
  `eth_sendTransaction`, generic `eth_blockNumber` passthrough, `wallet_switchEthereumChain`, and disconnect against the injected
  provider. Dev server runs `--host` on port 5173 for the physical iPhone.

As of Gate 5 fixing: the signing path reads the `.userPresence` keychain exactly once, only
at the moment of signing; `Signer.hasKey()` resolves the active wallet from the non-secret
shared App Group file (`WalletStore.wallet-address.conf`) and never presents Face ID.
Registry readiness uses `KeychainKeyStore.contains` with a fresh non-interactive `LAContext`;
`errSecInteractionNotAllowed` proves the exact protected item exists without releasing it or
presenting authentication UI.
`WalletService`/signer are built lazily per native message so a wallet created after the
extension started is resolved. The background ↔ bridge boundary uses a stable envelope so
structured EIP-1193 errors surface on the dapp; the method casing is normalized in
`background.js` so approval methods do not fall through to RPC passthrough. `WalletFactory`
creates a new wallet at runtime.

The prototype is gate-complete through Gate 5. The wagmi flow is proven on both
the iOS simulator and physical iPhone: connect; personal-sign and typed-data signatures;
complete legacy transaction signing and broadcast plumbing (including live Base network
acceptance); queue ordering; and disconnect followed by a fresh connect approval. The
simulator run fixed a JavaScript casing bug that
sent `eth_chainId` to passthrough and a transaction quantity parser that rejected canonical
odd-nibble JSON-RPC quantities such as `0x0`.
It preserves the identity, security, and documentation rules and its
Safari messaging/popup/Face ID, JSON/RPC proxy, key/transaction/crypto primitives,
old-format migration, canonical approval protocol, and real keychain signing all work.
The physical device remains the authoritative surface for provisioning and keychain-group
continuity.

The wagmi fixture now includes mainnet and Base. WebExtension manifest `0.1.10` invalidates
the previous approval-routed switch worker. Simulator verification proved immediate Base →
Ethereum → Base switches, `chainChanged`/wagmi updates, no popup/authentication or pending
switch record, App Group persistence, and Safari reload still reporting Base. Live Uniswap
verification found that the worker normalized
method names for classification and accidentally forwarded the normalized spelling to the
case-sensitive RPC. For example, `eth_blockNumber` became invalid `eth_blocknumber`, so
Uniswap failed before requesting the swap transaction. Passthrough now forwards the
original method string unchanged while retaining normalized classification. A funded
simulator ETH-to-USDC swap on Base then completed through canonical review, authenticated
signing, broadcast, and a successful receipt with the expected USDC transfer.

The reverse Uniswap path is also proven on the simulator. Its initial USDC allowance
transaction succeeded, but the following Permit2 typed-data request exposed two bugs:
popup code rendered a structured error as `[object Object]`, and EIP-712 converted integer
values through host `Int`, rejecting Permit2's maximum `uint160` allowance and `uint48`
fields. Popup errors now read the structured message, and unsigned EIP-712 integers parse
up to 256 bits with declared-width validation. A Permit2 digest matches viem, service-level
approval signs and consumes it, and a live USDC-to-ETH swap completed with a successful
Base receipt. One preceding broadcast returned a hash but did not propagate to either the
configured RPC or an independent node; both pending/latest nonces remained unchanged, so a
fresh canonical replacement at the same nonce was safe and mined.

The existing implementation in `../ios-wallet` is a behavior and migration reference,
not a codebase to copy wholesale. It contains useful feature work, protocol handling,
and persisted formats, but its confirmation, RPC-routing, dependency, and concurrency
boundaries are intentionally being redesigned.

## Prototype Notes

The prototype is deliberately mock in several places and must not be confused with
gate-proven behavior:

- Pending requests are stored in the shared App Group container.
- `personal_sign`, `eth_signTypedData_v4`, and `eth_sendTransaction` sign through the real
  `KeychainSigner` (shared-keychain key + vendored secp256k1). On a fresh install with no
  key present, signing reports `notReady` rather than mocking.
- The Face ID/passcode step is a real `LAContext` device-owner prompt on both device and
  simulator. Popup-to-approval binding for the full Gate 5 flow is proven on-device.
- The service worker keeps its pending map in memory for completion routing; durable
  delivery across suspension is verified by the native store + polling.

## Product Goal

Build a small, auditable iOS wallet distributed with a Safari Web Extension that:

1. Creates or imports local wallet groups, including seed-backed groups with multiple derived
   Ethereum accounts and single-account private-key groups.
2. Injects a standards-oriented EIP-1193 provider with EIP-6963 discovery.
3. Keeps Safari in the foreground while the user reviews and authenticates signing.
4. Uses a Safari-owned toolbar popup for review and a native Face ID or device-passcode
   prompt as the final authorization boundary.
5. Explicitly handles wallet-owned RPC methods and forwards all other JSON-RPC methods
   unchanged to the selected chain's RPC endpoint.
6. Uses `https://evm.stupidtech.net/v1/{decimalChainId}` by default for every EVM chain.
7. Allows deliberate, validated per-chain user RPC overrides.
8. Preserves the existing production app identity and migrates an installed wallet
   without requiring the user to re-import it.
9. Minimizes third-party code and keeps the remaining cryptographic dependency pinned,
   vendored, auditable, and replaceable.
10. Allows the iOS TestFlight app to run on Apple Silicon Mac and expose the same bundled
    Safari Web Extension to macOS Safari.

There is one iOS target. On Apple Silicon Mac it runs in Apple's iPhone/iPad-app
compatibility environment with its bundled iOS Safari extension. `ThisDeviceOnly`
keychain material and App Group containers do not synchronize between an iPhone and a
Mac; using the same account on both requires an explicit user-authorized import on the Mac.

## Locked Product Decisions

- The containing app keeps the production bundle identifier
  `co.za.stephancill.stupid-wallet`.
- The user-facing product name is rendered as `stupid wallet`; Swift products, targets,
  modules, and existing bundle identifiers retain their established casing.
- The Safari extension keeps the production release identifier
  `co.za.stephancill.stupid-wallet.extension`.
- Every release keeps the containing app and Safari extension
  `CFBundleShortVersionString` values identical. `stupid-app release bump` keeps
  `CFBundleVersion` build numbers in lockstep but does not synchronize marketing versions.
- Shared preferences and migration data keep the App Group
  `group.co.za.stephancill.stupid-wallet`.
- The existing team-prefixed keychain access group remains authoritative. Do not invent
  a second access group or silently move key material outside the shared group.
- The minimum deployment target remains iOS 17 unless a concrete API requirement changes
  it and this document records that decision.
- Do not add a native macOS or Mac Catalyst target unless the iOS compatibility path
  fails a concrete requirement that cannot be fixed in the existing iOS target.
- The iOS app and extension retain their existing package products, bundle identifiers,
  App Group, keychain groups, `NSExtensionRequestHandling` entry point, and web resources
  when installed on Mac through TestFlight compatibility.
- Signing confirmation uses the Safari toolbar popup followed by Face ID or device
  passcode authentication.
- The webpage must never be the security boundary for signing approval.
- A fully native SwiftUI transaction-details screen is not required for the primary
  Safari flow because iOS does not allow a Safari Web Extension handler to present an
  arbitrary app view over Safari.
- Widgets and Live Activities are not part of the signing authorization boundary. They
  may be reconsidered for status display only after the core flow is proven.
- The first usable milestone is the Secure Wallet Core defined below. Full parity with
  `../ios-wallet` is deliberately phased.
- The app uses Face ID or device passcode (`userPresence`) for signing rather than a
  biometrics-only policy.
- Authentication uses a fresh context for every signing operation. Authentication
  reuse and unlocked-key caching are prohibited.
- The default RPC resolver supports every chain through `evm.stupidtech.net`; the app
  does not maintain a hardcoded allowlist of RPC-capable chains.
- Dapp-supplied RPC URLs never silently replace the user's selected endpoint.
- Prefer failing loudly over fallback behavior that weakens signing, origin validation,
  chain validation, or key protection.
- Planning documents use ordered dependencies and acceptance gates, not timeline
  estimates.
- Wallet groups are either seed-backed with accounts derived at `m/44'/60'/0'/0/{index}` or
  private-key-backed with exactly one account.
- Wallet-group and account labels are editable, non-authoritative display metadata. Addresses and group
  IDs remain the identity for signing, grants, activity, migration, and canonical requests.
- Removing a seed-derived account deletes only its registration and live account-bound state, preserves
  the seed and activity, and never reuses its derivation index. A retained account-zero seed identity
  prevents duplicate group import after account-zero removal. The final seed account requires complete
  group deletion; removing a private-key account deletes its one-account group and key.
- Existing installations adopt their proven account as a one-account private-key group. Shipped
  formats did not retain seed phrases and must not be treated as expandable seed groups.
- Home account selection is independent from the default account proposed for new dapp connections.
- Connection grants bind account + normalized origin + Safari profile. Multiple accounts may retain
  grants for the same origin/profile, while exactly one granted account is active there.
- The active plain-connect request may select an existing account from the popup sticky bar. The
  popup never creates accounts and never rebinds SIWE, signing, sending, batch, or chain requests.
- Future popup approve/reject messages include the native summary revision in addition to request ID
  and decision, so a stale popup cannot decide a connect request after another popup rebinds it.
- A popup selection becomes the default for future new connections only after Connect succeeds;
  rejection and failure leave the prior default unchanged, and existing grants remain intact.
- The containing-app Accounts sheet remains open after selecting or deriving an account. New/imported
  wallet groups require a name and return to the Accounts list without dismissing it or implicitly
  changing home selection.

## Existing App Findings

The old app has three Xcode targets: the containing SwiftUI app, a Safari Web Extension,
and unit tests. Shared Swift code is compiled into both app and extension. The Web
Extension currently uses four request layers:

1. `safari/Resources/inject.js` installs EIP-1193/EIP-6963 in the page's MAIN world.
2. A React content script bridges requests and mounts confirmation UI into a Shadow DOM.
3. `safari/Resources/background.js` classifies methods and holds pending requests.
4. `safari/SafariWebExtensionHandler.swift` reads shared state, signs, and calls RPCs.

Features worth retaining or deliberately re-evaluating include:

- Wallet creation and private-key or seed-phrase import.
- Authenticated private-key backup.
- Connected-site authorization and disconnect.
- EIP-1193 and EIP-6963 provider behavior.
- `personal_sign`, `eth_signTypedData_v4`, and `eth_sendTransaction`.
- SIWE through `wallet_connect`.
- EIP-5792 calls and EIP-7702 authorizations.
- Network selection and custom RPC URLs.
- Aggregate native-token balances.
- ENS name and avatar display.
- SQLite-backed transaction and signature activity.
- Transaction receipt polling.
- Simulation, ABI decoding, and clear-signing previews.

Known weaknesses that the rebuild must not reproduce:

- The current approval UI is controlled by an in-page React tree. Shadow DOM reduces
  accidental CSS leakage but cannot stop the page from obscuring, removing, or imitating
  the wallet.
- JavaScript approval is not cryptographically bound to the exact native signing input.
- Supported methods are duplicated across provider, content UI, background worker, and
  native switches, causing ordinary node methods to fail as unsupported wallet methods.
- Native, modal, and ENS code use different RPC sources.
- Chain additions and switches mutate global state without one authoritative native policy.
- The generic JSON-RPC helper casts results to expected Swift types and loses arbitrary
  JSON values, `null`, and structured node errors.
- Pending requests live only in an in-memory service-worker `Map`, which is not durable
  across Manifest V3 worker suspension.
- The dependency graph is substantially larger than the product requires.

## Feature Scope

### Secure Wallet Core

The first usable milestone includes:

- Create one wallet.
- Import a raw private key or BIP-39 seed phrase and derive the standard first Ethereum
  account.
- Preserve or migrate an existing installed wallet.
- Display the account address and aggregate native-token balance across included networks.
- Authenticated private-key backup with explicit warnings and no persistent plaintext.
- Connect, list, and disconnect authorized sites.
- EIP-1193 request transport and EIP-6963 discovery.
- `eth_requestAccounts`, `eth_accounts`, `eth_chainId`, and `net_version`.
- `personal_sign`.
- `eth_signTypedData_v4`.
- `eth_sendTransaction` with legacy and EIP-1559 serialization.
- Confirmed `wallet_addEthereumChain`; authorized immediate `wallet_switchEthereumChain`.
- Durable site connect/disconnect grants (legacy `connectedSites` key) with
  eth_accounts/eth_requestAccounts gating and app-side list/detail/disconnect UI.
- Generic passthrough for all methods not explicitly handled or denied.
- Stupidtech default RPC resolution and validated per-chain user overrides.
- SQLite-backed transaction and signature activity.
- Receipt polling for submitted transactions.

### Multiple Wallet Groups And Accounts

Implemented next-scope. Gates A through H are complete. Gate H's physical-iPhone multi-account
lifecycle, foreground authentication, cross-profile/device-lock acceptance, and Mac compatibility
Safari account model are complete:

- Only Dawn v1 is a supported migration source. The current rebuild v2 is unsupported, and its
  `wallet-address.conf`, `sw2.walletAddress`, `connectedOriginsV2`, singleton balance cache, and
  `PendingRequests` records must not be adopted into a new registry. Keep `wallet-address.conf` only as
  the fail-closed downgrade projection after registry creation.

- Gate A foundation currently implements `WalletRegistry`, wallet-group/account/lifecycle types, strict
  schema and EIP-55 validation, monotonic revisions and seed derivation high-water checks, the
  `.migrating` readiness barrier, cross-process registry locking, and projection-first journaled
  persistence/recovery. It also implements the atomic `ConnectionState` authority: account-specific
  exact/legacy grants, active mappings, a separate connection default, durable connect-commit markers,
  cross-field validation, revision-checked locked updates, Dawn hostname migration, and the legacy
  `connectedSites` mirror. The account-bound `BalanceCache` persists a versioned per-account dictionary
  and rejects singleton payloads. Wallet registry adoption orchestrates the `.migrating` barrier: it
  authenticates only the Dawn account, adopts registry/connection/fallback state with an empty account
  cache, and commits `.complete`. Every app and extension entry now requires that complete validated
  state. Unsupported pending bindings are not migrated, listed, terminalized, or used for activity
  enrichment. New pending records carry the approved account-inclusive binding version 2 and a
  required monotonic revision. The adoption claim uses synchronous `NSFileCoordinator` write
  coordination on a stable App Group URL; canceled access fails closed. Deterministic interruption
  tests now cover registry journal/projection/authority, connection authority, account-bound cache,
  fallback removal, and adoption-state commits. A separate child process also proves the registry
  file-coordination claim excludes another process. A physical containing-app/Safari-extension test
  also proved exclusion without either process being terminated: iOS granted the app a File
  Coordination suspension assertion for a 45-second diagnostic claim, the extension did not enter the
  accessor during that claim, and a fresh popup request entered and completed immediately after
  release. Runtime Safari multi-account signer selection, popup connection selection, and
  origin-scoped provider account lifecycle are implemented by Gates E, F, and G. Rebuild source resolution, V2 grant ingestion, singleton
  cache migration, and retained rebuild-request migration have been removed.

- A historical simulator upgrade investigation started from a UI-created pre-multi rebuild wallet with a
  singleton balance cache and retained signed-message activity. Installing the current build in place
  preserved the compatibility projection, produced one complete private-key group, migrated the cache
  to one account entry, retained activity, and restored the wallet UI after fixing missing-revision
  decoding. This does not close upgrade acceptance: ad-hoc simulator app and extension processes did
  not share the App Group `UserDefaults` grant domain even before upgrade, so the old containing app
  itself showed no connected apps after Safari connected successfully. Grant migration, real
  app/extension lock exclusion, and old Dawn keychain migration still require a properly signed
  physical-device upgrade. This historical investigation does not contribute migration acceptance
  because v2 upgrades are out of scope; the separate Dawn v1 physical upgrade and production
  app/extension coordination proof completed Gate A.

- Add a versioned App Group wallet registry with seed and private-key group invariants, a separately
  persisted home-selected account, authenticated migration, recoverable group deletion, and a
  commit-forward journal that updates the fail-closed rebuild projection before registry authority.
- Keep the registry `.migrating` until Dawn key, connection, activity/network, projection, and
  downgrade-fallback adoption all validate; app and extension request handling fails closed until it
  becomes `.complete`.
- Treat `sw2.walletAddress` only as downgrade residue to remove and verify absent, never as a migration
  input. Do not enable seed groups or additional accounts until Dawn adoption completes.
- Generate and import BIP-39 seed groups, retain only protected entropy, and derive arbitrary
  unhardened address indexes under `m/44'/60'/0'/0` without persisting child private keys.
- Migrate every supported Dawn v1 installed account to one private-key group without changing its
  address, keychain identity, activity, grants, or installation-wide network preferences. Dawn has no
  supported singleton balance cache, so its new account-bound cache starts empty.
- Open an account picker from the home account-menu address and support selecting existing accounts,
  deriving the next seed account, creating a seed group, importing a seed, and importing a private
  key.
- Add a top-right Edit/Done mode to that picker for wallet-group/account labels and destructive account
  removal. Persist account deletion through an account-level `.deleting` barrier before cleaning its
  pending requests, grants, active/default mappings, and cache; preserve seed entropy and derivation
  high-water state.
- Registry schema 2 strictly requires labels, account lifecycle, and seed identity. Schema 1 migrates
  through the projection-first journal in one revision, assigning deterministic `Wallet N` and
  `Account N` labels while preserving group/account identity and seed derivation high-water state.
  Missing schema-2 lifecycle metadata fails closed rather than reactivating an account.
- The Accounts sheet keeps separate Close and Edit/Done controls, hiding Close while editing. Native
  list edit mode supplies the standard red removal control and trailing Delete action. Wallet section
  headers and account labels edit in place with dotted underlines identifying editable fields, plus
  confirmed destructive removal.
  Selection and derivation leave the sheet open; named additive create/import flows pop back to the
  list and preserve the prior home account. The Safari review popup's sticky action bar renders the
  account blockie followed by the current label when available, falling back to the shortened address;
  the full address remains the canonical request identity and hover metadata.
- Individual seed-account deletion marks the registration `.deleting`, immediately removes it from
  signer/provider/home/default resolution, terminalizes pending authority, removes connection and
  balance state, and then removes only the registration. The seed identity and next derivation index
  remain reserved. Private-key accounts and final seed accounts route through complete group deletion.
- Scope containing-app balance, Activity, Connected Apps, Settings, authorizations, and private-key
  export to the home-selected account.
- Replace the runtime origin/profile-only grant store with atomic account + origin + profile connection
  state that retains multiple account grants, one active account per origin/profile, and a separately
  persisted default for future connection prompts. Do not migrate `connectedOriginsV2` records.
- Read registration and connection state under registry-then-connection locks whenever both determine
  account visibility. Group deletion removes grants, active mappings, and repairs the default in one
  connection-state revision after the group becomes inactive.
- Resolve every Safari signing/sending account from the requesting origin/profile's active grant,
  not the containing app's home selection or the future-connection default.
- Make only the active plain-connect sticky account selectable in the popup. Native code performs a
  claimed, revision-checked, account-inclusive canonical rebind; successful approval of the reviewed
  revision atomically commits the grant, active origin account, future default, and request result.
- Preserve provider `requestKey` plus immutable page-intent digest across a connect rebind while
  replacing only the account-inclusive approval binding. New runtime records require binding version 2;
  unsupported rebuild records fail closed and are not migrated into the queue.
- Persist a connect commit marker in the same atomic connection-state revision as grant, active
  account, and default changes, then reconcile pending consumption from that marker after interruption.
- Use the plan's fixed cross-process order: registry-adoption claim, sorted group lifecycle claims,
  request claim, registry lock, connection lock, prepare lock, then account/chain submission claim;
  state locks never span authentication or network RPC.
- Keep origin/profile-scoped provider account state and `accountsChanged` bound to native
  `visibleAccounts`; never broadcast another site's account.

The complete design, migration rules, lock domains, file-level work, gates, and verification matrix
are maintained in `docs/multi-account-implementation-plan.md`.

### Gate 7 Parity

Implemented after the Secure Wallet Core gates passed:

- SIWE capability handling in `wallet_connect`, with exact EIP-4361 message persistence,
  strict origin/domain/URI/date validation, HTTPS except loopback HTTP, and rejection of
  unsupported `wallet_connect` capabilities.
- EIP-5792 `wallet_sendCalls`, `wallet_getCallsStatus`, and capability reporting for
  atomic batches on every configured network. Shipped v1 request
  compatibility and canonical v2 requests share one native validation and approval path.
- Wallet-owned EIP-7702 authorization management. Dapps cannot request arbitrary
  authorization signatures or replace foreign/malformed account code through
  `wallet_sendCalls`.
- Delegation is restricted to the reviewed eth-infinitism `Simple7702Account` at
  `0xe6Cae83BdE06E4c305530e199D7217f42808555B`. The runtime hash is pinned to
  `0xcc7b633aef4b2543cb8f37522adf1a401f910f0f6b2430c1eecc11f401ccfcf3` and must match
  before estimation or authorization on every configured chain. Capability reporting accepts
  either that verified runtime or a missing implementation with the hash-verified canonical
  deployment factory available; foreign implementation code is never reported as supported.
- If the implementation is absent, an approved atomic batch first deploys the exact reviewed
  creation code through the hash-pinned canonical CREATE2 factory, waits for a successful
  receipt, verifies the resulting runtime, and only then fetches a fresh nonce for the type-4
  authorization batch. Settings exposes the same deployment as an explicit Authorizations action.
- Positive runtime verification is persisted by chain and exact RPC endpoint to avoid repeated
  `eth_getCode` checks without carrying verification across endpoint changes. Changing or restoring
  that chain's RPC endpoint also invalidates the entry. Loopback RPCs are never persisted because a
  local chain can reset while retaining the same URL, including in the Settings status path.
- Safari sends and batches plus Settings deployment, enable, and revoke operations acquire one
  cross-process submission claim per account and chain before RPC preparation and retain it through
  broadcast. The batch's nested just-in-time deployment reuses the already-held boundary rather
  than reacquiring it. A competing operation fails as busy instead of signing the same pending nonce.
- First-delegation estimation uses the hash-verified runtime through an RPC state override. The
  display-only popup estimate can use runtime extracted and hash-checked from the pinned deployment
  artifact before that implementation is deployed, and overrides account balance so the requested
  call value cannot prevent gas estimation. Approval uses real code and balance. A signed
  authorization is never disclosed for estimation; the two protected signatures are created only
  after RPC preparation succeeds.

### Later Parity

Still deferred:

- ENS names and avatars.
- Transaction simulation and richer value previews.
- ABI and contract metadata resolution.
- ERC-7730 clear-signing previews.
- Rich activity detail and status surfaces.

Deferred functionality must not distort the core request, approval, key-storage, or RPC
boundaries in anticipation of future use.

## Recommended Project Layout

The intended SwiftPM products and targets are:

```text
StupidWallet              containing iOS SwiftUI app
WalletCore                shared value types, storage, RPC, signing, and policy
StupidWalletSafari        native Safari Web Extension handler
CSecp256k1                vendored C cryptographic target
StupidWalletTests         package unit tests where supported
```

On Apple Silicon Mac, TestFlight distributes this same iOS app and bundled
`StupidWalletSafari` extension through Apple's iPhone/iPad-app compatibility path. There
is no separate Mac SwiftPM product or web-resource fork. Extension-capable local installation
requires Xcode or TestFlight because `stupid-app run --mac` rejects extension-bearing apps.

The intended resources are:

```text
SafariExtension/
  Info.plist
  SafariExtension.entitlements
  Resources/
    manifest.json
    provider.js
    bridge.js
    background.js
    popup.html
    popup.css
    popup.js
```

`stupid-app.yml` declares `StupidWalletSafari` in `extensions:` and lists the extension
resource directory as a raw resource. `stupid-app` builds the extension product with
`_NSExtensionMain`, assembles `PlugIns/StupidWalletSafari.appex`, and signs nested bundles
leaf-first with the extension's profile and entitlements.

Keep boundaries explicit:

- `StupidWallet` owns user-driven setup, settings, network preferences, connected sites,
  backup, and activity views.
- `WalletCore` owns all canonical request types, validation, key access, hashing,
  transaction encoding, RPC transport, and persistent stores.
- `StupidWalletSafari` translates native messages into `WalletCore` operations. It must
  not contain a second implementation of wallet policy or Ethereum encoding.
- JavaScript owns EIP-1193 compatibility, Safari messaging, popup rendering, and routing
  completion back to the requesting tab. It never receives private keys or performs
  signing.

## Safari Request Flow

### Non-approval request

1. The MAIN-world provider receives `ethereum.request({ method, params })`.
2. It posts an envelope with a cryptographically random request ID to the isolated-world
   bridge. Messages are accepted only from the same window and origin.
3. The bridge forwards to the background worker.
4. The background worker derives the authoritative top-level origin and tab identity
   from Safari's `sender`; it ignores origin metadata supplied by the page.
5. The method classifier either handles the request locally/natively or proxies it to
   the selected RPC.
6. The bridge posts the structured result or error to the original page request.

`wallet_switchEthereumChain` follows this non-approval path: native code requires an active
wallet and an exact connected-origin/profile grant, validates `[chainObject].chainId`,
serializes and persists the switch, and returns `null`; the worker then broadcasts
`chainChanged`. It never accesses the private key.

### Approval request

1. The background worker sends the authoritative origin, tab identity, method, params,
   and request ID to native code as a prepare operation.
2. Native code validates and canonicalizes the request, computes a payload digest, and
   persists a one-time pending record in the App Group with an expiry. For sends, missing
   nonce/gas fields remain unresolved so queued requests do not snapshot the same values.
3. Native returns the canonical pending ID. The isolated bridge retains it only for the lifetime
   of the page request and polls native status through the worker. The App Group pending store is
   authoritative; browser storage does not hold approval authority or sensitive payloads.
4. Safari updates the extension badge. An optional minimal in-page notice may tell the
   user to open the wallet extension, but it cannot approve or alter the request.
5. The user opens the toolbar popup. On macOS it requests the canonical, display-safe list directly
   from native code, with the worker route retained as an iOS-compatible transport fallback.
6. On approval, the popup sends only the request ID, displayed revision, and decision. Native code
   reloads the canonical record and verifies its origin, chain, account-inclusive payload digest,
   revision, expiry, and unconsumed state. It never accepts canonical params from the popup.
7. For sends, native code resolves missing nonce, gas limit, and fee values through the
   active RPC immediately before signing while retaining the immutable approved intent.
   It then creates a fresh `LAContext`, requests device-owner authentication, and performs
   signing only after authentication succeeds.
8. Native code durably consumes the pending request and returns the result. Under multi-account Gate F,
   plain connect first writes its result marker atomically with grant/active/default connection state,
   so interruption before pending consumption recovers the same result rather than creating a grant
   that can later be rejected.
9. The originating isolated bridge observes the consumed or rejected record through native status
   polling and resolves the matching page request. Navigation or tab closure destroys that page
   session, so a result is never delivered to a different page.

Pending requests must expire, survive service-worker suspension, reject replay, and have
a deterministic policy for concurrency. The initial policy is one active approval
surface at a time with additional requests queued in creation order.

## RPC Method Policy

There is one method classifier shared conceptually by JavaScript and native code. Native
code remains authoritative.

### Explicitly handled methods

- Account and connection: `eth_requestAccounts`, `eth_accounts`, `wallet_connect`,
  `wallet_disconnect`.
- Chain state: `eth_chainId`, `net_version`, `wallet_addEthereumChain`,
  `wallet_switchEthereumChain`.
- Signing and sending: `personal_sign`, `eth_signTypedData_v4`,
  `eth_sendTransaction`.
- Deferred methods become explicit only when implemented and tested.

### Explicitly denied methods

Methods that would expose unsafe or ambiguous signing behavior return EIP-1193 error
code `4200` until a concrete reviewed design exists:

- `eth_sign`.
- `eth_signTransaction`.
- `eth_signTypedData`, `eth_signTypedData_v1`, and `eth_signTypedData_v3`.

### Passthrough methods

Every method not explicitly handled or denied is forwarded unchanged to the active RPC
endpoint. This includes ordinary `eth_*`, `net_*`, `web3_*`, and provider-specific node
methods. Do not add read methods to an allowlist merely to make a dapp work.

Routed passthrough is native: the extension's background worker dispatches unhandled
methods to the `passthrough` native action, which `WalletService` forwards through the one
`RPCResolver`/`RPCClient` (so reads, sends, polling, and passthrough share the same
endpoint hierarchy). Structured node errors and `null` results return untouched to the
page.

The proxy must preserve:

- Arbitrary nested JSON objects and arrays.
- String, number, Boolean, and `null` results.
- Node error `code`, `message`, and `data`.
- Transport failures as distinct wallet/provider errors.
- Request cancellation and a bounded timeout.

Use an internal `JSONValue: Codable, Sendable, Equatable` representation or equivalent;
do not use generic result casts such as `result as? T`.

Standard provider errors use the relevant EIP-1193 codes, including `4001` for user
rejection, `4100` for unauthorized account access, `4200` for intentionally unsupported
wallet methods, and `4900`/`4901` for connectivity failures where applicable.

## Network And RPC Model

For chain ID `N`, the default RPC URL is:

```text
https://evm.stupidtech.net/v1/N
```

`N` is decimal. A chain does not need to be present in a bundled registry for RPC access.
Metadata such as display name, native currency, and explorer URL is optional and may come
from confirmed dapp suggestions or user settings.

`NetworkStore` initially seeds four bundled networks and merges metadata from confirmed
add-chain requests, successful switches, manual additions, and legacy `customChains` names.
Switching to a chain is sufficient to make it visible in Settings. The Include in Total
Balance preference defaults on, preserves the legacy `excludedFromBalance` values, and gates
both fetching and home-screen aggregation. Manual additions require a name, chain ID, and an
RPC URL that passes the same HTTPS, reachability, and exact-chain validation as an edited
override. Any configured network can be deleted. Removal persists by chain ID so an initial seed or
legacy entry does not reappear; a later explicit add-chain approval, successful switch, or manual
addition restores it. Selection does not make a network undeletable.

Each chain may have one validated override. Saving an override requires:

- A syntactically valid URL.
- HTTPS, except for an explicit development-only loopback HTTP path.
- A successful `eth_chainId` response.
- Exact equality between the endpoint's chain ID and the chain being configured.

All app and extension operations use the same resolver. Balance reads, signing-time
transaction resolution, fee data, simulation, ENS work, receipt polling, and generic
passthrough must not create independent RPC hierarchies.

`wallet_addEthereumChain` displays the first dapp-provided `rpcUrls` entry as its fallback
candidate. During approval it validates the Stupidtech default with `eth_chainId`; if that
endpoint does not serve the requested chain and no user override already exists, it validates
and saves the first candidate. Invalid, insecure, unreachable, and wrong-chain candidates fail
loudly. `wallet_switchEthereumChain` requires an authorized origin/profile grant but changes
the active chain immediately without popup confirmation or biometric authentication. It never
saves dapp-supplied RPC URLs.

## Signing Security Model

### Approval boundary

- The Safari toolbar popup is extension-owned HTML and CSS. A webpage cannot style it.
- Safari requires a user gesture to open the popup; the extension cannot open it
  programmatically. The UX must make this requirement clear without treating an injected
  notice as approval.
- The popup displays data loaded from the native canonical pending record, not a separate
  JavaScript interpretation of page params.
- Native signing accepts a one-time pending request ID, never arbitrary signing params
  from the popup's approval message.
- The native authentication reason identifies the action and requesting origin within
  the limits of `LocalAuthentication` system UI.

### Key protection

- Generate secp256k1 private keys with `SecRandomCopyBytes` and reject zero or values at
  or above the curve order.
- Store new-format key material in the shared keychain with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and a `SecAccessControl` policy using
  `.userPresence`.
- Use a fresh `LAContext` for every signing or export operation.
- Set authentication reuse to zero and invalidate the context after use.
- Never preflight authentication, cache decrypted keys, or retain an unlocked account
  object between requests.
- Keep plaintext key bytes in the narrowest scope possible and overwrite mutable buffers
  before release.
- Never log private keys, seed phrases, decrypted payloads, raw authentication output, or
  full sensitive signing payloads.

Apple's Secure Enclave does not natively sign secp256k1. It supports P-256, so Ethereum
signing requires software secp256k1 after authenticated keychain release. Use a pinned,
vendored upstream `libsecp256k1` C target rather than implementing elliptic-curve signing
from scratch. Record its exact revision, build options, license, and provenance in the
implementation notes and repository notices.

Small protocol primitives should remain project-owned Swift where practical:

- Keccak-256.
- Hex and quantity parsing.
- EIP-55 address formatting.
- RLP.
- Legacy and EIP-1559 transaction serialization.
- EIP-191 message hashing.
- EIP-712 v4 encoding and hashing.
- JSON-RPC envelopes.
- BIP-39/BIP-32 support for the first-milestone seed-import flow.

Every cryptographic or serialization primitive requires independent known-vector tests.

## Existing Wallet Migration

Identity continuity makes migration a release blocker, not optional compatibility code.
The old app stores:

- The checksummed address in App Group defaults.
- ECIES ciphertext in a generic-password keychain item keyed by that address.
- A Secure Enclave P-256 private key tagged by the address in the shared access group.
- ECIES algorithm `eciesEncryptionCofactorVariableIVX963SHA256AESGCM`.

The migration sequence is:

1. Detect an old address and ciphertext only when no new-format wallet exists.
2. Retrieve the existing tagged Secure Enclave key from the preserved access group.
3. Decrypt the old ciphertext through Security using the existing algorithm. This invokes
   its `userPresence` policy.
4. Validate private-key length and secp256k1 range.
5. Derive the Ethereum address with the new implementation and require exact equality
   with the persisted address after checksum-insensitive normalization.
6. Store the key in the new format and mark migration pending verification.
7. Perform a new-format authenticated sign-and-recover self-test.
8. Mark migration complete only after the self-test succeeds.
9. Retain old ciphertext and Secure Enclave material until migration is proven. Deletion,
   if desired, is a separate idempotent cleanup step after successful use.

An interrupted attempt resumes from the pending new-format item and repeats step 7 rather than writing
the key again. If the key write committed before the pending marker, `errSecDuplicateItem` also advances
only to step 7. Neither path registers the wallet or removes old material without authenticated proof.

Do not retain Dawn Key Management as a runtime package solely for migration. Reimplement
the small Security-framework read/decrypt path against the documented persisted format.
Before release, test an actual old app installation upgraded in place on a physical
device. Unit fixtures alone are insufficient proof of Secure Enclave and access-group
continuity. Prepare that state by installing the old release under the production identities and
using its UI to create or import a disposable wallet and exercise the grants/activity being migrated.
Then install the new build over it without uninstalling, clearing Safari, or resetting App Group,
UserDefaults, keychain, or Secure Enclave state. Never use a personal or funded wallet for the test.

## Persistence

Use the production App Group for shared non-secret state:

- Current chain and network metadata.
- Validated user RPC overrides.
- Connected-site grants keyed by normalized origin, not hostname alone.
- Pending signing records and replay state.
- SQLite activity database.
- Migration status that contains no key material.

Connection grants bind at least scheme, host, and effective port. Do not collapse HTTPS
and HTTP or distinct ports into one hostname authorization. Safari profile identifiers
should be incorporated when available so grants do not silently cross Safari profiles.

SQLite remains appropriate for activity and pending-request state when transactional
consumption is required. UserDefaults is acceptable only for small preference values
that do not require atomic multi-field updates. Connected-site grants intentionally
reuse the legacy App Group `UserDefaults` key `connectedSites`
(`[hostname: {address, connectedAt}]`) so pre-existing connections survive an upgrade;
this is a locked compatibility exception, and grants are treated as sensitive user data
even though they are not key material.

### Encrypted iCloud Recovery Direction

Cloud wallet backup is designed but not implemented. The selected version-1 direction is
recorded in `docs/icloud-wallet-backup-plan.md`: one current, password-protected snapshot of
the active wallet state stored as a separate `kSecAttrSynchronizable` generic-password item
in iCloud Keychain. The password is not saved or synchronized by Stupid Wallet. There is no
password-independent recovery key, backup history, or silent iCloud Documents fallback.

The live seed and private-key stores remain unchanged, device-bound, `.userPresence`
protected, and non-synchronizable. Only authenticated ciphertext is synchronized. Restore
creates and verifies new device-bound items through a journaled additive transaction; it
never replaces an existing protected source automatically.

The selected transport requires no iCloud Documents/CloudKit container or ubiquity
entitlements. A dedicated containing-app-only keychain access group is preferred so the
Safari extension cannot query the backup envelope; profile authorization and two-device
synchronization behavior require a focused physical spike. Security.framework does not
provide a server-upload receipt, so UI must distinguish local Keychain success from proven
cross-device availability.

### Wallet Activity Notification Direction

Wallet-activity push notifications are designed but not implemented. The broader design is
`docs/wallet-backend-push-notifications-plan.md`; the approved first implementation scope and ordered
gates are in `docs/wallet-backend-push-notifications-mvp-plan.md`. Add the TypeScript Cloudflare Worker
to this repository under `WalletBackend/` and deploy it independently at
`wallet-api.stupidtech.net`. It holds upstream webhook credentials, verifies exact-body HMAC deliveries,
maintains installation/address/chain state, and sends best-effort APNs notifications. APNs is never the
activity authority; the app synchronizes a cursor-based event feed and persists remote observations plus
its cursor atomically in SQLite without changing the shipped sender-centric `transactions` identity.

Initial enrollment is opt-in only for active `WalletRegistry` accounts. The backend stores canonical
public address registrations without claiming ownership, so future watched-address support can reuse the
protocol without weakening the first app UI. Enrollment and synchronization use a separate device-bound
P-256 installation key and must never release a wallet key, create an Ethereum signature, or present
Face ID/passcode. The key and backend installation ID require a dedicated containing-app-only,
non-synchronizable `ThisDeviceOnly` keychain path; the current entitlements do not yet provide a proven
path. Retained keychain state may recover the same active server installation after reinstall, but Apple
does not guarantee keychain survival across uninstall. `identifierForVendor` and APNs tokens are not
installation identities.

The backend tracks only notification-capable installations: current alert authorization, an active APNs
token, at least one account enrollment, and an unexpired liveness window are all required. Explicit
disablement of the last account, client-observed loss of authorization, permanent invalidation of the
current APNs token, or liveness expiry deletes server installation state through idempotent cleanup.
APNs does not reliably report Settings changes or app deletion, and acceptance does not prove display,
so client reconciliation plus bounded liveness remains required. A delayed APNs failure for an old token
must not invalidate a replacement token.

User-opened Safari toolbar popup activity also triggers a coalesced liveness renewal. The installation
P-256 key remains app-only. Instead, the containing app creates a second non-synchronizable P-256 key in
the existing shared app/Safari keychain group. The backend accepts that key only for extending the
unchanged liveness of an already-active installation. It cannot create or revive an installation, read
events, or mutate notification settings, APNs tokens, accounts, addresses, or chains. Popup renewal
cannot extend past the freshness ceiling established by the containing app's last P-256-signed
notification-settings check. Page JavaScript, ordinary provider requests, worker startup, and popup
polling are not liveness signals.

MVP lifecycle defaults are a 30-day liveness window, 90-day containing-app notification-settings
freshness, popup renewal at most once per 24 hours, foreground full renewal at 14 days remaining, and
30-day backend event retention. Limits are 25 addresses, 25 configured chains, and 250 effective
address-chain pairs per installation. Disabling the final account deletes the complete server
installation; no dormant backend credential remains.

Each installation synchronizes a complete monotonic snapshot of every chain configured in
`NetworkStore`; `includeInBalance` is unrelated. Enabling one account covers all configured chains that
are globally active. A chain remains staged until five distinct notification-capable installations have
it configured, then becomes sticky-active unless an operator disables it. Multiple accounts on one
installation count once.

The selected notification presentation is an event title plus `<account label> • <chain>` subtitle and
a locally generated account-blockie attachment thumbnail. A Notification Service Extension resolves an
opaque registration ID against minimal App Group display state; labels and full addresses do not belong
in the base APNs payload. The standard app icon remains because iOS does not allow per-notification icon
replacement. The categorical MVP titles and generic fallback are locked below; attachment behavior still
requires physical-device review.

The MVP title is categorical only: received/sent native funds, token, NFT, sent transaction, failed
transaction, reverted activity, or generic wallet activity. Amounts, assets, counterparties,
localization, and user-selectable preview detail are deferred. Webhook deliveries deduplicate by
`(webhookId, eventType)` so current observed/reverted deliveries sharing one upstream ID both apply
exactly once.

No wallet entitlement or behavior changes until `stupid-app` supports per-bundle Push Notifications
capability/profile reconciliation. The containing app alone receives push capability. App Attest
collection and enforcement are deferred, with nullable backend trust state reserved for later work. The
new Notification Service Extension receives App Group access only and no wallet keychain, push, or App
Attest entitlement. MVP notification enrollment is hidden on Apple Silicon Mac; iPhone and iPad physical
acceptance are required.

## Dependency Policy

The target runtime dependencies are Apple system frameworks plus the vendored
`libsecp256k1` source:

- SwiftUI.
- Foundation and URLSession.
- Security.
- LocalAuthentication.
- SafariServices.
- CryptoKit where it provides an exact required primitive.
- OSLog.
- SQLite3.

Do not add React, React Query, Vite, Tailwind, viem, Web3.swift, PromiseKit, BigInt,
CryptoSwift, Dawn Key Management, or a general wallet SDK without a concrete reviewed
need that cannot be met safely by the project-owned core.

Dependency count is not the only criterion. For security-critical cryptography, prefer a
small, mature, pinned implementation over novel project-owned arithmetic. Every added
dependency requires a documented purpose, revision/version policy, license review,
attack-surface assessment, and removal boundary.

## Implementation Gates

### Gate 0: Project And Documentation Baseline

Exit conditions:

- `AGENTS.md`, this handover, and implementation notes exist and agree.
- Production app, extension, App Group, and keychain identities are represented in
  configuration and entitlements.
- Package targets have clear ownership boundaries.
- `stupid-app doctor` has no project-configuration failure.
- The containing app still builds and launches in the preferred simulator.

### Gate 1: Safari Extension Packaging Spike

Exit conditions:

- `stupid-app build` assembles the Safari `.appex` and all raw extension resources.
- The extension loads and can be enabled in iOS Safari.
- MAIN-world EIP-6963 discovery works on a minimal local dapp.
- A toolbar popup opens under user control and communicates with the background worker.
- Native messaging reaches `NSExtensionRequestHandling` and returns a structured response.
- A native Face ID/passcode prompt can be invoked from the extension flow while Safari
  remains foregrounded on a physical device.

This gate must be proven before implementing rich wallet UI or transaction signing. If
the native-auth interaction fails under real Safari lifecycle constraints, stop and
update the architecture rather than falling back silently to page approval.

### Gate 2: JSON And RPC Core

Exit conditions:

- `JSONValue` round-trips every JSON type, including nested `null`.
- The method classifier has one authoritative native policy.
- Explicit wallet methods, denied methods, and generic passthrough behave as documented.
- Node error objects are preserved.
- Stupidtech default routing works for multiple chain IDs.
- User overrides reject malformed, insecure, unreachable, and wrong-chain endpoints.

### Gate 3: Key And Ethereum Primitives

Exit conditions:

- Vendored `libsecp256k1` revision and license are recorded.
- Key generation, public-key derivation, address derivation, signing, and recovery pass
  independent vectors.
- Keccak, RLP, EIP-191, EIP-712, legacy transactions, and EIP-1559 transactions pass
  cross-implementation vectors.
- New keychain storage requires Face ID or device passcode on a physical device.
- No authentication reuse or plaintext key persistence is observed.

### Gate 4: Upgrade Migration

Exit conditions:

- Unit tests cover old-item detection, malformed ciphertext, wrong address, cancellation,
  idempotency, and cleanup safety.
- A wallet created by the old release survives an in-place upgrade on a physical device.
- Its address remains unchanged.
- A new-format authenticated signature verifies against that address.
- Failed or cancelled migration leaves old data usable and does not mark completion.

### Gate 5: Canonical Approval Protocol

Exit conditions:

- The popup renders the native canonical summary for connect, message, typed-data,
  add-chain, and transaction requests.
- Approval is bound to origin, chain, method, canonical payload digest, request ID, and
  expiry.
- Replay, mutation, origin mismatch, navigation, closed tabs, expired requests, and
  duplicate completion are rejected.
- Pending requests survive service-worker suspension.
- Concurrent requests follow the documented queue policy.
- Reject maps to EIP-1193 `4001` and never invokes signing.

### Gate 6: Secure Wallet Core

Exit conditions:

- Create/import/backup flows are authenticated and do not retain plaintext.
- New site connect/disconnect grants use normalized origins and Safari profiles when
  available; legacy hostname grants retain the documented compatibility fallback.
- Required signing and transaction methods work against representative dapps.
- Generic node methods no longer require wallet code changes.
- Chain addition requires approval; authorized switching is immediate and neither path can
  silently replace RPC preferences.
- Transactions are logged and receipt status updates correctly.
- App and extension use one RPC resolver and one canonical transaction implementation.
- The app builds, installs, launches, and signs through `stupid-app` on the preferred
  simulator and a physical device as applicable.

### Gate 7: Deferred Feature Parity

SIWE, EIP-5792 atomic calls, and wallet-owned EIP-7702 authorization management are
implemented behind the earlier canonical-request, native-approval, origin/profile,
keychain-authentication, and RPC-resolution boundaries. Simulation, ENS, ABI metadata,
and clear signing remain separate later work.

Current acceptance status (2026-08-25): deterministic vectors, native policy, Safari
routing, popup summaries, SIWE signing, all-configured-network capability reporting, runtime
hash checks and caching, safe foreign-code refusal, deterministic implementation deployment,
state-override estimation, and rejection without broadcast are proven. The prototype fixture
includes Ethereum, Base, Arbitrum, and an explicit local Anvil add/switch flow and wraps JSON
results for complete simulator OCR. A funded Base end-to-end run also proved first-time type-4
delegation and atomic execution, the canonical delegation designator, a subsequent type-2
atomic execution, successful receipts, and `wallet_getCallsStatus` status `200` with receipt
data. A funded simulator Anvil run added chain 31337 through `wallet_addEthereumChain`, applied
its deliberate loopback RPC override, deployed the missing implementation, completed the
  type-4 authorization batch, then completed a type-2 delegated batch; all three receipts
succeeded and the resulting runtime/designator matched. Raw RPC responses were retained
outside the repository for local audit.

Remaining exit conditions:

- Make successful call-bundle status lookup survive an activity-database write failure.
- Extend the proven Base and local-custom-chain flows to other production networks when
  cross-network release evidence is required.
- Prove physical-device authentication and Safari-foreground behavior for both protected
  signatures used by first-time delegation.

### Gate 8: iOS TestFlight On Mac

Exit conditions:

- App Store Connect continues to make the iOS TestFlight build available on compatible
  Apple Silicon Macs.
- The iOS TestFlight build installs and launches on Mac without a separate Mac binary.
- macOS Safari registers and enables the bundled `StupidWalletSafari` extension.
- Provider injection, EIP-6963 discovery, native messaging, toolbar popup review, pending
  completion, and RPC passthrough work in macOS Safari without platform-specific web code.
- Signature approval releases the compatibility-environment key through Touch ID or the
  available system authentication policy while Safari remains foregrounded.
- The containing app and extension share their App Group and keychain state on that Mac.
  Cross-device synchronization with an iPhone is not implied.
- Local `stupid-app run --mac` intentionally rejects this extension-bearing project because
  its LaunchServices-only installer cannot create the required MobileInstallation/PlugInKit
  records. The tracked `Mac/` XcodeGen project is the local development exception; TestFlight is
  still required to prove the distribution path.

Current Mac propagation status (2026-08-26): the multi-account Safari compatibility model is
accepted with Safari Technology Preview. A real TestFlight Dawn installation was upgraded in place
by the current Xcode compatibility build; the wallet opened without setup fallback, adopted the
legacy private-key wallet as one active group, removed the downgrade fallback, and then added a
separate disposable seed group with a derived account. Safari listed all grouped accounts in its
fixed-height popup, rebound a connection to the derived seed account, completed the grant, and a
second same-origin tab bootstrapped the same provider account. Rejection cleared the request and
badge. A protected `personal_sign` request produced a consumed 65-byte signature whose recovered
signer matched the persisted request account. Generic `eth_blockNumber` passthrough returned through
the active native resolver.

TestFlight installation had reintroduced multiple production-identity Safari rows and pointed
PlugInKit at the TestFlight extension. Quit Safari, unregister the exact stale TestFlight and local
appex paths, rerun the current Xcode scheme, then keep only the current manifest row enabled. The
account picker now bounds itself to the popup viewport and owns vertical scrolling so derived rows
do not clip or scroll the underlying dapp. The status reader also treats temporary request-claim
contention during popup approval as pending after rechecking profile and binding, rather than falsely
reporting the request missing; a clean current-build connection completed back to the originating
page after this fix.

The connect-account picker receives the editable wallet-group and account labels from the native
registry summary. It renders each group label as its heading and each account as blockie followed by
account label with a smaller muted shortened address below. Group headings preserve their editable
capitalization rather than forcing uppercase. The popup uses the native selector's 28-point blockie
proportion and regular account-label sizing, while the full address remains native rebind identity and
hover metadata.

The popup now sends `list`, `approve`, and `reject` directly to native on macOS so status polling in
the background worker cannot delay the review surface, while retaining the background route as a
transport fallback for Safari environments where direct native messaging is unavailable. Manifest
`0.1.53` contains the dedicated monochrome toolbar action icons, current request-review layout,
the viewport-bounded account picker, and the direct-popup synchronization introduced in `0.1.23`:
after a successful decision it notifies the worker before the popup closes,
and an empty worker request set clears the badge with an empty string rather than displaying `0`.
Live rejection proved the one-item badge disappears immediately. Mac transaction broadcast plus a
network-verified receipt remains unproven and is not part of the multi-account Gate H exit condition.

Current physical profile/lock status (2026-08-26): the latest development-signed app and nested
extension were installed over the saved network pairing without replacing persisted wallet state.
The same exact test origin retained a private-key account in Personal and a seed-derived account in a
disposable second Safari profile. Switching profiles preserved each account, and a protected signing
request's badge and popup entry were absent from Personal while remaining available in the requesting
profile. A fresh protected request then remained pending across a device auto-lock interval, produced
no result while locked, recovered unchanged when Mirroring resumed, and rejected normally afterward.
Both test grants and the disposable Safari profile were removed after acceptance. Safari had to be
force-quit once after replacing the installed extension so its content script and background worker
were loaded from the new build; a page reload alone retained the pre-install extension context.

External-TestFlight status (2026-08-29): version 1.0.0 build 97 is the current external candidate,
approved for external testing with its what's-to-test note preserved from build 96. It carries the
restored `NSFaceIDUsageDescription` in both the containing app and the Safari extension. Build 95 had
earlier been the first external candidate after the SDK-build-metadata fix.
Builds 92–94 were rejected or flagged by Apple's external gate because their archives omitted the
SDK build-number keys `DTPlatformBuild`/`DTSDKBuild` (and, before 94, had a wrong `DTXcode`).
External review now accepts build 95, whose packaged Info.plist carries the complete build-system
provenance (`DTXcode` `2660`, `DTXcodeBuild` `17F113`, `DTPlatformBuild`/`DTSDKBuild` `23F81a`),
and it is live in external beta testing. The `stupid-app` release pipeline was fixed to emit the
`DTPlatformBuild`/`DTSDKBuild` keys from the SDK's `SystemVersion.plist` build number and to encode
`DTXcode` canonically (`major*100 + minor*10 + patch`); build via
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer stupid-app release …` for the Xcode 26.6 /
iOS 26.5 SDK toolchain at `/Applications/Xcode.app`.

## Test Strategy

### Hermetic tests

- JSON parsing and property-list bridge conversion.
- Method classification and EIP-1193 errors.
- Origin normalization and authorization grants.
- RPC result/error preservation with a local stub server.
- Network override validation.
- Keccak, EIP-55, RLP, EIP-191, EIP-712, and transaction vectors.
- secp256k1 key validation, signing, low-s normalization, and recovery.
- Pending request state transitions and replay resistance.
- Activity schema and receipt transitions.
- Migration state-machine behavior using sanitized keychain abstractions.

### Integration tests

- MAIN-world provider to isolated bridge messaging.
- Service-worker suspension and pending completion.
- Toolbar popup request listing, approval, rejection, and expiry.
- Native message property-list conversion for all JSON values.
- RPC behavior against `evm.stupidtech.net` on representative chains.
- Compatibility against small viem-based dapp fixtures used only as test references.

### Physical-device gates

- Safari extension enablement and toolbar-popup UX.
- Face ID/passcode prompt while Safari stays foregrounded.
- New wallet creation and authenticated signing.
- In-place Dawn-format migration.
- Keychain access-group sharing between app and extension.
- Cancellation, biometric failure, passcode fallback, and device-lock behavior.

Record exact verification commands and public-safe outcomes in implementation notes.
Never record wallet secrets, seed phrases, private keys, addresses tied to a person,
device identifiers, or sensitive signing payloads.

## Risks And Open Decisions

- **Toolbar discoverability:** Safari cannot open the extension popup programmatically.
  Gate 1 must validate a clear badge/notice flow on iPhone and iPad.
- **Native authentication lifecycle:** LocalAuthentication is expected to present system
  UI over Safari, but the exact extension-process behavior requires physical proof.
- **Popup lifecycle:** Safari may destroy popup JavaScript immediately after dismissal.
  Native and background persistence must not depend on popup process lifetime.
- **Service-worker lifecycle:** In-memory state is insufficient. Completion routing must
  survive suspension without delivering to a navigated tab.
- **Property-list native bridge:** Safari native messaging does not carry arbitrary Swift
  `Codable` values directly. The JSON/property-list conversion layer needs exhaustive
  tests, especially for `null`.
- **Private-key backup:** Authenticated reveal, local expiring pasteboard copy, inactivity
  clearing, and background clearing are implemented. Physical-device cancellation/timeout
  behavior and screen-capture exposure still require focused verification before release.
- **Cloud recovery authority:** Version 1 synchronizes only a password-encrypted envelope;
  operational keys remain device-bound, and Stupid Wallet does not synchronize the password
  or an independent recovery key. Password policy and forgotten-password UX remain open,
  and the app must not imply that Apple Account recovery alone is sufficient.
- **Cloud availability and rollback:** App-level authenticated encryption protects backup
  confidentiality and integrity, not availability or freshness. Synchronizable Keychain
  supplies no server-upload receipt, conflict catalog, or guaranteed ordering. Item-size,
  delayed sync, concurrent update, account-change, deletion-propagation, reinstall, and
  independent-device restore behavior require physical acceptance.
- **Notification lifecycle:** APNs exposes no reliable disabled-setting or uninstall signal. Active
  server state therefore depends on app-reported settings, permanent errors for the current token, and a
  bounded liveness window. User-opened toolbar popup activity may renew unchanged liveness through a
  narrowly scoped capability, but it cannot refresh notification authorization or revive deleted state.
  The MVP locks 30-day liveness, 90-day settings freshness, 24-hour popup coalescing, 14-day foreground
  renewal threshold, and 30-day server event retention; bounded rollout evidence must precede changing
  them.
- **Notification identity and provisioning:** Same-installation recovery after reinstall is best effort,
  not an Apple guarantee. A dedicated containing-app-only keychain path and per-bundle `stupid-app`
  Push Notifications handling plus Notification Service Extension packaging must be proven before
  changing wallet entitlements. App Attest is deferred from MVP.
- **Notification privacy and presentation:** Account labels and addresses stay out of base APNs payloads.
  The MVP uses the locked categorical titles and generic fallback without amounts, assets, or
  counterparties. Blockie attachment rendering still requires physical-device proof.
- **Webhook event identity:** The upstream service currently reuses one delivery ID for observed and
  reverted notifications despite documenting header-only deduplication. MVP explicitly deduplicates by
  `(webhookId, eventType)` and requires a regression fixture for the collision.
- **Safari profiles:** Current physical-iPhone acceptance proves `SFExtensionProfileKey` isolation on
  the tested OS. Verify availability and stability on every other supported iOS version before making
  profile binding mandatory there.
- **Legacy grant identity precision:** new grants are scheme + effective-port + Safari-
  profile bound and mirror the old `connectedSites` key. Pre-existing hostname-only grants
  intentionally retain authorization until reconnect/disconnect, so those specific entries
  remain scheme/port/profile agnostic by compatibility policy.
- **Chain metadata:** Universal RPC support does not provide names, symbols, explorers,
  or icons. Keep metadata optional until a small trustworthy source is chosen.
- **Transaction preview:** A secure confirmation must display enough canonical detail
  before rich ABI decoding exists. The initial fallback is raw destination, value,
  chain, fees, and calldata hash/size rather than pretending unknown calldata is safe.
- **Multiple-account state transitions:** wallet registry, connection grants/default/active state,
  pending requests, protected secrets, and deletion span multiple processes and persistence systems.
  The implementation must use the lock order and recoverable commit boundaries in
  `docs/multi-account-implementation-plan.md`; independent actor isolation is insufficient.
- **Provider account-change delivery:** iOS SafariServices exposes no containing-app equivalent of
  macOS `SFSafariApplication.dispatchMessage`. Simulator evidence proved initial injection plus
  `pageshow`, focus, and visible `visibilitychange` refresh after returning to Safari; no polling is
  currently justified. Physical same-origin and cross-profile acceptance now confirms that model on
  the tested iPhone.

Resolve open decisions through focused proof work. Record the result here and the
investigation history in implementation notes.

## Recommended Next Work

1. Complete Gate I hardening with fault injection at each individual account-deletion boundary and
   physical-device acceptance for label persistence, picker navigation, protected derivation, pending
   authority cleanup, and seed-account removal/relaunch recovery.
2. Continue Gate 6 with the remaining focused backup timeout/screen-capture and broader
   cancellation/passcode-fallback checks. Multi-account Gate H, including its pending-request
   device-lock acceptance, is complete.
   Raw private-key import, protected seed import, generated-backup cancellation, seed-derived export,
   group deletion, and Safari signing are proven on the physical iPhone.
3. Physically verify `SFExtensionProfileKey` stability and cross-profile isolation on every other
   supported iOS version. The product owner chose seamless authorization for pre-existing
   hostname grants; consider a later user-visible reconnect campaign before removing that
   compatibility fallback.
4. Finish parity details that do not weaken the new model: richer activity detail and broader
   optional chain metadata. ENS/avatar resolution remains deferred rather than being hidden
   inside Gate 6.
5. Gate 7 and later per the implementation gates.
6. Resolve the remaining password-policy, snapshot-scope, deletion-copy, update-key, and
   maximum-item-size decisions in `docs/icloud-wallet-backup-plan.md`. Then complete its
   synchronizable-Keychain and cryptographic-format gates before adding backup UI or reading
   protected wallet sources.
7. Begin Gate 0 of `docs/wallet-backend-push-notifications-mvp-plan.md`: freeze shared Swift/TypeScript
   contracts and sanitized observed/reverted fixtures. Then fix per-bundle Push Notifications derivation
   in `stupid-app` and prove Notification Service Extension packaging before changing wallet entitlements
   or implementing backend enrollment.

## Reference Sources

- Existing app and migration source: `../ios-wallet`.
- Approved multiple-account design: `docs/multi-account-implementation-plan.md`.
- Draft encrypted iCloud recovery design: `docs/icloud-wallet-backup-plan.md`.
- Draft wallet backend and push-notification design:
  `docs/wallet-backend-push-notifications-plan.md`.
- Approved wallet backend and push-notification MVP scope:
  `docs/wallet-backend-push-notifications-mvp-plan.md`.
- Repository debugging workflow: `skills/stupid-wallet-debugging/SKILL.md`.
- `stupid-app` source and extension packaging behavior: `../stupid-ios-dev`.
- Maintained CLI extension scope:
  `../stupid-ios-dev/docs/app-extensions-app-groups-scope.md`.
- Safari Web Extension messaging:
  <https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension>.
- LocalAuthentication:
  <https://developer.apple.com/documentation/localauthentication/lacontext>.
- Keychain synchronization:
  <https://developer.apple.com/documentation/security/ksecattrsynchronizable>.
- iCloud data protection:
  <https://support.apple.com/en-us/102651>.
- EIP-1193: <https://eips.ethereum.org/EIPS/eip-1193>.
- EIP-6963: <https://eips.ethereum.org/EIPS/eip-6963>.
- EIP-712: <https://eips.ethereum.org/EIPS/eip-712>.
- EIP-1559: <https://eips.ethereum.org/EIPS/eip-1559>.

External source is reference material, not automatically current truth. Verify API
availability, behavior, licenses, and tests before adapting code.
