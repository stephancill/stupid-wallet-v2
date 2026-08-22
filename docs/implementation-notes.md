# Implementation Notes

## Purpose And Rules

This file is the chronological, public-safe engineering log. Append a dated entry after
meaningful implementation, investigation, verification, release, migration, or
architectural work.

Each entry should record:

- What changed.
- Why it changed.
- Decisions made.
- Verification performed and its result.
- Known limitations, failures, and follow-up work.

Do not rewrite old entries to describe current behavior. Add a new entry that supersedes
them. Corrections to factual mistakes may edit an old entry when the correction is
clearly identified.

Do not include personal information, wallet addresses tied to a person, credentials,
private keys, seed phrases, tokens, App Store Connect identifiers, certificate contents,
device identifiers, private hostnames, sensitive signing payloads, or secret-bearing
command output. Use generic placeholders when operational context is necessary.

The current project plan and architecture live in `docs/engineering-handover.md`. Update
that document in the same work whenever an implementation-note entry changes current
scope, architecture, security behavior, acceptance status, known risks, or recommended
next work.

Use this entry template:

```markdown
## YYYY-MM-DD - Short Title

### Summary

- What changed.

### Why

- Why this approach was chosen.

### Verification

- Exact public-safe commands or checks and their outcomes.

### Follow-Up

- Remaining risks, failures, or next work.
```

## 2026-08-22 - Scoped macOS Safari Surface

### Summary

- Added macOS into the product scope: a macOS host app (`StupidWalletMac`) shares the
  SwiftPM package, the `SafariExtension/Resources` web code, and `WalletCore` with the iOS
  app; one wallet / identity / approval / RPC-resolver across platforms.
- Recorded decisions: same SwiftPM package (no separate Xcode build source); the native
  handler reuses the same envelope and `WalletService` with only the macOS
  `SFSafariExtensionHandler` entry point differing; Touch ID/system-passcode replaces Face
  ID; app-to-extension messaging (`SFSafariApplication.dispatchMessage`) is in scope for
  status/hints only (never approval).
- Added Gate 8 (macOS Safari surface) and a corresponding step in Recommended Next Work.

### Why

- The existing extension JS/approval model is shared; only the containing app target and the
  macOS extension entry protocol differ, so scoping is cheap and keeps one source of truth.

### Verification

- Documentation-only scoping decision; no build or code change was made in this entry.

### Follow-Up

- Implement Gate 8 as a host target + `SFSafariExtensionHandler` and set the macOS minimum
  target when the target is added.

## 2026-08-22 - Removed Native Mock Signing Flow

### Summary

- Deleted the SwiftUI `personal_sign` prototype mock (`Sources/StupidWallet/Prototype/`) that
  was used to explore the native review surface before the Safari extension flow was proven.
- The app's root view reverted to a minimal placeholder; the real signature and Face ID now
  happen only through the Safari extension (`popup -> background -> native -> Face ID`).

### Why

- The Safari Web Extension flow became the proven primary signing path, so the in-app mock
  would be redundant and could be mistaken for a real surface. Keep one authoritative flow.

### Verification

- `stupid-app build` succeeded after clearing the stale build scratch that still referenced
  the deleted prototype sources.
- `stupid-app run --simulator` launched the app showing the placeholder:
  "Stupid Wallet / Signing happens in the Safari extension when you use a dapp."

## 2026-08-22 - Gate 3 Complete: Keychain User-Presence Proved On-Device

### Summary

- Added an on-device keychain self-test to the app (`ContentView` → "Run keychain
  proof") that generates a random key, saves it under a `.userPresence` + `ThisDeviceOnly`
  access control, reloads it, re-derives the address, and signs + recovers a digest.
- Deployed over the network to the physical iPhone and confirmed: the system Face
  ID/passcode prompt appeared during the reload, and the log returned PASS (address,
  save ok, load ok, address matches, sign+recover verify OK).

### Why

- Closes the last Gate 3 exit condition: new-format key storage must require the device
  owner on a physical device, with no preflight/plaintext persistence.

### Verification

- `stupid-app run --network` installed and verified the app on the device.
- Manual on-device run: Face ID prompt presented; self-test PASS.

### Follow-Up

- Gate 4 (upgrade migration) is the next gate. A shared-access-group read/write
  round-trip between the app and the Safari extension remains a runtime integration
  check to fold into the real signing path (Gate 5), since the self-test used the app's
  default group.

## 2026-08-22 - Gate 3 Cross-Implementation Transaction Vectors

### Summary

- Verified legacy and EIP-1559 transaction signing preimages against independent
  implementations.
- Legacy: the canonical signing preimage for the EIP-155 example tx matched a
  cross-implementation vector byte-for-byte, and its hash `daf5a779…` agreed across viem
  and `cast keccak`.
- EIP-1559: produced the canonical 12-field preimage (empty access list `c0`); hashing it
  with `cast keccak` independently reproduces the pinned digest. (viem's `toRlp` renders an
  empty array as `80` rather than `c0`, so it is not a reliable EIP-1559 access-list
  oracle; the canonical bytes were cross-checked via `cast keccak` instead.)
- Fixed a real encoding bug found by the vectors: integer zero must be RLP-encoded as an
  empty byte string (`0x80`), not a single `0x00` byte, in quantity fields such as nonce.

### Why

- Gate 3 requires every serialization primitive to pass cross-implementation vectors.

### Verification

- `swift test`: 43 tests / 11 suites pass. Legacy payload bytes and digest and the
  EIP-1559 payload bytes/digest are pinned against `cast keccak`; the legacy vector also
  matches viem exactly.

### Follow-Up

- Gate 3's only outstanding item is physical: prove `KeychainKeyStore` user-presence key
  release + shared-access-group continuity for app and extension on a device.

## 2026-08-22 - Gate 3 Primitives: Vendored secp256k1 + Ethereum Core

### Summary

- Vendored `libsecp256k1` at tag `v0.5.1` (commit `642c885b`) into `third-party/` and
  added a `CSecp256k1` SwiftPM C target. SwiftPM cannot run the upstream autotools
  configure, so the three needed translation units are `#include`d through thin shims
  (`shim_secp256k1.c`, `shim_precomputed_ecmult*.c`); `ENABLE_MODULE_RECOVERY` and
  `ENABLE_MODULE_ECDH` are set. Public headers are copied to the target's `include/`.
  Provenance and adaptation recorded in `THIRD_PARTY_NOTICES.md`.
- Added project-owned primitives in `StupidWalletCore`:
  - `Keccak` (Keccak-256; fixed a rho/pi destination-index bug).
  - RLP encoder (`RLP`), `Hex`, EIP-55 checksum, `EthereumKeypair`/`EthereumSigner`
    (recoverable sign + address recovery), `MessageHash` (EIP-191, EIP-712 struct hash),
    and legacy + EIP-1559 transaction serialization (`Transaction`).
  - `KeychainKeyStore`: new-format keys in the shared keychain with
    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + a `.userPresence` access control.

### Why

- Gate 3 is the key/Ethereum core required before any real signing can be trusted.

### Verification

- `swift test` (41 tests / 11 suites pass) including independent vectors:
  - Keccak-256 of `""` and `"abc"` match `cast keccak`.
  - secp256k1 private key 1 derives the generator point and the known address
    `0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf`.
  - EIP-55 known vector, EIP-191 empty-digest matched via `cast keccak`.
  - RLP spec vectors; zero/invalid keys rejected; sign->recover round-trips the address.
  - Legacy and EIP-1559 payloads encode and sign->recover the sender.
- `stupid-app build` produces `StupidWallet.app` including the vendored C target.

### Follow-Up

- Gate 3 remainder is device-bound: pin cross-implementation legacy/EIP-1559 transaction
  hash vectors, then prove `KeychainKeyStore` user-presence key release + the shared
  keychain access group on a physical device. The mock signer in `WalletService` stays
  until Gate 5 wires the real `KeychainKeyStore` + `EthereumSigner` into the approval
  path.

## 2026-08-22 - Live RPC Passthrough Sweep Verified

### Summary

- Wired the Gate 2 native passthrough into the Safari extension. Previously the
  background worker returned `-32601` for every generic `eth_*`/`net_*`/`web3_*` method;
  it now dispatches unhandled methods to a new native `passthrough` action, which
  `WalletService` routes through the single `RPCResolver`/`RPCClient` to
  `https://evm.stupidtech.net/v1/{chainId}`. Structured node results and errors return
  untouched.
- Extended `PrototypeDapp` with per-call buttons plus a `Sweep all RPCs` button that
  fires a batch of read methods and prints the composite JSON.

### Why

- Demonstrate that the JSON-RPC core from Gate 2 actually passes arbitrary node methods
  through in the live extension rather than failing as unsupported.

### Verification

- On the simulator the `Sweep all RPCs` button returned live data through the extension:
  `eth_chainId → 0x1`, `net_version → 1`, `eth_blockNumber → 0x189d444`, `eth_gasPrice →
  0x8733869`, `eth_getBalance → 0x0`, `eth_getTransactionCount → 0x0`, and a full
  `eth_getBlockByNumber` block object (parent beacon block root, hashes, validator
  indexes, withdrawals) — all JSON-RPC pass-through from `evm.stupidtech.net`.

### Follow-Up / Notes

- iOS Safari caches extension service workers across app reinstall and even simulator
  uninstall, so JS changes sometimes need an extension re-toggle or a clean simulator to
  pick up. Recording this so it is not mistaken for a packaging regression.
- `personal_sign` still uses the mock signer; Gate 3 replaces it with real secp256k1 and
  shared-keychain storage.

## 2026-08-22 - Gate 2 Simulator Smoke Test

### Summary

- Rebuilt and reinstalled the app on the preferred simulator after Gate 2 and drove the
  prototype dapp end to end: provider + EIP-6963 injection, `eth_requestAccounts`
  returning the native account, `personal_sign` creating a native pending record, the
  Safari toolbar popup rendering the native canonical card (Stupid Wallet / Ethereum /
  Sign message / origin localhost:8080 / account / `personal_sign • 0x1`), **Approve &
  Face** followed by the authentic `LAContext` device-owner prompt, and the signature
  returning to the dapp.

### Why

- Confirm the Gate 2 refactor (added `RPCClient`/`RPCResolver`/`MethodPolicy` and test
  target + platform) did not regress the Safari request, popup, or authentication path.

### Verification

- OCR of simulator screenshots confirmed injection, native account connect, the
  canonical popup card, the Face ID prompt, and a resolved `personal_sign` signature in
  the dapp (`Result` + log `[personal_sign] 0x…`).
- Provider/EIP-6963 `isStupidWallet=true`; full loop closed on-device.

### Follow-Up

- Gate 3 next (vendored `libsecp256k1` + Ethereum primitives + shared-keychain
  user-presence storage).

## 2026-08-22 - Gate 2 Complete: JSON And RPC Core

### Summary

- Added a unit-test target (`StupidWalletCoreTests`) and set a macOS 14 test platform so
  the shared core compiles on the host for hermetic tests.
- Fixed a real bug in `MethodPolicy.classify`: it lowercased the input but compared
  against mixed-case literals, so `eth_requestAccounts`, `eth_chainId`, and every
  camelCase signing/sending/chain method silently fell through to passthrough. Literals
  are now normalized to lowercase; `eth_signTypedData_v3` is denied, not signable.
- Added `RPCClient` (dependency-free JSON-RPC 2.0): preserves arbitrary results, `null`,
  and the full node error object; distinct `transport` / `invalidResponse` / `httpStatus`
  errors.
- Added `RPCResolver` (`https://evm.stupidtech.net/v1/{chainId}` default + per-chain
  overrides) and `RPCOverrideValidator` (rejects malformed, insecure non-loopback
  non-HTTPS, unreachable, and wrong-chain endpoints; compares `eth_chainId` decimal/hex
  numerically).
- `WalletService.passthrough` now tunnels unhandled methods through the one resolver.

### Why

- Gate 2 is the JSON-RPC and classification core required before wallet features. The
  resolver keeps reads, sends, polling, and passthrough on one hierarchy.

### Verification

- `swift test`: 24 tests across 5 suites pass (JSON round-tripping incl. nested null,
  method classification, origin normalization, default routing for chains 1/10/137/8453/
  42161, override validation, and result/error/transport preservation via a stubbed
  URLProtocol). The stub-based client suite is serialized to avoid shared-mutable
  cross-test races under Swift Testing.
- `swift format --in-place --recursive Sources Tests` succeeded.
- `stupid-app build` still produces `StupidWallet.app` (arm64 ios min 17.0 sdk 26.1).

### Follow-Up

- Gate 3: vendored `libsecp256k1` target, Ethereum primitives with independent vectors,
  and shared-keychain user-presence storage. The override `overrides` dictionary is
  in-memory; persist validated overrides under the App Group during the Secure Wallet
  Core persistence work.

## 2026-08-22 - Gate 1 Passed on Physical Device

### Summary

- Proved the Safari Web Extension stack end to end on a physical iPhone: extension
  enabled in Safari, the prototype dapp on the LAN received the injected provider,
  MAIN-world EIP-6963 discovery rendered `Stupid Wallet ·
  co.za.stephancill.stupid-wallet · isStupidWallet=true`, the toolbar popup opened under
  user control and showed the native request card, personal_sign signed, and the iPhone
  system Face ID prompt appeared while Safari remained foregrounded.
- This closes Gate 1. The logged risk of the FAce-lifecycle with real Safari was also
  resolved: the LAContext device-owner prompt presents over Safari on-device.

### Why

- Gate 1 is the spike gate that proves the Safari popup + native auth interaction under
  real operating-system lifecycle constraints before wallet signing is implemented.

### Verification

- Manual on-device walk-through of the prototype dapp: enabled the extension, loaded
  `http://<mac-lan>/index.html`, requested accounts (native card), and approved a
  `personal_sign` with the Face ID system prompt; the dapp resolved to a signature.
- The app and nested extension each signed `co.za.stephancill.stupid-wallet` and
  `...extension`.

### Follow-Up

- Begin Gate 2 (JSON-RPC core). This follows the observed on-device behavior; observed
  Safari/LA behavior is now recorded in the handover, so the remaining risk is now in
  JSON/vector and RPC-proxy coverage.

## 2026-08-22 - Device Launch Confirmed

### Summary

- The installed rebuild launched on the physical iPhone (icon tap), closing the
  "launch over tunnel" caveat recorded earlier the same day. The device now runs the
  `Stupid Wallet` foreground app with the Safari extension appex installed and signed.

### Why

- The physical device is the only credible surface for the Gate 1 popup + Face ID proof.

### Verification

- Confirmed manually on-device that the app opens.

### Follow-Up

- Continue Gate 1: enable the Safari extension in device Settings, drive
  `PrototypeDapp`, and verify EIP-6963 discovery, the toolbar popup, `LAContext`
  prompt, and signature completion while Safari stays foregrounded.

## 2026-08-22 - Device Signing Unblocked (Entitlement Fix)

### Summary

- After Gate 0, attempted to deploy the rebuild to a physical iPhone over the network.
  `stupid-app` device signing failed with `Entitlement 'keychain-access-groups value
  mismatch'`: the source uses `$(AppIdentifierPrefix)<bundle>.` keychain groups, but the
  `stupid-app` `EntitlementDeriver` passed that Xcode token through literally and did a
  rigid array-equality reconciliation against the development profile's `TEAM.*` wildcard.
- Fixed in the CLI: `EntitlementDeriver` now expands `$(AppIdentifierPrefix)` to the
  concrete `<teamID>.` prefix and wildcard-matches `TEAM.*` authorizations (tree
  `802631f` in `../stupid-ios-dev`). On the Mac host I rebuilt and reinstalled the CLI
  binary, and my storage then contains development profiles targeting the physical
  device's UDID.
- The app then **packaged, installed, and was verified** on the iPhone over the network
  tunnel. The post-install auto-launch could not run because the remote device does not
  offer the CoreDevice launch service (`com.apple.coredevice.appservice`) over the
  network tunnel.

### Why

- This was the Gate 1 login dev risk that blocking the physical-device debut explained in
  the handover's Recommended Next Work and the phys-device test strategy.

### Verification

- `stupid-app signing setup --kind development` registered production app and extension
  bundle IDs + App Group capability and minted development profiles for the target device
  UDID.
- `stupid-app run --network` reported `Installed and verified the application over the
  network.` The IPA packaged with both nested appex and app signed.
- Launch over the tunnel failed with a CoreDevice launch-service error; trusting the
  app's first manual open on the device or a USB launch is still required.

### Follow-Up

- Launch the installed app on the device (tap the icon or attach over USB) to complete the
  Gate 1 physical proof of the toolbar popup + Face ID flow.
- When the DeviceType is audited, prefer a USB run for the documented Gate-1 launch step.

## 2026-08-22 - Gate 0 Complete: Production Identities Restored

### Summary

- Restored production identities, closing the Gate 0 exit conditions in
  `docs/engineering-handover.md`:
  - App bundle ID: `net.stupidtech.stupid-wallet-2` -> `co.za.stephancill.stupid-wallet`
    in `Info.plist` and `stupid-app.yml`.
  - Extension bundle ID: `net.stupidtech.stupid-wallet-2.extension` ->
    `co.za.stephancill.stupid-wallet.extension` in `stupid-app.yml`.
  - `App.entitlements` gained the production App Group
    (`group.co.za.stephancill.stupid-wallet`) and the two team-prefixed keychain access
    groups (`co.za.stephancill.stupid-wallet` and `.safari`), matching `../ios-wallet`.
  - `SafariExtension.entitlements` gained the shared keychain access group so the
    extension and app share key material.
- Updated the handover: removed the temporary-bundle-id status, added a Gate-0-complete
  status line, and renumbered Recommended Next Work (Gate 1 is now the next step).
- Committed the initial repository (git) with the scaffold.

### Why

- Identity continuity is a release blocker. The rebuild must launch under the same
  production app, extension, App Group, and keychain access groups so an installed
  wallet can migrate in place without re-import.

### Verification

- `stupid-app doctor`: 0 failures, 0 warnings; project config accepted for
  `co.za.stephancill.stupid-wallet`.
- `stupid-app build` produced `StupidWallet.app` (Mach-O arm64 ios min 17.0 sdk 26.1) with
  `PlugIns/StupidWalletSafari.appex` and the full extension resource set at the appex root.
- `stupid-app run --simulator` installed and launched `co.za.stephancill.stupid-wallet` on
  the preferred simulator.

### Follow-Up

- Device/release signing reconciles keychain-access-groups via `EntitlementDeriver`, which
  passes `$(AppIdentifierPrefix)` through literally (Xcode expands it, `stupid-app` does
  not). Confirm the physical-device run (Gate 1) reconciles against the provisioning
  profile, or substitute the concrete team prefix for device/release signing. Simulator
  `build`/`run` use ad-hoc signing, so this does not affect Gate 0.
- Proceed to Gate 1: prove the real Safari popup + Face ID lifecycle on a physical
  device.

## 2026-08-22 - Rebuild Planning Baseline

### Summary

- Created `docs/engineering-handover.md` as the maintained source of truth for the
  Stupid Wallet rebuild.
- Recorded the existing app's feature inventory and the architectural weaknesses the
  rebuild must not reproduce.
- Locked the primary signing flow to a Safari toolbar popup followed by native Face ID
  or device-passcode authentication while Safari remains foregrounded.
- Defined explicit wallet-method handling, intentional denial of unsafe signing methods,
  and generic passthrough of every other JSON-RPC method.
- Defined universal stupidtech RPC defaults with validated per-chain user overrides.
- Defined a minimal dependency direction using Apple frameworks plus a pinned, vendored
  secp256k1 implementation.
- Defined an in-place old-key migration requirement because the rebuild preserves the
  existing production app identity.
- Added ordered implementation and verification gates rather than timeline estimates.

### Why

- The repository was only a generated SwiftUI scaffold and had no durable record of the
  agreed architecture, security boundaries, feature scope, migration requirements, or
  acceptance criteria.
- The handover and implementation log follow the documentation model used by the
  `stupid-app` CLI project so future work begins with current context and leaves an
  auditable public-safe history.

### Verification

- Compared the documentation responsibilities and file roles with the maintained
  `stupid-app` CLI project.
- Cross-checked the old wallet's app/extension structure, request flow, production
  identity pattern, key-storage format, method routing, network configuration, and
  dependency surface.
- `stupid-app doctor` completed with zero failures and zero warnings; it recognized the
  current `StupidWallet` project configuration.
- `stupid-app build` succeeded and produced an ARM64 iOS application with minimum iOS
  17.0 and SDK 26.1 metadata.
- No application behavior was modified in this documentation-only entry.

### Follow-Up

- Complete Gate 0 by restoring production configuration and defining app, shared core,
  Safari extension, and cryptographic target boundaries.
- Prove the Safari toolbar popup, native messaging, and LocalAuthentication lifecycle on
  a physical device before implementing wallet signing.

## 2026-08-22 - Full-Stack Signing Confirmation Prototype

### Summary

- Added the four-owner package layout behind the existing `StupidWallet` app: a shared
  `StupidWalletCore` target and a native `StupidWalletSafari` Safari Web Extension handler.
- Added the Safari WebExtension resources (compiled into the appex root, not nested):
  `manifest.json`, MAIN-world `provider.js` (EIP-1193 + EIP-6963), isolated-world
  `bridge.js`, MV3 `background.js`, and the toolbar `popup.html/css/js`.
- Wired the extension into `stupid-app.yml` with the Safari Info.plist, entitlements, and
  appex-root `resources:`, matching Safari's flat appex bundle layout.
- Kept the previous interactive SwiftUI `personal_sign` confirmation surface in the app as
  a native review path: request -> review (origin, chain, account, message) -> Face
  ID/passcode mock -> signed/rejected.
- Added `PrototypeDapp/index.html` as a local test dapp and a serve command.

### Why

- The milestone is to feel the confirmation flow end to end, so it must include the real
  Safari Web Extension plumbing rather than only a SwiftUI sketch. The extension is the
  Safari-owned review surface; native code must remain the approval authority.
- Value types and boundaries follow the handover: policy, JSON round-tripping, pending
  request state, and authentication live in `StupidWalletCore`; the handler only
  orchestrates native messages; JavaScript never sees keys.

### Decisions

- `JSONValue` is a `Codable, Sendable, Equatable` enum with `Double` numbers; JSON-RPC
  quantities pass as hex strings so integer precision is preserved without a BigInt.
- `PendingWalletRequestStore` persists to the extension process Application Support
  directory for the prototype because prepare/summary/approve run in the same handler
  process. Production should move it under the shared App Group container.
- The registered account is a fixed public address; `personal_sign` returns a deterministic,
  clearly-mock signature. The Face ID/passcode step is a real `LAContext` device-owner
  prompt on both device and simulator; the simulator shows the genuine system prompt. It was
  later confirmed on the simulator as the "Enter iPhone Passcode" system sheet.

### Verification

- `swift format --in-place --recursive Sources` succeeded.
- `stupid-app build` succeeded and packaged `PlugIns/StupidWallet.appex` with
  `manifest.json`, the four JavaScript files, `popup.*`, icons, and the extension
  executable all at the appex root.
- `stupid-app run --simulator` built, installed, and launched the app on the preferred
  simulator.
- **iOS Simulator drive:** after enabling the extension, the test dapp at
  `http://localhost:8080/index.html` received the injection: the OCR/accessibility and
  page log showed `Provider detected`, EIP-6963 announce
  `Stupid Wallet · co.za.stephancill.stupid-wallet · isStupidWallet=true`, and the
  `eth_requestAccounts` promise resolved to the native account `0xD8d6F226E874..c1d0`,
  which proves the background->native messaging bridge round-trips. The toolbar popup
  opens through the Safari page menu and renders the `Stupid Wallet`/`Ethereum` header.
  On this simulator the popup's own content round-trip (`popup -> background getPending`)
  did not complete, so approval rendering is not proven on iOS simulator; this requires a
  physical iPhone (matches the existing Gate 1 gate).
- `node --check` passed for all four JavaScript files; `manifest.json` parsed as valid JSON.
- The installed app container contains the nested signed appex with the expected resource set.

### Limitations And Follow-Up

- **Correction (this session):** `browser.runtime.sendNativeMessage` from the background
  DOES work on the iOS simulator — it returned the native account to the test page. The
  earlier "device only" note was overstated. The injected provider, EIP-6963, the
  background->native round-trip, and a real `LAContext` device-owner prompt (the "Enter
  iPhone Passcode" system sheet) all demonstrated on the simulator.
- The popup's request list now reads the **native pending store** (`WalletService.list` /
  `list` native action) so review cards survive MV3 service-worker suspension instead of
  depending on the in-memory background `Map`. Completion routing back to the requesting
  tab still depends on the worker's live routing state (Gate 5).
- The final "tap toolbar popup Approve -> Face ID -> signature back to the dapp" button
  chain was not completed on the simulator because automated coordinate taps of the iOS
  Safari popup are flaky. This is the physical-device gate; the native `list` change
  removes the pending-visibility flakiness that blocked the popup rendering.
- The mock signer is not a real secp256k1 implementation; Gate 3 adds the pinned
  vendored libsecp256k1 and real keychain-backed signing.
- **Completion routing is now poll-based.** The bridge no longer depends on a live
  worker sendResponse; for approval methods the background returns a `pending` id and the
  bridge polls native status (`background -> native get`) until the popup's native approve
  lands a result in the store. This makes the dapp promise close even across service-worker
  suspension.
- **Popup reaches native through the background worker.** Direct popup->native messaging is
  unreliable on iOS; the popup now forwards `list`/`approve`/`reject` via
  `browser.runtime.sendMessage` and the worker performs the (proven) native calls. This
  fixed the "No pending signatures" symptom: the review card is read from the durable
  store.
- **Verified end to end on the iOS simulator** (no device): `eth_requestAccounts` ->
  `personal_sign` -> Safari toolbar popup showed the native "Sign message" card ->
  "Approve & Face ID" -> real system Face ID prompt -> "Matching Face" -> the dapp's
  `Result` resolved to a `0x…` signature, and the pending record was atomically consumed
  with that result.
- **Primary request prompt:** added an in-page, non-authoritative notice (top-center pill,
  injected from the isolated bridge, `pointer-events:none`) shown while a signature is
  pending and auto-removed on resolution, plus the toolbar badge count (set/unset in the
  worker). Both are status/instruction surfaces only and can never approve or alter a
  request. Verified on the simulator: the pill appears on pending and disappears once the
  Face-matched signature resolves.
- Pending routing stays in-memory in the service worker plus the native store; durable
  cross-suspension routing remains for Gate 5.
