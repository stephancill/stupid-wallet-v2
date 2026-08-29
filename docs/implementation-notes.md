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

## 2026-08-29 - No-Wallet Setup Screen Layout

### Summary

- Redesigned the `SetupView` "no wallet" initial screen. It now shows the app logo centered in the
  middle of the screen (the canonical upward-arrow identity, displayed from the bundled
  `Resources/AppIcon.png` as a rounded, shadowed image) and pins the Import Wallet / Create New Wallet
  buttons (and the optional Choose Existing Account action) to the bottom of the screen.
- Added `Resources/AppIcon.png` to the app-level `stupid-app.yml` `resources` so the icon is copied
  into the app bundle and is loadable at runtime; previously it was only consumed as the `iconPath`
  app icon and not present as a bundle resource. The app still references the raw resource via
  `UIImage(named: "AppIcon")`.

### Why

- Replace the previous centered symbol + welcome-text hero with a closer match to the product's visual
  identity (its own logo) and anchor the primary create/import actions to the bottom of the screen so
  the logo is the clear focus.

### Verification

- `stupid-app build` succeeded and the packaged `StupidWallet.app` contains `AppIcon.png`.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
- On a freshly erased iPhone 17e simulator, accessibility inspection showed the `stupid wallet logo`
  image centered horizontally (168-point square) and the Import Wallet / Create New Wallet buttons
  anchored near the bottom of the screen.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-29 - Internal To External TestFlight Build 97 (Face ID Declaration)

### Summary

- Published version 1.0.0 build 97 to external TestFlight after the internal 96 upload. Build 97
  carries the restored `NSFaceIDUsageDescription` in both the containing app and Safari extension.

### Why

- The current "What to Test" note for build 96 was retained verbatim on build 97. Releasing build 97
  externally distributes the Face ID usage declaration to fresh testers.

### Verification

- `stupid-app release preflight`: READY (app and extension locked at 1.0.0/97).
- `stupid-app release bump`: 96 -> 97 in app and extension plists, same as build 96.
- Direct IPA inspection of build 97 confirmed both the containing app and Safari extension carry the
  `NSFaceIDUsageDescription` value and build number 97.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer stupid-app release archive` produced IPA
  SHA-256 `c61992865f5af293761ca3c36a3d7d0b040a9d056573a11968b4a21f31ee563a`; the post-sign verifier passed.
- `stupid-app release upload --wait` completed with `processing=VALID`, `internal=READY_FOR_BETA_TESTING`.
- `stupid-app release external-beta --whats-new "New approval flow, multi account, v1 import fixes"`
  created/added the build to external group `External Testers`, set the what's-to-test note, and created the
  external review submission. The CLI then timed out polling review approval even though the submission was
  created; live App Store Connect state confirmed the outcome directly.
- Live App Store Connect state for build 97: processing VALID, internal beta READY_FOR_BETA_TESTING,
  external beta BETA_APPROVED, and the beta build localization retains the preserved what's-to-test note.
- `stupid-app release status --live` confirms `external beta: BETA_APPROVED`.

### Follow-Up

- Retry/observe the external beta approval polling boundary so a future `release external-beta` exits on
  approval rather than timing out.

## 2026-08-29 - Face ID Usage Declaration Restored

### Summary

- Restored `NSFaceIDUsageDescription` to the containing app and Safari extension plists, including
  the tracked Apple Silicon Mac compatibility plists that package the same iOS code.
- The purpose string explains that Face ID authorizes signing and access to protected wallet keys.
  The existing `.userPresence` policy remains unchanged and continues to permit device-passcode
  fallback.
- Documented the fresh-install versus upgraded-install diagnostic: an upgraded production bundle can
  retain an older Face ID authorization entry, while a fresh installation needs the current usage
  declaration and a legitimate first protected operation before its per-app Settings control appears.

### Why

- The prior Dawn project declared Face ID usage for both executable bundles, but the rebuild's source
  and build-96 IPA omitted it. That could leave upgraded users with a retained Settings control while
  fresh users had no declared permission through which iOS could authorize Face ID.

### Verification

- `plutil -lint Info.plist SafariExtension/Info.plist Mac/Info-App.plist Mac/Info-Ext.plist` passed.
- `stupid-app doctor` completed with zero failures and zero warnings.
- `stupid-app build` succeeded. Direct inspection of the assembled app and nested extension confirmed
  both contain the expected `NSFaceIDUsageDescription` value.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Direct inspection of both installed bundles confirmed the purpose string, and accessibility
  inspection showed the retained wallet home.
- `git diff --check` passed before this implementation-note entry.

### Follow-Up

- On a fresh physical installation, trigger one legitimate protected operation and confirm the Face ID
  consent and per-app Settings control. An upgraded device with retained authorization is not
  sufficient first-use evidence.

## 2026-08-29 - Account Navigation And Copy Feedback

### Summary

- Removed disclosure chevrons from Add Account, Create New Wallet, and Import Wallet on the
  Accounts screen while preserving each navigation flow.
- Replaced the Accounts sheet's text Close button with the native close-role button on iOS 26 and
  retained the text control on older supported iOS versions where that role is unavailable.
- Changed the home Copy Address toolbar symbol directly, without a content-transition animation, to
  a checkmark for 1.5 seconds after copying, then restored the copy symbol.

### Why

- Keep the account switcher visually quieter and provide immediate confirmation that the address
  reached the pasteboard.

### Verification

- `swift test` passed all 303 tests in 34 suites.
- `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension.
- Simulator verification showed the checkmark immediately after copying and the copy symbol restored
  after 1.5 seconds. Accessibility inspection retained the `Copy Address` button label.
- Simulator inspection confirmed Add Account, Create New Wallet, and Import Wallet have no
  chevrons. Selecting each replacement Add Wallet button opened its correct destination.
- On the iOS 26 simulator, the close-role button rendered as the native X and dismissed Accounts.

### Follow-Up

- None.

## 2026-08-29 - Internal TestFlight Build 96 (Wallet Migration Reliability)

### Summary

- Archived and uploaded 1.0.0 (96) to App Store Connect / internal TestFlight, containing the
  resumable wallet-migration and legacy keychain access-group work described in today's Dawn
  upgrade entry.

### Why

- Publish the migration-retry and keychain lookup fixes to testers ahead of further Gate B work.

### Verification

- `stupid-app doctor`: 0 failures, 0 warnings (Xcode 26.6 in place, iOS SDK 26.5).
- `stupid-app release preflight`: READY (app and extension locked at 1.0.0/96).
- `stupid-app release archive`: signed single-pass Distribution IPY, IPA SHA-256
  `3729c0323812d9b2d3c4f8429ac1eb6fb11cb59543e0c20a5d8e9bdd769ec405`, post-sign verifier passed.
- `stupid-app release upload --wait` reported a client timeout, but a re-run resolved the build as
  already uploaded (build number 96 exists), confirming the first upload reached App Store Connect.
  Because the already-uploaded path does not rewrite the release manifest, the manifest was refreshed
  to point at build 96 and `stupid-app release status --live` confirmed live state.
- Live App Store Connect state for 1.0.0 (96): processing VALID, internal beta READY_FOR_BETA_TESTING,
  external beta READY_FOR_BETA_SUBMISSION. No external beta submission was made.

### Follow-Up

- The release-upload "already-uploaded" recovery path leaves the `release-manifest.json` pointing at
  the previous build; a stale manifest then makes `release status --live` and external-beta operate on
  the wrong build until it is refreshed. Consider teaching `release upload` to adopt the existing
  build and refresh the manifest instead of only erroring.
- Build 96 is internal-only; submit for external review when the migration work is ready for external
  distribution.

## 2026-08-29 - Dawn Upgrade Retry And Keychain Lookup Fix

### Summary

- Fixed a production upgrade failure that could stop before any Face ID/passcode prompt and leave the
  containing app without a ready wallet registry.
- Dawn ciphertext and Secure Enclave lookups now explicitly use the preserved production keychain
  access group. The ciphertext query also binds Dawn's empty generic-password service so a partially
  written new-format item for the same account cannot be selected as legacy ciphertext. Lookup and
  cleanup never remove the access-group constraint or wildcard across other entitled groups.
- New-format key and seed stores explicitly select the shared production access group on entitled
  device builds. Simulator and macOS package-test builds retain their ungrouped test behavior.
- Migration now resumes an already-persisted pending key directly at authenticated sign-and-recover
  verification. A duplicate item caused by interruption between the key write and pending-marker write
  follows the same proof path instead of failing before authentication. Existing items are never
  replaced or deleted by recovery.
- Setup now reports registry unavailability as an existing-wallet load failure rather than incorrectly
  claiming that a new wallet could not be saved.
- Device-owner cancellation, authentication failure, and interaction-unavailable keychain statuses now
  remain a retryable migration cancellation. The setup message explains that recovery authentication
  was cancelled or unavailable and that a device passcode must be enabled; wallet creation remains
  blocked so denying recovery cannot replace or obscure the old wallet.

### Why

- Both reported messages came from one startup failure: creation requires a ready registry, so its
  generic save message did not establish that key generation or keychain storage had run. Missing
  authentication localized the primary failure before legacy decryption or new-format verification.
- The migration's pending marker existed but was not previously read, and `errSecDuplicateItem` was
  treated as terminal. An interrupted protected-key write could therefore make every later launch fail
  before the recovery authentication prompt.

### Verification

- Inspected the old Dawn source and confirmed its shared access group, address-tagged Secure Enclave
  item, and empty-service generic-password ciphertext contract.
- Inspected the packaged release IPA entitlements and confirmed the containing app and Safari extension
  both carry the preserved shared keychain group.
- `swift test --filter MigrationTests` passed 17 tests, including pending-marker resume without another
  decrypt/save, pre-marker duplicate-item continuation through proof, ordinary save failure, and the
  exact legacy keychain query and authentication-status contracts.
- `swift test` passed all 303 tests in 34 suites.
- `swift format lint --recursive Sources Tests` and `git diff --check` passed.
- `stupid-app doctor` completed with zero failures and zero warnings.
- `stupid-app build` completed successfully. `stupid-app run --simulator --udid <preferred-simulator>`
  rebuilt, installed, and launched the app; accessibility inspection showed the retained wallet home.

### Follow-Up

- Reinstall over the affected physical installation and confirm the app presents authentication,
  preserves the existing address, completes registry adoption, and signs with the recovered account.
- Repeat a clean old-Dawn in-place upgrade before releasing; simulator keychain behavior is not
  acceptance evidence for production access-group continuity.

## 2026-08-27 - External Beta Review SDK-Metadata Fix

### Summary

- Diagnosed why external TestFlight submissions of Stupid Wallet builds 92, 93, and 94 failed even
  though the binaries were internally valid: the `stupid-app` release archiver omitted the
  build-system Info.plist keys `DTPlatformBuild` and `DTSDKBuild` (the SDK build number), and build
  93 also carried a wrong `DTXcode` encoding.
- Fixed `stupid-app` (source in `~/environments/personal/pus/stupid-ios-dev`) to emit
  `DTPlatformBuild`/`DTSDKBuild` from the SDK's `SystemVersion.plist` build number and to encode
  `DTXcode` canonically (`major*100 + minor*10 + patch`, e.g. Xcode 26.6 -> `2660`). The previous
  naive concatenation produced `266`, which App Store Connect could not map to a supported Xcode.
- Built, uploaded, and submitted version 1.0.0 build 95 for external beta review. The external
  submission was accepted and the build is live in external beta testing.

### Why

- Apple's external-beta gate rejects any build whose packaged metadata does not identify a supported
  SDK. Two stupid-app defects independently triggered it: missing SDK build keys, and a non-canonical
  `DTXcode` for Xcode 26.6. Genuine Xcode archives carry both, so a probe with an existing real-Xcode
  build proved the toolchain was not the blocker.

### Verification

- Verified the on-disk build 94 IPA metadata matched Xcode 26.6 GA (`DTXcode` `2660`,
  `DTXcodeBuild` `17F113`, `DTSDKName` `iphoneos26.5`) yet external submission still returned
  `BUILD_SDK_NOT_ALLOWED_FOR_EXTERNAL_TESTING`.
- Compared against a genuine Xcode 26.1.1 archive (another project, build 97) and found
  `DTPlatformBuild`/`DTSDKBuild` (`23B77`) and `BuildMachineOSBuild` present there. Submitting that
  genuine archive for external review returned HTTP 201 `WAITING_FOR_REVIEW`, while a same-SDK
  stupid-app-packaged build returned the SDK rejection.
- Confirmed the SDK build number source: the SDK's
  `System/Library/CoreServices/SystemVersion.plist` `ProductBuildVersion` (iOS 26.1 -> `23B77`,
  iOS 26.5 -> `23F81a`).
- `swift test` in stupid-ios-dev passed all 269 tests in 49 suites after the changes; `stupid-app`
  release build rebuilt and reinstalled to `~/.local/bin`.
- Build 95 archive inspection confirmed both the app and nested extension carry
  `DTXcode` `2660`, `DTXcodeBuild` `17F113`, `DTPlatformBuild`/`DTSDKBuild` `23F81a`.
- `stupid-app release status --live` for build 95 reports `internal=IN_BETA_TESTING`,
  `external=IN_BETA_TESTING`.

### Follow-Up

- The probe left another project's build 97 in `WAITING_FOR_REVIEW`; it cannot be cancelled through
  the public API (DELETE returned 403) and should be cancelled in App Store Connect if that build
  must not ship externally.
- Re-export any stale Linux-host iOS SDK bundles so their `sdk-manifest.json` records
  `iphoneosSDKBuild`; bundles exported before this fix will simply omit the two keys rather than
  failing.
- Consider a future GA Xcode to remove the beta-seed toolchain dependency once Apple's acceptance
  window moves forward again.

## 2026-08-27 - External Beta Review SDK Blocker

### Summary

- Preflighted version 1.0.0, build 92 for external beta review and confirmed its beta app
  descriptions, review contact information, and localized What to Test text are present.
- The public App Store Connect beta-review submission endpoint rejected the build with
  `BUILD_SDK_NOT_ALLOWED_FOR_EXTERNAL_TESTING`.
- Identified an installed supported toolchain for the replacement build: Xcode 26.6 with the iOS
  26.5 SDK at `/Applications/Xcode.app`.

### Why

- Build 92 was archived with Xcode 26.1.1 and the iOS 26.1 SDK. Apple accepts it for internal
  TestFlight but no longer permits that Xcode/SDK combination for external TestFlight review.
- Uploaded binaries are immutable, so changing the build's group or retrying submission cannot fix
  the SDK provenance.

### Verification

- The beta-review API returned HTTP 422 with the unsupported-Xcode/SDK error before creating a
  submission; build 92 remained in external state `READY_FOR_BETA_SUBMISSION`.
- Apple's current App Store Connect release notes list Xcode 26.6 with the iOS 26.5 SDK as accepted
  for internal and external TestFlight testing.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer stupid-app doctor` selected Xcode 26.6,
  Swift 6.3.3, and the iOS 26.5 SDK successfully.

### Follow-Up

- Create and upload a new build number with Xcode 26.6, assign that build to external group `v2`,
  and submit the replacement for beta review.

## 2026-08-27 - External TestFlight Group Assignment

### Summary

- Added version 1.0.0, build 92 to the existing external TestFlight group `v2` through the public
  App Store Connect API.

### Why

- The installed `stupid-app` release commands upload builds and report beta state but do not yet
  manage TestFlight group relationships.

### Verification

- Resolved the exact app and the exact non-internal group named `v2`, then used Apple's
  `betaGroups/{id}/relationships/builds` endpoint to add build 92.
- A fresh relationship read confirmed the group contains build 92.
- The build remained internally available and reported external state `READY_FOR_BETA_SUBMISSION`.

### Follow-Up

- Submit the build for external beta review before expecting external testers to receive it.

## 2026-08-27 - Corrected Internal TestFlight Build 92

### Summary

- Bumped the containing app and Safari extension build numbers together from 91 to 92.
- Archived and uploaded version 1.0.0, build 92 to internal TestFlight with matching app and
  extension marketing versions.

### Why

- Builds 90 and 91 contained a Safari extension marketing version of `0.1.0` while the containing app
  used `1.0.0`, producing App Store Connect warning `ITMS-90473`. A new binary and build number were
  required because an uploaded binary cannot be replaced.

### Verification

- `stupid-app release new-build` identified 92 as the next available build number.
- `stupid-app release archive` signed the app and nested extension, packaged the IPA, and passed the
  project-owned post-sign verifier.
- Direct IPA inspection confirmed both the containing app and nested extension are `1.0.0 (92)` and
  the app declares `ITSAppUsesNonExemptEncryption=false`.
- `stupid-app release upload --wait` completed successfully. `stupid-app release status --live`
  confirmed `processing=VALID`, `internal=IN_BETA_TESTING`, and
  `external=READY_FOR_BETA_SUBMISSION`.

### Follow-Up

- None for internal TestFlight. External TestFlight submission remains a separate decision.

## 2026-08-27 - Safari Extension Marketing-Version Match

### Summary

- Changed the Safari extension `CFBundleShortVersionString` from `0.1.0` to `1.0.0` so it matches
  the containing app for the next App Store Connect delivery.
- Recorded that `stupid-app release bump` synchronizes `CFBundleVersion` build numbers but does not
  synchronize marketing versions, and added the `ITMS-90473` pre-archive check to the debugging
  workflow.

### Why

- App Store Connect accepted builds 90 and 91 but warned that the nested Safari extension's
  marketing version did not match the containing app. Inspection of the archived build 91 IPA
  confirmed the same `1.0.0` versus `0.1.0` mismatch.

### Verification

- `plutil -lint Info.plist SafariExtension/Info.plist` passed, and a direct source-plist comparison
  confirmed both marketing versions are `1.0.0`.
- `stupid-app doctor` completed with zero failures and zero warnings.
- `stupid-app build --configuration release` succeeded. Direct inspection of the assembled app and
  nested extension confirmed both are `1.0.0 (91)`.
- `git diff --check` passed.

### Follow-Up

- Upload a new build number after the corrected archive is created; previously uploaded binaries
  cannot be replaced.

## 2026-08-27 - Stale Build Export Compliance Fix

### Summary

- Patched the stale App Store Connect build 90 (from the first upload attempt) with
  `usesNonExemptEncryption=false` through the App Store Connect builds API instead of the CLI, since
  `stupid-app` has no single-build export-compliance command.

### Why

- The first upload lacked `ITSAppUsesNonExemptEncryption` in its Info.plist and landed with the build
  beta state `MISSING_EXPORT_COMPLIANCE`. The corrected build 91 already distributes internally; this
  cleared the stale build's compliance gate rather than leaving a permanently non-compliant build
  on record.

### Verification

- A JWT from the stored App Store Connect key (`cryptography` ES256) patched the build attribute, then
  re-fetch confirmed `usesNonExemptEncryption=false`.
- The build's beta detail resource then reported `internalBuildState=IN_BETA_TESTING` and
  `externalBuildState=READY_FOR_BETA_SUBMISSION`, matching build 91.

### Follow-Up

- None. Both build 90 and 91 are internal beta-eligible; 91 remains the current fixed build.

## 2026-08-27 - First Internal TestFlight Upload

### Summary

- Uploaded the merged rebuild to App Store Connect internal TestFlight as version 1.0.0, build 91
  (bundle ID `co.za.stephancill.stupid-wallet`, with the nested Safari extension
  `co.za.stephancill.stupid-wallet.extension`).
- Provisioned App Store distribution profiles through `stupid-app signing setup --kind distribution`
  (the archive step had failed for lack of a stored distribution profile).
- Added `ITSAppUsesNonExemptEncryption=false` to the app Info.plist after the first upload landed in
  `MISSING_EXPORT_COMPLIANCE`; the corrected build 91 reached `IN_BETA_TESTING`.

### Why

- The rebuild needs to reach internal testers through the existing production TestFlight pipeline and
  bundle ID, closing the "upload the rebuild through the existing iOS TestFlight pipeline" follow-up
  from the 2026-08-24 TestFlight-on-Mac direction entry.

### Verification

- `stupid-app release new-build` reported 90 as the next build from ASC (previous line ended at 89).
- `stupid-app release bump --build-number 90` then `--build-number 91` updated the app and extension
  plists in lockstep.
- `stupid-app release archive` signed the app and extension, packaged `.release/StupidWallet.ipa`, and
  passed the post-sign verifier.
- `stupid-app release upload --wait` reached `processing=VALID`, `internal=IN_BETA_TESTING`, and
  `external=READY_FOR_BETA_SUBMISSION`; `stupid-app release status --live` confirmed the same live
  states. The release manifest records build `1.0.0 (91)`.
- An intermittent network issue made `api.appstoreconnect.apple.com` hit a stale, unreachable
  endpoint; a temporary `/etc/hosts` pin to the live endpoint restored ASC access and was removed
  after the upload completed.

### Follow-Up

- Add the "What to Test" note for build 91 in App Store Connect if needed.
- External TestFlight submission remains a separate decision.

## 2026-08-26 - Multi-Account Build Network Installation

### Summary

- Installed the committed multi-account UI and initial wallet-state loading changes on the paired
  physical iPhone over Wi-Fi, including the nested Safari extension.

### Why

- Physical installation confirms the current development-signed app and extension still package and
  deploy together after the account-selection and startup-state changes.

### Verification

- `stupid-app device list` found the saved network pairing.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` assembled and signed the app,
  signed the nested extension, packaged the IPA, then installed and launched the containing app.

### Follow-Up

- None.

## 2026-08-26 - Initial Wallet-State Loading Gate

### Summary

- Added an explicit initial-state loading flag to `WalletViewModel` and gated the containing app's
  root content and account toolbar on it.
- The app now renders a neutral loading indicator while registry adoption resolves, then chooses the
  wallet or setup surface from authoritative loaded state instead of treating default empty values as
  a real no-wallet result.
- Added the startup-state boundary to the project debugging skill.

### Why

- The asynchronous adoption task previously began after `ContentView` had already rendered, so an
  installed wallet briefly showed the create/import setup screen on every cold launch.

### Verification

- `swift test` passed all 297 tests across 34 suites.
- `stupid-app build` completed successfully, and `stupid-app run --simulator` rebuilt, installed, and
  launched the app on the preferred iOS simulator.
- Terminated and cold-launched the installed app, then inspected the Simulator accessibility state.
  The first observed app state contained the restored wallet controls and no create/import setup
  content.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-26 - Seed Import Account Selection Handoff

### Summary

- Changed wallet import to return the newly registered wallet group to the UI.
- A successful recovery-phrase import now pushes the existing Add Accounts discovery screen for that
  seed group instead of immediately returning to Accounts. Finishing or backing out of discovery then
  closes the import flow.
- Deferred the containing-app view-model reload for seed imports until discovery exits, preventing an
  initial wallet import from replacing its own navigation stack before the selector appears. The
  protected source and registry group remain durably committed during the selector step.
- Kept private-key imports on the immediate completion path because they expose exactly one account.

### Why

- Seed import should include account discovery in one continuous flow so users can select all known
  derived accounts before returning to the wallet-group list.

### Verification

- `swift test` passed all 297 tests in 34 suites, `stupid-app build` succeeded, and
  `git diff --check` passed.
- No additional seed wallet was created solely for simulator verification, avoiding leftover protected
  test material; the final build was reinstalled and launched on the preferred simulator.

### Follow-Up

- Exercise the complete import-to-selection transition during the next intentional seed import on a
  simulator or physical device.

## 2026-08-26 - Account Navigation Visual Consistency

### Summary

- Updated the home account-menu switcher row to use the shared squircle `BlockieView`, with the muted
  shortened address beneath the account label.
- Added the native trailing disclosure chevron to Add Account while retaining its blue additive tint
  and long-press Add Next Account shortcut.
- Applied the same blue tint to Create New Wallet and Import Wallet navigation labels.
- Renamed More to Load More and removed its inset-grouped pill background so it reads as a standalone
  pagination action. The action now sits directly beneath the final account row and is replaced by a
  centered spinner while another page is loading.

### Why

- Account identity and navigation actions should use one consistent visual language and clearly
  distinguish navigation from immediate actions.

### Verification

- `swift test` passed all 297 tests in 34 suites, and `git diff --check` passed.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid <clean-simulator>` rebuilt,
  installed, and launched the app.
- Live simulator inspection confirmed the squircle blockie and two-line account-menu identity row,
  Add Account disclosure chevrons, blue Add Wallet navigation labels, and standalone Load More action
  without a pill background.

### Follow-Up

- None.

## 2026-08-26 - Multi-Select Account Discovery

### Summary

- Inverted the seed-group Add Account interaction: a normal tap now navigates to an Add Accounts
  screen, while long press is the shortcut for immediately adding the monotonic next account.
- The discovery screen authenticated-loads ten blockie, default-label, and shortened-address previews,
  supports multiple selection, and uses More to load ten additional previews without clearing the
  current selection. It does not expose raw derivation paths.
- Added bulk derivation under one group claim and one authenticated seed read. Every selected child is
  sign-and-recover verified and the ascending selection is appended in one registry revision. The
  high-water mark advances past the highest selection, and the UI warns when lower unselected previews
  will be skipped.
- Expanded registry transition validation to accept a non-empty, strictly increasing batch of active
  derived accounts while preserving the existing monotonic and no-index-reuse constraints.

### Why

- Account discovery is easier to scan and extend on a full mobile screen, and multi-selection avoids
  repeating the import flow for several known accounts. Long press remains a fast path for the common
  next-account action.

### Verification

- The focused `WalletGroupManagerTests` suite passed all 17 tests. Its new regression derives indexes
  1, 3, and 5 with one protected seed load and one registry revision, verifies ascending labels and
  high-water advancement, and rejects duplicate selections.
- `swift test` passed all 297 tests in 34 suites. The first complete run hit a transient existing
  SQLite `database is locked` failure in one activity migration test; the complete ActivityStore suite
  and the subsequent full run both passed.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid <clean-simulator>` rebuilt,
  installed, and launched the app.
- Live simulator inspection confirmed that tap navigates to ten blockie/address rows, selecting two
  rows updates the toolbar to Add 2, More exposes the next ten rows without clearing selection, and the
  Add Next Account accessibility shortcut adds exactly the current next account. The multi-selection
  confirmation was not invoked, so the simulator wallet was changed only by that single shortcut.

### Follow-Up

- Physical-device acceptance remains required for LocalAuthentication behavior.

## 2026-08-26 - Long-Press Account Preview Menu

### Summary

- Added a long-press account chooser to each seed wallet group's Add Account row. After fresh native
  authentication, it shows the next five available accounts as blockies and shortened addresses,
  excludes indexes already registered in the group, and does not expose raw derivation paths.
- Preview generation derives only the public addresses needed for the transient menu, zeroizes each
  temporary child key and the loaded entropy, and persists neither previews nor extended public keys.
- Added explicit-index derivation to `WalletGroupManager` under the existing group lifecycle claim,
  authenticated entropy load, sign-and-recover proof, and atomic registry update.
- Kept a normal Add Account tap on the current monotonic next index. Selecting a preview performs a
  separate authenticated derivation and advances beyond it; stale or lower selections fail rather
  than reusing skipped or deleted indexes.

### Why

- Users need to recognize the account they want by its familiar visual identity and address without
  interpreting a raw derivation path or weakening the registry's monotonic allocation, concurrency,
  or protected-secret boundaries.

### Verification

- The focused explicit-derivation regression passed, proving candidate exclusion, selection of a
  future index, label assignment, monotonic advancement, and rejection of a stale lower index.
- `swift test` passed all 296 tests in 34 suites. `swift format lint --recursive Sources Tests`
  reported only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`, and
  `git diff --check` passed.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid <clean-simulator>` rebuilt,
  installed, and launched the app.
- A real held touch on a seed group's Add Account row completed the simulator's protected seed read
  and opened a popover with exactly five distinct blockies and shortened addresses. The accessibility
  tree retained each full address and exposed no derivation paths. The live group already contained
  indexes 0, 1, and 2, so the previews represented the next five available accounts. The popover was
  dismissed without selecting a preview or changing wallet state.

### Follow-Up

- None.

## 2026-08-26 - Native Import Wallet Form

### Summary

- Replaced Import Wallet's centered lowercase hero layout and custom gray input surface with the
  native inset-grouped list structure used by Accounts, Settings, and wallet backup.
- Split wallet-group label and secret input into labeled sections, added accepted-format guidance, renamed
  the action from `Save` to `Import Wallet`, and added an inline importing progress state.
- Kept the recovery phrase/private key visible for user review while marking it privacy-sensitive and
  retaining disabled capitalization and autocorrection.

### Why

- Wallet import should use the app's established native hierarchy and controls while making required
  input formats easier to understand on mobile.

### Verification

- `swift test` passed all 295 tests in 34 suites. `swift format lint --recursive Sources Tests`
  reported only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`, and
  `git diff --check` passed.
- The first `stupid-app build` exposed an iOS-only SwiftUI section-initializer mismatch that the
  macOS package-test build cannot compile. Converting the titled sections to explicit
  content/header/footer initializers fixed it; this boundary is now recorded in the project debugging
  skill.
- `stupid-app build` then succeeded, and
  `stupid-app run --simulator --udid <clean-simulator>` rebuilt, installed, and launched the app.
- Live simulator inspection confirmed the form uses title-case inline navigation, native grouped
  sections, readable field sizing and guidance, and a standard disabled Import Wallet row without
  clipping at the default phone size.
- Renamed the first field from Wallet Name to Wallet Group Label, including its placeholder and
  guidance, to match the registry terminology; live simulator inspection confirmed all three strings
  render without clipping at the default phone size.

### Follow-Up

- None.

## 2026-08-26 - Selected Account Settings Header

### Summary

- Added a display-only selected-account identity row at the top of Settings, with a 52-point blockie,
  editable account label, and muted shortened address.
- Kept navigation and destructive account management out of the header so Accounts remains the only
  account-selection and removal surface.

### Why

- The selected account should remain clear while viewing account-scoped settings, using the familiar
  identity hierarchy of the Apple Settings account row.

### Verification

- `swift test` passed all 295 tests in 34 suites. `swift format lint --recursive Sources Tests`
  reported only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`, and
  `git diff --check` passed.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid <clean-simulator>` rebuilt,
  installed, and launched the app.
- Live simulator inspection confirmed the selected account appears in a separate top Settings card
  with its large rounded blockie, label, muted shortened address, and a combined accessibility value
  containing the full address. The ordinary settings links remain in the section below.

### Follow-Up

- None.

## 2026-08-26 - Remove Settings Forget Account Action

### Summary

- Removed the separate destructive `Forget Account` / `Forget Wallet` section and its confirmation
  state from Settings.
- Kept account and wallet removal in the Accounts screen's edit-mode flow, which retains its scoped
  confirmation and recoverable deletion behavior.

### Why

- Destructive account management should have one clear entry point in the Accounts screen instead of
  a second button tied only to the currently selected home account.

### Verification

- `swift test` passed all 295 tests in 34 suites after one timing-sensitive expiry test transiently
  returned `unavailable`; that test passed in isolation and the complete rerun passed.
- `swift format lint --recursive Sources Tests` reported only the three pre-existing block-comment
  warnings in `SecurityWalletBackend.swift`; `git diff --check` passed.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid <clean-simulator>` rebuilt,
  installed, and launched the app.
- Live simulator inspection confirmed Settings contains only Networks, Authorizations, and Private
  Key, with no Forget Account/Wallet section.

### Follow-Up

- None.

## 2026-08-26 - Safari Account Picker Labels And Avatar Spacing

### Summary

- Extended the native available-account summaries with the editable wallet-group and account labels,
  and rendered those labels in the Safari popup's connect-account picker.
- Each picker row now mirrors the native selector: a 28-point blockie precedes a regular-sized account
  label, with the shortened address on a smaller muted line below. The full address remains canonical
  rebind data and hover metadata.
- Wallet-group headings preserve their editable capitalization instead of forcing uppercase.
- Bumped the WebExtension manifest to `0.1.53` so Safari reloads the modal resources.

### Why

- The account picker should use the same editable registry names as the containing app and sticky
  popup action, without obscuring the canonical address used by the native rebind boundary.

### Verification

- `node --test Tests/JavaScript/*.test.mjs` passed all 22 tests, including native-style account-row
  proportions, normal-case group headings, muted address text, and rendered blockies.
- `swift test` passed all 295 tests in 34 suites. `swift format lint --recursive Sources Tests`
  reported only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`.
- `PrototypeDapp/node_modules/.bin/oxlint SafariExtension/Resources/popup.js Tests/JavaScript/popup.test.mjs`
  and `git diff --check` passed.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid <clean-simulator>` rebuilt,
  installed, and launched the app with WebExtension manifest `0.1.53`.
- A fresh prototype-dapp connect request rendered live in simulator Safari. Its picker preserved the
  capitalization of multiple wallet-group labels and showed each account with a larger blockie,
  regular-sized label, and muted shortened-address subtitle. The test request was rejected normally.
- `stupid-app doctor` passed every host, toolchain, signing, pairing, project, and CoreDevice check.
  `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` then signed the app and nested
  extension, installed them over the saved network pairing, and launched the containing app.

### Follow-Up

- Confirm the native-style picker layout on a physical device.

## 2026-08-26 - Safari Popup Avatar-First Account Label

### Summary

- Changed the sticky popup action bar to render the account blockie followed by the editable label
  when one is available. The shortened address is now a fallback rather than additional visible text;
  the full address remains hover metadata and canonical request identity.
- Bumped the WebExtension manifest to `0.1.51` so Safari reloads the revised popup script.

### Why

- The label should replace the address as the readable account name without appearing before the
  account avatar or duplicating identity text in the constrained action bar.

### Verification

- `node --test Tests/JavaScript/popup.test.mjs` passed all 6 tests, including a regression proving the
  blockie precedes the label and the shortened address is absent when a label exists.
- `swift test` passed all 295 tests in 34 suites. `swift format lint --recursive Sources Tests`
  reported only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`.
- `node --check SafariExtension/Resources/popup.js`,
  `PrototypeDapp/node_modules/.bin/oxfmt --check SafariExtension/Resources/popup.js Tests/JavaScript/popup.test.mjs`,
  and `git diff --check` passed.
- `stupid-app build` succeeded, and `stupid-app run --simulator --udid <clean-simulator>` rebuilt,
  installed, and launched manifest `0.1.51`.
- A fresh prototype-dapp connect request rendered live in Safari with the blockie first, the edited
  label after it, no visible address text, and unchanged Reject/Connect actions. Test requests were
  rejected normally after inspection.

### Follow-Up

- Confirm the avatar-first label layout on a physical device.

## 2026-08-26 - Safari Popup Account Label Simulator Acceptance

### Summary

- Completed live Safari popup acceptance for the editable account label on a clean iOS simulator.
  A freshly edited label rendered in the active connect request's sticky action bar immediately
  before the blockie and shortened canonical address.
- Confirmed a longer label ellipsizes within the fixed popup width without displacing the Reject and
  Connect actions. The test request was rejected normally after inspection.

### Why

- The earlier verification covered native summary propagation and hermetic popup rendering but had
  not visually proved the installed WebExtension assets in Safari.

### Verification

- `stupid-app run --simulator --udid <clean-simulator>` rebuilt, installed, and launched the app with
  WebExtension manifest `0.1.50`.
- `npm run dev -- --host 0.0.0.0` served the local prototype dapp. Safari injected the provider, a
  fresh `eth_requestAccounts` request opened in the extension popup, and live inspection confirmed the
  edited label, blockie, shortened address, and decision actions rendered together.
- The preferred retained-state simulator could not be used for this visual check because it contains
  unsupported pre-binding-v2 request records from earlier rebuild development. Those records were not
  edited or deleted to force progress; acceptance continued on a clean simulator.

### Follow-Up

- Confirm the same label rendering and truncation behavior in a live Safari popup on a physical
  device.

## 2026-08-26 - Safari Popup Account Labels

### Summary

- Surfaced the editable account label in the Safari review popup. Native request summaries now resolve
  the current account label from the registry, the Safari handler serializes it as `accountLabel`, and
  the popup renders it in the sticky action bar ahead of the blockie and shortened address. An unknown
  account leaves the label absent and the bar unchanged.
- Bumped the WebExtension manifest to `0.1.50` for the popup JavaScript change.

### Why

- Account labels are non-authoritative display metadata, so showing them in the review surface helps
  the user recognize which account a request is bound to while the address remains the canonical
  identity.

### Verification

- `node --test Tests/JavaScript/*.test.mjs` passed all 21 tests, including a new regression proving the
  action bar renders the label and the shortened address together. `oxfmt`, `oxlint`, `node --check`,
  and manifest JSON validation passed.
- `swift test` passed all 295 tests in 34 suites, including a new summary regression that resolves the
  account's editable label. `swift format lint --recursive Sources Tests`
  reported only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`, and
  `git diff --check` passed.
- `stupid-app doctor` completed with zero failures and zero warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched manifest
  `0.1.50`; the app rendered the retained wallet home.

### Follow-Up

- Confirm the label rendering in a live Safari popup on a device.

## 2026-08-26 - Account Menu Row Blockie And Trailing Switch

### Summary

- Revised the home account-menu row to lead with a squircle account blockie beside the home account's
  editable label (falling back to the shortened address), followed by a small, muted trailing
  `arrow.left.arrow.right` switch symbol.
- This supersedes the earlier trailing-arrow-only and leading-arrow treatments; the row now reads like
  the other menu rows while keeping the blockie and a subtle trailing switch affordance.

### Why

- The blockie should stay the leading account identity, and a smaller, quieter trailing symbol avoids
  competing with the text while still signaling the switch action.

### Verification

- `swift format --in-place Sources/StupidWallet/ContentView.swift` completed; `git diff --check` passed.
- `swift test` passed all 294 tests in 34 suites. `swift format lint --recursive Sources Tests` reported
  only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`, and
  `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Live inspection confirmed the account-switch row leads with the squircle account blockie beside the
  home account label with a small muted trailing `arrow.left.arrow.right` symbol, and that selecting the
  row still opens the grouped Accounts picker. The app was returned to the home screen after acceptance.

### Follow-Up

- None.

## 2026-08-26 - Account Label Save Crash Fix

### Summary

- Fixed the Accounts picker crash when Done was pressed while an in-place wallet or account label
  field still owned keyboard focus. The picker now resigns all label fields and yields the main actor
  before saving labels or replacing the editable list hierarchy.
- Replaced edit-mode pencil indicators with dotted underlines on editable wallet and account labels.

### Why

- The crash report identified a UIKit collection-view first-responder assertion in
  `_resignOrRebaseFirstResponderViewWithIndexPathMapping`. Registry persistence had completed, but the
  observed registry refresh updated the SwiftUI list while its section-header text field remained the
  first responder.

### Verification

- `swift test` passed all 294 tests in 34 suites. `swift format lint --recursive Sources Tests`
  reported only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`, and
  `git diff --check` passed.
- `stupid-app doctor` completed with zero failures and zero warnings; `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Live reproduction edited a wallet section-header field and pressed Done while that field and keyboard
  remained active. The save succeeded twice, edit mode closed, the app process remained running, no new
  crash report appeared, and the restored label remained correct after app restart. A subsequent live
  inspection confirmed every unfocused pencil sits directly after its wallet/account label and only
  each wallet/account label uses the dotted editable-field treatment.

### Follow-Up

- Complete the existing Gate I account-deletion fault injection and physical-device acceptance.

## 2026-08-26 - Gate I Account Picker And Lifecycle Implementation

### Summary

- Advanced the wallet registry to schema 2 with strict persisted labels, account lifecycle, and
  retained seed identity. Schema 1 migrates through the existing projection-first journal in one
  revision with deterministic wallet/account labels; malformed schema-2 records fail closed.
- Added atomic wallet-group/account label edits and recoverable individual seed-account deletion.
  Deletion marks the registration inactive before terminalizing pending requests and removing grants,
  active/default mappings, and balance cache state. It preserves seed entropy, activity, account-zero
  identity, and the derivation high-water mark. Private-key and final-seed-account removal uses complete
  group deletion.
- Added picker Edit/Done mode using SwiftUI's native list edit state and standard red removal/Delete
  treatment. Wallet section headers and account labels edit in place with pencil indicators; Close is
  hidden during editing and destructive actions retain confirmation. Selection and derivation keep the
  sheet open. Named create/import flows return to the Accounts list and do not implicitly replace an
  existing home selection.
- Updated signer, connection, service, and containing-app account lookups so an account marked
  `.deleting` is not selectable, visible to a provider, or usable for protected operations.

### Why

- Labels are non-authoritative organization metadata, while account removal crosses several durable
  stores and therefore needs the same fail-closed, resumable lifecycle discipline as group deletion.
  Retaining seed identity and the derivation high-water mark prevents duplicate seed groups and index
  reuse after removing account zero or another derived registration.

### Verification

- `swift test` passed all 294 tests in 34 suites. New coverage verifies schema migration, strict
  schema-2 decoding, atomic trimmed label edits, final-seed-account rejection, pending/connection/cache
  cleanup, retained seed identity, and monotonic derivation after account removal.
- `swift format lint --recursive Sources Tests` reported only the three pre-existing block-comment
  warnings in `SecurityWalletBackend.swift`; `git diff --check` passed.
- `stupid-app doctor` completed with zero failures and zero warnings. `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Live inspection confirmed Close disappears in edit mode, wallet section headers and account labels
  are directly editable with pencil indicators, native red minus controls reveal the standard trailing
  Delete action, selection does not dismiss, and additive import requires a wallet name. The app was
  returned to its home screen after acceptance.

### Follow-Up

- Add deterministic fault injection across every individual account-deletion phase, including pending
  marker reconciliation, connection cleanup, cache removal, and final registration removal.
- Complete physical-device acceptance for protected derivation/removal, relaunch recovery, label
  persistence, and additive picker navigation before closing Gate I.

## 2026-08-26 - Account Picker Editing Scope

### Summary

- Approved a follow-up multi-account gate for editable wallet-group and account labels, with a
  top-right Edit/Done mode in the containing-app Accounts sheet.
- Changed home selection and derivation UX so the Accounts sheet remains open. Named create/import
  flows return to the Accounts list instead of dismissing the sheet or implicitly changing home.
- Approved individual seed-account registration deletion. It preserves the seed, retained activity,
  and monotonic derivation high-water mark while recoverably removing pending authority, grants,
  active/default mappings, and the account balance cache. A removed derivation index is never reused;
  a retained account-zero seed identity prevents duplicate group import after account-zero removal.
- Kept complete-group deletion for a private-key account and for the final account in a seed group.
  Labels remain display metadata and never enter signing, connection, migration, or canonical request
  identity.

### Why

- The account picker should support ongoing organization rather than acting only as a dismissing
  selector. Seed-derived keys cannot be erased independently from retained entropy, so account removal
  is explicitly registry removal with durable cleanup rather than a false key-deletion claim.

### Verification

- Reconciled the new behavior with the current registry, group lifecycle, connection cleanup, pending
  request, home-selection, and picker navigation design in the maintained handover and multi-account
  plan.
- Documentation-only scope update; no application behavior or tests changed.

### Follow-Up

- Implement Gate I with registry-schema migration, fault-injected account-deletion recovery, UI tests,
  the normal Swift verification ladder, and simulator reinstall/launch.

## 2026-08-26 - Gate H Cross-Profile And Device-Lock Acceptance

### Summary

- Installed and launched the latest development-signed app and nested Safari extension on the
  physical iPhone while preserving the existing multi-account wallet state.
- Completed exact-origin Safari profile isolation with Personal and a disposable second profile.
  Each profile retained a different active account, and switching profiles did not change the other
  profile's provider account.
- Queued a protected signing request in the disposable profile. Its page-menu badge and popup request
  were absent from Personal and remained available only in the requesting profile.
- Left a fresh protected signing request pending through a device auto-lock interval. No result was
  released while locked; the same review recovered after reconnection and rejected normally.
- Disconnected both test grants and deleted the disposable Safari profile after acceptance. Gate H is
  complete.

### Investigation

- The first post-install page reload retained a stale Safari extension context: the dapp had no
  provider and native showed no pending request even though the extension remained enabled for both
  profiles. Force-quitting and relaunching Safari loaded the newly installed content script and
  background worker; the same request then queued normally.
- A direct libimobiledevice sleep attempt could not see the CoreDevice-only network pairing. The
  accepted lock check instead closed Mirroring for the configured auto-lock interval and reopened it
  while the fresh canonical request was pending.

### Verification

- `stupid-app doctor` completed with zero failures and zero warnings.
- The initial sandboxed `stupid-app build` could not write SwiftPM/Clang caches outside the workspace;
  the unrestricted retry succeeded.
- `stupid-app run --network --udid <device> --sudo /usr/bin/sudo` rebuilt, signed, packaged, installed,
  and launched the current app and nested extension on the physical iPhone.
- Physical Safari proved per-profile account/grant persistence, cross-profile badge and pending-popup
  isolation, lock-without-completion, post-lock recovery, and normal rejection. No secret, complete
  address, request identifier, signature, device identifier, or profile identifier is recorded here.

### Follow-Up

- Repeat `SFExtensionProfileKey` acceptance on every other supported iOS version before treating the
  tested runtime behavior as universal.
- Broader backup reveal timeout/screen-capture and passcode-fallback checks remain release hardening;
  they are not multi-account Gate H blockers.

## 2026-08-26 - Account Switch Menu Icon

### Summary

- Replaced the main screen account submenu row's repeated blockie with a trailing
  `arrow.left.arrow.right` symbol. The toolbar button retains the selected account blockie, and the
  menu uses an anchored SwiftUI popover so the switch icon can occupy the trailing edge.

### Why

- `UIAction` always rendered its image in the leading slot on the supported iOS runtime. An anchored
  popover preserves the compact menu interaction while allowing the directional symbol to be aligned
  at the requested trailing edge.

### Verification

- `swift format` and `swift format lint` passed for `ContentView.swift`; `git diff --check` passed.
- `swift test` passed all 289 tests in 34 suites.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Live inspection confirmed the switch symbol occupies the account row's trailing edge, and selecting
  that row dismissed the popover and opened the grouped Accounts sheet.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` built, signed, packaged,
  installed, and launched the app and nested Safari extension on the paired iPhone.

### Follow-Up

- None.

## 2026-08-26 - Prototype Result-State Borders

### Summary

- Removed the filled backgrounds from the prototype dapp's result messages. Success and failure are
  now distinguished by green and red borders while retaining the current page background.

### Verification

- `bun run build` passed for `PrototypeDapp`.

### Follow-Up

- None.

## 2026-08-26 - Mac Safari Multi-Account Acceptance

### Summary

- Completed the Apple Silicon Mac portion of multi-account Gate H using the production-identity
  TestFlight app, the tracked Xcode compatibility project, and Safari Technology Preview.
- Regenerated the tracked XcodeGen project so current multi-account Swift sources belong to the Mac
  targets. Upgraded a real disposable Dawn installation in place, verified registry adoption without
  setup fallback or identity replacement, then added a separate seed group and derived account.
- Fixed the Safari popup account picker so all grouped accounts remain reachable inside the fixed
  viewport without wheel input falling through to the dapp. Manifest version is now `0.1.49` and the
  Mac compatibility build number is 7.
- Fixed a provider completion race: a status poll arriving while approval owns the request claim now
  remains pending after profile/binding validation instead of reporting the request missing. Added a
  deterministic regression test for that lock overlap.
- Added an `eth_blockNumber` action to the local prototype dapp for explicit generic-passthrough
  acceptance.

### Why

- TestFlight can replace the production PlugInKit registration and leave multiple Safari rows, so
  visible version labels and exact appex paths must be reconciled before runtime conclusions.
- The popup must own its account-list scroll region on Mac, and durable provider polling must
  distinguish a temporarily claimed record from a genuinely absent record.

### Verification

- Safari Technology Preview exposed only the current extension after stale TestFlight/local
  registrations were removed. EIP-6963 discovery, grouped account rendering and rebind, connection
  completion, rejection and badge clearing, same-origin bootstrap, and generic `eth_blockNumber`
  passthrough succeeded without Mac-specific web code.
- Native protected signing produced a consumed 65-byte signature. Independent recovery with
  `cast wallet verify` matched the persisted request account. No seed phrase, private key, complete
  address, request identifier, or signature is recorded here.
- `swift test` passed 289 tests, including the new decision-claim status regression.
- `node --test Tests/JavaScript/*.test.mjs` passed 20 tests, including the popup overflow check.
- `bun run build` passed for `PrototypeDapp`.
- `stupid-app doctor` completed with zero failures and zero warnings; `stupid-app build` produced the
  arm64 iOS debug app.
- `xcodegen generate --spec Mac/project.yml` regenerated the tracked compatibility project, and
  `xcodebuild -project Mac/StupidWalletMac.xcodeproj -scheme StupidWallet -destination
  'platform=macOS,arch=arm64' -derivedDataPath /tmp/StupidWalletMacDerivedData build` succeeded with
  only the existing orientation and launch-configuration warnings.
- Safari's temporary “Press Tab to highlight each item on a webpage” setting was restored to its
  original disabled value, and the temporary diagnostic log was removed.

### Follow-Up

- Gate H now retains only cross-profile and device-lock acceptance. Mac transaction broadcast and a
  network receipt remain separate transaction-release evidence, not a multi-account Gate H blocker.

## 2026-08-26 - Gate B Physical Seed And Account-Lifecycle Acceptance

### Summary

- Completed Gate B physical-iPhone acceptance through iPhone Mirroring plus on-device Face ID. The
  containing app canceled a generated backup before registration, derived the next monotonic account
  from an existing protected seed group, exported that derived account's private key, and cleared the
  reveal on navigation without retaining secret material in project documentation.
- Connected a separate Safari origin through the popup's grouped account picker, rebound the plain
  connect request from the private-key proposal to the derived seed account, approved it, and completed
  a canonical `personal_sign` request with Safari foregrounded. Mirroring alone could not satisfy the
  protected release; the request completed only after Face ID on the physical phone.
- Permanently deleted the seed group after explicit owner confirmation. All three derived accounts
  disappeared, the seed-backed Safari origin became disconnected on return, and the independent
  private-key group remained registered and became the surviving home account.
- Imported a public, never-funded BIP-39 test vector through the physical app. On-device authentication
  completed protected storage and account-zero derivation, and the new seed group appeared alongside
  the retained private-key group. No phrase, private key, full address, or device identifier is recorded
  here.
- Recorded the reusable iPhone Mirroring/physical Face ID boundary in the wallet debugging skill.

### Why

- Hermetic and simulator coverage cannot prove the physical keychain access-control boundary, actual
  Face ID behavior while Safari remains foregrounded, or complete cleanup across the app/extension
  shared state. These checks close Gate B without weakening the native approval or one-time pending
  request protocol.

### Verification

- Physical UI inspection proved generated-backup cancellation left no partial group; derivation added
  exactly the next account; seed-derived export transitioned only after protected release and cleared
  on navigation; and deletion removed the complete seed group while retaining the other group.
- Physical Safari displayed the canonical connect card for a distinct origin, listed the private-key
  group plus all seed accounts, rebound to the selected seed account, committed the connection, and
  displayed that account as active. A subsequent canonical message-signing request completed after
  on-device Face ID while Safari stayed foregrounded.
- Returning to the seed-connected origin after deletion showed no connected account. A diagnostic
  reconnect request proposed the surviving private-key account and was rejected without changing the
  connection default.
- `stupid-app --version` reported 0.0.8 with Swift 6.2.1 before device acceptance. No source, package,
  entitlement, or project-configuration change was required.
- `git diff --check` passed for the resulting documentation and debugging-skill updates.

### Follow-Up

- Gate H still requires cross-profile and device-lock acceptance plus the Mac compatibility Safari
  account model. Focused backup timeout/screen-capture checks also remain release hardening work.

## 2026-08-26 - Gate G Provider Account Lifecycle

### Summary

- Added provider-owned account state initialized from native `visibleAccounts`. Connect,
  `eth_accounts`, and disconnect responses update that state directly, while duplicate snapshots are
  suppressed so `accountsChanged` fires only for an actual one-account-or-empty transition.
- Added a sender-scoped account bootstrap route and payload-free same-origin tab refresh after
  successful connect or disconnect. Tabs for another top-level origin receive no refresh; each
  receiver resolves its own native snapshot under Safari's authoritative profile context.
- Added bridge refresh on initial injection, `pageshow`, window focus, and visible
  `visibilitychange`. No interval polling was added. WebExtension manifest `0.1.48` carries the new
  provider, bridge, and worker resources.
- Fixed physical-device injection on LAN-hosted HTTP fixtures. Safari does not expose
  secure-context-only `crypto.randomUUID` there, so provider initialization now generates the same
  RFC 4122 v4 session identity from `crypto.getRandomValues` when necessary.

### Why

- The containing app cannot dispatch directly into iOS Safari after account removal. Refreshing one
  atomic native snapshot on proven page lifecycle signals converges provider state without leaking
  another origin's account or running a permanent poller.

### Verification

- `node --test Tests/JavaScript/*.test.mjs` passed all 19 tests. New coverage proves provider
  deduplication, connect/disconnect transitions, native bootstrap, same-origin versus cross-origin tab
  delivery, return-to-page lifecycle refresh, and provider injection without `crypto.randomUUID`.
  Oxc formatting/linting, JavaScript syntax checks, manifest JSON validation, and `git diff --check`
  passed.
- `swift test` passed all 288 tests in 34 suites. `stupid-app 0.0.8 doctor` completed with zero failures
  and warnings, `stupid-app build` succeeded, and `stupid-app run --simulator --udid
  <preferred-simulator>` installed and launched; the final manifest `0.1.48` was installed and launched
  on both the preferred simulator and the physical iPhone over Wi-Fi.
- Live simulator Safari bootstrapped an existing connection after extension relaunch. Disconnecting
  that exact account/site grant from the containing app and returning to the existing Safari page
  changed the dapp to disconnected immediately without a reload, proving focus/visibility lifecycle
  refresh and showing that polling is unnecessary.
- Wi-Fi installation and launch of manifest `0.1.48` succeeded on the physical iPhone. The first LAN
  fixture attempt reproduced provider-not-found despite enabled website access; the insecure-origin
  UUID regression above fixed it. After reinstall and reload, Connect opened the canonical wallet
  request normally.
- Physical Safari acceptance passed: approving Connect in one of two same-origin tabs updated the
  other tab without reload; containing-app Connected Apps revocation disconnected the existing page
  immediately on return; force-quitting and reopening Safari restored the retained connected account
  without approval; and changing only the containing-app home account left the dapp's active account
  unchanged.
- A final reconnect attempt was not used as acceptance evidence: repeated test taps created separate
  deliberate pending calls, and the opened popup instance did not list them. The canonical records
  were not edited or deleted and were left to expire under normal policy; Gate F's successful
  simulator connection proof and the later physical `0.1.48` connection both provide current
  connect-approval evidence.

### Follow-Up

- Gate H retains physical-device and Mac Safari multi-account acceptance, including concrete
  cross-profile event isolation. Gate B physical protected-seed acceptance also remains open.

## 2026-08-26 - Gate F Revisioned Connect Account Selection

### Summary

- Added grouped public account summaries and a sticky popup account picker for the active plain-connect
  request. The picker lists only available existing registry accounts and routes both direct-native and
  background-fallback selection through revisioned native messages.
- Added claimed connect rebinding that preserves page intent and retry identity while replacing the
  selected account, account-inclusive binding digest, and request revision. Approve and reject now
  require the popup's reviewed revision, so stale decisions fail closed.
- Made connect completion recoverable: one connection-state revision writes the exact grant, active
  origin/profile account, future connection default, and `ConnectCommit` before pending consumption.
  Status, later decisions, and group deletion reconcile a valid marker to the committed result and
  preserve conflicts for fail-closed diagnosis.
- Changed retained provider retry identity to cover terminal records and separated its scan from
  explicit request transitions. Unsupported pre-v2 bindings are not decoded as retry inputs, while an
  explicit decision for a decodable unsupported record still fails as a binding mismatch. WebExtension
  manifest `0.1.45` carries the popup and worker changes.

### Why

- Popup account choice must not create partial connection authority or let another stale popup approve
  a different account. A durable marker is required because connection state and pending files cannot
  be committed atomically together.
- Retained unsupported rebuild records are outside migration scope and must not block a new Gate F
  connect, but hiding them from explicit request-ID handling would incorrectly turn a binding conflict
  into a not-found result.

### Verification

- `swift test` passed all 288 tests in 34 suites, including revision races, stale decisions, marker
  recovery/conflicts, deletion reconciliation, terminal polling after account removal, and unsupported
  retry-record isolation.
- `node --test Tests/JavaScript/*.test.mjs` passed all 14 tests. Oxc formatting/linting, JavaScript
  syntax checks, manifest JSON validation, and `git diff --check` passed.
- `swift format lint --recursive Sources Tests` reported only the three pre-existing block-comment
  warnings in `SecurityWalletBackend.swift`.
- `stupid-app 0.0.8 doctor` completed with zero failures and warnings, `stupid-app build` succeeded, and
  `stupid-app run --simulator --udid <preferred-simulator>` installed and launched manifest `0.1.45`.
- Live simulator Safari acceptance prepared a connect request despite retained unsupported pre-v2
  records, rendered the sticky account button, listed grouped private-key and seed accounts with no
  creation controls, rebound to a different seed account, rerendered the selected account, approved,
  and returned that account to the dapp.

### Follow-Up

- Implement Gate G's origin/profile-scoped provider account state and `accountsChanged` lifecycle.
- Gate B physical protected-seed acceptance and Gate H physical/Mac multi-account Safari acceptance
  remain separate.

## 2026-08-26 - Gate E Account-Specific Safari Policy

### Summary

- Replaced Safari's separate home-account and grant reads with one native `visibleAccounts` operation
  backed by a validated registry/connection snapshot. `eth_accounts` and existing plain-connect
  short-circuiting now expose only the active account for the authoritative origin/profile.
- Injected the registry-backed account resolver into production `WalletService`. Every non-connect
  wallet-owned prepare resolves the active origin/profile account, validates standard personal-sign,
  typed-data, transaction, and batch account fields, and persists that account in binding version 2.
- Approval now re-resolves the active account, rejects disconnect or active-account replacement, and
  selects the protected private-key or seed-derived signer from the persisted request account. SIWE and
  all other non-connect records remain immutable rather than following home/default/active changes.
- Kept one deterministic creation-time-plus-UUID queue across accounts. Added recovered-signer tests
  for two connected accounts, mismatch and active-replacement regressions, SIWE immutability coverage,
  atomic visible-account coverage, and a JavaScript regression proving `eth_accounts` makes one native
  account-state request. WebExtension manifest `0.1.44` carries the worker change.

### Why

- The home-selected account is containing-app state, not dapp authority. Resolving account and grant in
  separate calls could combine different snapshots, and retaining one home signer could sign a request
  for the wrong connected account after a home or active-account change.

### Verification

- `swift test` passed all 276 tests in 34 suites. Focused Gate E coverage proves two account-specific
  requests coexist in the global queue and each signature recovers to its persisted account; mismatched
  standard account fields fail before persistence; and active-account replacement terminalizes ordinary
  signing and SIWE requests.
- `node --test Tests/JavaScript/*.test.mjs` passed all 12 tests. Oxc formatting/linting, `node --check`,
  manifest JSON validation, and `git diff --check` passed.
- `swift format lint --recursive Sources Tests` reported only the three pre-existing block-comment
  warnings in `SecurityWalletBackend.swift`.
- `stupid-app 0.0.8 doctor` completed with zero failures and warnings, `stupid-app build` succeeded, and
  `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app and
  extension resources. Accessibility inspection confirmed the retained wallet home rendered.

### Follow-Up

- Implement Gate F's revisioned popup connect-account picker and recoverable connect commit before
  changing the future connection default. Gate G provider account events and Gate H physical/Mac
  multi-account Safari acceptance remain separate.

## 2026-08-26 - Gate D Containing-App Account UX

### Summary

- Added a grouped account picker opened from the home account-menu address. It selects existing
  accounts, derives the next account only for seed groups, and links to additive seed/private-key
  wallet flows without exposing creation or key operations to Safari.
- Replaced containing-app singleton provisioning with registry-backed group operations. New wallet
  creation now generates a BIP-39 phrase, requires explicit backup confirmation before registration,
  clears the visible phrase on cancellation/backgrounding/completion, and stores protected entropy
  rather than an address-keyed child key.
- Added journaled home-account selection with protected-source availability validation. Selection
  updates only registry/home state and the fail-closed downgrade projection; it does not mutate the
  connection default, grants, or active provider accounts.
- Made account-scoped destinations stable across selection changes. Balance, Activity, Connected Apps,
  Settings, EIP-7702 authorizations, group-aware forgetting, and private-key export now resolve the
  selected home account, including seed-derived accounts through `WalletAccountResolver`.

### Why

- Gate D makes the existing multi-account registry usable without weakening the separation between
  containing-app home state and Safari authorization state. Generated wallets must remain seed-backed
  so sibling derivation does not depend on persisted child keys.

### Verification

- `swift test` passed all 271 tests in 34 suites. New manager coverage proves persisted home selection,
  fail-closed seed/private-key compatibility projection changes, unavailable-source rejection, and
  unchanged connection authority.
- `node --test Tests/JavaScript/*.test.mjs` passed all 11 tests. `stupid-app doctor` completed with zero
  failures and warnings, and `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Accessibility-driven acceptance created a generated seed wallet after confirmation, derived its next
  account, switched between private-key and seed accounts, proved selection persisted after relaunch,
  observed empty account-scoped Activity and Connected Apps for the new account, confirmed seed-group
  `Forget Wallet` wording, and successfully exercised seed-derived private-key reveal without recording
  secret material.
- The simulator accessibility audit reported no critical issues; its seven warnings are missing-trait
  warnings on the current Settings hierarchy.

### Follow-Up

- Complete Gate B's physical-device protected-seed/signing/export/deletion acceptance.
- Proceed to Gate E account-specific Safari request policy. Gate F popup connect selection and Gate G
  provider account events remain intentionally separate.

## 2026-08-26 - Gate C Account-Scoped Connections And Activity

### Summary

- Completed the Gate C runtime transition to account-scoped connection authority. Authorization reads
  now validate registry membership while holding registry then connection locks; multiple accounts can
  retain grants for one origin/profile while active and default selections remain independent.
- Split provider disconnect from exact connected-app-row deletion. Provider disconnect removes the
  effective same-account hostname fallback as well as its exact grant, while exact-row deletion retains
  separately persisted hostname grants. The JavaScript route now propagates native structured failures
  instead of resolving failed durable revocation as success. WebExtension manifest `0.1.43` carries the
  corrected worker.
- Routed containing-app Forget Account through recoverable group deletion and scoped app activity,
  connected-app details, authorization reads, and cleanup to the selected account.
- Serialized activity migration with `BEGIN IMMEDIATE`, retained Dawn versions 1/2 and shipped rebuild
  versions 3/4/6/7/8/9, and made unknown or malformed schemas fail before mutation. Validation now
  covers exact canonical columns, type/nullability/primary-key shape, app foreign keys, signature
  uniqueness by version, and the complete current-version index set.
- Added deterministic coverage for every shipped activity schema, near-valid malformed current schemas,
  provider disconnect envelopes, and a real child-process grant update retained by the next mutation.
  Recorded the native-envelope failure pattern in the wallet debugging skill.

### Why

- Gate C requires account identity to remain consistent across registry, connection, activity, deletion,
  and provider boundaries. Silent schema repair or a false-success disconnect could expose stale account
  authority even when the UI or dapp believed it had been removed.

### Verification

- `swift test` passed all 269 tests in 34 suites. The focused `ActivityStoreTests` run passed 12 tests,
  including eight historical-version migration cases and four malformed-version-9 cases.
- `node --test Tests/JavaScript/*.test.mjs` passed all 11 tests. `oxfmt`, `oxlint`, and `node --check`
  passed for the changed extension JavaScript and manifest.
- `swift format lint --recursive Sources Tests` reported only the three pre-existing block-comment
  warnings in `SecurityWalletBackend.swift`; `git diff --check` passed.
- `stupid-app 0.0.8 doctor` completed with zero failures and warnings. `stupid-app build` succeeded,
  and `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app
  and extension resources. Accessibility inspection confirmed the retained wallet home rendered.

### Follow-Up

- Complete Gate B's physical protected-seed/signing/deletion acceptance, then proceed to Gate D. Gate E
  account-specific Safari request policy, Gate F connect account selection, and Gate G provider account
  lifecycle remain intentionally separate.

## 2026-08-25 - Private-Key Reveal Lifecycle Fix

### Summary

- Changed private-key reveal clearing to react to the SwiftUI `.background` scene phase rather than
  every phase other than `.active`. Navigation away and the 60-second timeout still clear the value.
- Recorded the LocalAuthentication scene-phase behavior in the wallet debugging skill.

### Why

- On a physical iPhone, the system user-presence prompt temporarily moved the app to `.inactive`.
  Authentication succeeded and the key briefly rendered, but the broad lifecycle handler immediately
  erased it and restored the Reveal button.

### Verification

- `swift test` passed all 256 tests in 34 suites. `stupid-app doctor` completed with zero failures and
  warnings, and `git diff --check` passed.
- `stupid-app run --usb --udid <connected-device> --sudo /usr/bin/sudo` rebuilt, signed, installed,
  and launched the app and nested extension on the connected iPhone. Physical-device verification
  confirmed the key remains visible after authentication, while navigation away and actual app
  backgrounding still clear it.

### Follow-Up

- None.

## 2026-08-25 - Gate B Bootstrap, Signing, And Deletion

### Summary

- Added idempotent empty-install bootstrap under the registry-adoption claim. A fresh installation now
  persists an empty complete registry and revision-zero connection state while keeping the compatibility
  projection absent. Current-rebuild registration remains an unsupported exclusion signal and is not
  adopted.
- Added `WalletAccountResolver` and registry-backed signers. Private-key groups load their address-keyed
  item; seed groups load one protected entropy item and derive the registered child only in memory under
  the group lifecycle claim. Signing and private-key export revalidate active membership and the derived
  address, then clear transient buffers. Safari home-account signing and Settings export now use this
  resolver.
- Added recoverable group deletion. The registry first commits `.deleting` and a deterministic surviving
  home selection through the projection journal. Cleanup then terminalizes matching pending requests,
  deletes and verifies absence of the protected source, removes matching connection grants/active state,
  repairs the connection default, removes account caches and exact migration material, and finally
  removes the group. Adoption resumes retained `.deleting` groups before publishing ready state.
- Future connect-commit markers are deliberately preserved and make deletion fail loudly. Their
  reconcile-to-consumed protocol remains coupled to Gate F, before runtime code can create markers.

### Why

- Empty authority must exist before the first seed group can register without reviving unsupported
  singleton state. Protected operations and deletion must share one cross-process group claim so a
  signature already holding the claim may finish, while no operation beginning after `.deleting`
  commits can release the removed group's secret.

### Verification

- `swift test` passed all 256 tests in 34 suites. New coverage proves interruption-safe empty bootstrap
  at every existing persistence fault point, seed account-one sign/recover and export from one entropy
  item without child-key persistence, private-key-group derivation rejection, complete account-state
  cleanup, and recovery after secret deletion fails with the group already marked `.deleting`.
- `swift format lint --recursive Sources Tests` reported only the three pre-existing block-comment
  warnings in `SecurityWalletBackend.swift`. `git diff --check` passed before this documentation update.
- `stupid-app 0.0.8` doctor completed with zero failures and warnings, and `stupid-app build` succeeded
  against the iOS 26.1 SDK.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched on the
  preferred iOS 26.3 simulator. Accessibility inspection confirmed the retained wallet home screen
  rendered after launch.
- `stupid-app run --usb --udid <connected-device> --sudo /usr/bin/sudo` rebuilt, development-signed,
  installed, and launched the containing app and nested Safari extension on the connected iPhone. The
  first unprivileged attempt installed successfully but could not create the CoreDevice TUN needed for
  launch. This proves current artifact installation and launch, not the remaining seed-keychain flows.

### Follow-Up

- Complete Gate B on a physical device by proving protected seed creation/import, derivation,
  seed-backed signing and export, authentication cancellation/device-lock behavior, and complete group
  deletion.
- Gate D must replace the singleton setup/forget UI with generated-seed backup confirmation and group
  operations. Gate F must reconcile connect markers during deletion before enabling marker writes.

## 2026-08-25 - Gate B Seed And Derivation Foundation

### Summary

- Began Gate B with canonical BIP-39 entropy generation and entropy/mnemonic round trips for every
  supported English word count. Generalized BIP-32 derivation from account zero to
  `m/44'/60'/0'/0/{index}` and return the actual valid index when an invalid child must be skipped.
- Added `KeychainSeedStore`, storing one entropy item per lowercase wallet-group UUID under the
  dedicated seed service with user-presence access control, ThisDeviceOnly accessibility, a fresh
  authentication context per release, a noninteractive existence probe, and no child-key persistence.
- Added suspension-safe group lifecycle coordination through synchronous `NSFileCoordinator` claims.
  This avoids retaining an App Group `flock` while a containing app may be suspended.
- Added `WalletGroupManager` operations that import verified seed and private-key groups into an
  already complete registry and derive the next seed account under the group claim. Registration
  rejects duplicate addresses, advances indexes monotonically, preserves home selection, and removes
  a newly inserted secret when authenticated verification fails before registration.
- Extended registry readiness validation so every active seed group must have its exact protected
  entropy item, just as each active private-key group must have its address-keyed item.
- Kept these APIs out of the current singleton setup and Safari paths. Fresh-install bootstrap,
  seed-backed signing/export, recoverable group deletion, and account UI remain separate work.

### Why

- Seed provenance and serialized derivation must exist before account UI or Safari account selection
  can safely expose additional accounts. Persisting only account-zero child keys would make sibling
  derivation impossible and violate the approved one-entropy-item model.
- Secret-bearing derivation may span interactive authentication, so it needs the same suspension-safe
  coordination lesson proven during Gate A rather than a long-lived App Group advisory lock.

### Verification

- `swift test --filter SeedPhraseTests` passed 6 tests, including independent Hardhat account-zero and
  account-one vectors, all supported entropy sizes, generation, checksum, vocabulary, and boundary
  rejection.
- `swift test --filter WalletGroupManagerTests` passed 6 tests covering seed/private-key registration,
  duplicate seed rejection, authenticated rollback, account-one derivation, no child-key persistence,
  and concurrent monotonic allocation of indexes one and two.
- The seed-source readiness regression proves an active seed group fails closed without its exact
  entropy item and becomes ready when that group ID is present.
- `swift test` passed all 252 tests in 34 suites.
- `swift format lint --recursive Sources Tests` reported only the three pre-existing block-comment
  warnings in `SecurityWalletBackend.swift`. `git diff --check` passed.
- `stupid-app 0.0.8` doctor completed with zero failures and warnings, and `stupid-app build` succeeded
  against the iOS 26.1 SDK.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app on
  the preferred iOS 26.3 simulator.

### Follow-Up

- Add fresh-install registry and connection-state bootstrap so generated seed creation can become the
  default setup path only after backup confirmation.
- Add seed-backed signer and private-key export resolution under the group lifecycle claim, verifying
  the derived address against the registry before use.
- Implement and fault-test resumable `.deleting` cleanup before declaring Gate B complete, then prove
  seed entropy protection and derivation on a physical device.

## 2026-08-25 - Shared Call Detail Tables

### Summary

- Extracted the popup's bordered request-detail table into one reusable renderer.
- Changed each `wallet_sendCalls` call from a filled card to the same detail-table presentation used
  by `eth_sendTransaction`, retaining optional Value and Data rows and expandable calldata.
- Removed the obsolete batch-card styles and bumped the WebExtension manifest to `0.1.42`.

### Why

- Single transactions and atomic calls should present the same canonical call fields with one visual
  language and one DOM implementation.

### Verification

- Extension `oxfmt`, `oxlint`, `node --check`, manifest JSON validation, and `git diff --check`
  passed. `node --test Tests/JavaScript/*.test.mjs` passed all 10 tests, including two batch calls
  rendered through the shared bordered detail table with omitted zero/empty fields.
- `swift test` passed all 181 tests in 28 suites.
- `stupid-app doctor` completed with zero failures and warnings, and `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app
  and extension resources with manifest `0.1.42`.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` assembled, signed,
  packaged, installed, and launched the app and nested Safari extension on the paired iPhone.

### Follow-Up

- Confirm the shared table layout in a live multi-call Safari popup.

## 2026-08-25 - Compatible Request Blockies

### Summary

- Replaced the popup's approximate identicon generator with the exact `blo` 2.0 Ethereum blockies
  algorithm: lowercase seed hashing, signed-shift xorshift PRNG, `2^31` random scale, upstream
  random-call order, background/main/spot palette mapping, and mirrored 4x8 source pixels.
- Kept the project-owned DOM renderer and squircle clipping rather than adding a runtime package.
- Rendered exact address values in generic request-detail tables as block containers, removing the
  same inline baseline padding previously corrected in atomic-call cards.
- Pinned upstream commit `bb15b6309bb5903601adab83d049c53a5a6852d2`, provenance, adaptation,
  copyright, and complete MIT terms in `THIRD_PARTY_NOTICES.md`.
- Bumped the WebExtension manifest to `0.1.41`.

### Why

- The previous popup implementation used the wrong shift semantics, random scale, and palette order,
  so its output did not match standard Ethereum blockies or the referenced `blo` implementation.

### Verification

- Added a full deterministic palette and 64-pixel vector for a fixed address, plus a rendered
  `eth_sendTransaction` To-address regression. `node --test Tests/JavaScript/*.test.mjs` passed all
  10 tests.
- Extension `oxfmt`, `oxlint`, `node --check`, manifest JSON validation, and `git diff --check`
  passed.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched
  manifest `0.1.41`.
- `stupid-app doctor` completed with zero failures and warnings.
- `stupid-app run --network --udid <paired-device> --sudo /usr/bin/sudo` assembled, signed,
  packaged, installed, and launched the app and nested Safari extension on the paired iPhone.
- Live Safari inspection confirmed the corrected blockie in a transaction To row and sticky footer
  without the prior address baseline padding. The transaction was left unapproved.

### Follow-Up

- Recheck the same deterministic address against the referenced `blo` SVG in Mac Safari before
  release.

## 2026-08-25 - Home Account Squircle

### Summary

- Changed the top-trailing 28-point account-menu blockie button and its generated icon clip from a
  circle to an 8-point continuous-corner squircle, matching request-preview blockies.

### Why

- Address identity should use one consistent shape across the home screen and Safari confirmations.

### Verification

- `swift format --in-place Sources/StupidWallet/ContentView.swift` completed, `git diff --check`
  passed, and `swift test` passed all 181 tests in 28 suites.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Simulator inspection confirmed the top-right account blockie is a squircle without clipping.

### Follow-Up

- None.

## 2026-08-25 - Labeled Call Fields

### Summary

- Matched the sticky signing-account text to the action buttons' 14-point text and retained centered
  vertical alignment across the account, Reject, and primary action.
- Added compact uppercase To, Value, and Data headings to every atomic-call card. The fields stack
  vertically at full width, including zero values and empty `0x` calldata.
- Removed the address row's inline-baseline line box so To-to-address spacing matches the compact
  Value and Data label/value rhythm.
- Restored the original 3-point spacing between every field label and value after correcting the
  address baseline, and changed popup blockies from circles to 18-point squircles.
- Increased spacing between call fields, omitted zero Value and empty `0x` Data fields, and removed
  the sticky account's remaining inline baseline box so it centers with both action buttons.
- Shortened the batch introduction to "Review the calls that will execute." and bumped the
  WebExtension manifest to `0.1.39`.

### Why

- The signing account and actions are one authorization bar, and call fields need explicit,
  consistently spaced labels without a side-aligned Value column.

### Verification

- Extension `oxfmt`, `oxlint`, `node --check`, manifest JSON validation, and `git diff --check`
  passed. `node --test Tests/JavaScript/*.test.mjs` passed all 10 tests, including ordered To,
  Value, and Data labels across two calls and account placement inside the action bar.
- `swift test` passed all 181 tests in 28 suites before the CSS-only baseline correction.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  request-review resources through manifest `0.1.39`.
- `stupid-app doctor` completed with zero failures and warnings.
- Live Safari inspection confirmed vertically stacked non-empty call fields with even label and
  inter-field spacing, squircle blockies, omitted zero values, and the account text centered on the
  same vertical coordinate as both sticky action buttons. The two-call request was left unapproved.

### Follow-Up

- Recheck the labeled call cards at the Mac Safari popup width before release.

## 2026-08-25 - Multi-Call Card And Action Bar Polish

### Summary

- Reduced atomic-call card vertical padding from 12 to 8 points while preserving 12-point
  horizontal alignment.
- Moved the non-connect signing account out of the scrolling request body and into the sticky action
  bar, where its blockie and shortened address sit to the left of Reject and the primary action.
- Changed the prototype `wallet_sendCalls` action and native/popup regressions to use two distinct
  calls. The second prototype call includes long calldata so the real popup exercises three-line
  clamping and expansion.
- Bumped the WebExtension manifest to `0.1.32`.

### Why

- Single-line call cards had excess vertical space, the authorizing account should remain visible
  with the approval controls, and multi-call layout needed real Safari verification rather than
  relying on a one-call fixture.

### Verification

- `bunx oxfmt --write <changed JavaScript, TypeScript, CSS, and manifest files>`, extension and
  prototype `oxlint`, `node --check SafariExtension/Resources/popup.js`, and `git diff --check`
  passed. `node --test Tests/JavaScript/*.test.mjs` passed all 10 tests.
- `swift test` passed all 181 tests in 28 suites. The EIP-5792 service fixture now summarizes and
  estimates a two-call batch.
- `bun run build` passed for `PrototypeDapp`. `stupid-app run --simulator --udid
  <preferred-simulator>` rebuilt, installed, and launched manifest `0.1.32`.
- `stupid-app doctor` completed with zero failures and warnings.
- A live Safari request displayed `Details (2 calls)` with two compact cards and distinct address
  blockies. Long calldata rendered as three lines with an ellipsis and expanded to its full wrapped
  content when selected. The signing account remained visible in the sticky action bar while the
  details scrolled. The request was left unapproved.

### Follow-Up

- Recheck the same compact card and action-bar layout at the Mac Safari popup width before release.

## 2026-08-25 - Expandable Request Preview Data

### Summary

- Replaced transaction and atomic-call calldata digests with the exact canonical raw calldata. The
  popup clamps calldata to three wrapped lines by default and expands or collapses it when selected.
- Made every exact 20-byte address value in the popup use a deterministic round blockie followed by
  `0x1234...abcd`; the full address remains attached as title metadata.
- Made queued request cards start collapsed and expand from their keyboard-accessible heading. Queue
  order and native approval authority are unchanged, and queued approval remains disabled.
- Removed redundant Execution and Authorization batch rows and retained one regular foreground
  treatment for call targets, values, and calldata.
- Added pre-authorization batch fee estimation with an RPC state override. Undelegated accounts use
  reviewed runtime code, including runtime extracted from the pinned deployment artifact only when
  its hash matches the pinned runtime hash. The display-only estimate overrides balance so call
  value does not block estimation; approval still resolves against real account state.
- Bumped the WebExtension manifest to `0.1.30`.
- Moved the canonical SIWE test vector's expiration into the durable future after its fixed expiry
  made the otherwise deterministic full suite fail; production SIWE validation did not change.

### Why

- Request previews should expose the data a user is authorizing, make addresses quickly
  distinguishable, and keep inactive queued requests compact without changing canonical signing or
  queue policy.

### Verification

- `swift format --in-place <changed Swift files>` and `bunx oxfmt --write <changed extension and
  JavaScript test files>` completed. `bunx oxlint SafariExtension/Resources/popup.js
  Tests/JavaScript/popup.test.mjs`, `node --check SafariExtension/Resources/popup.js`, `jq empty
  SafariExtension/Resources/manifest.json`, and `git diff --check` passed.
- `node --test Tests/JavaScript/*.test.mjs` passed all 10 tests, including rendered blockie,
  collapsed-queue, and calldata-expansion behavior.
- `swift test` passed all 181 tests in 28 suites, including raw single-send and atomic-call calldata
  summary regressions and pre-authorization state-override estimation coverage.
- `stupid-app doctor` completed with zero failures and warnings. `stupid-app build` succeeded, and
  `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app
  and extension.
- A live two-request Safari run showed blockie-prefixed `0x1234...abcd` call targets and a second
  card containing only its heading and Queued badge by default; selecting that heading revealed its
  details while approval remained disabled. Both requests were left unapproved. The prototype's
  built-in batch uses empty calldata, so long-data clamping was verified by the rendered DOM test.

### Follow-Up

- Exercise long calldata and multiple queued requests in both iPhone and Mac Safari popup widths
  before release.

## 2026-08-25 - Request Review And Account Menu Polish

### Summary

- Changed transaction and atomic-call value summaries from hexadecimal wei quantities to trimmed
  native-currency amounts, and changed explicit add-network Chain IDs from hexadecimal to decimal.
- Replaced flattened atomic-call rows with the old app's compact rounded per-call card hierarchy.
  The popup still does not decode calldata; each card uses the canonical target, formatted value,
  and calldata digest supplied by native code.
- Removed popup monospace overrides so request fields use regular system typography.
- Removed the separator bullet from expanded aggregate-balance rows. Rounded the account-menu
  blockie and changed its shortened address from disabled/muted text to regular text that keeps the
  menu presented when selected.
- Bumped the WebExtension manifest to `0.1.28` so Safari reloads the popup resources.

### Why

- These surfaces now match the established old-app layout and human-readable quantity presentation
  without introducing deferred ABI decoding or changing canonical approval/signing inputs.

### Verification

- `swift format --in-place <changed Swift files>`, `node --check
  SafariExtension/Resources/popup.js`, `jq empty SafariExtension/Resources/manifest.json`, and
  `git diff --check` passed.
- Added summary regressions for decimal add-network Chain IDs and native-currency single/batch call
  values. `swift test` passed all 180 tests in 28 suites.
- `stupid-app doctor` completed with zero failures and warnings, and `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app
  and extension. Simulator inspection confirmed the account menu's rounded blockie and regular
  address text, plus expanded network-balance rows without separator bullets.

### Follow-Up

- Exercise a live multi-call Safari request before release to confirm the final popup card layout at
  both iPhone and Mac popup widths.

## 2026-08-25 - Add-Network RPC Fallback

### Summary

- Changed approved `wallet_addEthereumChain` handling to validate the chain-specific Stupidtech
  endpoint with `eth_chainId`. When that endpoint does not serve the requested chain, the wallet
  validates and persists the first supplied `rpcUrls` entry as the fallback.
- Added the fallback candidate to the canonical popup summary and preserved any existing
  user-selected override instead of replacing it with the dapp suggestion.
- Kept the existing HTTPS-or-loopback, reachability, and exact-chain validation policy. Invalid,
  unreachable, insecure, and wrong-chain fallbacks fail loudly.

### Why

- Local development chains such as Anvil are not necessarily available through the universal
  Stupidtech endpoint, even though the dapp supplies a reachable loopback RPC URL.

### Verification

- `swift format --in-place Sources/StupidWalletCore/WalletService.swift
  Tests/StupidWalletCoreTests/RPCClientTests.swift` completed.
- Added hermetic regressions for default-endpoint success and first-URL fallback persistence.
- `swift test --filter RPCClientTests` passed 17 tests in 2 suites in a clean detached worktree
  containing only this add-network change.
- Direct `eth_chainId` probes reproduced the reported boundary: the Stupidtech endpoint for chain
  31337 returned an HTTP 530 error while the local loopback Anvil endpoint returned `0x7a69`.
- The targeted `swift test --filter RPCClientTests` build was blocked by a concurrent, unrelated
  EIP-7702 worktree edit that references an undefined `shouldCacheDeployment(chainID:)`; the new
  tests did not execute in the shared worktree attempt.
- `git diff --check` passed before the documentation update.

### Follow-Up

- Run the full shared-worktree verification ladder and exercise the Anvil add-chain flow after the
  concurrent EIP-7702 edit type-checks.

## 2026-08-25 - Dedicated Monochrome Safari Toolbar Icon

### Summary

- Deterministically converted the existing hand-drawn arrow with ImageMagick into transparent,
  black Safari action icons at 16, 19, 32, and 38 pixels. The app icon, general extension
  icons, provider metadata, and in-page hint remain unchanged.
- Added the dedicated files to `action.default_icon` and the `stupid-app` extension resource list.
- Bumped the WebExtension manifest to `0.1.25` to invalidate Safari's cached action icon.

### Why

- Dedicated action sizes avoid using the padded general extension icon as Safari's toolbar fallback.
  Safari can still apply its blue active-state tint to monochrome artwork; preserving the requested
  black-and-white identity takes precedence over avoiding that platform behavior.

### Verification

- ImageMagick inspection confirmed exact 16x16, 19x19, 32x32, and 38x38 PNG dimensions, alpha
  transparency, and black arrow pixels.
- `jq empty SafariExtension/Resources/manifest.json` and `git diff --check` passed.
- `stupid-app doctor` completed with zero failures and zero warnings.
- `stupid-app build` succeeded. Inspection of the assembled extension confirmed manifest `0.1.25`,
  all four `action.default_icon` mappings, and all four transparent PNG resources at the appex root.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension on iOS 26.3. Safari's Page Menu displayed the hand-drawn arrow with its expected
  system-blue active-state tint, confirming the installed monochrome action icon is current and that
  the blue appearance is Safari rendering rather than stale or colored source artwork.

### Follow-Up

- Confirm the same platform tint on a physical-device surface before release if icon rendering
  differs across supported Safari versions.

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

## 2026-08-25 - Gate 7 SIWE, Atomic Calls, And Wallet Authorizations

### Summary

- Added canonical SIWE support for `wallet_connect`, including ERC-7846 version 1 and the
  shipped legacy `chainIds` request shape. Native code persists and signs the exact EIP-4361
  message and returns the matching account, signature, and message response.
- Added EIP-5792 `wallet_sendCalls`, `wallet_getCallsStatus`, and
  `wallet_getCapabilities`, with strict native validation, atomic `executeBatch` encoding,
  durable call-bundle ownership/status, structured errors, and Safari popup review.
- Added EIP-7702 authorization and type-4 transaction encoding with vectors independently
  cross-checked against viem 2.55.19. Added wallet-owned enable, replace, revoke, receipt,
  and status operations plus the Settings authorization surface.
- Extended the local protocol fixture with SIWE, capability, batch, status, and
  Ethereum/Base/Arbitrum controls. Result JSON now wraps at arbitrary characters so complete
  responses can be read through simulator OCR.

### Security Decisions

- Dapps have no arbitrary authorization-signing method. Automatic batching delegates only
  an account with empty code; foreign delegations and malformed code fail and direct the user
  to the wallet-owned Authorizations surface.
- The only allowed implementation is the reviewed eth-infinitism `Simple7702Account` at
  `0xe6Cae83BdE06E4c305530e199D7217f42808555B`. Its runtime hash is pinned to
  `0xcc7b633aef4b2543cb8f37522adf1a401f910f0f6b2430c1eecc11f401ccfcf3` for chains 1,
  8453, and 42161. Nonempty code alone is not accepted.
- First-delegation gas estimation applies the verified runtime to the account through an RPC
  state override and adds authorization overhead locally. It does not disclose a signed,
  reusable authorization to the RPC before the outer transaction is ready to broadcast.
- SIWE requires HTTPS except for `localhost`, `127.0.0.1`, and `::1`; unsupported
  `wallet_connect` capabilities fail instead of silently becoming plain connection grants.
- App-provided call-bundle IDs are checked under the cross-process prepare lock while an
  identical provider retry still converges on the original pending request.

### Verification

- `swift test` passed 166 tests across 28 suites after the security review fixes.
- `node --check SafariExtension/Resources/background.js`,
  `node --check SafariExtension/Resources/popup.js`, and
  `node --test Tests/JavaScript/*.test.mjs` passed; 9 JavaScript tests ran.
- Prototype `oxfmt`, `oxlint`, TypeScript compilation, and Vite production build passed.
- `stupid-app doctor` completed with 0 failures and 0 warnings; `stupid-app build` and
  simulator install/launch succeeded on the preferred simulator before the final security
  tightening and are repeated as the final verification step.
- Simulator Safari proved provider connection, SIWE review and signature completion,
  capability reporting on Ethereum, Base, and Arbitrum, and atomic batch review/rejection.
  The rejection path made no transaction.
- Read-only RPC checks confirmed nonzero simulator-account balances on all three networks.
  Independent `cast code ... | cast keccak` checks returned the pinned runtime hash on all
  three chains. Ethereum also accepted an `eth_estimateGas` request using the verified runtime
  as a state override.

### Remaining Work

- Coordinate Settings authorization operations and Safari transaction approvals under one
  account/chain nonce lock.
- Preserve queryable call-bundle status if SQLite activity persistence fails after a
  successful broadcast.
- With explicit spend approval, prove first-delegation type-4 and already-delegated type-2
  batches against live networks and independently verify their receipts.
- Prove the two-authentication first-delegation flow on a physical device while Safari
  remains foregrounded.

## 2026-08-25 - Live Base Just-In-Time Authorization And Batch Proof

### Summary

- Executed the local Safari protocol fixture against Base with explicit approval to spend the
  simulator wallet's funded balance.
- The account began with empty code and pending nonce zero. The first `wallet_sendCalls`
  approval displayed the atomic call and possible authorization, completed the protected
  authorization and outer-transaction signatures, and returned a transaction hash.
- The durable canonical record resolved to transaction type `0x4`, outer nonce zero, the
  expected self-targeted `executeBatch((address,uint256,bytes)[])` calldata, and a single
  authorization for the pinned `Simple7702Account` at authorization nonce one.
- After confirmation, account code was exactly the canonical EIP-7702 designator for the
  reviewed implementation and the account nonce was two. A second identical batch resolved
  to type `0x2` at nonce two, confirmed successfully, preserved the designator, and advanced
  the nonce to three.
- `wallet_getCallsStatus` returned status `200`, Base chain ID `0x2105`, and the corresponding
  successful receipt for both call-bundle hashes.

### Independent Verification

- `cast tx <hash> --rpc-url https://evm.stupidtech.net/v1/8453 --json` independently showed
  type `0x4` with the expected authorization tuple for the first transaction and type `0x2`
  without an authorization list for the second.
- `cast receipt <hash> --rpc-url https://evm.stupidtech.net/v1/8453 --json` returned status
  `0x1` for both transactions. The first used less gas than its conservative limit and the
  second used less gas than its separately estimated limit.
- Direct `eth_getCode`, `eth_getTransactionCount`, and `eth_getBalance` responses were saved
  outside the repository before and after each transaction. Total balance reduction across
  both zero-value calls was approximately `0.00000038061 ETH`, entirely transaction fees.
- No wallet address, transaction hash, signature, or account-linked raw response is recorded
  in this public engineering log.

### Remaining Work

- Coordinate Settings authorization operations and Safari transaction approvals under one
  account/chain nonce lock.
- Preserve queryable call-bundle status if SQLite activity persistence fails after a
  successful broadcast.
- Repeat the live type-4/type-2 proof on Ethereum and Arbitrum only when cross-network release
  evidence is required; Base now proves the end-to-end implementation path.
- Prove physical-device authentication and Safari foreground behavior for the two protected
  signatures used by first-time delegation.

## 2026-08-25 - Arbitrary-Network Atomic Batching And Deployment

### Summary

- Removed the Ethereum/Base/Arbitrum allowlist from EIP-5792 canonicalization, Settings
  authorizations, and capability reporting. Atomic calls and wallet-owned EIP-7702 operations now
  apply to every default or manually recorded network.
- Pinned the original Simple7702Account creation code, zero salt, canonical CREATE2 factory,
  factory runtime hash, calldata hash, and derived target address. The Authorizations screen now
  offers deployment when that exact implementation is absent and refuses foreign implementation
  or factory code.
- An approved batch now deploys a missing implementation first, waits for a successful receipt,
  verifies the resulting runtime, and only then obtains a fresh nonce and signs the authorization
  batch. A dapp still cannot select deployment code or a delegate.
- Added a positive-only deployment cache containing the verified runtime. RPC override changes
  invalidate the chain entry. Loopback endpoints bypass persistent caching so a reset local chain
  cannot inherit stale deployment state.
- Extended the protocol fixture with explicit `wallet_addEthereumChain` and switch controls for a
  local Anvil chain.

### Verification

- `swift test -q` passed 171 tests across 28 suites, including custom-chain deployment-before-
  batch ordering, fresh nonces, exact type-2/type-4 serialization, cache behavior, RPC-override
  invalidation, and refusal of missing or mismatched deterministic factories.
- Prototype `oxfmt`, `oxlint`, TypeScript compilation, and Vite production build passed.
- `stupid-app doctor` completed with zero failures and warnings. `stupid-app build` succeeded, and
  `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  app and extension.
- Started Anvil with chain ID 31337 and Prague rules, installed the canonical CREATE2 factory
  runtime, and funded the simulator wallet through `anvil_setBalance`. The dapp added Anvil via
  `wallet_addEthereumChain`; the containing app deliberately selected the loopback RPC override;
  and the provider switched to the new chain.
- The first approved `wallet_sendCalls` produced a successful type-2 implementation deployment,
  then a successful type-4 authorization batch. Runtime code matched the pinned hash, account code
  became the canonical delegation designator, and the account nonce advanced by three. A second
  approved batch used type 2 at the next nonce and also produced a successful receipt.

### Follow-Up

- Settings deployment and Safari sends still need one cross-process account/chain nonce allocation
  boundary so two independently initiated operations cannot reserve the same pending nonce.
- Physical-device proof is still required for the three protected signatures in the fresh-chain
  deployment plus authorization-batch path while Safari remains foregrounded.

## 2026-08-25 - Deployment And Submission Race Hardening

### Summary

- Bound every positive Simple7702Account deployment-cache entry to both decimal chain ID and the
  exact resolved RPC URL. An entry written concurrently with an RPC override change is therefore
  ignored by services resolving the new endpoint even before explicit invalidation is observed.
- Applied the existing loopback cache bypass to the Settings authorization service as well as the
  Safari batch path, preventing reset local chains from displaying stale verified status.
- Added a nonblocking App Group file claim per normalized account and chain. Safari sends and
  batches and Settings deployment, enable, and revoke actions hold that claim from preparation
  through broadcast, so a competing operation fails as busy instead of signing a duplicate nonce.
- Approved add-chain handling now fails before recording network metadata when the default endpoint
  is unusable, no existing override exists, and the request has no valid fallback RPC URL; the
  canonical request is persisted as failed so provider polling receives a terminal error.
- Prevented an older overlapping Authorizations refresh from replacing newer on-screen state.
- Capability reporting now treats a missing implementation as supported only when the pinned
  canonical factory is present, allowing capable dapps to reach just-in-time deployment. Settings
  continues to expose revocation when implementation status is missing, unsafe, or unavailable.
- The just-in-time batch deployment path reuses the outer Safari submission claim instead of
  reacquiring the non-reentrant lock.
- Deployment receipt RPC failures are translated into wallet errors and terminalize the canonical
  batch instead of leaving a retryable pending request after the deployment broadcast.

### Why

- Cache invalidation alone had a race where an in-flight verification against the old endpoint
  could repopulate the chain entry after removal. Endpoint identity makes the cache safe regardless
  of operation ordering.
- Settings and Safari previously fetched pending nonces independently, allowing concurrent
  user-approved operations to sign the same account nonce.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test -q` passed 179 tests across 28 suites, including endpoint-bound cache behavior,
  loopback cache bypass, terminal add-chain fallback refusal, deployable capability reporting,
  unsafe-code capability omission, deployment receipt failure terminalization, first-batch
  deployment ordering, and account/chain submission exclusivity.
- Prototype `oxfmt`, `oxlint`, TypeScript compilation, and Vite production build passed.
- `stupid-app doctor` completed with zero failures and warnings. `stupid-app build` succeeded, and
  `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
- The repository debugging skill passed `quick_validate.py`; `git diff --check` passed.

### Follow-Up

- Physical-device proof remains required for the protected fresh-chain deployment and authorization
  signatures while Safari remains foregrounded.

## 2026-08-25 - Pre-Seeded Network Terminology

### Summary

- Removed the runtime and UI notion of default networks. The four bundled entries are now modeled
  as pre-seeded networks; user- or dapp-added entries remain equally configured networks.
- Renamed `WalletNetwork.defaults` and `isDefault` to `preseeded` and `isPreseeded`, and changed the
  Networks screen sections to `Pre-seeded Networks` and `Added Networks`.
- Preserved installed data compatibility by decoding the old persisted `isDefault` field while
  encoding all subsequently written records with `isPreseeded`.
- Updated current architecture documentation and internal name lookup to use pre-seeded terminology.

### Why

- The bundled list describes initial data, not privileged or exclusive network behavior. Atomic
  calls, authorizations, balances, switching, and RPC configuration apply to every configured
  network regardless of how it entered the store.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test -q` passed 180 tests across 28 suites, including legacy provenance decoding and
  current-key encoding.
- `stupid-app build` succeeded. `stupid-app run --simulator --udid <preferred-simulator>` rebuilt,
  installed, and launched the app; accessibility-driven navigation opened Settings > Networks and
  exposed the four pre-seeded entries plus added Anvil and Polygon entries.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-25 - Unified Network Model

### Summary

- Superseded the preceding provenance rename by removing network provenance entirely from
  `WalletNetwork`. A network now contains only its chain ID, display name, and balance-inclusion
  preference.
- Moved the four initial records to `NetworkStore.initialNetworks`, where they are used only to
  seed the configured list. Returned records are not marked or treated differently based on origin.
- Replaced the separate pre-seeded and added UI sections with one unified Networks list.
- Existing persisted records containing obsolete `isDefault` or `isPreseeded` keys remain readable
  because those unknown JSON fields are ignored, and new writes contain neither key.
- Added persistent deletion for every configured network. Removed chain IDs suppress initial and
  legacy records until an explicit add or successful switch records the chain again.
- Added a destructive Delete Network action to network details. Successful deletion clears its
  custom RPC override and deployment verification cache. If the deleted network was selected, the
  app selects the first remaining configured network instead of blocking deletion.
- Removed the conditional `Use Default RPC` action from network details. The effective endpoint
  remains visible and can be replaced through the existing validated Change flow.

### Why

- Initial seeding is a store construction detail, not persistent network identity or behavior.
  Every configured network should follow the same capability, balance, switching, and RPC paths.

### Verification

- `swift format --in-place <changed Swift files>` completed.
- `swift test -q` passed 180 tests across 28 suites, including decoding records with obsolete
  provenance fields, confirming new records encode without either field, persistent removal of
  initial and added networks, and explicit restoration.
- `stupid-app build` succeeded. `stupid-app run --simulator --udid <preferred-simulator>` rebuilt,
  installed, and launched the app. Accessibility-driven testing confirmed one unified list, a
  detail screen with Change and Delete Network but no Use Default RPC action, successful deletion
  of an ordinary network, and successful deletion of the currently selected local Anvil network.
- `git diff --check` passed.

### Follow-Up

- None.

## 2026-08-25 - Multiple-Account Architecture Plan

### Summary

- Added `docs/multi-account-implementation-plan.md` with the approved product behavior, persistence
  models, migration rules, account and signer resolution, containing-app flows, Safari popup account
  selection, provider semantics, concurrency boundaries, file-level work, ordered gates, and
  verification matrix for multiple wallet groups and accounts.
- Locked seed-backed groups to one protected BIP-39 entropy item with in-memory child derivation at
  `m/44'/60'/0'/0/{index}`. Private-key groups contain exactly one account, and existing installed
  wallets migrate to that one-account form because shipped formats did not retain their seed phrase.
- Separated the home-selected account, the default account proposed for future new connections, and
  the active granted account for each normalized origin/Safari profile.
- Scoped the planned home balance, Activity, Connected Apps, Settings, authorizations, and private-key
  export to the home-selected account.
- Restricted Safari popup account selection to the active plain-connect sticky bar. The popup lists
  existing accounts only; native code owns the canonical rebind, and only successful Connect updates
  the future default while preserving every existing account grant.
- Completed the consistency audit by separating immutable provider retry identity from the
  account-inclusive approval binding, specifying an authoritative connect commit marker and recovery
  path, terminalizing pending legacy-binding requests before they can sign, fixing the cross-process
  lock order, and defining commit-forward registry/projection recovery.
- Tightened the final crash/race boundaries with a durable `.migrating` adoption barrier, locked
  registry-plus-connection snapshots, one-revision connection cleanup during group deletion, marker
  inspection before any pending mutation, and durable pending retry records with no cleanup race in
  this scope.
- Locked registry adoption to remove the rebuild-era `sw2.walletAddress` fallback before any
  multi-account operation. New code projects only a private-key home account through
  `wallet-address.conf`; a seed-backed home removes that file so downgraded code fails closed.
- Updated the maintained engineering handover to mark the design as approved next-scope but not yet
  implemented.
- Added a migration-test prerequisite: prepare legacy Dawn-format state through the old app UI on a
  dedicated physical test device and current singleton-rebuild state on the preferred simulator, then
  install the new build in place without clearing shared persistence. Synthetic fixtures remain unit
  coverage rather than acceptance proof.

### Why

- The current one-address registration, signer construction, origin/profile-only grant key, global
  activity query, singleton balance cache, and noninteractive popup account cannot safely implement
  multiple accounts as isolated UI changes.
- Separate home, default-connection, and per-origin active-account state prevents a containing-app
  selection or another site's connection from silently changing an existing dapp's signing account.
- A detailed migration and recoverability design is required before writing key, grant, pending-request,
  or deletion code across the app and Safari extension processes.

### Verification

- Read the maintained handover and implementation history and traced the current wallet store,
  provisioning, BIP-39/BIP-32, keychain, signing, pending-request, activity, connected-site, app UI,
  Safari handler, popup, background, bridge, provider, and relevant tests.
- Inspected the old application and confirmed that it persisted only one derived private key for seed
  imports, so existing installations cannot be upgraded automatically to expandable seed groups.
- Inspected the installed iOS 26.1 SafariServices SDK and confirmed it exposes profile/message keys but
  no containing-app `dispatchMessage` equivalent; macOS exposes that API separately.
- Repeated the cross-document consistency audit after resolving retry, marker, legacy, projection,
  deletion, adoption, and lock-order findings; no remaining design blocker was identified. This is
  documentation verification only and does not claim implementation or device proof.
- `git diff --check` is run after the final documentation edits.

### Follow-Up

- Implement Gate A from the plan: versioned registry, explicit migration/adoption, connection-state
  authority, and fault-injected recovery tests before adding account UI or popup selection.
- Preserve the now-fixed lock order while adapting the current approval, prepare, and
  transaction-submission paths; add pairwise concurrency tests before protected-secret or
  pending-request mutation ships.

## 2026-08-25 - Gate A Barrier Wiring

### Summary

- Wired the `.migrating` barrier into request entry points. `SafariWebExtensionHandler` now runs the
  idempotent `WalletRegistryAdoption().ensureAdopted()` before every native message and dispatches
  through a registry-gated `WalletService`; a throwing barrier responds with a structured `4900`
  not-ready error. The app `WalletViewModel` runs the same adoption at startup and after create/import
  so the registry tracks a freshly provisioned singleton wallet, while the projection file drives the
  visible account.
- `WalletService` gains an optional `registryStore`. When supplied, `ensureRegistryReady()` fails
  request handling closed while the registry is `.migrating` (mapped to `notReady`), and
  `permanentLegacyBinding` terminalizes any retained pending legacy-binding record (binding version
  not 2) with JSON-RPC code `-32000` and message `Wallet account state changed; retry request` before
  queue checks, expiry, signing, grant mutation, or RPC submission. `prepare`/`list`/`summarize` also
  gate on readiness; `status` still returns the terminalized record's failed state so polling pages
  converge. With no `registryStore`, hermetic single-account behavior is unchanged.
- `ensureAdopted()` now runs the whole-pending legacy-terminalization scan only on the `.adopted`
  transition; records it misses are terminalized lazily by the request paths that encounter them, so
  per-message adoption stays cheap.
- Confirmed Dawn/rebuild adoption never deletes old key material: the Dawn path retains ciphertext and
  Secure Enclave material under the existing cleanup policy, and the rebuild keychain item is preserved
  in place.

### Why

- This closes the remaining Gate A barrier exit condition: app and extension request handling is
  refused until singleton registry, connection, fallback, and cache adoption validate as `.complete`,
  and retained legacy pending bindings can never reach authentication, signing, grant mutation,
  broadcasting, or a later rebind.

### Verification

- `swift format --in-place` and `swift format lint` passed for all changed Swift.
- `swift test --filter WalletRegistryAdoptionTests` passed all 14 focused tests, including new
  coverage: a `.migrating` registry fails `prepare`/`list` closed, an adopted service terminalizes a
  retained legacy binding on approve with the structured retry error and exposes it as failed, an
  adopted service still approves canonical v2 records, adoption recovers an interrupted
  projection-first transition journal, no-wallet creates no authority files, and no-creation on empty
  installs.
- `swift test` passed all 229 tests in 32 suites (224 previously).
- `stupid-app build` succeeded, `stupid-app doctor` reported zero failures, and `git diff --check`
  passed.

### Follow-Up

- Fault injection at the claim/journal/projection/registry/connection/cache/fallback boundaries plus a
  real app/extension process-exclusion test before Gate A is declared closed.
- Gate B begins seed/private-key group lifecycle; the app create/import flows still provision the
  singleton (adopted into one private-key group on the next require) until those production flows are
  given registry-backed group creation, and forgetting an adopted account leaves an inert stale
  registry group that the Gate B deletion protocol will reconcile.

## 2026-08-25 - Pending Request Binding Version 2

### Summary

- Added the approved account-inclusive approval binding as the default for new pending records.
  `WalletPendingRequest` now carries `bindingVersion` (`nil` for retained legacy records) and a
  monotonic `revision` starting at zero that later increments only on the single permitted
  plain-connect account rebind. Both decode safely from retained legacy JSON.
- Added `CanonicalRequest.bindingDigestV2`: Keccak-256 of the sorted-key canonical JSON object of
  version, lowercase request ID, kind, persisted method, normalized origin, profile ID or `null`,
  normalized decimal chain ID, lowercase account, canonical params, and UTC Unix-millisecond decimal
  string timestamps. Any mutation to a listed field invalidates approval.
- Added `CanonicalRequest.intentDigestV2`: a sorted-key canonical JSON object of version, normalized
  lowercase method, normalized origin, profile ID or `null`, normalized decimal chain ID, and canonical
  page params. It excludes the request ID, timestamps, and any wallet-selected account, so transport
  retry identity survives a future popup rebind while a genuinely new request mints a new provider
  request key.
- `WalletService.prepare` now persists account-inclusive v2 digests with `bindingVersion: 2` and
  `revision: 0`. `WalletService.approve` dispatches digest revalidation by binding version: v2 records
  re-derive the account-inclusive digest, retained legacy records re-derive the prior
  request-ID-plus-params digest and remain approvable in the current hermetically-tested service.
- New records still create the canonical intent through the existing prepare path; dedup continues on
  provider `requestKey` plus the v2 `intentDigest`.

### Why

- The plan requires an account-inclusive, immutable approval identity before any popup account rebind
  or post-adoption legacy-terminalization policy can land. Adding the versioned bytes and record
  fields now keeps retained v1 records decodable and lets later slices add popup rebind (revision
  guard), adoption-gated legacy terminalization, and prepare convergence across all retained statuses
  as isolated changes.

### Verification

- `swift format --in-place` and `swift format lint` passed for the changed sources and tests.
- `swift test --filter ApprovalTests` passed all 20 tests, including new coverage: prepare records
  carry binding version 2 and revision zero with a stable recomputed digest, persisted-account
  mutation is rejected, origin and timestamp mutation are rejected, retained legacy records decode
  with nil binding version and remain approvable, and the v2 intent digest excludes the wallet-selected
  account and request identity while changing canonical intent fields.
- `swift test` passed all 224 tests in 32 suites (219 tests previously). The previously passing
  mutation/expiry/queue/reject/signer-replacement approval tests still pass under the v2 default.
- `stupid-app build` succeeded after the Swift change.
- `git diff --check` passed.

### Follow-Up

- Adoption-gated lazy terminalization: after `ensureRegistryAdopted`, every status/list/rebind/
  approve/reject path must terminalize a pending legacy-binding record with `-32000` and the retry
  message and never sign, reject differently, or rebind it. Gate it behind the registry and wire
  app/extension entry points through adoption.
- Prepare convergence across all retained statuses plus the transport-integrity error for a reused
  `requestKey` with a different `intentDigest`, then the popup connect-account rebind that increments
  `revision` and preserves `requestKey`/`intentDigest`.

## 2026-08-25 - Registry Adoption Orchestration

### Summary

- Added `WalletRegistryAdoption` in `Sources/StupidWalletCore/WalletRegistryAdoption.swift`: the
  idempotent `ensureAdopted()` operation that converts a singleton rebuild wallet or an old Dawn-format
  wallet into one private-key registry group behind the durable `.migrating` barrier.
- Acquisition order follows the plan: recover the registry, resolve the single proven account from
  `wallet-address.conf`, the `sw2.walletAddress` fallback, or the authenticated Dawn migration state
  machine, adopt the registry as `.migrating`, adopt connection state, adopt the account-bound balance
  cache, remove and verify `sw2.walletAddress`, validate registry/connection/cache, and then atomically
  commit `.complete`.
- Conflicting nonempty sources (`wallet-address.conf`, `sw2.walletAddress`, old `walletAddress`) fail
  loudly. A registered address without a matching protected secret fails loudly rather than adopting
  an un-signable group. The authenticated Dawn path reuses the Gate-4 `WalletMigration` state machine
  through the `OldWalletBackend` protocol, so it is hermetically testable.
- An existing `.migrating` registry is resumed (including connection, fallback, and cache steps) rather
  than rebuilt; an existing `.complete` registry returns immediately. A second call converges to
  committed state.
- `ensureAdopted` takes the cross-process registry-adoption claim for the composed registry/connection
  operations, releases it, then terminalizes every pending legacy-binding request to `.failed` with
  JSON-RPC code `-32000` and message `Wallet account state changed; retry request`, preserving the
  record for status/activity backfill.
- Added the narrow `ProtectedSecretProbing` existence-probe protocol over a protected item, with
  `KeychainKeyStore` conformance through its existing non-releasing `contains` check.

### Why

- This is the durable barrier that prevents app and extension request handling from using registry,
  connection, fallback, and balance state until all of them adopt and validate as `.complete`. It is
  the piece the registry, connection-state, and balance-cache foundations were built for.

### Verification

- `swift format --in-place` and `swift format lint` passed for the new source and tests.
- `swift test --filter WalletRegistryAdoptionTests` passed all 9 focused tests: rebuild adoption,
  no-wallet no-creation, Dawn migration adoption, conflicting sources, missing secret, interrupted
  migration resume, fallback removal, legacy pending terminalization, and migration failure mapping.
- `swift test` passed all 219 tests in 32 suites (210 tests in 31 suites previously).
- `stupid-app build` succeeded after the Swift change.
- `git diff --check` passed.

### Follow-Up

- The adoption claim serializes composed registry/connection adoption; strict hold-registry-lock-while-
  acquiring-connection-lock composition for concurrent runtime reads (`visibleAccounts` and revocations)
  arrives with the entry-point wiring slice, which also switches every app and extension request entry
  through `ensureRegistryAdopted` and adds the lazy legacy-binding check at prepare/approve/reject.
- Fault injection across the adoption boundaries (claim, journal, projection, registry, connection,
  cache, fallback) plus a real app/extension process-exclusion test before Gate A exits.

## 2026-08-25 - Account-Bound Balance Cache

### Summary

- Replaced the single-snapshot `native-balance-cache.json` payload in `BalanceCache` with a versioned
  dictionary keyed by normalized address in the same atomic App Group file.
- Each entry retains the account, formatted aggregate balance, last successful `updatedAt`, and the
  registry revision captured when the refresh that produced it began.
- Preserved the existing `balance(account:)`, `save(balance:account:)`, and `remove(account:)` API so
  the single-account containing app continues to read and write the same file unchanged.
- Added `entry(account:)`, `load() -> BalanceCacheSnapshot?`, `removeAll()`, and an internal
  `revision()` for multi-account hydration and stale-write detection.
- Migration preserves a stored singleton `{account, balance}` snapshot for its recorded account,
  rewriting the payload once in the versioned shape; missing files return nil and corrupt payloads
  fail loudly.
- Persistence uses the same durable same-directory temporary write, file synchronization, and atomic
  rename as the registry and connection-state stores.

### Why

- The plan requires account-bound balance caches so switching home accounts hydrates the correct
  cached total and forgetting one account removes only that account's entry. Keeping the singleton
  read/write API working means the cache can be adopted without touching the containing app's
  read path, then extended for account switching later.

### Verification

- `swift format --in-place` and `swift format lint` passed for the changed source and new tests.
- `swift test --filter BalanceCacheTests` passed all 6 focused tests: multi-account coexistence and
  single-account removal, case-insensitive lookups with full-entry metadata, monotonic cache revision,
  singleton migration that preserves only the recorded account, corrupt/absent failure modes, and
  `removeAll`.
- `swift test` passed all 210 tests in 31 suites (204 tests in 30 suites previously). The pre-existing
  `Gate6AppCoreTests.cachedTotalBalance` still passes against the migrated API.
- `stupid-app build` succeeded after the Swift change.
- `git diff --check` passed.

### Follow-Up

- Continue Gate A adoption: reconcile current rebuild and Dawn migration states into one private-key
  group under the registry-adoption claim, adopt connection grants, remove and verify
  `sw2.walletAddress`, migrate the balance cache under the proven account, terminalize legacy pending
  bindings, and switch every app and extension entry through `ensureRegistryAdopted`.

## 2026-08-25 - Atomic Connection-State Authority

### Summary

- Added the second Gate A persistence foundation: `ConnectionState` and `ConnectionStateStore` in
  `Sources/StupidWalletCore/ConnectionState.swift`, replacing normalized-grant authority in
  `UserDefaults` with one versioned, atomic `connection-state.json` App Group file guarded by an OS
  advisory lock.
- Defined the plan's value types: account-specific `ConnectionGrant` (exact origin/profile precision
  and hostname-only legacy precision), one `ActiveConnection` per origin/profile, a separately
  persisted `defaultAccount`, and durable `ConnectCommit` markers that travel with the same atomic
  revision that holds grant/active/default fields.
- Added strict validation: canonical EIP-55 accounts, unique grant identities, exact-origin grants
  that match their normalized origin and derived hostname, hostname-precision grants that carry no
  origin, at most one active account per origin/profile that must be backed by an exact grant, a
  canonical default, and unique connect-commit request IDs.
- Added a locked, revision-checked `getOrCreate`/`update` API with durable same-directory atomic
  writes, plus an idempotent `initialMigratedState` that reads shipped V2 normalized grants
  (`connectedOriginsV2`, default `Date` encoding) and legacy hostname grants (`connectedSites`) into a
  revision-zero state. V2 grants become exact grants and restore their origin/profile active mapping;
  legacy hostname grants keep hostname precision and are skipped per domain when an exact grant
  already exists (preserving the fail-closed policy).
- Every authoritative write mirrors the legacy `connectedSites` hostname dictionary
  (best-effort downgrade compatibility) after the file commit; the mirror cannot represent multiple
  accounts for one domain, so the most recently connected account wins.

### Why

- Connection grants are the other half of the approved state that must move behind a durable,
  cross-process, account-aware authority before multi-account UI, signer switching, or active-account
  request policy can be enabled. The registry owns group/account identity; connection state owns
  who is granted, which granted account is active per origin/profile, and which account future plain
  connects propose. Building it as a tested foundation lets the later adoption orchestration switch
  app and extension readers together without temporarily splitting state.

### Verification

- `swift format --in-place` and `swift format lint` passed for the new source and tests.
- `swift test --filter ConnectionStateTests` passed all 11 focused tests: persistence across
  independent store instances, revision monotonicity and concurrent-update exclusion, empty-state
  idempotency, active-without-grant rejection, duplicate-active rejection, exact/legacy grant shape,
  address/default validation, duplicate connect-commit rejection, V2/legacy migration that preserves
  each stored account and precision, and the legacy mirror write.
- `swift test` passed all 204 tests in 30 suites (193 tests in 29 suites previously).
- `git diff --check` passed.

### Follow-Up

- Next Gate A steps remain: reconcile current rebuild and Dawn migration states with
  `initialMigratedState` under the adoption claim, remove and verify `sw2.walletAddress`, migrate the
  singleton balance cache, terminalize legacy pending bindings, and switch every app and extension
  entry through `ensureRegistryAdopted`. The connection store is not yet authority until those
  readers switch together.
- Add fault injection around the connection-state boundary (file write, lock interruption, corrupt
  payload) and marker/request reconciliation coverage once connect commits are produced.

## 2026-08-25 - Wallet Registry Foundation

### Summary

- Started Gate A on branch `feat/multi-account` with versioned `WalletRegistry`, `WalletGroup`, and
  `WalletAccount` models for seed-backed and private-key-backed groups, independent home selection,
  adoption state, lifecycle state, and monotonic revisions.
- Added strict validation for canonical EIP-55 addresses, global case-insensitive uniqueness,
  private-key group cardinality, ordered seed derivation indexes below the BIP-32 boundary, active
  home membership, and the legacy-fallback barrier.
- Added monotonic transition validation so adoption/fallback state cannot regress, deleting groups
  cannot reactivate or mutate, active groups cannot disappear before deletion, seed accounts append
  one registered derivation at a time without index reuse, and multi-account state cannot appear
  before fallback removal.
- Added `WalletRegistryStore` with a dedicated advisory lock, revision-checked create/update, durable
  same-directory temporary writes, file and parent-directory synchronization, and durable removals.
- Implemented the approved projection-first `wallet-registry-transition.json` protocol. Recovery
  validates the complete journal relationship, commits an interrupted transition forward, rejects
  conflicts, repairs stale projections left by a downgraded build, projects only a private-key home
  account to `wallet-address.conf`, and removes that projection for a seed-backed home account.
- Kept the registry unused by production app and extension flows in this slice. Existing singleton
  behavior is unchanged until the rest of Gate A can migrate registry, connection, fallback, and
  balance state behind one readiness barrier.

### Why

- Multi-account UI or signer changes cannot safely precede a durable cross-process registry. Building
  the model, lock, revision, projection, and recovery boundary first gives later adoption and account
  lifecycle work one tested authority without temporarily splitting app and extension state.

### Verification

- `swift format --in-place Sources/StupidWalletCore/WalletRegistry.swift
  Tests/StupidWalletCoreTests/WalletRegistryTests.swift` and `swift format lint` completed without
  findings.
- `swift test --filter WalletRegistryTests` passed all 12 focused tests, covering both group kinds,
  validation failures, readiness, revisions, independent-store exclusion, projection repair,
  commit-forward recovery, inconsistent-journal refusal, monotonic transitions, and persisted date
  precision.
- `swift test` passed all 193 tests in 29 suites.
- `stupid-app doctor` completed with zero failures and warnings, and `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app
  and extension on the preferred simulator. Accessibility inspection found the existing wallet home
  controls, confirming this unused foundation did not change the current single-account UI.
- `git diff --check` passed.

### Follow-Up

- Complete Gate A adoption rather than wiring this store piecemeal: add the registry-adoption claim,
  reconcile current rebuild and Dawn migration states, remove and verify `sw2.walletAddress`, migrate
  connection and balance authority, terminalize legacy pending bindings, and switch every app and
  extension entry through `ensureRegistryAdopted`.
- Add exhaustive fault injection around journal, projection, registry, fallback, connection, and cache
  boundaries plus a real app/extension process-exclusion test. Current independent-store tests prove
  advisory-lock serialization in one host process but are not device migration acceptance.

## 2026-08-25 - Gate A Fail-Closed Adoption Validation

### Summary

- Tightened the Gate A readiness barrier so an absent registry, a `.migrating` registry, a missing
  private-key source, corrupt or missing connection authority, mismatched active/default membership,
  an invalid account-bound cache, a stale compatibility projection, or a retained malformed pending
  record prevents app and extension operations.
- Removed optimistic containing-app projection reads. Wallet state is published only from a validated
  complete registry, and the Safari signer is constructed from that registry rather than the removed
  `sw2.walletAddress` fallback.
- Made retained legacy-binding terminalization conditional and per-request claimed. Every adopted
  entry scans the production `PendingRequests` directory, and status fails closed when terminalization
  cannot be persisted.
- Made balance-cache read-modify-write operations cross-process locked and corruption preserving.
  Concurrent account saves no longer lose another process's entry.
- Made V2 and legacy connection migration reject malformed stored containers and entries. A legacy
  hostname grant is preserved even when an exact grant shares its domain, retaining the original
  account and authorization precision.

### Why

- `.complete` must mean that wallet identity, protected-key availability, connection authority,
  compatibility projection, fallback removal, cache state, and retained request state all validate.
  Returning from adoption based only on the registry flag allowed corrupt or interrupted state to
  bypass the intended migration barrier.

### Verification

- `swift format` completed for changed Swift. Recursive `swift format lint` reported only three
  pre-existing block-comment warnings in `SecurityWalletBackend.swift`.
- `swift test` passed all 237 tests in 32 suites. New regressions cover absent-registry refusal,
  complete-state revalidation, corrupt migration sources, same-domain exact/legacy grant retention,
  claimed legacy request terminalization, and concurrent balance-cache saves.
- `stupid-app doctor` completed with zero failures and zero warnings, and `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app.
  Accessibility inspection found the expected setup actions with no wallet state exposed before
  adoption.
- `git diff --check` passed.

### Follow-Up

- Gate A is not yet declared complete. Add deterministic interruption injection across every
  journal, projection, registry, connection, cache, and fallback persistence step, then prove the
  fixed lock boundary in real app/extension processes.
- Perform in-place acceptance upgrades from a production-shaped rebuild installation and a real old
  Dawn-format installation. Synthetic fixtures do not prove App Group, keychain, Secure Enclave, or
  shipped-format behavior.

## 2026-08-25 - Gate A Fault Matrix And Rebuild Upgrade Investigation

### Summary

- Added deterministic one-shot persistence interruption seams and recovery coverage across registry
  journal, compatibility projection, registry authority, connection authority, account-bound cache,
  fallback removal, fallback-state commitment, completion-state commitment, and the adoption claim.
- Added a separate child-process proof that `wallet-registry.lock` excludes another process. Changed
  the test worker from the shared dispatch pool to a dedicated thread after full-suite contention
  demonstrated that dispatch scheduling latency was not a valid lock timeout signal.
- Performed a clean in-place simulator upgrade from the pre-multi rebuild commit. The old app UI
  created a disposable wallet, populated the singleton balance cache, connected a loopback test site,
  and produced one signed-message activity row before the current build was installed without an
  uninstall or state reset.
- The first upgraded launch exposed a concrete persisted-format bug: retained consumed request files
  predated the non-optional `revision` field, so the fail-closed pending-store scan reported `corrupt`
  after registry adoption and the app showed setup. `WalletPendingRequest` now decodes an absent
  revision as zero, matching the shipped binding format, and a regression removes all later optional
  binding fields plus revision before decoding.
- After the fix, the upgrade produced one complete private-key registry group, preserved the exact
  compatibility projection, migrated the singleton cache to one account entry, retained the activity
  rows, removed the rebuild fallback commitment, and displayed the existing wallet again.

### Simulator Limitation

- The ad-hoc simulator could not provide valid grant-migration acceptance. Immediately after Safari
  connected successfully under the old build, the old containing app itself displayed no connected
  apps. Inspection showed App Group files were shared but the app and extension used separate
  process-container `UserDefaults` suite files; replacing the extension removed the old process
  container before Gate A could read it.
- No simulator-only recovery or preference copying was added. A properly signed physical-device
  upgrade must prove legacy grant preservation. Real app/extension simultaneous-process exclusion and
  the old Dawn-format in-place device upgrade also remain outstanding, so Gate A is not closed.

### Verification

- `swift format --in-place` completed for changed Swift files. Recursive `swift format lint` reported
  only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`.
- The focused shipped-record compatibility test and separate-process lock test passed.
- The first full `swift test` run exposed the dispatch-pool scheduling flaw in the new lock test. After
  using a dedicated worker thread, `swift test` passed all 244 tests in 32 suites.
- `stupid-app doctor` completed with zero failures and zero warnings. `stupid-app build` succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` installed and launched the current app;
  accessibility inspection found the existing wallet home with address and balance controls.
- `git diff --check` passed.

### Follow-Up

- Prove the registry/adoption lock boundary with the real containing app and Safari extension running
  concurrently.
- On a properly signed disposable physical installation, prepare a rebuild grant and activity before
  upgrading and verify exact identity, grant, activity, cache, and signing continuity afterward.
- Perform the separate in-place upgrade from a real old Dawn-format installation. Never use personal
  wallet state for either acceptance run.

## 2026-08-25 - Multi-Account Migration Scope Narrowed To Dawn V1

### Decision

- Narrowed the approved multi-account migration scope to old Dawn v1 installations only.
- Current single-account rebuild v2 installations are explicitly unsupported migration sources. Their
  `wallet-address.conf`, `sw2.walletAddress`, `connectedOriginsV2`, singleton balance cache, and
  `PendingRequests` records receive no upgrade-preservation guarantee and must not be silently adopted.
- Retained fail-closed `wallet-address.conf` projection for downgrade safety. Downgrade compatibility
  is a separate boundary and does not make v2 an accepted upgrade source.

### Plan Changes

- Replaced the dual-source startup sequence with direct authenticated Dawn migration into a
  `.migrating` registry.
- Kept Dawn's actual persisted compatibility requirements: old address/ciphertext/Secure Enclave key
  proof, `connectedSites` hostname grants, Activity, installation-wide network preferences, and old-key
  retention until authenticated sign-and-recover succeeds.
- Removed v2 singleton balance, normalized-grant, and pending-request migration from Gate A and upgrade
  acceptance. Dawn starts with an empty account-bound balance cache and has no supported
  `PendingRequests` source format.
- Made deletion of the already-implemented superseded v2 migration paths the first recommended work in
  `docs/engineering-handover.md`, followed by real app/extension exclusion proof and the physical Dawn
  upgrade.

### Verification

- Reviewed the current implementation and the Dawn reference source to distinguish Dawn
  `connectedSites`, Activity, and network preferences from rebuild-only v2 formats.
- `git diff --check` passed after the documentation changes.

### Follow-Up

- Remove the superseded implementation and tests before claiming Gate A matches the approved plan.
- Refactor Dawn migration so authenticated key proof commits directly into registry adoption instead
  of staging through current-rebuild registration artifacts.

## 2026-08-25 - Dawn-Only Registry Adoption Implemented

### Summary

- Removed `wallet-address.conf` and `sw2.walletAddress` as pre-registry identity sources. A
  current-rebuild-only installation now remains unsupported and creates no registry.
- Changed authenticated Dawn key migration to persist only the protected key and a Dawn-specific proof
  marker before `WalletRegistryAdoption` commits the account directly into a `.migrating` registry.
- Removed `connectedOriginsV2` ingestion, singleton balance-cache conversion, adoption-time pending
  request terminalization, retained-request activity backfill, and missing-revision request decoding.
- Kept Dawn `connectedSites` hostname grants, old-key retention, runtime account-bound connection and
  balance stores, binding-version-2 request handling, and fail-closed downgrade projection cleanup.
- Unsupported pending bindings are omitted from list, summary, and status results and cannot be
  approved or rejected.

### Why

- Gate A now implements the approved Dawn-v1-only migration boundary instead of carrying unshipped
  current-rebuild compatibility into the multi-account registry.

### Verification

- Formatted all changed Swift source and tests with `swift format --in-place`.
- Targeted migration, registry-adoption, connection-state, balance-cache, activity, approval, and
  wallet-factory tests passed: 80 tests in 7 suites.
- `swift test` passed all 239 tests in 32 suites.
- Recursive `swift format lint` reported only the three pre-existing block-comment warnings in
  `SecurityWalletBackend.swift`.
- `stupid-app --version` reported 0.0.8 with Swift 6.2.1. The project remains on manifest version 1.
- `stupid-app doctor` completed with zero failures and zero warnings, and `stupid-app build`
  succeeded.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the app
  on the preferred simulator. Accessibility inspection found the wallet home address, balance, and
  copy-address controls.

### Follow-Up

- Prove the registry/adoption lock boundary in the real containing app and Safari extension, then
  perform a real in-place Dawn v1 physical-device upgrade before closing Gate A.

## 2026-08-25 - Physical Dawn Upgrade And Protected-Probe Fix

### Summary

- Performed an in-place physical-device upgrade from TestFlight Dawn build 89 using a newly created
  disposable wallet. After the required authenticated migration prompts, the current app preserved
  and reopened the old wallet; no persisted files were edited to force migration.
- The first attempted fixture was intentionally rejected because it still contained a rebuild
  `wallet-address.conf`. Deleting the disposable app installation and preparing Dawn first produced
  the required uncontaminated source and confirmed the v2 exclusion policy works.
- Fixed a repeating Face ID loop in Safari after migration. Registry validation called
  `KeychainKeyStore.contains`, and `SecItemCopyMatching` evaluated the protected item ACL even with
  `kSecReturnData=false`. The existence query now uses a fresh `LAContext` with
  `interactionNotAllowed=true` and treats `errSecInteractionNotAllowed` as proof that the exact item
  exists, without releasing key bytes or presenting authentication UI.

### Process-Exclusion Finding

- A DEBUG-only 45-second hold after the app acquired `wallet-registry-adoption.lock` showed that the
  Safari extension could not return from adoption while the app owned the claim.
- When the user switched to Safari, RunningBoard terminated the suspended containing app with
  `0xDEAD10CC` specifically because it retained a shared App Group file lock. The extension proceeded
  only after process termination released the lock.
- This confirms OS-level exclusion but fails the production safety gate. Gate A remains open until the
  adoption claim is suspension-safe, followed by a real app/extension proof that completes without
  killing either process. All temporary hold and diagnostic logging code was removed.

### Verification

- TestFlight metadata identified the migration source as version 1.0, build 89; the installed current
  development build was version 1.0.0, build 1.
- Signed app and extension entitlements both contained the production App Group; device logs confirmed
  successful shared-container lookup and a complete registry in the current extension.
- Before the fix, bounded `idevicesyslog --process StupidWalletSafari` output showed
  `LocalAuthentication evaluateAccessControl` during the readiness probe. After the fix and a device
  restart, the containing app reopened the migrated wallet and the Safari popup loaded normally with
  no Face ID loop.
- `KeychainKeyStoreTests` passed the new status-classification regression, and all 17 focused
  `WalletRegistryAdoptionTests` continued to pass.
- Final `swift test` passed all 240 tests in 33 suites. Recursive `swift format lint` reported
  only the three pre-existing block-comment warnings in `SecurityWalletBackend.swift`.
- `stupid-app doctor` completed with zero failures and zero warnings. `stupid-app build` succeeded,
  and the final diagnostic-free development build installed over USB.
- After a final device restart, the containing app loaded the migrated wallet and the current Safari
  popup opened normally without authentication.

### Follow-Up

- Replace the long-lived App Group adoption `flock` with a suspension-safe coordination boundary, or
  prove bounded containing-app background execution that always releases it before suspension.
- Repeat the real app/extension exclusion test without a watchdog termination before declaring Gate A
  complete.

## 2026-08-25 - Suspension-Safe Adoption Coordination And Gate A Closure

### Summary

- Replaced the outer registry-adoption `flock` with synchronous `NSFileCoordinator` write coordination
  on the same stable App Group claim URL. Registry, connection-state, cache, journal, projection, and
  fallback recovery boundaries remain unchanged.
- Added a macOS child-process regression that compiles a coordinator helper and proves a second process
  cannot enter its accessor before the first process releases the claim.
- Kept coordination cancellation fail-closed: an app or extension that does not receive its accessor
  cannot inspect, prepare, decide, or expose wallet state.

### Physical Verification

- Temporarily held the containing app's coordinated accessor for 45 seconds in a DEBUG build, then
  foregrounded Safari and opened the wallet popup. Device logs showed `filecoordinationd` grant the app
  a RunningBoard `File Coordination Claim` suspension assertion for the full interval.
- The Safari extension did not enter its accessor during the app claim. The popup attempt returned to
  its no-request state rather than handling wallet state. The app released normally after 45 seconds;
  neither process was terminated and no `0xDEAD10CC` occurred.
- After release, closing and reopening the popup launched a fresh extension process. Device logs showed
  its write claim granted, `StupidWalletSafari` enter and leave the coordinated accessor, and the
  native `list` request complete normally without an authentication prompt.
- Removed all temporary hold and coordination logging from source after collecting the result.

### Outcome

- Gate A exit conditions are complete: deterministic persistence interruption and cross-process tests,
  Dawn-v1-only adoption, the real in-place Dawn build-89 physical upgrade, non-interactive protected
  key existence validation, and suspension-safe real app/extension exclusion are proven.
- Continue with Gate B seed groups and account lifecycle. Gate A does not enable deferred runtime
  multi-account selection or connection behavior by itself.

### Final Verification

- Strengthened the child-process coordination regression after the full parallel suite exposed a test
  timing race in its fixed-duration hold. The helper now remains inside its coordinated accessor until
  an explicit release marker, and the test verifies adoption has not completed before that release.
- `swift test --filter crossProcessCoordination` passed, followed by all 241 tests in 33 suites.
- Recursive `swift format lint` reported only the three pre-existing block-comment warnings in
  `SecurityWalletBackend.swift`.
- `stupid-app 0.0.8` doctor completed with zero failures and zero warnings, and `stupid-app build`
  succeeded against the iOS 26.1 SDK.
- `stupid-app run --simulator --udid <preferred-simulator>` rebuilt, installed, and launched the
  diagnostic-free app. Accessibility inspection found the wallet-address, copy-address, and balance
  controls.
- `stupid-app run --usb` signed and installed the diagnostic-free app and extension over the physical
  migrated installation. Its known CoreDevice TUN launch step failed after installation; a direct
  `devicectl` launch of the installed bundle then succeeded.
