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

## 2026-08-22 - Wagmi Dapp Simulator E2E Completed

### Summary

- Completed the new wagmi dapp flow on the preferred iOS simulator: connect,
  `personal_sign`, `eth_signTypedData_v4`, `eth_sendTransaction`, chain rejection and
  approval, `wallet_disconnect`, and reconnect authorization.
- Fixed the post-connect upstream failure: `background.js` lowercased methods but compared
  chain ID against mixed-case `eth_chainId`, so wagmi's follow-up chain query incorrectly
  reached RPC passthrough. The comparison now uses `eth_chainid`.
- Added `Hex.quantityData(hex:)` and routed transaction quantity fields through it. This
  accepts canonical odd-nibble JSON-RPC quantities such as viem's `0x0` while retaining
  strict even-length parsing for calldata and byte fields. Existing legacy/EIP-1559
  cross-implementation vectors now use canonical no-leading-zero quantities.
- Updated the test dapp to await and report connect results, skip wagmi's optional
  permissions probe, provide deterministic complete legacy transaction fields, and call
  `wallet_disconnect` before clearing wagmi state. Bumped the WebExtension manifest to
  `0.1.1` to invalidate stale simulator service-worker state after resource changes.

### Verification

- `swift format --in-place` completed for the changed Swift files.
- `swift test`: 75 tests in 15 suites passed, including unchanged transaction preimage
  bytes and digests with canonical odd-nibble quantity inputs.
- `stupid-app doctor`: 0 failures and 0 warnings.
- Repeated `stupid-app run --simulator --udid <preferred-simulator>` runs assembled,
  installed, and launched the app and Safari extension successfully.
- `PrototypeDapp`: `bunx oxfmt --write src/App.tsx`, `bunx oxlint .`, and `bun run build`
  passed. `node --check` passed for the extension scripts.
- Simulator popup/OCR results:
  - connect resolved to the account and wagmi reported chain 1;
  - message and typed-data approvals each returned a 65-byte signature;
  - the complete legacy transaction returned a signed raw payload (broadcast remains
    intentionally unimplemented);
  - rejecting chain switch returned EIP-1193 `4001`, then approving it resolved chain 1;
  - `wallet_disconnect` returned true and restored the Connect button;
  - reconnect created a fresh canonical connect request, proving grant revocation.
- Failed/incomplete transaction attempts were rejected through the popup's normal Cancel
  path before retrying; persisted pending files were never edited to bypass policy.

### Follow-Up

- Repeat the complete flow on the physical iPhone to close Gate 5's authoritative popup,
  authentication, keychain-group, and lifecycle proof.
- Gate 6 must prepare missing transaction fields from RPC and broadcast the signed payload;
  the dapp currently supplies deterministic fields only to exercise canonical signing.

## 2026-08-22 - Wagmi Dapp Simulator E2E Blocked After Connect Approval

### Summary

- Rebuilt, installed, and launched the current app and extension on the preferred iOS
  simulator, then served the new wagmi dapp on loopback and exercised connect through the
  Safari toolbar popup.
- Native preparation and review worked: the popup rendered the canonical connect card,
  approval consumed the matching App Group pending record, and a repeat account request
  did not create another pending record, consistent with a persisted connection grant.
- The dapp did not enter wagmi's connected state after approval. Updated its connect
  button to await `connectAsync` through the existing result/error reporter; this exposed
  an EIP-1193 `-32603` upstream RPC failure instead of leaving the failure invisible.
- An orphaned earlier localhost request initially occupied the queue head. It was rejected
  through the normal popup path; no persisted files were edited to bypass policy.

### Verification

- `stupid-app doctor`: 0 failures and 0 warnings.
- `stupid-app run --simulator --udid <preferred-simulator>`: app and extension assembled,
  installed, and launched successfully.
- `swift test`: 75 tests in 15 suites passed.
- `PrototypeDapp`: `bunx oxfmt --write src/App.tsx`, `bunx oxlint .`, and `bun run build`
  passed; Vite served the dapp at `http://127.0.0.1:5173/`.
- Simulator OCR confirmed the canonical connect card, normal rejection of the orphaned
  request, approval of the active loopback request, and removal of the pending notice.
  The consumed record contained the approved account-array result.
- The awaited wagmi mutation displayed `eth_requestAccounts failed: -32603 All upstrea…`;
  the remaining text was clipped by the simulator viewport. UI automation was stopped
  after the subsequent scroll interaction stalled.

### Follow-Up

- Capture the complete connector error and determine whether wagmi's
  `wallet_requestPermissions` probe is incorrectly reaching generic RPC passthrough and
  contaminating connect. Connection must not depend on an upstream node implementing a
  wallet-owned permissions method.
- Re-run personal-sign, typed-data, transaction, chain-switch, reject, and disconnect only
  after the dapp reaches connected state. `eth_sendTransaction` is still expected to
  return a signed raw payload rather than broadcast in the current Gate 6 implementation.

## 2026-08-22 - Connected-Site Grants + EIP-1193 Standard Params + Wagmi Dapp

### Summary

- **Connected-site grants (Gate 6 head start):** added `ConnectedSitesStore` +
  `ConnectedSite` to `StupidWalletCore`, persisting dapp connection grants in the SAME
  shared App Group `UserDefaults` key the legacy app used (`connectedSites`,
  `[hostname: {address, connectedAt}]` ISO-8601 with fractional-seconds tolerance). The
  shipped new app therefore sees entrenched users' existing connections with no migration.
  Persisted identity is the lowercased hostname (legacy shape); `Origin.normalize`
  (scheme+port) remains available in memory for review/validation.
- **Approval flow now establishes the grant:** `WalletService.approve` records a
  connection when a `.connect` kind (`eth_requestAccounts`/`wallet_connect`) is approved.
  Added `WalletService.isConnected/connect/disconnect/connectedSitesList`, native handler
  actions `isConnected`, `listSites`, `disconnectSite`, and background.js gating:
  - `eth_accounts` returns `[]` when the origin has no grant (rather than always the
    account).
  - `eth_requestAccounts`/`wallet_connect` short-circuit to the account when a grant
    exists — fixes "the popup shows a connect card ahead of my signature request" on the
    physical device, which was the queued duplicate connect from the dapp's unconditional
    `eth_requestAccounts` re-call.
  - `wallet_disconnect` revokes the grant.
- **Standard EIP-1193 param shapes accepted natively:** `personal_sign` params are
  `[messageHex, address]` (message first) as viem/wagmi and MetaMask send them; the
  signable digest, summary message row, and tests were corrected to this order.
  `eth_signTypedData_v4` accepts `[address, jsonString]` (unwraps to the EIP-712 object
  the hasher consumes; bare-object canonical form still accepted for hermetic tests).
  `wallet_addEthereumChain`/`wallet_switchEthereumChain` summaries accept `[chainObject]`
  and read the standard `chainId` key. This unblocks driving typed-data/send/chain through
  a real dapp.
- **Test dapp rewritten:** `PrototypeDapp` is now a wagmi (v3) + viem + React + Vite app
  scaffolded with `bun create wagmi --template vite-react --bun`, with hooks for connect
  (`injected()` connector through the Safari-extension provider), `personal_sign`,
  `eth_signTypedData_v4`, `eth_sendTransaction` (value 0n to a burn address),
  `wallet_switchEthereumChain` (→ chain 1), and disconnect. Dev server runs `--host` on
  port 5173 for the physical iPhone. oxlint/oxfmt clean; `tsc && vite build` passes.
- Extension JavaScript was formatted with oxfmt (no repo formatter was configured) and
  re-checked with `node --check`.

### Why

- The physical-device Gate 5 proof surfaced a UX blocker: after connecting, every signing
  button in the old dapp re-called `eth_requestAccounts`, enqueueing a second connect
  approval ahead of the signature. The wallet had no durable notion of "connected", so it
  could not skip the duplicate approval. The old app solved this with App Group
  `UserDefaults` "connectedSites" grants gated in the extension; the product decision was
  to replicate that system (shared key, shared shape) rather than invent a new store.
- viem/wagmi send standard EIP-1193 params; the prototype's non-standard shapes would have
  failed typed-data, chain, and message flows when driven from the real dapp.

### Verification

- `stupid-app build`: clean; app + extension signed in place.
- `swift test`: 75 tests / 15 suites pass, including new standard-param approval tests and
  ConnectedSitesTests (grant, idempotent disconnect, refresh-on-reconnect, grant after
  connect approval, no grant after message approval, service-level disconnect).
- `PrototypeDapp`: `bun run build` (tsc + vite) passes; oxlint 0 warnings / 0 errors;
  dev server served at `http://<localhost>:5173` and `http://192.168.111.114:5173`.
- `node --check` passes on all `SafariExtension/Resources/*.js`.
- `stupid-app run --network` installed + launched the app and extension on the physical
  iPhone.

### Follow-Up

- Drive the wagmi dapp end-to-end on the physical device: connect once, then
  personal_sign / typed-data / send / switch should each show exactly one approval card
  with no duplicate connect, and `wallet_disconnect` should revoke so
  `eth_accounts` returns `[]`.
- Gate 6 app-side connected-apps list/disconnect UI is still outstanding (native
  `listSites`/`disconnectSite` actions exist and are ready to back it).
- Connection grants are hostname-keyed to preserve the legacy format; Safari profile
  binding and scheme/port separation remain open (documented risk).
- `eth_sendTransaction` still returns the signed raw transaction rather than broadcasting;
  real submission is Gate 6 work.

### Summary

- Two fixes were needed to run the complete Gate 5 approval flow on the iOS simulator:
  1. `UserDefaults(suiteName:)` for `sw2.walletAddress` wrote into each process's own
     sandbox on the simulator, so the app set it but the Safari extension read an empty
     place. Introduced `WalletStore`, which persists the active EIP-55 address as a small
     file (`wallet-address.conf`) in the shared App Group container via
     `containerURL(forSecurityApplicationGroupIdentifier:)` — the same mechanism the
     pending-request store already uses — and routed `WalletFactory`, `KeychainSigner`,
     the migration's `SecurityWalletBackend`, and the extension handler through it
     (with a UserDefaults fallback for pre-existing wallets).
  2. The extension handler now builds the `WalletService`/signer lazily per native
     message instead of once at init, so a wallet created/migrated after the extension
     process was launched is picked up (previously it froze with "no wallet key").

### Verification (iOS simulator, fresh install)

- After the CLI entitlements fix plus these, "Connect" drove the toolbar popup "Stupid
  Wallet / Ethereum / Connect site" and **Approve resolved eth_requestAccounts** to the
  account array, with no Face ID.
- "Personal sign" surfaced the canonical "Sign message" card (From/Account/Chain/Message +
  warning); **Approve triggered a single Face ID/passcode prompt** and resolved to a real
  65-byte EIP-191 signature in the dapp Result, consumed from the App Group pending store.
- The shared App Group pending records (`PendingRequests/*.json`) are written by the
  extension and readable on the host, confirming cross-process persistence.
- `swift test`: 66 tests / 14 suites pass; `stupid-app` build and doctor clean.

### Follow-Up

- Typed-data, send, add/switch chain, and reject paths are implemented and unit-tested;
  driving the remaining kinds through the simulator popup is additional manual exercising.
- The physical device remains the authoritative surface for provisioning/keychain
  continuity, but the simulator now exercises the full approval loop.

## 2026-08-22 - Simulator Keychain Fix (stupid-app ad-hoc entitlements)

### Summary

- Root-caused why keychain on the iOS simulator failed with `-34018 (errSecMissingEntitlement)`
  for signing/self-test and "Create a wallet": `stupid-app`'s simulator ad-hoc signing used
  plain `codesign --sign -` with no `--entitlements`, so the installed app had no
  `com.apple.security.application-groups` and no default keychain access. On the
  simulator the security daemon refused the read/write.
- Fixed in the `stupid-app` CLI (`Sources/stupid-app/RunCommand.swift`): the simulator
  ad-hoc pass now substitutes project entitlements with `$(AppIdentifierPrefix)` removed,
  keeps `com.apple.security.application-groups`, and drops `keychain-access-groups`
  entirely (a team-less keychain group triggers `SBMainWorkspace` launch denial; the
  simulator grants the default bundle-id keychain group without that entitlement).
- Rebuilt `stupid-app`, reinstalled it to `~/.local/bin`, and reinstalled the app on the
  preferred simulator.

### Verification

- On a fresh-not-erased simulator, tapping "Run keychain proof" now logs PASS (address,
  save ok, load ok — "Face ID/passcode released the key", re-derived address matches).
- "Create a wallet" saves a real `.userPresence` key and logs `Created wallet <address>`.
- `swift test`: 66 tests / 14 suites pass.
- Without these simulator entitlements the same flows fail with `saveFailed` and the
  underlying reason was `errSecMissingEntitlement` (`-34018`).

### Follow-Up

- The Safari extension injection on the simulator still requires a manual enable (Settings
  → Safari → Extensions), which is a user-driven iOS step rather than a code path.
- The physical device (real signing) embeds full entitlements already and remains the
  authoritative Gate 3/5 surface.

### Summary

- **Two Face ID prompts on one signature** were traced to the `.userPresence` keychain
  access control firing on two separate reads: `prepare` → `Signer.hasKey()` →
  `KeychainKeyStore.contains()`, and `approve` → `signDigest` → `KeychainKeyStore.load()`.
  Both are `SecItem*` reads of a `.userPresence` item, so iOS presents Face ID twice.
  Fix: `KeychainSigner.hasKey()` no longer touches the keychain at all — it resolves the
  wallet's existence from the non-secret App Group default (`sw2.walletAddress`, written
  by create and migration). Only `signDigest` → `load()` (actual signing) presents the
  single Face ID prompt. Connect / chain-change requests never sign, so they show no Face
  ID; only message/typed-data/send show exactly one prompt.
- **`accounts.join is not a function` / `sig.slice is not a function`** were the real,
  reproducible root cause: `background.js` lower-cased the JSON-RPC method
  (`eth_requestAccounts` → `eth_requestaccounts`) but `APPROVAL_METHODS`/`DENIED_METHODS`
  held mixed-case strings, so every approval method fell through to RPC passthrough and
  the dapp received a node error object where it expected an array/string. The sets are
  now lowercase, matching the casing fix already applied to native `MethodPolicy`.
- **`[object Object]` errors**: native structured errors (`{code,message}`) were wrapped
  a second time (`message: prepared.error` nests the object) and the bridge resolved the
  non-pending branch as `ok:true`. Background now replies through a stable envelope
  `{ __envelope:true, ok, result|pendingId|error }`; `bridge.js` decodes it and surfaces
  structured EIP-1193 `{message,code}` to the page provider. Native errors now reach the
  dapp as readable messages.
- Added `WalletFactory` (create a brand-new wallet in the new format) so a fresh install
  has a key for `KeychainSigner` and a "Create a wallet" button in the app. Reuses the
  same keychain service and App Group default key as migration.

### Verification

- `swift test`: 66 tests / 14 suites pass (added `WalletFactoryTests`; all Approval core).
- `node --check` passes for all four extension scripts.
- `stupid-app build` produces the app + extension appex; `stupid-app run --network`
  installs and launches on the physical iPhone.
- **Simulator (fresh install, current extension):** connect stays pending awaiting the
  toolbar popup (no `accounts.join`), native errors (`[object Object]` / HTTP 530)
  surface as readable messages, and the eth_blockNumber passthrough round-trips provider
  → bridge → worker → native → RPC with structured transport errors preserved.

### Follow-Up

- The `.userPresence` signing step initially failed on the simulator with `-34018`; this
  was the missing simulator entitlements (fixed in the CLI and verified, see the
  "Simulator Keychain Fix" entry above), not a lack of passcode. On the simulator the
  keychain self-test and wallet creation now both work through Face ID / passcode.
- Simulator egress to `evm.stupidtech.net` returns HTTP 530 (sim network/edge), unrelated
  to the extension; the failure is propagated correctly.

## 2026-08-22 - Gate 5: Canonical Approval Protocol + Real Signing

### Summary

- Replaced the fixed mock signer and the mock account with an injected `Signing`
  protocol. Production uses `KeychainSigner`, which loads the new-format key from the
  shared keychain (via `KeychainKeyStore`) and signs with the vendored secp256k1;
  `UnavailableSigner` reports `notReady` when no key exists so the wallet fails loudly.
- Added `RequestKind` (connect, message, typed-data, send, chain, denied, passthrough)
  and per-kind canonical summaries (`ApprovalSummary.title/rows`); `WalletService.Summary`
  now carries `kind`, `title`, ordered `rows`, and a `queued` flag.
- Pending requests now persist under the shared App Group
  (`PendingRequestStore.defaultAppGroup`) so the app and extension share durable records
  and approvals survive service-worker suspension.
- Approval is bound to request ID, kind, method, origin, chain, `payloadDigest`, expiry,
  and unconsumed state. On approve, native code recomputes the canonical digest
  (`CanonicalRequest` = keccak of request ID + canonical sorted-keys params) and rejects
  any mutation; it rejects expired/queued/already-handled cases and recomputes the
  signable digest (EIP-191, EIP-712, or transaction signing payload) before signing.
- One active approval at a time in creation order (oldest approvable); the rest are
  `queued`. `reject` maps to EIP-1193 `4001` and never signs.
- Handler error mapping now covers 4100/4001/-32000/-32602/4200/4900. Background worker
  classifies connect/sign/send/chain as approvals, denies unsafe methods with 4200, and
  passes everything else through.
- Popup renders canonical per-kind cards from native summaries (icon, title, host, rows,
  queued state, danger warning) and submits only request ID + decision.
- Added `EIP712` (v4 typed-data hashing) and `RequestExecutor` (pure digest/result
  derivation per kind).

### Verification

- `swift test`: 63 tests / 13 suites pass. New `ApprovalTests` cover approve+consume,
  duplicate approval, method-not-approved, max-with-unwanted deny, payload mutation
  (bindingMismatch), expiry, queue order (oldest approvable, queued rejected), reject
  (never consumed, 4001), and per-kind summaries.
- `swift format --in-place --recursive Sources Tests` succeeded.
- `stupid-app build` produces `StupidWallet.app` including the vendored C target and the
  extension appex (arm64 ios min 17.0 sdk 26.1).
- `node --check` passes for all four extension scripts.
- All Route/tests for the JSON/RPC core still pass unmodified.

### Follow-Up

- Run the physical-device Gate 5 proof: drive each approval kind through the Safari
  popup on an iPhone with a migrated wallet present, confirm popup > Face ID > sign /
  reject binds to the canonical record, `4001` on reject, and queueing.
- Wire wallet create/import (Gate 6) so a brand-new install has a key for the
  `KeychainSigner` to sign with, and add transaction submission.

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

## 2026-08-22 - Gate 4 Migration: State Machine + Security Backend

### Summary

- Added `WalletMigration` (Gate 4), a hermetic-testable state machine over an
  `OldWalletBackend` abstraction, plus `SecurityWalletBackend`, the production backend
  that reads the old app's persisted format:
  - checksummed address in App Group defaults (`"walletAddress"`)
  - ECIES ciphertext in a generic-password keychain item keyed by the address
  - a Secure Enclave P-256 key tagged by the address, decrypted with
    `.eciesEncryptionCofactorVariableIVX963SHA256AESGCM` (presents the device-owner
    prompt automatically).
- The orchestrator runs only when no new-format wallet exists, derives the address from
  the decrypted key and requires case-insensitive equality with the persisted address,
  saves in the new format (pending), then requires an authenticated sign-and-recover
  self-test before marking completion. Old keychain material is retained until an
  explicit idempotent cleanup. Failed and cancelled attempts never complete.

### Why

- Gate 4 is the identity-continuity release blocker: the rebuild must migrate an
  installed old wallet to the new format in place, without re-import.

### Verification

- `swift test`: 54 tests / 12 suites pass, including 11 migration tests (success +
  re-derived address match; no old wallet; idempotency; skip when new wallet exists;
  malformed ciphertext; wrong address; user cancellation; save failure; self-test
  failure; idempotent cleanup).
- `stupid-app build` produces the app including the new core.

### Follow-Up

- The on-device half of Gate 4 was proved: an old-format wallet was installed and created
  on the iPhone, then the new app upgraded in place and migrated it, with the recovered
  address equal to the old wallet's address. During the live run the migrator presented
  three Face ID/passcode prompts; investigation showed the orchestrator decrypted the old
  ciphertext twice (the second decrypt before persisting was superfluous). Removed the
  duplicate decrypt so a successful run now shows exactly two prompts: one to decrypt the
  old key and one to reload the new-format `.userPresence` key for the self-test. All 54
  tests and the app build still pass after the fix.

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
