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
- `StupidWalletCore`: shared value types, method classification, origin normalization,
  a canonical pending-request store, and a mock signer plus a fresh-`LAContext` local
  authentication boundary.
- `StupidWalletSafari`: a native Safari Web Extension handler (`NSExtensionRequestHandling`)
  that bridges flat JSON envelopes to `StupidWalletCore`.
- A Safari Web Extension resource set (`manifest.json`, MAIN-world `provider.js`,
  isolated-world `bridge.js`, MV3 `background.js`, and `popup.html`/`css`/`js`) packaged at
  the appex root through `stupid-app.yml` `extensions:`/`resources:`.
- An in-page, non-authoritative Safari notice plus a toolbar badge as the request prompt.
- `PrototypeDapp/index.html` for driving requests from Safari.

The prototype is not gate-complete past Gate 1; it preserves the identity, security, and
documentation rules, is signed for a physical device, and its Safari messaging/popup/
Face ID lifecycle has been proven on that device. Production work must complete the
remaining gates before release.

The existing implementation in `../ios-wallet` is a behavior and migration reference,
not a codebase to copy wholesale. It contains useful feature work, protocol handling,
and persisted formats, but its confirmation, RPC-routing, dependency, and concurrency
boundaries are intentionally being redesigned.

## Prototype Notes

The prototype is deliberately mock in several places and must not be confused with
gate-proven behavior:

- Pending requests are stored in the extension handler's Application Support directory for
  convenience; production moves them under the shared App Group container.
- `personal_sign` returns a deterministic, clearly-labeled mock signature (no secp256k1).
- The Face ID/passcode step is a real `LAContext` device-owner prompt on both device and
  simulator; the simulator shows the genuine system authentication prompt.
- The service worker keeps its pending map in memory; durable cross-suspension routing is
  deferred to Gate 5.

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
that do not require atomic multi-field updates.

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
- Site connect/disconnect grants use normalized origins.
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
- **Key format:** The exact new keychain item shape and cleanup policy remain to be
  finalized during Gate 3, subject to the locked user-presence and access-group rules.
- **BIP-39 word list:** Seed import needs a word list and PBKDF2/BIP-32 implementation.
  Decide whether to own the data/code or vendor a narrowly scoped audited component
  before Gate 3 closes.
- **Private-key backup:** Retaining the existing reveal/export feature is planned for
  Secure Wallet Core, but its copy behavior, screen-capture handling, and timeout need a
  focused design before implementation.
- **Safari profiles:** Verify availability and stability of `SFExtensionProfileKey` on
  all supported iOS versions before making profile binding mandatory.
- **Chain metadata:** Universal RPC support does not provide names, symbols, explorers,
  or icons. Keep metadata optional until a small trustworthy source is chosen.
- **Transaction preview:** A secure confirmation must display enough canonical detail
  before rich ABI decoding exists. The initial fallback is raw destination, value,
  chain, fees, and calldata hash/size rather than pretending unknown calldata is safe.

Resolve open decisions through focused proof work. Record the result here and the
investigation history in implementation notes.

## Recommended Next Work

1. Implement Gate 2 JSON-RPC behavior (the prototype's `JSONValue` and mock passthrough
   become a real node proxy) before adding wallet features.

## Reference Sources

- Existing app and migration source: `../ios-wallet`.
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
