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
  connect, message, typed-data, send, and chain requests. `WalletService.Summary` carries
  `kind`, `title`, ordered `rows`, a `queued` flag, and the active-head queue.
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
- Native approval accepts standard EIP-1193 params throughout: `personal_sign` as
  `[messageHex, address]`, `eth_signTypedData_v4` as `[address, jsonString]` (unwrapped to
  the EIP-712 object), and chain methods as `[chainObject]` reading the standard `chainId`
  key.
- Error mapping in `SafariWebExtensionHandler` covers not-found (4100), already-consumed/
  expired/auth-cancelled (4001), queued/binding-mismatch (‑32000/‑32602), and
  not-ready (4900). Denied methods never prepare.

- The physical-device wagmi flow was completed through the Safari popup for connect,
  message, typed-data, send, and chain approvals. Reconnect after a grant did not enqueue
  a duplicate approval, rejection returned `4001`, and concurrent requests followed the
  documented queue order.

Gate 6 is underway. `eth_sendTransaction` now fills missing nonce, gas limit, and legacy
or EIP-1559 fee fields through the shared resolver before persisting the canonical request;
the popup summary shows the prepared nonce/gas/fees. Approval signs a canonical legacy or
type-2 raw transaction, submits it with `eth_sendRawTransaction`, and resolves to the
32-byte transaction hash. Structured node/transport submission failures become durable
terminal request errors so polling does not strand the dapp promise. Approval/rejection
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
preparation, and passthrough routing. Approved `wallet_switchEthereumChain` requests from a
currently connected origin update that state; `wallet_addEthereumChain` does not switch.
Stale queued requests fail terminally with `4901`. A global advisory lock plus a write-ahead
switch journal prevents concurrent readers from observing an uncommitted chain and recovers
the old or target chain according to durable request consumption after interruption. The
worker broadcasts the canonical native chain to every tab, including after recovery.

Gate 6 activity persistence is implemented. `ActivityStore` extends the existing shared
App Group `Activity.sqlite` schema in place so installed transaction and signature history
is retained. New transaction rows bind the canonical request ID, hash, chain, account,
origin, and nonce, then move through submitted/pending/confirmed/reverted/dropped/replaced
states. Receipt polling uses the same `RPCResolver`; a missing receipt remains non-terminal
while the node knows the transaction or during a propagation grace period, then the latest
account nonce distinguishes dropped from replaced. New signature rows retain only a digest
and metadata, not plaintext messages or signatures. The app exposes a minimal activity list,
polls while its activity task is foreground-active, and supports manual refresh. A funded
Base simulator self-transfer was recorded as submitted, mined,
refreshed to confirmed with its block number, and rendered in the app; configured and
independent RPCs agreed on receipt success and 21,000 gas used.

The Gate 6 containing-app shell now follows the shipped app's SwiftUI screen hierarchy and
presentation: the lowercase welcome and import screens; centered large native balance with
an anchored details popover; top-leading account blockie menu with a copy-address action;
clock and gear toolbar actions; Settings sheet; Connected Apps list/detail/disconnect;
default Networks list and RPC detail/editor; authenticated
Private Key reveal; and Activity list/detail. The implementation keeps the old native
labels, spacing, forms, inset-grouped lists, typography, and SF Symbols while using the new
core boundaries. The home balance is intentionally the selected chain's native balance,
not the old app's invalid sum of native units across unrelated chains. Signature activity
details remain redacted rather than restoring persisted plaintext messages or signatures.

`RPCOverrideStore` atomically persists one validated endpoint per decimal chain ID in the
App Group. Both the app and Safari handler construct their resolver from this store, and
the editor displays exactly one effective endpoint per chain. The user may replace it or
restore the Stupidtech default; the editor requires HTTPS (except explicit loopback
development), reachability, and an exact `eth_chainId` match before saving.
`NativeBalanceService` uses that same resolver and
formats full-width 256-bit quantities without a BigInt dependency. Raw private-key import
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
- An in-page, non-authoritative Safari notice plus a toolbar badge as the request prompt.
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

The prototype is gate-complete through Gate 5. The complete wagmi flow is proven on both
the iOS simulator and physical iPhone: connect; personal-sign and typed-data signatures;
complete legacy transaction signing and broadcast plumbing (including live Base network
acceptance); chain-change approval and `4001` rejection; queue ordering; and disconnect
followed by a fresh connect approval. The simulator run fixed a JavaScript casing bug that
sent `eth_chainId` to passthrough and a transaction quantity parser that rejected canonical
odd-nibble JSON-RPC quantities such as `0x0`.
It preserves the identity, security, and documentation rules and its
Safari messaging/popup/Face ID, JSON/RPC proxy, key/transaction/crypto primitives,
old-format migration, canonical approval protocol, and real keychain signing all work.
The physical device remains the authoritative surface for provisioning and keychain-group
continuity.

The wagmi fixture now includes mainnet and Base. WebExtension manifest `0.1.9` invalidates
the previous Base-only worker. Simulator verification proved mainnet default → approved
Base switch → `chainChanged`/wagmi chain 8453 → App Group persistence → Safari reload and
reconnect still reporting Base. Live Uniswap verification found that the worker normalized
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
10. Ships the same provider/approval experience on macOS Safari from a macOS host app that
    shares the same package, extension JS, `WalletCore`, and approval model as the iOS app.

The iOS app is the primary target. macOS is a parallel surface, not a second wallet: one
wallet, one keychain-key identity, one approval flow, and one shared RPC resolver.

## Locked Product Decisions

- The containing app keeps the production bundle identifier
  `co.za.stephancill.stupid-wallet`.
- The Safari extension keeps the production release identifier
  `co.za.stephancill.stupid-wallet.extension`.
- Shared preferences and migration data keep the App Group
  `group.co.za.stephancill.stupid-wallet`.
- The existing team-prefixed keychain access group remains authoritative. Do not invent
  a second access group or silently move key material outside the shared group.
- The minimum deployment target remains iOS 17 unless a concrete API requirement changes
  it and this document records that decision.
- A macOS host app is in scope and shares the iOS product scope: the same SwiftPM package,
  the same `StupidWalletSafari` extension resources, and the same `WalletCore`. The macOS
  minimum target is recorded when the host target is added.
- The macOS native handler reuses the same envelope and `WalletService`; only the
  extension entry protocol (`SFSafariExtensionHandler` on macOS) and the local-
  authentication policy (Touch ID / system passcode) differ from iOS.
- macOS may use app-to-extension messaging (`SFSafariApplication.dispatchMessage`,
  unavailable on iOS) for status/hints; it is not an approval boundary.
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
- Chain additions and switches mutate global state without confirmation.
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
- Display the account address and native-token balance for the selected chain.
- Authenticated private-key backup with explicit warnings and no persistent plaintext.
- Connect, list, and disconnect authorized sites.
- EIP-1193 request transport and EIP-6963 discovery.
- `eth_requestAccounts`, `eth_accounts`, `eth_chainId`, and `net_version`.
- `personal_sign`.
- `eth_signTypedData_v4`.
- `eth_sendTransaction` with legacy and EIP-1559 serialization.
- Confirmed `wallet_addEthereumChain` and `wallet_switchEthereumChain`.
- Durable site connect/disconnect grants (legacy `connectedSites` key) with
  eth_accounts/eth_requestAccounts gating and app-side list/detail/disconnect UI.
- Generic passthrough for all methods not explicitly handled or denied.
- Stupidtech default RPC resolution and validated per-chain user overrides.
- SQLite-backed transaction and signature activity.
- Receipt polling for submitted transactions.

### Deferred Parity

Implement only after the Secure Wallet Core gates pass:

- SIWE capability handling in `wallet_connect`.
- EIP-5792 `wallet_sendCalls`, `wallet_getCallsStatus`, and capability reporting.
- EIP-7702 authorization management.
- Aggregate balances across selected chains.
- ENS names and avatars.
- Transaction simulation and fee/value previews.
- ABI and contract metadata resolution.
- ERC-7730 clear-signing previews.
- Rich activity detail and status surfaces.

Deferred functionality must not distort the core request, approval, key-storage, or RPC
boundaries in anticipation of future use.

## Recommended Project Layout

The intended SwiftPM products and targets are:

```text
StupidWallet              containing iOS SwiftUI app
StupidWalletMac           containing macOS SwiftUI app (hosts the Mac extension)
WalletCore                shared value types, storage, RPC, signing, and policy
StupidWalletSafari        native Safari Web Extension handler
CSecp256k1                vendored C cryptographic target
StupidWalletTests         package unit tests where supported
```

macOS note: `StupidWalletMac` hosts the same `StupidWalletSafari` appex resources and
links the same `WalletCore`. The handler logic is shared; only the extension entry
protocol differs (a `SFSafariExtensionHandler` on macOS). No JavaScript or HTML/CSS
diverges between platforms.

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

### Approval request

1. The background worker sends the authoritative origin, tab identity, method, params,
   and request ID to native code as a prepare operation.
2. Native code validates and canonicalizes the request, computes a payload digest, and
   persists a one-time pending record in the App Group with an expiry.
3. Browser storage retains only routing metadata needed to reconnect the pending native
   request to the requesting tab. Sensitive payloads and approval authority do not live
   in browser storage.
4. Safari updates the extension badge. An optional minimal in-page notice may tell the
   user to open the wallet extension, but it cannot approve or alter the request.
5. The user opens the toolbar popup. The popup requests the canonical, display-safe
   summary from native code by request ID.
6. On approval, the popup sends only the request ID and decision. Native code reloads
   the canonical record and verifies its origin, chain, payload digest, expiry, and
   unconsumed state.
7. Native code creates a fresh `LAContext`, requests device-owner authentication, and
   performs signing only after authentication succeeds.
8. Native code atomically consumes the pending request and returns the result.
9. The background worker routes completion to the originating tab. If the tab navigated,
   closed, changed origin, or no longer recognizes the request ID, the result is dropped
   and never delivered to a different page.

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

Each chain may have one user-selected override. Saving an override requires:

- A syntactically valid URL.
- HTTPS, except for an explicit development-only loopback HTTP path.
- A successful `eth_chainId` response.
- Exact equality between the endpoint's chain ID and the chain being configured.

All app and extension operations use the same resolver. Balance reads, transaction
preparation, fee data, simulation, ENS work, receipt polling, and generic passthrough must
not create independent RPC hierarchies.

`wallet_addEthereumChain` may record confirmed metadata, but a dapp-provided `rpcUrls`
array is a suggestion, not an automatic user override. `wallet_switchEthereumChain`
requires an authorized origin and explicit confirmation before changing wallet state.

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

- The popup renders the native canonical summary for connect, message, typed-data, chain,
  and transaction requests.
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
- Chain add/switch requires approval and cannot silently replace RPC preferences.
- Transactions are logged and receipt status updates correctly.
- App and extension use one RPC resolver and one canonical transaction implementation.
- The app builds, installs, launches, and signs through `stupid-app` on the preferred
  simulator and a physical device as applicable.

### Gate 7: Deferred Feature Parity

Each deferred feature requires its own scoped acceptance criteria and must preserve all
earlier security gates. Do not combine SIWE, EIP-5792, EIP-7702, simulation, and clear
signing into one unreviewable change.

### Gate 8: macOS Safari Surface

Exit conditions:

- `StupidWalletMac` (a macOS host app) builds and hosts the extension appex from the same
  `SafariExtension/Resources` used by iOS.
- The extension enables in macOS Safari with the toolbar popup review surface and Touch
  ID/system-passcode auth via the same `WalletService`.
- macOS uses the `SFSafariExtensionHandler` entry protocol; envelope and `WalletService`
  are identical to iOS (no web-code layer divergence).
- App-to-extension messaging (`SFSafariApplication.dispatchMessage`) delivers status/hints
  and is verified to not be an approval boundary.
- Both platforms read/write the same pending and activity state through the shared
  container/App Group.

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

1. Continue Gate 6 with physical-device proof of create, raw private-key import, BIP-39
   seed import, backup reveal/cancellation/timeout, automatic migration launch, and Safari
   signing with each newly provisioned key. The implementation and hermetic vectors are
   complete, but these device-bound flows are not yet gate-proven.
2. Physically verify `SFExtensionProfileKey` stability and cross-profile isolation on every
   supported iOS version. The product owner chose seamless authorization for pre-existing
   hostname grants; consider a later user-visible reconnect campaign before removing that
   compatibility fallback.
3. Finish parity details that do not weaken the new model: reviewed wallet deletion/logout,
   custom chain metadata, and richer activity detail. ENS/avatar resolution and aggregate
   balances remain deferred rather than being hidden inside Gate 6.
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
