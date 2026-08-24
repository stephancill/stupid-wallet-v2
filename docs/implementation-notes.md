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

## 2026-08-24 - Safari Request Identity And Diff Cleanup

### Summary

- Corrected the request-retry model introduced during the Mac propagation investigation. Native
  preparation no longer treats canonical intent equality alone as retry identity: the provider now
  assigns each call a stable page-session `requestKey`, retries reuse it, and native deduplication
  requires both that key and the canonical `intentDigest`.
- Added regression coverage proving a transport retry converges while two deliberate identical
  requests remain distinct, including concurrent app/extension store access.
- Made failure to acquire the cross-process prepare lock an explicit error instead of silently
  degrading to an in-process check.
- Removed obsolete background-worker completion callbacks and popup routes. The worker now owns
  preparation and best-effort badge state; the originating bridge completes requests by polling the
  durable native record.
- Kept the direct-native Mac popup path and iOS-compatible background fallback. A successful popup
  decision synchronizes the worker set, and zero pending requests render as an empty badge string.
- Bumped the WebExtension manifest to `0.1.24` and the local Mac app/extension build to `5`, then
  regenerated the tracked Xcode project.
- Updated the maintained handover, focused Mac handovers, and debugging skill to remove superseded
  assumptions about the Xcode project, unresolved propagation, retry identity, and completion
  routing.

### Why

- Two intentional transactions can have identical canonical parameters. Collapsing them solely by
  intent would lose a user action; retry identity must originate with the provider call and remain
  stable only across transport retries of that call.
- Completion already survives service-worker suspension through the native pending store and bridge
  polling, so retaining worker callbacks created a second stale model with no authoritative role.

### Verification

- `swift test -q` passed all 128 tests in 21 suites.
- `node --check` passed for all four JavaScript files.
- `node --test Tests/JavaScript/*.test.mjs` passed all 6 tests.
- `xcodegen generate` regenerated `Mac/StupidWalletMac.xcodeproj` successfully.
- `stupid-app doctor` completed with zero failures and zero warnings.
- `stupid-app build` succeeded and packaged the iOS app and Safari extension. The first sandboxed
  attempt could not write Swift's user cache; the required rerun with normal cache access passed.
- `git diff --check` passed.
- Live Safari rejection on the preceding `0.1.23` diagnostic install proved the badge's one-to-zero
  transition and returned the expected user-rejection error without signing. `0.1.24` retains that
  path and adds retry-identity cleanup; it has not been reinstalled for a second live run.

### Follow-Up

- Verify Mac `eth_sendTransaction` broadcast with a network-confirmed receipt.
- Repeat the complete flow from a TestFlight distribution install for Gate 8.

## 2026-08-24 - Mac Safari Stale Native Plugin Image

### Summary

- Reproduced Relay waiting on a wallet approval while the Safari toolbar popup showed no pending
  requests.
- Disproved the leading Safari-profile-asymmetry hypothesis on this host: once the current native
  build actually ran, the popup logged `list profile=nil`.
- Found that Safari had been launching an old monolithic extension inode even though `.XCInstall`
  contained current instrumented code. Fresh records from the stale process lacked the newly added
  intent identity, and the expected diagnostic log was absent.
- Updated the gitignored Mac XcodeGen project to disable Xcode's debug-dylib split and bumped its
  diagnostic build number. Quitting Safari before Xcode Run was required to release the stale
  plugin image. Reopening Safari then launched the current monolithic extension and produced the
  expected popup diagnostic.

### Verification

- `xcodegen generate` succeeded.
- `xcodebuild -project Mac/StupidWalletMac.xcodeproj -scheme StupidWallet -configuration Debug
  -destination 'platform=macOS,arch=arm64' build | xcpretty` succeeded.
- `stupid-app doctor` completed with zero failures and warnings.
- `pgrep` plus `lsof` distinguished the stale 3,110,335-byte plugin image from the current
  258,256-byte image after the clean Safari lifecycle.
- Semantic toolbar activation produced `list profile=nil` in the temporary App Group diagnostic.
  The list was empty because the prior records had expired during installation diagnosis.

### Follow-Up

- Trigger one fresh Relay approval with the current native image, open the popup semantically, and
  capture adjacent `prepare`, `get`, and `list` diagnostics before changing request policy.
- Remove temporary native file diagnostics after the fresh-request boundary is resolved.

## 2026-08-24 - Request-Propagation Handover Created

- Added `docs/macos-safari-request-propagation-handover.md` as the focused handover for the
  ongoing Mac Safari defect where the popup shows no pending requests despite valid pending
  records. It records: fixed causes (duplicate extension registration, disable-on-reinstall,
  idempotent `prepare`, bridge backoff/retry), the current Safari-profile-asymmetry hypothesis,
  the temporary `handle-diag.log` instrumentation and how to read it, the resume path, and the
  outstanding verification (prompt popup listing, no duplicates after window switching, and
  network-verified `eth_sendTransaction` on the Mac).
- The engineering handover points to this document for the Mac popup defect.

## 2026-08-24 - Idempotent Prepare And Request-Delivery Resilience

### Summary

- Reported that switching away from the dapp window duplicated pending requests (relay.link
  `eth_sendTransaction` records appeared every few seconds). The dapp's SDK logged
  "Execution aborted" and re-issued the transaction when its request channel was interrupted;
  each re-issue created a fresh pending record.
- Made native `prepare` **idempotent**: a request re-sent while an identical intent is still
  pending now resolves to that existing record instead of enqueueing a duplicate. A new stable
  `intentDigest` (normalized method + origin + chain + profile + canonical params, independent
  of the record ID) is persisted on each record; `prepare` scans pending records for a match
  and returns the existing ID. Completion still reaches the original requester via durable
  status polls.
- Made the JS bridge resilient to worker suspension/contention: `ethereum.request` now retries
  (twice, with backoff) on a transport rejection before surfacing an error, so a dapp does not
  abort and re-issue a duplicate. `busy` status polling already backs off (1s → 4s) to stop the
  page's `get` polls saturating the native plugin and delaying the popup's `list`.
- Updated tests that had modelled simultaneous identical pending requests as distinct queue
  entries: distinct intents still queue; identical simultaneous intents dedupe. The
  quick-successive-nonce test now prepares the second identical send only after the first is
  consumed (the realistic "nonce too low" flow).
- Fix-up within the same work: the first idempotent `prepare` used a non-atomic read-then-insert,
  which still duplicated under truly concurrent re-sends (two identical `eth_sendTransaction`
  with the same `intentDigest` were observed). The check-and-insert now runs atomically inside
  the `PendingRequestStore` actor via `insertIfAbsent`, returning the existing ID when an
  identical intent is already pending. A concurrent-prepare regression test was added.

### Why

- The duplication was a dapp-retry artifact: an interrupted request channel causes the dapp to
  re-issue the exact request. Idempotent `prepare` converges those re-issues to one canonical
  pending card while preserving the one-active-approval queue for genuinely different requests.

### Verification

- New tests: "re-sent identical request converges to one pending record" and "concurrent
  identical prepares converge to one pending record" (the latter covers the atomic
  check-and-insert). `swift test`: 126 tests in 21 suites pass.
- `xcodebuild ... -destination 'platform=macOS,arch=arm64'` rebuild succeeds; the extension
  resources carry the updated bridge/popup scripts.

### Follow-Up

- Reinstall on the Mac (Xcode Run) and confirm switching away no longer duplicates requests, and
  that the popup lists the single pending card promptly.
- Watch for pending records without `intentDigest` (written before this change); requests
  matching those are not deduplicated until they are consumed.

## 2026-08-24 - Duplicate Safari Extension Registration Fix

### Summary

- On newest dapps (Uniswap, OpenSea), `eth_requestAccounts` prepared a canonical pending record
  and the in-page notice appeared, but the Safari toolbar popup showed "No pending requests".
- Root cause: **two `stupid wallet` extensions were registered in Safari** for the same display
  name. A stale registration from the old `ios-wallet` reference install
  (`co.za.stephancill.stupid-wallet.dev.extension`) remained alongside the production
  `co.za.stephancill.stupid-wallet.extension` installed to `My Mac (Designed for iPad)` by the
  XcodeGen project. The page and the popup could resolve to different instances, so the popup
  never listed the page's pending requests. Instrumentation (temporary popup + handler logging)
  showed the popup's `popup.list` never reached native code at all.
- Fix: unregistered the stale `ios-wallet` appex with `pluginkit -r <path>`; verified exactly one
  production registration in `pluginkit -m -v`; restarted Safari Technology Preview to drop the
  cached duplicate; and re-enabled the production extension.
- A second gotcha: an Xcode **Run** re-install re-registers the plugin and can reset the extension
  to **disabled** in Safari, which also makes the popup appear empty. After any reinstall, check
  `~/Library/Containers/com.apple.SafariTechnologyPreview/.../WebExtensions/Extensions.plist` and
  re-enable the single extension in Safari settings.
- Reverted all temporary diagnostics after confirming the flow; the clean working tree carries no
  instrumentation.

### Why

- Native messaging and signing were already proven; the empty popup was a registration/
  enablement issue, not a request-path defect. Recording the exact external symptoms and the
  duplicate-registration remediation avoids re-diagnosing the same multi-install mess.

### Verification

- `pluginkit -m -v` lists exactly one `co.za.stephancill.stupid-wallet.extension`
  (the `.XCInstall` path).
- Safari Technology Preview `WebExtensions/Extensions.plist` shows
  `co.za.stephancill.stupid-wallet.extension … Enabled=True`.
- Connect + sign confirmed working again after re-enabling the single extension.

### Follow-Up

- Consider having the project clean stale extension registrations before a new install, and
  documenting that Xcode re-runs may require re-enabling the extension in Safari.

## 2026-08-24 - Mac Safari Native Messaging And Signing Proven Via Entitled Install

### Summary

- Owner decision confirmed: local Mac testing routes through Xcode's "My Mac (Designed
  for iPad/iPhone)" install using the gitignored XcodeGen project at `Mac/`. Re-running the
  scheme in Xcode performed the **entitled install**, which now spawns the
  `StupidWalletSafari.appex` plugin as its own process, so Safari's `sendNativeMessage` reaches
  the native handler (previously `Launchd job spawn failed`).
- Verified end to end on the Mac: EIP-6963 discovery, `eth_requestAccounts` connect consumed,
  `personal_sign` prepared → approved in the Safari popup → native device-owner authentication →
  signature returned, and the returned signature **independently recovered to the registered
  account** via `cast wallet verify` ("Validation succeeded").
- A re-imported wallet on the Mac is required: new-format keys are `ThisDeviceOnly` and do not
  synchronize from the iPhone; the old-format same-device migration has no material on the Mac.

### Why

- The previous entries recorded the launchd-plugin-spawn boundary. The entitled install closes
  it: macOS can launch the appex plugin for native messaging, so the full request/approval/signing
  path now works on Apple Silicon Safari instead of requiring TestFlight.

### Verification

- `personal_sign` pending record moved to `consumed` with a 65-byte signature; recovering the
  signer returned the registered account.
- Keychain note for future debugging: `.userPresence` keychain items are ACL-protected and are
  **not visible to the `security` CLI** (reports item-not-found) even when signing succeeds; do
  not treat that probe as a missing key.
- Also fixed in the generated project: XcodeGen was overwriting `entitlements.path` files with
  empty plists, so the signed app lacked the App Group and keychain groups (the app did not see
  the pre-existing wallet, and wallet creation failed to "share with the Safari extension"). The
  project now keeps gitignored entitlements under `Mac/` and sets `CODE_SIGN_ENTITLEMENTS` per
  target; the signed app and appex carry `com.apple.security.application-groups` and
  `keychain-access-groups`. The API-created development identity (`P6ZUM5V6TP`) used by the
  Mac-native-messaging profiles was imported into the login keychain from the `stupid-app`
  credential store so xcodebuild can sign.

### Follow-Up

- Transaction broadcast (`eth_sendTransaction`) on the Mac still needs network-verified proof.
- `stupid-app run --mac` remains web-content-only; the full Mac flow uses the Xcode project.

## 2026-08-24 - Gitignored Xcode Project For Mac Testing

### Summary

- Owner decision: route local Mac testing/install through `xcodebuild` so Apple's entitled
  installer performs the placement and creates the launchd/RBS plugin registration that enables
  Safari native messaging (see the native-messaging launch boundary entry below). This is a
  Mac-testing-only exception; `stupid-app` remains the build/sign/release authority elsewhere.
- Added a **gitignored** Xcode project under `Mac/` (not tracked): `Mac/project.yml`
  (XcodeGen spec) generating `Mac/StupidWalletMac.xcodeproj`. It uses the existing source and
  package directly:
  - App target `StupidWalletApp` compiles `Sources/StupidWallet` (the existing `@main` SwiftUI
    app).
  - Extension target `StupidWalletSafariExt` compiles `Sources/StupidWalletSafari`
    (`NSExtensionRequestHandling` handler), embeds the `SafariExtension/Resources` at the appex
    root via a copy script, and carries the `NSExtension` (`com.apple.Safari.web-extension`)
    info.
  - `StupidWalletCore` is built as a project-local framework compiling `Sources/StupidWalletCore`
    plus the `Sources/CSecp256k1` C sources, with project-local module glue
    (`Mac/CSecp256k1Module`, gitignored) that mirrors the package's cSettings
    (`ENABLE_MODULE_RECOVERY`/`ENABLE_MODULE_ECDH`).
- No new product source was added to the repository, and no existing source file was modified.
  The project targets are named `StupidWalletApp`/`StupidWalletSafariExt` to avoid colliding with
  the package's library products (`StupidWallet`, `StupidWalletSafari`).

### Why

- The iOS-compat extension's web content runs under `stupid-app run --mac`, but native messaging
  requires the appex to be spawnable as a launchd/RBS plugin, which only the entitled installer
  creates. Routing the Mac run through Xcode's "My Mac (Designed for iPad/iPhone)" destination
  uses that installer. The project must use the existing package source with no Mac-specific
  product code, so it references `Sources/` via XcodeGen and the shared package.
- Early XcodeGen experiments rewrote tracked plists when `info.path`/`entitlements.path` pointed
  at repo files; the final spec copies entitlements and generates Info plists inside `Mac/`
  (gitignored) and the tracked files were restored unchanged.

### Verification

- `xcodegen generate` produces `Mac/StupidWalletMac.xcodeproj`; `git status` shows `Mac/`
  ignored and no tracked file modified by the project.
- `xcodebuild -project Mac/StupidWalletMac.xcodeproj -scheme StupidWallet -destination
  'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` succeeds.
- The same build succeeds for `-destination 'platform=macOS,arch=arm64'` (My Mac, Designed for
  iPad/iPhone), producing `StupidWallet.app` with `PlugIns/StupidWalletSafari.appex` containing
  the handler executable, `Info.plist` with `NSExtension` (point
  `com.apple.Safari.web-extension`, principal class `StupidWalletSafari.SafariWebExtensionHandler`),
  and the Safari resources (`manifest.json`, scripts, popup, icons) at the appex root.
- Bundle identifiers verified: app `co.za.stephancill.stupid-wallet`, extension
  `co.za.stephancill.stupid-wallet.extension`.

### Follow-Up

- `xcodebuild build` with `-destination 'platform=macOS,arch=arm64'` signs and produces the
  Designed-for-iPad app, but the entitled install to the Mac happens on Xcode's **Run** action
  (GUI), not on an `xcodebuild` build. Open `Mac/StupidWalletMac.xcodeproj`, select
  "My Mac (Designed for iPad/iPhone)", and Run once; that installs via the entitled installer and
  creates the launchd/RBS plugin registration. Then re-verify Safari native messaging end to end:
  `eth_requestAccounts` creates a canonical pending request, popup approval, fresh device-owner
  authentication, and recovered-signer verification.
- Signing for xcodebuild uses the API-created development identity (`P6ZUM5V6TP`) that the
  Mac-native-messaging profiles were created with; that identity was imported into the login
  keychain from the `stupid-app` credential store (reversible with `security delete-certificate`).
- `stupid-app run --mac` continues to support iOS-compat web content only.

## 2026-08-24 - macOS Native Messaging Plugin Launch Boundary

### Summary

- Investigated the connect failure on macOS Safari Technology Preview at a test dapp
  (`networked.art/auth/connect`): the dapp listed `stupid wallet` via EIP-6963 and showed
  `Waiting for stupid wallet confirmation...`, but no canonical pending request was created.
- Root cause found by surfacing the raw `sendNativeMessage` error end to end: Safari routes the
  message to the extension host app but **cannot spawn the iOS-compat appex plugin**:
  `Invalid call to runtime.sendNativeMessage(). RBSLaunchRequest error trying to launch plugin
  …: Launch failed … Launchd job spawn failed`.
- Conclusion: on Apple Silicon Mac, `run --mac`'s LaunchServices + `pluginkit` registration lets
  Safari load the extension's **web content** (background page, content scripts, EIP-6963
  announce) but does **not** create the launchd/RBS plugin registration required to spawn the
  `StupidWalletSafari.appex` process for native messaging. The entitled installer
  (Xcode/TestFlight `.XCInstall`) creates that registration; the `sendNativeMessage` application
  ID is not the cause.
- The old `../ios-wallet` used the identical mechanism — `sendNativeMessage("co.za.stephancill.stupid-wallet")`
  to a `SafariWebExtensionHandler` (`NSExtensionRequestHandling`) with the plain bundle ID — and
  signed on desktop because it was installed via Xcode, which creates the launchd plugin
  registration. The new app uses the same plain bundle ID, confirming the ID is correct.
- Reverted all temporary diagnostic instrumentation (JS logging, Swift `os_log`/marker files,
  manifest version bumps) and the experimental Team-ID-prefixed application ID; restored the
  original plain bundle ID and manifest version.

### Why

- Needed to distinguish a signing/persistence bug from an installation/platform boundary. The
  definitive error separated "native messaging delivers but the app handler cannot start" from
  "the handler runs but rejects the request".
- Recording that macOS native messaging for an iPhone/iPad-compat Safari extension requires the
  launchd plugin registration that only Apple's entitled installer creates, so future work does
  not chase the application ID.

### Verification

- EIP-6963 discovery and provider injection work in Tech Preview without manual event injection.
- Reproduced: click `stupid wallet` → dapp hangs (`Waiting for stupid wallet confirmation...`) or
  reports `Active chain unavailable`. The surfaced raw error named `RBSLaunchRequest … Launch
  failed … Launchd job spawn failed` while trying to launch `co.za.stephancill.stupid-wallet.extension`.
- Neither the plain bundle ID nor the Team-ID-prefixed application ID changed delivery; the
  handler's `beginRequest` did not execute (no marker file, no response reaching it).
- Both plain and composite application IDs produce the same launchd-spawn failure, confirming the
  application ID is not the fix.

### Follow-Up

- To prove signing/native messaging on an Apple Silicon Mac, use the TestFlight build (or an
  Xcode-installed build) whose install creates the launchd plugin registration, per the acceptance
  workflow in `docs/macos-safari-extension-install-handover.md`.
- `stupid-app run --mac` supports the extension's web content on this host but cannot deliver
  native messaging; keep the iOS simulator/device path for the full connect/approval/signing flow.

## 2026-08-24 - macOS Safari Installation Problem Handover

### Summary

- Added `docs/macos-safari-extension-install-handover.md` as a focused handover for the local
  macOS Safari extension failure.
- Consolidated the observed failure signatures, InstallCoordination evidence, rejected signing
  hypotheses, retained CLI behavior, completed verification, TestFlight verification sequence,
  and closure criteria.

### Why

- The main engineering handover describes the whole wallet and the chronological notes preserve
  the investigation, but the unresolved cross-repository installation problem needed one
  operational document that a future engineer can follow without reconstructing the diagnosis.

### Verification

- Cross-checked the handover against the current wallet and CLI handovers, implementation notes,
  source locations, test count, release build result, doctor result, and fail-fast error.
- `git diff --check` passed.

### Follow-Up

- Execute the documented TestFlight-on-Mac acceptance sequence; do not treat an Xcode-controlled
  diagnostic build as proof of the `stupid-app` artifact.

## 2026-08-24 - macOS Extension Installation Boundary

### Summary

- Traced the macOS Safari launch failure past signing and provisioning to the installation layer.
- Confirmed that Xcode creates app and PlugInKit placeholders through its entitled
  `IDEInstallService`, while direct wrapper copy plus LaunchServices registration does not create
  the nested extension's MobileInstallation record.
- Changed the CLI to reject extension-bearing `run --mac` projects before build; this wallet must
  use Xcode or TestFlight for local macOS Safari verification.
- Removed the rejected profile/signature experiments from the CLI so ordinary iOS development and
  distribution signing keep their previously qualified profile and signature formats.

### Why

- The extension executable itself runs and its development profile authorizes the Mac, but Safari's
  managed launch still reports no matching profile after a LaunchServices-only install.
- macOS explicitly rejects non-Apple clients of InstallCoordination for missing the private allowed
  entitlement. Using Xcode's test-host path would require Xcode to modify and sign the app, violating
  the project's single source of build truth and one-signing-pass rules.

### Verification

- Unified logs captured Xcode's complete `.XCInstall` transaction and the direct CLI entitlement
  rejection.
- `xcodebuild test` invoked the entitled install helper on the Designed for iPad/iPhone destination;
  `xcodebuild install` did not perform device-style installation.
- The CLI's 262-test suite passed, its release build succeeded, and `doctor` completed with zero
  failures and warnings. Running the release binary with `run --mac` in this project returned the
  extension-specific failure before profile lookup, build, signing, or installation.

### Follow-Up

- Install a current TestFlight build or use Xcode for the remaining macOS Safari provider, native
  messaging, popup, shared-storage, and authenticated-signing checks.

## 2026-08-24 - Immediate Persisted Activity

### Summary

- Changed global Activity and connected-app details to read and render their persisted activity
  before refreshing transaction receipts.
- Receipt polling still runs when either screen opens or is manually refreshed, and the visible
  rows are replaced afterward with any updated transaction statuses.

### Why

- The previous load order awaited serial RPC polling for every unresolved transaction before reading
  SQLite, leaving Activity behind a spinner even though its persisted rows were local. The initial
  connected-app-only fix did not address the same ordering in the global Activity screen; testing
  with a copied production-shaped database made that remaining delay clear.

### Verification

- `swift format --in-place Sources/StupidWallet/ConnectedAppsView.swift` and
  `git diff --check` passed.
- `swift test`: 124 tests in 21 suites passed, including connected-app activity filtering.
- The repository debugging skill passed `quick_validate.py`.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid
  <preferred-simulator>` rebuilt, installed, and launched the app and extension.
- A consistent SQLite backup of the Mac compatibility app's activity database was restored into
  the stopped simulator app's App Group for realistic testing. Source and destination row counts
  matched, the simulator database passed `PRAGMA integrity_check`, and the app relaunched.
- With that production-shaped database containing multiple unresolved transactions, simulator
  accessibility inspection found persisted Activity rows within 0.6 seconds of selecting Activity;
  receipt polling continued without holding the list behind the loading indicator.

### Follow-Up

- None.

## 2026-08-24 - Local Apple Silicon Mac Run

### Summary

- Added and exercised `stupid-app run --mac` against this unchanged iOS app and bundled
  Safari Web Extension. No native macOS/Catalyst target or Xcode project was added.
- The CLI retained the ordinary iOS build and production identities, development-signed
  the app and extension for the Mac provisioning UDID, created macOS's compatibility
  wrapper, registered it with LaunchServices, and launched it through UIKitSystem.
- This supplements the TestFlight-on-Mac distribution direction with a local development
  workflow; it does not change release packaging or imply cross-device keychain sync.

### Verification

- `stupid-app run --mac` built, signed, packaged, installed, and launched the containing
  app as a live iOS process on Apple Silicon Mac.
- LaunchServices classified the installed wrapper as platform iOS and registered the
  nested Safari Web Extension under the production extension identity.
- `swift test` passed 124 tests in 21 suites; `stupid-app doctor` completed with zero
  failures and warnings; and `git diff --check` passed.

### Follow-Up

- Enable the extension in macOS Safari and complete provider injection, native messaging,
  popup review, shared App Group/keychain, and authenticated-signing verification.

## 2026-08-24 - Regular Activity Typography

### Summary

- Removed every monospaced font override from Activity details, including account addresses and
  EIP-712 domain hex values.
- Transaction hashes and signatures continue to use regular UIKit label typography with middle
  truncation and their existing compact long-press Copy interaction.

### Verification

- `swift format --in-place Sources/StupidWallet/ActivityView.swift` completed, and source inspection
  found no remaining monospaced typography in that file.
- `swift test`: 124 tests in 21 suites passed.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension with the regular activity typography.
- `stupid-app build` succeeded. After refreshing uniquely named development profiles,
  `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` signed, installed, and
  launched the app and nested extension on the paired iPhone.

### Follow-Up

- This change is intentionally scoped to Activity screens; typography in import, network, and
  private-key settings screens is unchanged.

## 2026-08-24 - Complete Signatures In Activity

### Summary

- Extended signature activity persistence to retain the complete resulting signature alongside the
  signed content and existing digest metadata.
- Added a middle-truncated Signature row to signature details. A held touch opens the same compact
  Copy edit menu used by transaction hashes and copies the complete signature.
- Folded From, Network, and Timestamp into the Signature section with Method, Status, and Signature,
  removing the separate Verification section.
- Advanced the in-place activity schema to version 7. Existing rebuild-era signature rows with an
  empty `signature_hex` are backfilled from a retained consumed pending-request result when it is a
  valid 65-byte signature; old-app rows that already contain signatures remain unchanged.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test`: 124 tests in 21 suites passed, including direct signature persistence,
  deterministic-row enrichment, and retained-result migration.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension. Schema inspection confirmed version 7 with zero linked empty signatures. OCR
  showed Method, Status, the middle-truncated signature, From, Network, and Timestamp in one
  Signature section with no Verification section; a real held touch on the signature opened Copy.
- `stupid-app build` succeeded. Fresh uniquely named development profiles avoided the existing App
  Store Connect duplicate-name conflict, and `stupid-app run --network --udid <paired-device>
  --sudo /usr/bin/sudo` signed, installed, and launched the final app and nested extension on the
  paired iPhone.

### Follow-Up

- Rows without either an existing signature or a retained canonical request result cannot be
  reconstructed.

## 2026-08-24 - Structured Typed-Data Activity

### Summary

- Replaced the raw EIP-712 JSON blob in signature activity details with the old app's structured
  Domain and Message hierarchy.
- Domain name, version, chain, and verifying contract use a fixed familiar order. Root message keys
  are alphabetized, scalar values remain readable, and nested objects or arrays use sorted,
  pretty-printed JSON.
- Implemented parsing through the shared typed `JSONValue` representation instead of copying the
  old app's lossy `[String: Any]` casts. Malformed or unsupported typed-data content falls back to
  the exact persisted JSON.
- Attached one compact long-press Copy edit menu to the entire structured EIP-712 content area.
  Copy uses the original persisted JSON string, not an individual formatted field; no permanent
  copy row or field-level selection UI is shown.

### Verification

- `swift format --in-place Sources/StupidWallet/ActivityView.swift` and `git diff --check` passed.
- `swift test`: 124 tests in 21 suites passed.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension. OCR of an existing EIP-712 activity showed the structured Domain labels and
  values followed by readable Message fields, including pretty-printed nested content.
- A real 1.5-second held touch inside that structured content opened the compact Copy edit menu.
  Selecting Copy placed the complete 592-byte test JSON on the simulator clipboard.
- `stupid-app build` succeeded. After refreshing uniquely named development profiles to avoid the
  existing App Store Connect duplicate-name conflict, `stupid-app run --network --udid
  <paired-device> --sudo /usr/bin/sudo` signed, installed, and launched the app and nested extension
  on the paired iPhone.

### Follow-Up

- The structured view intentionally mirrors the old app's root-field presentation rather than
  recursively expanding every nested EIP-712 type into separate UI rows.

## 2026-08-24 - MIPD Provider Re-Announcement

### Summary

- Investigated why the wallet did not appear on a public Wagmi sign-in page. The deployed page
  enables multi-injected-provider discovery, listens for `eip6963:announceProvider`, and
  dispatches `eip6963:requestProvider`; manually announcing the existing wallet provider made
  its button appear immediately.
- Fixed the wallet's EIP-6963 implementation to re-announce in response to every provider
  request instead of announcing only once during injection. This removes the initialization
  race that caused late MIPD consumers to miss the wallet.
- Replaced the fixed non-v4 provider identifier with a page-session UUIDv4 and froze the
  announced provider metadata as specified by EIP-6963.
- Added a dependency-free Node regression for discovery when the consumer starts after the
  wallet, and bumped the WebExtension manifest to `0.1.20` to invalidate Safari's cached script.

### Verification

- Live bundle and event inspection confirmed the public page uses Wagmi 3.4.6 with
  `multiInjectedProviderDiscovery` enabled and performs the EIP-6963 request/announce handshake.
- Loading the exact updated `provider.js` before that page initialized produced a visible
  `stupid wallet` connector through the real MIPD flow.
- `oxfmt`, `oxlint`, `node --check`, and `node --test Tests/JavaScript/provider.test.mjs` passed.
- The updated repository debugging skill passed `quick_validate.py`.
- `swift test` passed 124 tests in 21 suites. `stupid-app doctor` completed with zero failures
  and warnings, and `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and manifest `0.1.20` extension.
- Opening the public sign-in page in simulator Safari after installation showed
  `stupid wallet` in its connector list between MetaMask and Base Account.

### Follow-Up

- None.

## 2026-08-24 - Current Build Installed On iPhone

### Summary

- Refreshed development provisioning for the containing app and Safari extension, then built,
  signed, installed, and launched the current activity-detail build on the paired iPhone.
- Used a distinct profile-name prefix because App Store Connect rejected the default name while
  duplicate historical profiles existed.

### Verification

- `stupid-app signing setup --kind development --udid <paired-device> --profile-name
  <unique-prefix>` created app and extension profiles provisioning the selected iPhone.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` signed the app and nested
  extension, packaged the IPA, installed it over the saved network pairing, and launched the app.
- The first network attempt encountered a transient Pair-Verify rejection; an immediate retry
  completed without changing the pairing record.

### Follow-Up

- App Store Connect still contains duplicate historical profiles using the default development
  profile name. They can be cleaned up separately; the uniquely named current profiles are valid.

## 2026-08-24 - Activity Signed Content Details

### Summary

- Extended the existing shared activity schema in place to version 6 with nullable transaction
  calldata. Newly recorded transactions persist the canonical `data` value that was approved and
  signed.
- Restored signed-message persistence for `personal_sign` and `eth_signTypedData_v4` activity.
  Personal messages retain their exact hex bytes, typed-data requests retain their exact JSON, and
  resulting signatures remain redacted.
- Added selectable multiline Data and Message sections to transaction and signature details.
  UTF-8 personal messages render as readable text; non-UTF-8 messages remain in exact hex form.
- Added a one-time upgrade backfill for rebuild-era activity rows that initially rendered without
  the new sections. It joins each empty row to its retained canonical pending request by request ID
  and restores the exact transaction calldata or signed content. Rows without retained linkage stay
  readable and unchanged.
- Re-signing content whose deterministic signature collides with an older redacted row now enriches
  that row with the signed message instead of silently keeping it empty.

### Why

- Activity details need to identify the transaction payload and the exact content the account
  signed, not only method and status metadata.

### Verification

- `swift format --in-place <changed Swift files>` and `git diff --check` passed.
- `swift test`: 124 tests in 21 suites passed, including personal-message bytes, typed-data JSON,
  transaction calldata, deterministic-signature enrichment, retained-request backfill, and unified
  activity reads.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension. Before opening Activity, the existing version-5 database had one linked
  transaction and one linked signature with empty content. Opening Activity migrated to version 6
  and reduced both missing-content counts to zero without inspecting the payloads.
- Simulator OCR confirmed the existing signature detail now contains a Message section and the
  existing transaction detail contains a Data section.
- `stupid-app build` succeeded, and `stupid-app run --network --udid <paired-device> --sudo
  /usr/bin/sudo` development-signed, installed, and launched the schema-v6 build and nested Safari
  extension on the paired iPhone. App Store Connect again had duplicate historical names, so setup
  used a fresh distinct profile prefix before the successful install.

### Follow-Up

- Signed message content and calldata are sensitive App Group data. A later activity-retention or
  deletion control should remove them together with their activity rows.
- Activity rows without a retained canonical request ID cannot be backfilled.

## 2026-08-24 - Descending Balance Breakdown

### Summary

- Changed the home balance breakdown to order non-zero network balances from largest to
  smallest using their full-width raw wei bytes rather than formatted strings or floating-point
  conversion.
- Replaced the wide spacer between each network and balance with a compact bullet separator,
  rendering each row as `Network • Balance`, and explicitly kept the compact rows left-aligned
  within the full popover width.
- Equal balances use the network name as a deterministic secondary ordering key.

### Verification

- `swift format --in-place <changed Swift files>` and `git diff --check` passed.
- `swift test`: 121 tests in 21 suites passed. Full-width comparison coverage includes values of
  different byte lengths, leading zeroes, and numeric equality with different encodings.
- `stupid-app build` succeeded, and
  `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` development-signed the
  app and nested Safari extension, installed them on the paired iPhone, and launched the app.

### Follow-Up

- The preferred simulator had no non-zero included-network balances during this run, so the
  breakdown remained correctly disabled and the revised row presentation was not visually
  exercised there.

## 2026-08-24 - Connected-App Activity Navigation

### Summary

- Added an Activity section to each connected-app detail. It uses the existing activity row and
  detail presentation but queries SQLite for that app rather than filtering the global capped
  result in memory.
- Modern grants filter by exact normalized origin and Safari profile. Legacy hostname-only grants
  retain domain-level aggregation.
- Added reciprocal navigation from activity details to the matching currently connected app.
  Activity opened from an app detail carries that exact grant forward; globally opened activity
  resolves it from the connected-sites store.
- Changed Connected Apps list timestamps to the regular row text size and removed the leading
  icon from the Open App action.
- Extended the existing SQLite schema in place to user version 4 with nullable `profile_id`
  columns for transactions and signatures. Existing rows remain readable without inventing a
  profile assignment.

### Verification

- `swift format --in-place <changed Swift files>` and `git diff --check` passed.
- `swift test`: 121 tests in 21 suites passed, including exact origin/profile filtering, legacy
  domain aggregation, and activity-to-grant matching.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` development-signed the
  app and nested Safari extension, installed them on the paired iPhone, and launched the app.
- With a temporary localhost simulator grant, the app detail showed only its two existing
  activity records. Opening a record exposed an App navigation row, and selecting it returned to
  the same connected-app detail and filtered Activity section. The temporary grant was then
  disconnected through the app, restoring the simulator's original empty Connected Apps state.

### Follow-Up

- Activity created before profile persistence has no trustworthy profile identity. It remains
  available globally and through legacy domain filtering, but is not attributed to a non-default
  profile-specific grant.

## 2026-08-24 - iOS TestFlight-On-Mac Direction

### Summary

- Confirmed that the old production iOS TestFlight build installs on Apple Silicon Mac and
  exposes its bundled Safari Web Extension to macOS Safari.
- Selected that compatibility path for the rebuild. A separate native macOS or Mac
  Catalyst target is not required and must not be added without a concrete failed
  compatibility requirement.
- Removed the exploratory native Mac target, metadata, configuration, local installation,
  and associated `stupid-app` native-target changes.

### Verification

- The old production TestFlight build provides the existing-device proof for the selected
  deployment model.
- Source and worktree inspection confirmed the exploratory native target and CLI changes
  were removed while unrelated implementation work remained intact.
- `swift test` passed 121 tests in 21 suites; `stupid-app doctor` reported zero failures
  and warnings; and `stupid-app build` produced the unchanged ARM64 iOS app and extension.
- The restored CLI passed 259 tests in 47 suites after clearing stale SwiftPM objects, and
  its release binary rebuilt successfully.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and
  launched the iOS app and bundled extension after the native-target removal.

### Follow-Up

- Upload the rebuild through the existing iOS TestFlight pipeline and repeat installation,
  Safari extension enablement, provider/native messaging, popup approval, shared storage,
  and authenticated signing on Apple Silicon Mac before closing Gate 8.

## 2026-08-24 - Home Copy Address Icon

### Summary

- Moved Copy Address out of the account blockie menu into a dedicated
  `square.on.square` toolbar icon immediately beside the blockie.
- Kept the existing full-address pasteboard behavior and left Activity, Connected Apps,
  and Settings in the account menu.
- Added a non-interactive first menu row showing the account blockie and shortened address.
- Updated the blockie accessibility hint to describe the remaining account menu.

### Verification

- `swift format --in-place Sources/StupidWallet/ContentView.swift` completed.
- `swift test`: 120 tests in 21 suites passed.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and extension.
- Simulator accessibility inspection exposed adjacent Copy Address and Wallet address toolbar
  buttons. The blockie menu began with a non-focusable shortened-address row followed by
  Activity, Connected Apps, and Settings, with no duplicate copy action. Visual inspection
  confirmed the informational row uses the account blockie, and tapping the copy icon placed a
  valid 20-byte Ethereum address on the simulator clipboard.

### Follow-Up

- None.

## 2026-08-24 - Lowercase Home Screen Name

### Summary

- Changed the containing app's `CFBundleDisplayName` from `StupidWallet` to `stupid wallet`
  so the iOS Home Screen follows the locked user-facing product name.
- Internal Swift products, targets, modules, and bundle identifiers remain unchanged.

### Verification

- `plutil -lint Info.plist` passed.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app. The installed bundle reports `CFBundleDisplayName = stupid wallet`.

### Follow-Up

- None.

## 2026-08-24 - Refreshed Upward-Arrow Artwork

### Summary

- Replaced the canonical app icon with the newly supplied hand-drawn upward-arrow artwork.
- Regenerated the Safari extension's 48px and 128px icons and the EIP-6963 provider data URI
  from the same opaque 1024px source so every wallet surface retains one identity.
- Bumped the WebExtension manifest to `0.1.19` to invalidate cached icon resources.

### Verification

- Image inspection confirmed opaque 1024x1024, 48x48, and 128x128 PNG outputs.
- The EIP-6963 data URI decoded to the same bytes as the packaged 48px extension icon.
- `bunx oxfmt`, `bunx oxlint`, and `node --check` passed for the changed extension files.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded
  and retained `CFBundleIconName = AppIcon` in the assembled app.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and manifest `0.1.19` extension.

### Follow-Up

- None.

## 2026-08-24 - Reinstall-Safe Private-Key Import

### Summary

- Fixed raw private-key and seed import when a protected new-format keychain item survived
  app uninstall but the App Group active-wallet registration did not.
- `errSecDuplicateItem` no longer becomes a generic save failure. Provisioning now presents
  device-owner authentication, requires the retained key bytes to exactly match the imported
  secret, repeats the sign-and-recover proof, and restores only the shared address registration.
- Existing retained items are never deleted or replaced on cancellation, mismatch, proof
  failure, or registration failure. Newly inserted items retain the existing rollback behavior.
- Added a specific secure-storage error message for genuine keychain-add failures and recorded
  the no-prompt failure boundary in the debugging workflow.

### Why

- iOS keychain items can survive uninstall while App Group files are removed. Importing the
  same key then failed before the verification prompt even though the protected key was intact.

### Verification

- `swift format --in-place <changed Swift files>` and `git diff --check` passed.
- `swift test`: 120 tests in 21 suites passed, including matching retained-item recovery and
  mismatch preservation without deletion.
- The repository debugging skill passed `quick_validate.py`.
- `stupid-app doctor` completed with 0 failures and 0 warnings.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and extension.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` signed the app and
  nested extension, installed them in place, and launched the app on the physical iPhone.
- Retrying the same previously failing private-key import on the iPhone succeeded, confirming
  that the retained protected item authenticated, verified, and restored wallet registration.

### Follow-Up

- Confirm Safari signing with the recovered account as part of the remaining Gate 6 device
  acceptance work.

## 2026-08-24 - Lowercase User-Facing Product Name

### Summary

- Changed rendered instances of `Stupid Wallet` to `stupid wallet` across the containing app,
  Safari extension identity and request hint, EIP-6963 provider metadata, provider-facing
  errors, and prototype app UI.
- Replaced user-facing `dapp` wording with `app` while retaining the protocol term in code
  comments, tests, directory names, and technical documentation.
- Kept internal Swift target/module names, bundle identifiers, source comments, historical
  documentation, and signing-domain strings unchanged. The extension manifest is now `0.1.18`
  to invalidate cached UI resources.

### Verification

- `swift format`, `oxfmt`, `oxlint`, `node --check`, and plist linting passed for the changed
  Swift, extension, prototype-app, manifest, HTML, and plist files.
- The prototype app's `bun run build` succeeded.
- `swift test`: 118 tests in 21 suites passed.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and manifest `0.1.18` extension.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` signed the app and
  nested extension, installed them on the physical iPhone, and launched the containing app.
- Source searches confirmed remaining `Stupid Wallet` and `dapp` matches are limited to
  non-UI signing-domain values, comments, technical documentation, identifiers, and tests.

### Follow-Up

- None.

## 2026-08-24 - Public Repository README

### Summary

- Added a root README describing the product, implemented features, security model,
  architecture, requirements, `stupid-app` build and simulator workflows, prototype dapp, and
  maintained project documentation.
- Added an explicit experimental/not-independently-audited warning and documented deferred
  functionality without claiming a license that the repository does not currently provide.

### Verification

- Checked every linked repository path and command against the current tree and project
  configuration.
- `git diff --check` passed.

### Follow-Up

- Add licensing terms only after the project owner selects a repository license.

## 2026-08-24 - Unified Upward-Arrow Identity

### Summary

- Added the final supplied hand-drawn upward-arrow artwork as the canonical 1024x1024,
  non-alpha `Resources/AppIcon.png` and configured `stupid-app.yml` to compile it as the
  containing app icon.
- Regenerated the Safari WebExtension's 48px and 128px icons from the same asset, replaced the
  in-page hint's separate CSS glyph with the packaged 48px image, and exposed that image as a
  read-only web-accessible resource.
- Added the same 48px PNG to EIP-6963 provider metadata as a data URI because the MAIN-world
  provider cannot use WebExtension runtime URLs. Its decoded bytes are identical to the
  packaged extension icon.
- Bumped the WebExtension manifest to `0.1.17` for Safari resource-cache invalidation.

### Why

- The app had no configured icon, the extension used placeholder artwork, provider discovery
  announced an empty icon, and the page hint drew an unrelated mark. One generated asset set
  now provides a consistent identity without adding runtime image processing.

### Verification

- Image inspection confirmed 1024x1024, 48x48, and 128x128 PNG outputs with no alpha channel.
- `bunx oxfmt --write <changed extension resources>`,
  `bunx oxlint SafariExtension/Resources/bridge.js SafariExtension/Resources/provider.js`, and
  `node --check` for both changed scripts passed.
- `swift test`: 118 tests in 21 suites passed.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded and
  produced `Assets.car` plus `CFBundleIconName = AppIcon` metadata.
- Source and packaged extension-icon SHA-256 values matched, and the EIP-6963 data URI decoded
  to the same bytes as `icon-48.png`.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and manifest `0.1.17` extension. Simulator screenshots confirmed the final arrow on
  the home-screen app icon, Safari Page Menu extension row, and pending-request page hint. The
  test request was rejected without signing or broadcasting, and the hint disappeared.
- Safari applies its system blue template tint to the monochrome icon in the Page Menu; the
  source files, compiled app icon, and in-page image remain black and white.

### Follow-Up

- None.

## 2026-08-24 - Cleaner In-Page Popup Hint

### Summary

- Replaced the long dark pending-request pill with a compact system-style banner containing
  a small wallet mark, the title `Open Stupid Wallet`, and the instruction
  `Tap the extension in Safari to continue`.
- Kept the banner non-interactive and non-authoritative. It still appears only while a
  canonical request is pending; review and approval remain in Safari's extension popup.
- Made the banner respect the top safe area and narrow viewports, and bumped the WebExtension
  manifest to `0.1.16` so Safari invalidates cached resources.

### Why

- The previous single-line pill was visually heavy, overly wordy, and contained a typo in the
  wallet name. The new hierarchy is shorter and easier to scan without implying that the page
  notice can approve the request.

### Verification

- `bunx oxfmt --write SafariExtension/Resources/bridge.js
  SafariExtension/Resources/manifest.json`,
  `bunx oxlint SafariExtension/Resources/bridge.js`, and
  `node --check SafariExtension/Resources/bridge.js` passed.
- `swift test`: 118 tests in 21 suites passed.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and manifest `0.1.16` extension.
- Simulator Safari/OCR and screenshot inspection confirmed the compact two-line banner rendered
  above the dapp. Opening the real extension popup and rejecting the request removed the banner;
  the request was not signed or broadcast.

### Follow-Up

- None.

## 2026-08-24 - macOS Safari Popup Propagation Resolved

### Summary

- Reproduced the Mac-only state where a canonical pending send existed while the Safari toolbar
  popup displayed no requests.
- Found two enabled `stupid wallet` rows in Safari Settings with the same production extension
  identity but different manifest versions. Disabled only the stale row, kept the current row
  enabled, and restored the current toolbar item through Safari's toolbar customization UI.
- Changed popup `list`, `approve`, and `reject` operations to contact native directly on macOS so
  page status polling cannot block the review surface. The established background-worker route is
  retained as a transport fallback for Safari environments where direct native messaging fails.
- Bumped the WebExtension manifest to `0.1.22` and the Mac diagnostic app/extension build number to
  `3`. Kept `ENABLE_DEBUG_DYLIB: NO` for the compatibility-extension Xcode build.
- Added JavaScript regression coverage for both the direct native list and its background fallback.
- Removed the temporary App Group `handle-diag.log` instrumentation after it proved the boundary.

### Why

- PlugInKit showed one current registration and the running native plugin was current, but Safari
  could still select stale page/popup resources from its duplicate enabled version row. The popup
  also shared the busy MV3 worker used by request-status polling, making its security-critical
  review path unnecessarily dependent on worker responsiveness.

### Verification

- Xcode 26.1.1 Run installed app and extension build `3`; the installed manifest was `0.1.22`, and
  Safari launched the current monolithic extension executable.
- With only the current Safari Settings row enabled, the toolbar popup immediately rendered the
  canonical send card. Native diagnostics recorded `list profile=nil` and a non-empty pending
  result for the same current build. The current pending record contained `intentDigest`.
- Both diagnostic requests were rejected through the popup. No transaction was signed or
  broadcast.
- `node --check SafariExtension/Resources/popup.js` passed; `node --test
  Tests/JavaScript/*.test.mjs` passed 4 tests; `swift test` passed 127 tests in 21 suites.
- `stupid-app doctor` completed with 0 failures and 0 warnings. `stupid-app build` succeeded and
  packaged manifest `0.1.22`. The Xcode 26.1.1 `StupidWallet` Debug build for the Mac compatibility
  destination succeeded; it retained the existing orientation/launch-screen warnings.
- `git diff --check` passed.

### Follow-Up

- Prove a Mac `eth_sendTransaction` approval with system authentication and a network-verified
  receipt. This propagation investigation intentionally stopped before signing.
- Continue the physical-device Safari signing acceptance gate; the background fallback preserves
  the previously proven iOS popup route.

## 2026-08-24 - Safari Rejection Badge Synchronization

### Summary

- Fixed the toolbar badge remaining after a successful popup rejection.
- Added a `popup.didDecide` worker message. A successful direct popup decision now synchronizes the
  decided request ID back to the worker before Safari destroys the popup document.
- Centralized worker badge updates so a zero-size request map clears Safari's badge with an empty
  string instead of setting the visible text `0`.
- Applied the same normalized badge update to preparation, polling cleanup, rejection, resolution,
  expiry, failure, and reject-all paths.
- Bumped the WebExtension manifest to `0.1.23` and the Mac Xcode diagnostic app/extension build to
  `4` to prevent Safari from reusing the faulty resources.

### Why

- macOS popup decisions now reach native directly to avoid worker contention. That intentionally
  bypassed the worker's non-authoritative routing map, but the toolbar badge was still derived from
  that map. The decision completed durably while the stale ID remained counted until later polling.
- Safari treats `"0"` as badge content; clearing requires `""`.

### Verification

- `node --check` passed for `background.js` and `popup.js`; the JavaScript suite passed 5 tests,
  including a deterministic one-request to empty-badge regression.
- Xcode 26.1.1 Run installed manifest `0.1.23`, containing-app build `4`. Safari Settings was
  verified with only the current manifest-version row enabled.
- In Safari Technology Preview, a local prototype connect request changed the toolbar item to
  `1 item`. Rejecting that exact request immediately removed the badge and returned the expected
  EIP-1193 4001 rejection to the page. No request was approved or signed.

### Follow-Up

- The badge remains worker-local routing status rather than an authoritative total of every native
  pending record. If product behavior requires recovery of badge counts after worker suspension,
  derive it from the native list in a separate reviewed change.

## 2026-08-23 - Popup Request Renderer Parity

### Summary

- Reworked the Safari toolbar popup to follow the old app web components' request hierarchy:
  request title and context, two-column site/details summary, request-specific Domain, Message,
  and transaction Details sections, account context, and Connect/Sign/Send/Add action labels.
- Expanded the native display-safe typed-data summary with primary type, domain version and
  chain, and ordered root message fields. The popup still receives no signing authority or
  raw approval params and submits only the persisted request ID.
- Kept transaction review deliberately undecoded: destination, value, a display-only estimated
  Network Fee, and a complete calldata hash plus byte count are shown without simulation or
  ABI/calldata decoding. Nonce, gas limit, gas price, max fee, and priority fee rows are hidden.
  The estimate uses `eth_estimateGas` and the effective fee cap through the shared resolver,
  never mutates canonical params, and reports an explicit unavailable state on RPC failure.
- Removed the generic emoji/card treatment, retained queue ordering, and made failed actions
  restore their original disabled state without allowing structured errors to render as
  `[object Object]`.
- Removed the duplicate in-content wallet header and fixed the active request's Reject and
  primary action footer to the bottom of the popup so long review details scroll behind an
  always-available decision surface.
- Replaced the popup body's fixed 360-point width with a 360-point minimum so request tables
  fill Safari's wider popup viewport with equal side padding.
- Removed the popup approval path's obsolete summary lookup for approval-era network switches,
  avoiding a duplicate fee-estimation round trip before signing. Bumped the WebExtension
  manifest to `0.1.14` for worker/resource cache invalidation.
- Resolved ordinary request and typed-data domain Chain rows through the shared persisted
  `NetworkStore`, showing names such as Ethereum instead of bare IDs. Unknown metadata falls
  back to `Chain N`, while add-network `Chain ID` details remain explicit. Bumped the
  WebExtension manifest to `0.1.15`.
- Documented the display-estimate versus signing-time-resolution boundary in the repository
  debugging skill.

### Verification

- `swift test`: 118 tests in 21 suites passed, including typed-data primary type/domain/message
  summaries and a hermetic network-fee estimate with low-level gas rows absent.
- `bunx oxfmt --write <changed extension resources>`,
  `bunx oxlint SafariExtension/Resources/popup.js`, and
  `node --check SafariExtension/Resources/popup.js` passed.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and manifest `0.1.15` extension.
- Simulator Safari/OCR verified real popup rendering for personal message, typed-data, and
  transaction requests. Domain/message fields and long transaction details scrolled within
  the popup. A long typed-data request kept Reject and Sign at the same bottom position before
  and after scrolling, showed no duplicate in-content wallet header, and rendered its Domain
  table with equal left and right popup padding. Every verification request was rejected
  without signing or broadcasting.
- A live simulator transaction review showed Chain, Network Fee, and destination only; the fee
  was formatted in the active chain's native currency, and nonce/gas/fee-detail rows were
  absent. The request was rejected without signing or broadcasting.
- The simulator transaction popup rendered `Ethereum` for chain 1 instead of the decimal ID;
  the request was rejected without signing or broadcasting. Typed-data regression coverage
  verifies the same name resolution for its domain chain.
- The repository debugging skill passed `quick_validate.py`.
- `git diff --check` passed.

### Follow-Up

- Simulation and ABI/calldata decoding remain deferred by design.

## 2026-08-23 - Stale-While-Revalidate Total Balance

### Summary

- Added an atomic App Group cache for the last successfully aggregated native balance, bound
  to the active account so one account's total is never shown for another.
- Hydrated the cached total when the wallet view model initializes and stopped clearing the
  visible total at the start of a refresh.
- Successful refreshes replace and persist the total. Complete network or store failures keep
  an existing stale total visible; only a wallet without any cached or successful total shows
  Unavailable.
- Account deletion removes the matching cached total, and an in-flight response cannot restore
  state after the active account changes.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test`: 118 tests in 21 suites passed, including account binding, case-insensitive
  lookup, mismatch rejection, persistence, and removal for the balance cache.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- A successful simulator refresh created the App Group balance-cache file. An immediate app
  terminate and relaunch exposed the formatted total balance instead of a progress indicator
  while revalidation ran.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-23 - Account Menu Navigation Consolidation

### Summary

- Removed the standalone Settings cog and added a Settings item to the account menu.
- Moved Connected Apps out of the Settings list and added it directly to the account menu.
- Added familiar icons to Copy Address, Activity, Connected Apps, and Settings.
- Preserved Settings as a sheet and Connected Apps as a direct navigation push.

### Verification

- `swift format --in-place Sources/StupidWallet/ContentView.swift
  Sources/StupidWallet/SettingsView.swift` completed.
- `swift test`: 117 tests in 21 suites passed.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- Simulator accessibility inspection found Copy Address, Activity, Connected Apps, and Settings
  in the account menu. Settings opened as a sheet containing Networks, Private Key, and Forget
  Account, with no duplicate Connected Apps row.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-23 - Activity Moved Into Account Menu

### Summary

- Moved the account blockie from the leading toolbar position into the former trailing
  Activity-button position beside Settings.
- Removed the standalone Activity clock button and added Activity to the account menu while
  retaining Copy Address and its shortened address subtitle.
- Preserved Activity as a navigation push rather than changing its presentation.

### Verification

- `swift format --in-place Sources/StupidWallet/ContentView.swift` completed.
- `swift test`: 117 tests in 21 suites passed.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- Simulator accessibility inspection found the account button at the former trailing Activity
  position and no standalone clock button. Opening the account menu exposed Copy Address and
  Activity; selecting Activity pushed the existing activity list.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-23 - Legacy Wallet Reinstalled On iPhone

### Summary

- Reinstalled and launched the previously validated legacy wallet build on the paired
  physical iPhone under the production app and Safari extension bundle identities.
- Installed in place rather than uninstalling first so the production App Group and
  keychain state remain available for upgrade and migration testing.

### Verification

- Verified the legacy app and nested Safari extension signatures, production bundle IDs,
  App Group and keychain entitlements, unexpired development profile, and target-device
  provisioning before installation.
- `xcrun devicectl device install app --device <paired-device> <legacy-app>` acquired the
  device tunnel and reported the production app bundle installed successfully.
- `xcrun devicectl device process launch --device <paired-device> --terminate-existing
  co.za.stephancill.stupid-wallet` launched the installed legacy app successfully.

### Follow-Up

- A future rebuild migration test can upgrade this installation in place without first
  deleting the legacy app.

## 2026-08-23 - Signing-Time Transaction Nonce And Gas Resolution

### Summary

- Changed `eth_sendTransaction` preparation to persist only normalized, validated dapp intent.
  Missing nonce, gas limit, and legacy or EIP-1559 fee values are now fetched through the
  active shared RPC resolver immediately before authenticated signing.
- Kept the original params and payload digest immutable. Resolved signing params are stored
  separately on the terminal pending record and drive serialization and activity nonce
  persistence. Explicit dapp-provided nonce and gas caps remain unchanged.
- Changed transaction summaries to identify unresolved fields as latest, estimated, or
  resolved at signing rather than displaying a stale snapshot.
- Added a regression that prepares two sends before either is approved and proves their
  approvals fetch consecutive pending nonces after the first broadcast.

### Why

- Preparing requests in quick succession previously fetched the same pending nonce for each
  canonical record. Approving the first advanced the account nonce, so approving the second
  broadcast a stale nonce and failed with `nonce too low`.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test`: 117 tests in 21 suites passed.
- The repository debugging skill passed `quick_validate.py` after documenting the
  `resolvedParams` diagnosis path.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build`
  succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and
  launched the app and Safari extension. The containing app remained running after launch.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` signed the app and
  nested extension, packaged the IPA, installed it over the saved network pairing, and
  launched the containing app on the physical iPhone.

### Follow-Up

- Repeat a quick-successive-send flow against a live dapp/RPC on the simulator or physical
  device before treating network behavior as independently proven.

## 2026-08-23 - Persisted Networks And Aggregate Balance

### Summary

- Added shared, locked `NetworkStore` persistence. Successful
  `wallet_switchEthereumChain` calls now make their target visible in Settings; chain 137 is
  recognized as Polygon, while unknown switched chains receive a generic decimal name.
- Confirmed `wallet_addEthereumChain` requests persist their chain ID and supplied name
  without turning dapp RPC suggestions into user overrides.
- Added Default Networks and Custom Networks sections, a separate Add... action, and a manual
  network form for name, decimal/hex chain ID, and RPC URL. Manual RPC endpoints must pass
  HTTPS, reachability, and exact `eth_chainId` validation before persistence.
- Restored the per-network Include in Total Balance toggle. Existing `customChains` names and
  `excludedFromBalance` choices are read from the production App Group, and inclusion changes
  continue to mirror the old preference key for upgrade continuity.
- Changed the home balance to fetch every included network concurrently and add full-width wei
  quantities without a BigInt dependency. Network metadata and the total refresh when the app
  returns to the foreground, and the total also refreshes after Settings closes.
- Expanded balance details now retain and display one named row per included network from the
  same RPC results used to calculate the aggregate. Zero and unavailable balances are omitted;
  if no non-zero rows remain, the chevron is hidden and the balance control is disabled.
- Extended the wagmi fixture with Polygon so the direct switch path can be exercised against
  chain 137.

### Why

- Active-chain persistence alone made switched networks usable but invisible to users. One
  shared metadata store now drives dapp additions, manual additions, Settings, activity names,
  and aggregate-balance selection without accepting untrusted RPC preferences.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test`: 116 tests in 21 suites passed. Regressions cover direct Polygon switching and
  visibility, legacy network/include import, manual metadata persistence, include mirroring,
  ordered per-network results, and full-width aggregation across two RPC responses.
- `PrototypeDapp`: `bunx oxfmt --write src/App.tsx src/wagmi.ts`, `bunx oxlint .`, and
  `bun run build` passed with Polygon in the configured chain set.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and extension. The Add... sheet exposed name, decimal/hex chain ID, and RPC URL
  fields, and Polygon details exposed chain ID 137, the Include toggle, and the shared default
  RPC endpoint. The home balance detail reported five included networks after Polygon was
  added, with separate Ethereum, Base, Arbitrum One, Optimism, and Polygon balance rows.
- Simulator verification with all five balances at zero showed no chevron, no popover, and an
  accessibility-disabled balance button. Unit coverage also distinguishes non-zero, zero, and
  unavailable native balance results.
- The connected wagmi fixture switched directly from Base to Polygon with no popup or
  authentication, reported chain 137, and Settings then listed Polygon under Custom Networks.
- `git diff --check` passed.

### Follow-Up

- Repeat network-addition visibility and aggregate-balance behavior on the physical device as
  part of the broader Gate 6 acceptance pass.

## 2026-08-23 - Immediate Authorized Network Switching

### Summary

- Removed `wallet_switchEthereumChain` from the Safari popup approval queue. A connected
  origin now receives an immediate native switch with no popup or biometric authentication.
- Native code remains authoritative: it requires the active wallet and exact origin/profile
  grant, validates standard `[chainObject].chainId` params, serializes persistence under the
  global switch lock, and returns `null` before the worker broadcasts `chainChanged`.
- `wallet_addEthereumChain` remains confirmation-based and dapp-supplied RPC URLs still never
  replace user preferences.
- Native preparation rejects new switch requests so a stale or modified worker cannot put
  them back into the approval queue. Recovery support remains for switch records persisted by
  older installed workers.
- Bumped the WebExtension manifest to `0.1.10` to invalidate Safari's cached worker.
- Updated the wagmi fixture's network control to toggle between Ethereum and Base and its
  busy copy to avoid claiming that every wallet response requires popup approval.

### Why

- The product owner chose immediate switching for already-connected sites; changing active
  chain state does not require private-key access or device-owner authentication.

### Verification

- `swift format --in-place <changed Swift files>` and
  `bunx oxfmt --write SafariExtension/Resources/background.js SafariExtension/Resources/manifest.json`
  completed.
- `swift test`: 114 tests in 21 suites passed, including immediate persistence,
  authorization/revocation, malformed params, no pending switch record, stale prepare
  rejection, stale approval invalidation, and approval-era journal recovery.
- `bunx oxlint SafariExtension/Resources/background.js` and
  `node --check SafariExtension/Resources/background.js` passed.
- `PrototypeDapp`: `bunx oxfmt --write src/App.tsx`, `bunx oxlint .`, and `bun run build`
  passed after correcting the toggle target to retain wagmi's `1 | 8453` chain-ID type.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and manifest `0.1.10` Safari extension.
- The connected wagmi fixture switched Base -> Ethereum -> Base immediately. Its displayed
  chain changed from 8453 -> 1 -> 8453, the button target toggled accordingly, no popup or
  authentication appeared, and no switch pending record was created. Reload retained the
  connected account on chain 8453.
- The repository debugging skill passed `quick_validate.py` after recording the iOS 26
  compact-toolbar Page Menu location used to open the extension popup.
- `stupid-app run --network --udid <device> --sudo /usr/bin/sudo` signed, installed, and
  launched the final current app and nested manifest `0.1.10` extension on the paired iPhone.
- `git diff --check` passed.

### Follow-Up

- Repeat on the physical iPhone before closing the Gate 6 device acceptance work.

## 2026-08-23 - Current Build Installed On iPhone

### Summary

- Built, development-signed, installed, and launched the current app and nested Safari
  extension on the paired physical iPhone over the saved network connection.

### Verification

- `stupid-app doctor` completed with 0 failures and 0 warnings.
- `stupid-app device list` found the saved network pairing.
- `stupid-app run --network --udid <device> --sudo /usr/bin/sudo` signed the app and nested
  extension, packaged the IPA, installed it, and launched the production app bundle.

### Follow-Up

- Exercise the physical-device Gate 6 checklist, especially the modal Forget Account flow
  with a securely backed-up throwaway account.

## 2026-08-23 - Muted Read-Only RPC URL

### Summary

- Changed the effective RPC URL text on network details to the secondary foreground style.
- The separate Change action remains the only way to edit the endpoint.

### Why

- Muted text makes the displayed endpoint read as a non-editable value rather than an input.

### Verification

- `swift format --in-place Sources/StupidWallet/NetworksView.swift` completed.
- `swift test`: 113 tests in 21 suites passed.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- Simulator visual inspection of Base network details confirmed that the endpoint text uses
  the muted secondary color while Change remains a blue action.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-23 - Modal Forget Account Confirmation

### Summary

- Replaced the adaptive Forget Account confirmation dialog with a modal SwiftUI alert.
- The destructive confirmation, cancellation, warning text, and deletion behavior are
  otherwise unchanged.

### Why

- `confirmationDialog` adapted to a popover presentation in the tested environment. Account
  deletion requires an explicitly modal confirmation surface.

### Verification

- `swift format --in-place Sources/StupidWallet/SettingsView.swift` completed.
- `swift test`: 113 tests in 21 suites passed.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- Simulator accessibility inspection confirmed a centered modal alert containing the title,
  warning, destructive Forget Account action, and Cancel action. Cancel dismissed it without
  modifying the funded simulator wallet.

### Follow-Up

- Physical-device verification remains part of the Gate 6 acceptance pass.

## 2026-08-23 - Confirmed Forget Account Flow

### Summary

- Added a separate destructive Settings section containing Forget Account and a native
  confirmation dialog warning that the private key will be removed.
- Confirming removes the expected active new-format keychain item and shared account
  registration, clears matching retained migration material so the account is not
  automatically restored on relaunch, and revokes that account's legacy and normalized
  connected-site grants.
- The operation restores the active-account registration if keychain deletion fails and
  rejects stale account mismatches. Activity history and network preferences remain.
- Successful deletion dismisses Settings and returns the app to its setup screen; failures
  remain visible and produce an actionable alert.

### Why

- Simulator reprovisioning and user-directed account removal need an in-app path that does
  not leave the protected key behind or create a partial wallet registration.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test`: 113 tests in 21 suites passed, including account-bound registration removal
  and account-scoped grant revocation regressions.
- `stupid-app doctor`: 0 failures and 0 warnings. `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension. Accessibility inspection confirmed the separate destructive
  section and confirmation dialog.
- A disposable simulator completed create -> Settings -> Forget Account -> confirm and
  returned to setup. A metadata-only keychain query reported zero items under the wallet's
  new-format key service afterward. The disposable simulator was then deleted; the funded
  preferred simulator wallet was not modified.
- `git diff --check` passed.

### Follow-Up

- Repeat account forgetting on a physical device as part of the Gate 6 provisioning and
  keychain lifecycle acceptance pass.

## 2026-08-23 - Long-Press Transaction Hash Copy

### Summary

- Removed the persistent copy icon from the transaction hash row in Activity details.
- Long-pressing the hash now opens the compact system edit menu with a Copy action, without
  selecting the text or showing a context-menu preview.
- Recorded the reliable simulator held-touch command in the repository debugging skill;
  the existing simulator helper's long-press option performs only a tap plus host delay.

### Why

- Keeps the detail row visually quiet while preserving full-hash copying through the same
  compact menu treatment used by text selection, without exposing selection handles.

### Verification

- `swift format --in-place Sources/StupidWallet/ActivityView.swift` completed.
- `swift test`: 111 tests in 21 suites passed.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and
  launched the app and Safari extension.
- Simulator visual/OCR inspection confirmed the hash row had no inline copy icon and an
  actual held touch opened the compact Copy edit menu without text selection or a context
  preview. Selecting Copy placed a complete 32-byte transaction hash on the simulator
  clipboard.
- The first iOS-target build exposed an `NSObject` property-name collision and missing Swift
  actor metadata on the Objective-C edit-menu delegate. Renaming the stored value and using
  an explicit pre-concurrency delegate conformance resolved both; the final build succeeded.

### Follow-Up

- None.

## 2026-08-23 - Activity Detail Number Formatting

### Summary

- Changed transaction hashes in Activity details from monospaced to the regular system
  body font.
- Converted persisted hexadecimal RPC block quantities to decimal integers for display.

### Why

- Activity details should use ordinary readable typography and present block heights as
  familiar decimal numbers rather than JSON-RPC quantities.

### Verification

- `swift format --in-place Sources/StupidWallet/ActivityView.swift` completed.
- `swift test`: 111 tests in 21 suites passed.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and
  launched the app and Safari extension.
- Simulator visual/OCR inspection confirmed the transaction hash used the regular system
  font and a confirmed transaction's hexadecimal RPC block quantity rendered as a decimal
  integer.

### Follow-Up

- Activity persistence continues to retain the node's original block-number string.

## 2026-08-23 - Anchored Balance Details Popover

### Summary

- Replaced the balance disclosure menu with an anchored popover that opens beneath the
  balance button.
- The balance button remains visible while its selected-chain balance detail is shown.
- The detail uses the regular system body font rather than monospaced text.

### Why

- The system toolbar-style menu expanded in place and visually replaced the large balance
  control instead of presenting its detail below it.

### Verification

- `swift format --in-place Sources/StupidWallet/ContentView.swift` completed.
- `swift test`: 111 tests in 21 suites passed.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and
  launched the app and Safari extension.
- Simulator visual/OCR inspection confirmed the large balance button remained visible,
  its chevron changed direction, and the selected-chain balance detail appeared in a
  separate anchored popover directly beneath it.

### Follow-Up

- None.

## 2026-08-23 - Home Address Menu

### Summary

- Moved the wallet address affordance from beneath the centered balance to a top-leading
  account blockie.
- Pressing the blockie now opens a native menu containing a Copy Address action with the
  shortened wallet address as a native secondary subtitle; the action copies the full
  address.
- Rendered the toolbar blockie at its actual 28-point control size so the UIKit menu button
  does not clip its top and bottom edges.

### Why

- Keeps the balance screen focused on the selected chain balance while retaining quick
  access to the wallet address.

### Verification

- `swift format --in-place Sources/StupidWallet/ContentView.swift` completed.
- `swift test`: 111 tests in 21 suites passed.
- `stupid-app doctor`: 0 failures and 0 warnings. `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and
  launched the app and Safari extension.
- Simulator visual/OCR inspection confirmed the centered address was absent, the
  top-leading blockie rendered without edge clipping, and pressing it exposed the Copy
  Address action with a shortened native secondary subtitle. Selecting it copied a valid
  20-byte Ethereum address to the simulator clipboard.

### Follow-Up

- None.

## 2026-08-23 - Single RPC Endpoint Network UI

### Summary

- Removed the misleading multi-RPC list and Add RPC URL action from network details.
- Each chain now displays exactly one effective RPC URL. The user can replace it through a
  Change RPC URL sheet or restore the Stupidtech default when an override is active.
- The endpoint uses the standard system body font rather than monospaced text.
- The RPC section uses a plain Change action with no icon or explanatory footer.
- Kept the existing one-value-per-chain persistence, chain-ID validation, HTTPS policy, and
  shared app/extension resolver unchanged.

### Verification

- `swift format --in-place Sources/StupidWallet/NetworksView.swift` completed.
- `swift test`: 111 tests in 21 suites passed.
- `stupid-app doctor`: 0 failures and 0 warnings. `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- Simulator accessibility inspection of Base network details exposed only the Chain ID and
  Change RPC URL actions; Add RPC URL and multi-endpoint controls were absent.

### Follow-Up

- None.

## 2026-08-23 - Normalized And Safari-Profile-Bound Grants

### Summary

- Added a V2 connected-site grant store keyed by normalized scheme, hostname, effective
  port, and Safari profile identifier when native Safari supplies `SFExtensionProfileKey`.
- New grants also mirror the legacy hostname-only `connectedSites` dictionary so the old app
  can continue reading and disconnecting sites.
- Bound canonical pending requests to the native Safari profile. Pending list, summary,
  status, approval, and rejection operations filter or reject across profile boundaries;
  profile identity never comes from page JavaScript.
- Implemented the product owner's compatibility choice: pre-existing hostname-only grants
  remain authorized. Once a domain reconnects and receives any V2 grant, authorization for
  that domain requires an exact normalized origin/profile match and no longer falls back to
  the mirrored hostname entry.
- Updated Connected Apps disconnection to remove the selected normalized profile/origin
  grant while preserving the old screen presentation.

### Verification

- Added regressions proving scheme/port separation, Safari-profile separation, cross-profile
  approval rejection, normalized reconnect behavior, and continued legacy authorization.
- `swift test`: 111 tests in 21 suites passed.
- `stupid-app doctor`: 0 failures and 0 warnings. `stupid-app build` succeeded.
- `git diff --check` passed.

### Follow-Up

- Verify the concrete runtime type and stability of `SFExtensionProfileKey` on physical
  iOS 17+ devices and exercise two Safari profiles end to end.
- The retained hostname fallback is intentionally weaker. Removing it requires a later
  product decision and user-visible reconnect path.

## 2026-08-23 - BIP-39 Seed Import And Verified Provisioning

### Summary

- Implemented English BIP-39 vocabulary/checksum validation, NFKD normalization,
  PBKDF2-HMAC-SHA512 seed derivation, and BIP-32 private derivation for the old app's first
  Ethereum account path, `m/44'/60'/0'/0/0`.
- Added compressed public-key serialization and private-key tweak-add through the existing
  vendored libsecp256k1 target. No BigInt, CryptoSwift, Dawn, MnemonicSwift runtime package,
  or general wallet SDK was added.
- Vendored only MnemonicSwift 2.2.5's BIP-39 English vocabulary with retained copyright and
  MIT provenance in `THIRD_PARTY_NOTICES.md`; all validation and derivation code is
  project-owned.
- Wired seed phrases into the old-app-compatible import screen and added specific word-count,
  unknown-word, checksum, and derivation errors.
- Unified create, raw-key import, and seed import provisioning. A new key is saved under
  `.userPresence`, authenticated back out with a fresh context, used for a sign-and-recover
  self-test, and only then registered in the App Group. Failure or cancellation removes the
  newly saved key. App Group registration is now throwing instead of silently ignoring a
  failed write.
- Updated migration saving to use the same loud App Group registration behavior and remove
  a newly saved key if registration fails.

### Verification

- The standard Hardhat mnemonic derived private key
  `ac0974...ff80` and first address `0xf39F...2266`, matching independent ecosystem vectors.
- Regression coverage rejects an unknown BIP-39 word and a valid-vocabulary phrase with an
  invalid checksum.
- `swift test`: 109 tests in 21 suites passed.
- `stupid-app build` succeeded, and
  `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- `git diff --check` passed.

### Follow-Up

- Prove create, private-key import, seed import, cancellation rollback, backup, and Safari
  signing on a physical device. Hermetic tests do not prove LocalAuthentication/keychain
  lifecycle behavior.
- Complete the normalized origin + effective port + Safari profile grant migration without
  breaking the legacy hostname store.

## 2026-08-23 - Gate 6 Old-App Screen Parity And Wallet Settings

### Summary

- Replaced the diagnostic containing-app shell with the shipped app's Gate 6 SwiftUI screen
  hierarchy and presentation: welcome, import, wallet home, Settings, Connected Apps,
  Networks/RPC editor, authenticated Private Key reveal, Activity, and activity details.
- Restored the old home treatment including the large diamond-prefixed balance, disclosure
  menu, deterministic address blockie, shortened copyable address, and clock/gear toolbar.
- Added strict raw private-key import, operation-specific authenticated private-key export,
  selected-chain native balance reads, full-width quantity formatting, and atomic persisted
  RPC overrides shared by the app and Safari extension.
- RPC overrides are validated for transport security, reachability, and exact chain identity
  before persistence. Backup plaintext is privacy-sensitive and clears after 60 seconds,
  when the scene becomes inactive, or when the view disappears; pasteboard copies are local
  and expire.
- The containing app now attempts the already-proven old-format migration only when old
  material exists and no active new-format wallet is registered. Fixed the production
  migration backend's new-wallet check to include the shared WalletStore file.
- Preserved the new privacy and RPC boundaries instead of copying old behavior: the home
  shows only the selected chain's native balance, signature activity stays redacted, and
  dapp RPC suggestions are not silently saved.

### Verification

- `swift format --in-place --recursive Sources Tests` completed.
- `swift test`: 107 tests in 20 suites passed, including new persisted-RPC and full-width
  native-balance formatting coverage.
- `stupid-app doctor`: 0 failures and 0 warnings. `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  the app and Safari extension.
- Simulator accessibility inspection confirmed the wallet home toolbar/address, Settings
  actions, and the Networks list containing Ethereum, Base, Arbitrum One, and Optimism.

### Follow-Up

- BIP-39 seed-phrase import and BIP-32 derivation are still unimplemented; the matching old
  import screen currently reports this limitation rather than accepting an unvalidated
  phrase.
- Complete authenticated provisioning verification/rollback and physical-device tests for
  create, raw import, backup reveal/cancellation/timeout, and automatic migration launch.
- Migrate hostname-only legacy grants to normalized scheme + effective port + Safari profile
  identity without breaking installed-wallet compatibility.
- Reviewed wallet deletion/logout, custom chain metadata, ENS/avatar resolution, aggregate
  balances, and richer activity details remain later work.

## 2026-08-23 - SQLite Activity And Base Receipt Polling

### Summary

- Added `ActivityStore`, extending the existing shared App Group `Activity.sqlite` schema
  in place so installed transaction and signature history remains readable.
- Transaction activity binds the canonical request, chain, account, origin, nonce, and
  returned hash. Receipt refresh uses the shared RPC resolver and persists submitted,
  pending, confirmed, reverted, dropped, and replaced lifecycle states.
- Missing transactions remain non-terminal during a propagation grace period. Afterward,
  the latest account nonce distinguishes a dropped broadcast from a replacement.
- Signature activity stores only a digest plus request metadata; new rows do not persist
  plaintext messages or signatures.
- Added a minimal app activity list with cancellable foreground polling and explicit refresh.

### Verification

- `swift test`: 105 tests in 19 suites passed, including SQLite reopen, unified transaction
  and signature reads, broadcast binding, receipt confirmation, and dropped/replaced
  classification.
- `stupid-app doctor`: 0 failures and 0 warnings. `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` installed and launched the app
  and extension.
- A funded Base simulator wallet completed a zero-value self-transfer through the dapp,
  canonical Safari popup, authenticated signer, and broadcast path. The dapp received the
  same hash persisted in SQLite. Configured and independent RPCs both returned receipt
  status `0x1`; recovered sender and destination matched the simulator wallet and gas used
  was 21,000.
- Relaunching the app and selecting Refresh moved the durable row from `submitted` to
  `confirmed`, persisted the block number, and visibly rendered the confirmed Base activity.

### Follow-Up

- Continue Gate 6 with wallet import/backup, balance and RPC-override screens, and the
  connected-apps list/disconnect UI.
- Add richer activity details after the core wallet-management screens.

## 2026-08-23 - Repository-Wide Debugging Skill

### Summary

- Added `skills/stupid-wallet-debugging/SKILL.md`, an evidence-first workflow covering the
  dapp/provider, isolated bridge, background worker, toolbar popup, native extension
  handler, WalletCore, App Group state, keychain authentication, RPC routing, signing,
  broadcast, and independent chain verification.
- Added project `opencode.json` registration for the root `skills/` directory so OpenCode
  discovers the repository skill after restart.
- Added an `AGENTS.md` requirement to read the skill for relevant investigations and to
  update it whenever debugging reveals a reusable command, failure signature, stack
  boundary, simulator interaction, or safety rule.
- The skill records known operational sharp edges without exposing user-linked wallet
  activity: Safari worker caching, exact passthrough method casing, durable request-state
  interpretation, popup scrolling, multi-request dapp flows, structured errors, EIP-712
  width handling, and safe on-chain verification.

### Verification

- The skill creator's `quick_validate.py` reported `Skill is valid!`.
- `git diff --check` passed and no generated placeholder resources remain.

### Follow-Up

- Keep the skill current as the app gains activity storage, receipt polling, additional
  wallet methods, and macOS Safari support.

## 2026-08-23 - Permit2 Typed-Data And Popup Error Fix

### Summary

- Investigated `[object Object]` appearing above Uniswap's Permit2 approval card. The
  popup stringified a structured native error instead of reading its `message` property.
- The preceding on-chain token allowance transaction had succeeded; the subsequent
  Permit2 `eth_signTypedData_v4` request failed because EIP-712 integer parsing converted
  values through host `Int`. Permit2 uses maximum `uint160` allowance plus `uint48` fields.
- Added full-width unsigned decimal/hex parsing into 32-byte EIP-712 words with declared
  width enforcement, fixed popup error-message extraction, and bumped the extension
  manifest to `0.1.9`.

### Verification

- A Permit2 digest vector with maximum `uint160` and `uint48` values matches viem
  byte-for-byte.
- `swift format` and `oxfmt` completed; `oxlint` and `node --check` passed.
- `swift test`: 100 tests in 18 suites passed.
- `stupid-app run --simulator --udid <preferred-simulator>` installed and launched the
  `0.1.9` extension.

### Follow-Up

- The user redirected the session to documentation work before the post-fix live
  USDC-to-ETH Permit2 approval could be retried. Complete that simulator verification
  before claiming the reverse swap works end to end.

## 2026-08-23 - Permit2 Typed Data Fix And Reverse Swap

### Summary

- Reproduced `[object Object]` above a Uniswap Permit2 approval card. The popup stringified
  a structured native error instead of reading its `message`; it now displays structured
  errors correctly.
- The underlying `eth_signTypedData_v4` request failed because EIP-712 integer parsing used
  host `Int`. Permit2 supplied a maximum `uint160` allowance plus `uint48` expiration and
  nonce fields. Unsigned integers now parse decimal or hex into 32-byte values and reject
  values outside the declared `uintN` width.
- Bumped the extension manifest to `0.1.9`, completed the authorized Permit2 signature, and
  completed a small USDC-to-ETH swap on Base.

### Verification

- Pinned the exact Permit2 digest against viem `hashTypedData`; the new `uint160`/`uint48`
  vector passed.
- Added a service-level regression proving the standard `[address, jsonString]` Permit2
  request signs and reaches `consumed`.
- `swift test`: 101 tests in 18 suites passed.
- Extension `oxfmt`, `oxlint`, and `node --check` passed.
- `stupid-app run --simulator --udid <preferred-simulator>` installed and launched the
  `0.1.9` extension. The live popup signed Permit2 without an error toast, then reviewed
  and broadcast the swap transaction.
- The first broadcast returned a hash but was absent from the configured and independent
  Base nodes; latest and pending nonces were equal, proving it had not propagated. A fresh
  canonical replacement used the same nonce and mined successfully. The receipt status was
  `0x1`, transfer logs showed the exact authorized USDC input, and balances reflected the
  expected token decrease and native output net of gas.

### Follow-Up

- Durable activity and receipt polling should distinguish a returned broadcast hash from
  observed network propagation and surface dropped transactions instead of treating the
  immediate RPC response as final lifecycle success.

## 2026-08-22 - Uniswap Passthrough Casing Fix And Live Swap

### Summary

- Superseded the earlier cache-only diagnosis. Repeated Uniswap attempts showed that the
  failure was deterministic when the app needed a fresh `eth_blockNumber` read: the
  background worker lowercased the method for classification and forwarded
  `eth_blocknumber` to the case-sensitive Base RPC.
- Changed generic passthrough to forward the page's original method spelling unchanged.
  Wallet-owned classification remains case-insensitive. Bumped the WebExtension manifest
  to `0.1.8` to ensure Safari loads the corrected worker, and removed all temporary
  diagnostics.
- Executed the authorized small ETH-to-USDC Base swap through Uniswap, canonical popup
  review, authenticated key release, raw transaction broadcast, and dapp completion.

### Verification

- Before the fix, live diagnostics showed `eth_blockNumber` returning an upstream error
  and Uniswap never called a send method or created a pending record.
- `oxfmt`, `oxlint`, and `node --check` passed for the extension resources.
- `swift test`: 99 tests in 17 suites passed.
- `stupid-app run --simulator --udid <preferred-simulator>` installed and launched the
  corrected `0.1.8` extension.
- The same Base ETH/USDC URL and input immediately created a canonical type-2 transaction.
  Approval consumed the request and returned a transaction hash. Independent Base RPC
  checks confirmed the expected sender and native value, receipt status `0x1`, and a USDC
  transfer of approximately the quoted output to the simulator wallet.

### Follow-Up

- Add a dependency-free JavaScript routing test harness so exact method preservation is
  covered automatically; the current live Uniswap regression and syntax/lint checks cover
  this fix operationally.
- `wallet_requestPermissions` and `wallet_getCapabilities` remain unsupported probes and
  pass through unchanged. Uniswap tolerates their errors and uses `eth_sendTransaction`.

## 2026-08-22 - Uniswap Base Swap Worker Cache Invalidation

### Summary

- Reproduced an immediate Uniswap ETH-to-USDC swap failure on Base. The failing attempt
  created no native pending request, so it failed before canonical review, signing, or
  broadcast.
- Reopened the swap with Base ETH and USDC selected through URL parameters and captured
  the provider behavior without retaining request data. Uniswap's actual swap request was
  a standard EIP-1559 `eth_sendTransaction` already supported by the current native core.
- A fresh install under a new WebExtension manifest version made the same amount and
  transaction reach the canonical Safari popup immediately. Bumped the final manifest to
  `0.1.5` so Safari invalidates the stale `0.1.3` service worker; temporary diagnostics
  were removed before the final build.

### Verification

- `swift test`: 99 tests in 17 suites passed.
- Extension resources: `oxfmt`, `oxlint`, and `node --check` passed with no
  warnings or errors.
- `stupid-app doctor`: 0 failures and 0 warnings.
- `stupid-app run --simulator --udid <preferred-simulator>` installed and launched the
  versioned extension.
- Simulator Safari loaded
  `https://app.uniswap.org/swap?chain=base&inputCurrency=NATIVE&outputCurrency=<base-usdc>`;
  entering `0.0001` ETH and confirming Uniswap's review created a canonical Base send
  request and displayed the native transaction popup. The request was cancelled rather
  than approved, so verification spent no funds.

### Follow-Up

- Uniswap also probes `wallet_requestPermissions` and `wallet_getCapabilities`; these are
  not required for its ordinary `eth_sendTransaction` fallback and remain outside the
  currently handled method subset. Add them only with reviewed EIP-2255/EIP-5792 behavior,
  not as dapp-specific stubs.

## 2026-08-22 - Persisted Active Chain And Approved Switching

### Summary

- Added `ChainStore`, which persists the normalized decimal active chain in the shared App
  Group and defaults only a genuinely missing first-run file to mainnet. Malformed or
  unavailable persistence fails loudly.
- Native state now authoritatively answers `eth_chainId`/`net_version` and selects the chain
  for prepare and passthrough; JavaScript-supplied chain metadata is ignored.
- Approved `wallet_switchEthereumChain` persists its target, while
  `wallet_addEthereumChain` remains consent-only. Chain changes require a connected origin
  at both preparation and approval.
- Added stale-request rejection (`4901`), a global advisory switch lock, and a write-ahead
  journal that recovers the previous or target chain from durable request consumption after
  interruption. This prevents readers from observing an uncommitted switch.
- Added canonical cross-tab `chainChanged` delivery, initial provider bootstrap from native
  state, and recovery-time rebroadcast. The provider no longer announces a guessed chain.
- Restored the wagmi fixture to mainnet + Base and bumped the extension manifest to `0.1.3`.

### Verification

- `swift test`: 99 tests in 17 suites passed, including persistence/normalization,
  add-versus-switch semantics, unauthorized preparation, authorization revocation before
  approval, stale queued requests, switch journal recovery, and lock exclusion.
- `PrototypeDapp`: `oxlint` and `bun run build` passed; extension `oxfmt`, `oxlint`, and
  `node --check` passed.
- `stupid-app doctor`: 0 failures and 0 warnings.
- `stupid-app run --simulator --udid <preferred-simulator>` installed and launched the app
  and manifest `0.1.3` extension.
- Simulator Safari started the connected dapp on chain 1, rendered a canonical Ethereum
  “Switch network” popup for Base, approved without key access, updated wagmi to chain 8453,
  and persisted decimal `8453` in the shared App Group.
- After Safari reload, reconnect used the existing grant and reported chain 8453, confirming
  extension restart/bootstrap reads native persisted state rather than a worker constant.

### Follow-Up

- Add SQLite transaction activity and receipt polling.
- The legacy hostname-only grant remains a locked compatibility limitation: it does not yet
  separate scheme, effective port, or Safari profile for chain-change authorization.

## 2026-08-22 - Live Base Transaction Accepted

### Summary

- Temporarily switched the injected provider and wagmi fixture from hardcoded mainnet to
  Base (`8453` / `0x2105`) for a funded simulator send proof; bumped the WebExtension
  manifest to `0.1.2` to invalidate stale worker state.
- Changed the dapp transaction to a zero-value self-transfer and removed its deterministic
  nonce, gas, and gas-price fields so native RPC preparation supplied all three.
- Completed the full simulator flow through Safari popup review and keychain-backed signing.
  The wallet broadcast the signed transaction and the dapp resolved to the node-returned
  transaction hash.

### Verification

- Base RPC showed the simulator test account had sufficient native ETH before the test.
- `swift test`: 91 tests in 16 suites passed.
- `PrototypeDapp`: `oxfmt`, `oxlint`, and `bun run build` passed.
- Extension resources: `oxfmt`, `oxlint`, and `node --check` passed.
- `stupid-app run --simulator --udid <preferred-simulator>` assembled, installed, and
  launched the Base-configured app and extension.
- The native pending record contained canonical Base fields populated by RPC preparation:
  nonce `0x0`, gas limit `0x5208`, and a node-provided legacy gas price. The popup displayed
  Base, the self-transfer destination, nonce, gas limit, and gas price before approval.
- `cast tx <tx-hash> --rpc-url https://evm.stupidtech.net/v1/8453 --json` confirmed chain
  `0x2105`, zero value, empty calldata, the expected recovered simulator signer, and the
  returned hash.
- `cast receipt <tx-hash> --rpc-url https://evm.stupidtech.net/v1/8453 --json` returned
  status `0x1` and gas used `0x5208` (21,000).

### Follow-Up

- Replace the temporary Base compile-time constant with persisted active-chain state and
  make approved chain switches update it.
- Add SQLite transaction activity and receipt polling now that the live receipt path is
  proven. Physical-device broadcasting remains a separate optional verification.

## 2026-08-22 - Gate 6 Transaction Preparation And Broadcast

### Summary

- Added canonical `eth_sendTransaction` preparation through the shared RPC resolver:
  missing nonce, gas limit, and legacy or EIP-1559 fees are fetched before the pending
  request is persisted and bound.
- Added complete signed legacy and type-2 serialization. Approval now submits the raw
  transaction through `eth_sendRawTransaction` and returns the node's 32-byte transaction
  hash instead of returning signature bytes.
- Corrected the EIP-1559 signing preimage to contain the nine unsigned fields only. The
  previous implementation incorrectly appended empty `yParity`, `r`, and `s` fields.
- Added nonce, gas limit, and fee rows to the canonical popup summary. Malformed or
  account/chain-mismatched transactions fail before persistence.
- Added durable terminal failure state and structured error persistence so a node or
  transport submission failure reaches the polling dapp instead of leaving it pending.
- Added cross-process advisory locking for approve/reject, signer-to-record account
  revalidation, approval-time semantic revalidation, strict supported-field and alias
  handling, explicit contract-creation review text, and returned-hash verification.
- Structured RPC error data is preserved through immediate preparation failures and
  persisted broadcast failures; expired requests now terminate browser polling.
- Removed unused worker bindings surfaced by JavaScript linting.

### Why

- Gate 6 requires `eth_sendTransaction` to prepare, sign, broadcast, and return a
  transaction hash through the same resolver used by generic RPC traffic. Preparation
  must happen before approval so the displayed and signed transaction are identical.

### Verification

- `swift test`: 91 tests in 16 suites passed, including missing-field preparation,
  legacy and EIP-1559 fee handling, malformed-input rejection, successful broadcast,
  durable structured submission errors, signer replacement, atomic claims, unsupported
  fields, alias conflicts, hash mismatch, persisted-request revalidation, and signed raw
  transaction vectors.
- viem `serializeTransaction`, `keccak256`, and `signTransaction` independently matched
  the corrected EIP-1559 preimage/hash and complete legacy/type-2 signed bytes.
- `swift format` completed for changed Swift files. `swift format lint --recursive Sources
  Tests` reported only pre-existing warnings in unrelated files.
- `oxfmt`, `oxlint`, and `node --check` passed for the changed extension worker.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build`
  succeeded.
- `stupid-app run --network --udid <device> --sudo /usr/bin/sudo` signed the app and nested
  extension and installed the final build on the physical iPhone. The first final run
  verified installation but CoreDevice returned no launch output; an immediate retry
  installed and launched the same current build successfully.

### Follow-Up

- Deliberately submit a funded physical-device transaction and confirm recovered signer,
  returned hash, network acceptance, and receipt. This verification was not triggered
  automatically because it spends gas.
- Add SQLite activity logging and receipt polling, then continue the remaining Gate 6 app
  flows.

## 2026-08-22 - Gate 5 Physical-Device Proof Completed

### Summary

- Completed the Gate 5 wagmi approval flow on the physical iPhone through the Safari
  toolbar popup: connect, message, typed-data, transaction, and chain approvals.
- Confirmed reconnect after an existing grant did not enqueue a duplicate approval,
  rejection returned EIP-1193 `4001`, and concurrent requests followed creation-order
  queueing.
- Gate 5 is now complete; the maintained next work advances to Gate 6.

### Verification

- Served the wagmi dapp from Bun/Vite on the local network and loaded it in iPhone Safari.
- Manually exercised the complete popup flow on the physical device and confirmed the
  expected approval, rejection, reconnect, and queue behavior.

### Follow-Up

- Begin Gate 6 with transaction preparation and broadcast, wallet import/backup, and the
  connected-sites app UI.

## 2026-08-22 - Current Build Deployed To Physical iPhone

### Summary

- Built, development-signed, installed, and launched the current app and nested Safari
  extension on the paired physical iPhone over the network.

### Verification

- `stupid-app doctor` completed with 0 failures and 0 warnings.
- `stupid-app device list` found the saved network pairing.
- `stupid-app run --network --udid <device> --sudo /usr/bin/sudo` assembled and signed
  the app and extension, packaged the IPA, installed it, and launched the production app
  bundle successfully.

### Follow-Up

- Drive the physical-device wagmi approval flow to finish Gate 5.

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
