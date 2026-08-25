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
explicit cleanup. A duplicate decrypt was removed so a successful run shows exactly two
Face ID/passcode prompts.

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
  a deterministic squircle blockie plus `0x1234...abcd` text, while retaining the full address as hover
  metadata. Native-value quantities are formatted in the network currency rather than shown as
  hexadecimal, and explicit add-network Chain IDs are decimal; nonce, gas limit, and raw
  fee fields are not exposed in the popup, while simulation and calldata decoding remain
  deferred. Generic chain rows resolve through the shared `NetworkStore` and display the
  persisted network name, falling back to `Chain N` for unknown metadata; explicit add-network
  Chain ID fields remain numeric. Atomic batches use a compact per-call card hierarchy
  without ABI decoding, while retaining canonical target, formatted value, and raw calldata. The
  batch summary omits redundant Execution and Authorization rows. Each card stacks a compact To
  field plus Value and Data only when they are non-zero/non-empty, with labels above their values
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
an anchored details popover; top-trailing Copy Address icon beside the account blockie menu,
which uses a continuous-corner squircle and begins with a matching squircle blockie plus regular
shortened-address row followed by Activity,
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
message content as multiline text. Legacy signature content remains readable, while
schema migration backfills rebuild-era transaction calldata and signed messages from retained
canonical pending requests joined by request ID. Rows too old to have that request linkage remain
unchanged. EIP-712 activity follows the old app's readable hierarchy: known Domain fields in fixed
order and alphabetized root Message fields, with nested objects and arrays pretty-printed. Invalid
typed-data JSON falls back to exact raw content. Long-pressing anywhere on a structured EIP-712
message opens the compact Copy edit menu and copies the complete original JSON rather than one
display field. Signature details also display the complete signature in a middle-truncated row;
long-pressing it opens the same compact Copy edit menu. Method, status, signature, account, network,
and timestamp share one Signature section rather than splitting verification metadata into a
second section. Schema migration restores rebuild-era signatures from retained consumed request
results when available. Activity list and detail content uses regular system typography throughout;
hashes, addresses, signatures, and typed-data hex values are not monospaced.

Settings also includes a separate destructive Forget Account section. Its modal confirmation
alert warns that the private key will be removed and requires an explicit destructive choice.
Confirming removes the expected active keychain item, clears the shared active-
account registration and migration remnants (including retained old-format material for
that same account), revokes that account's legacy and normalized site grants, dismisses
Settings, and returns to setup. Account-mismatch and keychain-deletion failures do not
silently clear the visible registration. Activity and network preferences are retained.

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
on backgrounding, and on navigation away, and copies only to a local expiring pasteboard.
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
  provider metadata. The current manifest is `0.1.39`; the EIP-6963 reannounce behavior introduced
  in `0.1.20` invalidated the earlier one-shot discovery script, which could be missed when an MIPD
  consumer initialized after the wallet.
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
  `eth_sendTransaction`, `wallet_switchEthereumChain`, and disconnect against the injected
  provider. Dev server runs `--host` on port 5173 for the physical iPhone.

As of Gate 5 fixing: the signing path reads the `.userPresence` keychain exactly once, only
at the moment of signing; `Signer.hasKey()` resolves the active wallet from the non-secret
shared App Group file (`WalletStore.wallet-address.conf`) and never presents Face ID.
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

1. Creates or imports one Ethereum account and keeps its private key local.
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
6. On approval, the popup sends only the request ID and decision. Native code reloads
   the canonical record and verifies its origin, chain, payload digest, expiry, and
   unconsumed state.
7. For sends, native code resolves missing nonce, gas limit, and fee values through the
   active RPC immediately before signing while retaining the immutable approved intent.
   It then creates a fresh `LAContext`, requests device-owner authentication, and performs
   signing only after authentication succeeds.
8. Native code atomically consumes the pending request and returns the result.
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

Do not retain Dawn Key Management as a runtime package solely for migration. Reimplement
the small Security-framework read/decrypt path against the documented persisted format.
Before release, test an actual old app installation upgraded in place on a physical
device. Unit fixtures alone are insufficient proof of Secure Enclave and access-group
continuity.

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

Current Mac propagation status (2026-08-24): request preparation and prompt popup listing are
proven with Safari Technology Preview. Safari Settings had retained two
enabled production-identity rows at different manifest versions even though PlugInKit showed one
current registration; the stale row selected old web resources. Keep only the current row enabled.
The popup now sends `list`, `approve`, and `reject` directly to native on macOS so status polling in
the background worker cannot delay the review surface, while retaining the background route as a
transport fallback for Safari environments where direct native messaging is unavailable. Manifest
`0.1.39` contains the dedicated monochrome toolbar action icons, current request-review layout, and
the direct-popup synchronization
introduced in `0.1.23`: after a successful
decision it notifies the worker before the popup closes,
and an empty worker request set clears the badge with an empty string rather than displaying `0`.
Live rejection proved the one-item badge disappears immediately. The test requests were rejected
without signing. Mac transaction broadcast plus a network-verified receipt remains unproven.

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
- **Safari profiles:** Verify availability and stability of `SFExtensionProfileKey` on
  all supported iOS versions before making profile binding mandatory.
- **Legacy grant identity precision:** new grants are scheme + effective-port + Safari-
  profile bound and mirror the old `connectedSites` key. Pre-existing hostname-only grants
  intentionally retain authorization until reconnect/disconnect, so those specific entries
  remain scheme/port/profile agnostic by compatibility policy.
- **Chain metadata:** Universal RPC support does not provide names, symbols, explorers,
  or icons. Keep metadata optional until a small trustworthy source is chosen.
- **Transaction preview:** A secure confirmation must display enough canonical detail
  before rich ABI decoding exists. The initial fallback is raw destination, value,
  chain, fees, and calldata hash/size rather than pretending unknown calldata is safe.

Resolve open decisions through focused proof work. Record the result here and the
investigation history in implementation notes.

## Recommended Next Work

1. Continue Gate 6 with physical-device proof of create, BIP-39 seed import, backup
   reveal/cancellation/timeout, Forget Account, automatic migration launch, and Safari
   signing with each newly provisioned key. Raw private-key import, including recovery of a
   protected item retained across uninstall, is proven on the physical iPhone; the remaining
   device-bound flows are not yet gate-proven.
2. Physically verify `SFExtensionProfileKey` stability and cross-profile isolation on every
   supported iOS version. The product owner chose seamless authorization for pre-existing
   hostname grants; consider a later user-visible reconnect campaign before removing that
   compatibility fallback.
3. Finish parity details that do not weaken the new model: richer activity detail and broader
   optional chain metadata. ENS/avatar resolution remains deferred rather than being hidden
   inside Gate 6.
4. Gate 7 and later per the implementation gates.

## Reference Sources

- Existing app and migration source: `../ios-wallet`.
- Repository debugging workflow: `skills/stupid-wallet-debugging/SKILL.md`.
- `stupid-app` source and extension packaging behavior: `../stupid-ios-dev`.
- Maintained CLI extension scope:
  `../stupid-ios-dev/docs/app-extensions-app-groups-scope.md`.
- Safari Web Extension messaging:
  <https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension>.
- LocalAuthentication:
  <https://developer.apple.com/documentation/localauthentication/lacontext>.
- EIP-1193: <https://eips.ethereum.org/EIPS/eip-1193>.
- EIP-6963: <https://eips.ethereum.org/EIPS/eip-6963>.
- EIP-712: <https://eips.ethereum.org/EIPS/eip-712>.
- EIP-1559: <https://eips.ethereum.org/EIPS/eip-1559>.

External source is reference material, not automatically current truth. Verify API
availability, behavior, licenses, and tests before adapting code.
