---
name: stupid-wallet-debugging
description: Debug Stupid Wallet end to end across Uniswap or other dapps, the EIP-1193 provider, Safari bridge/background/popup, native extension handler, WalletCore, App Group pending records, keychain authentication, RPC calls, transaction signing, and Base/EVM receipts. Use when a dapp request fails, hangs, shows [object Object], never opens the popup, fails approval or Face ID, broadcasts incorrectly, returns an RPC error, or behaves differently after reinstall.
---

# Stupid Wallet Debugging

Debug from observed behavior toward the failing boundary. Do not guess from the page's
generic error text and do not bypass the canonical approval protocol.

## Establish Context

1. Read `AGENTS.md`, `docs/engineering-handover.md`, and the latest relevant entries in
   `docs/implementation-notes.md`.
2. Inspect `git status --short`, `stupid-app --version`, the installed manifest version,
   and the relevant source before assuming the simulator runs the current worktree.
3. Load the `ios-simulator-skill`; load `simulator-ocr` for Safari web content and extension
   popups because their useful elements are often absent from the accessibility tree.
4. Load `stupid-app-cli` before building, installing, or launching.
5. `swift test` runs against macOS and does not compile views guarded by `#if os(iOS)`. After every
   iOS-only SwiftUI change, run `stupid-app build` before treating package-test compilation as proof;
   the iOS SDK can expose SwiftUI overload or availability errors that the test build never sees.
6. Preserve unrelated worktree changes. Never edit App Group records to force progress.
7. If the simulator skill's live `log_monitor.py` does not terminate at its requested
   duration, stop it rather than waiting indefinitely. Continue with bounded `simctl`,
   App Group inspection, and RPC checks; a log-stream helper hang is not evidence that the
   app hung.
8. On Apple Silicon Mac, a copied compatibility wrapper plus LaunchServices registration can
   launch the containing iOS app without creating the MobileInstallation/PlugInKit records Safari
   needs for its nested extension. Xcode's `IDEInstallService` uses private InstallCoordination and
   `InstallLocalProvisioned` entitlements; a non-Apple CLI is rejected before installation. Treat a
   Safari `0xe8008015`/`No matching profile found` after an otherwise valid direct wrapper install as
   an installation-boundary failure, not another prompt to mutate signatures or profiles. Verify
   extension-bearing builds through Xcode or TestFlight.
9. On a USB iPhone, use `idevicesyslog --udid <udid> --process StupidWalletSafari` for bounded
   extension authentication diagnosis. A `LocalAuthentication evaluateAccessControl` immediately
   around registry readiness checks means a supposedly metadata-only keychain probe touched a
   protected item. `SecItemCopyMatching` can authenticate even with `kSecReturnData=false`; bind an
   `LAContext` with `interactionNotAllowed=true` and treat `errSecInteractionNotAllowed` as evidence
   that the exact protected item exists.
10. Never hold or deliberately pause a containing app on an App Group `flock` while backgrounding it
   to Safari. RunningBoard terminates that process with `0xDEAD10CC` because suspended apps may not
   retain shared-container file locks. An extension proceeding only after that kill proves exclusion,
   but it does not prove a safe production coordination boundary.
11. Use the stable App Group claim URL with synchronous `NSFileCoordinator` for registry adoption.
    Device logs should show a `File Coordination Claim` RunningBoard assertion while the containing
    app accessor runs. A competing extension accessor may be canceled rather than visibly wait; verify
    it did not enter during the claim and that a fresh popup request enters after release. The popup's
    no-request state alone does not prove native success because its transport fallback can render an
    empty list.
12. iPhone Mirroring can drive the containing app, Safari page menu, popup review, account selection,
    and decision buttons, but it does not satisfy the protected Face ID release. Complete Face ID on
    the physical phone. A mirrored `Confirming…` state, popup dismissal, or pending-record transition
    alone is not signing evidence; require the originating dapp to receive success (and independently
    recover the signer when the payload can be checked safely). A failure without on-device Face ID
    is useful cancellation/authentication-boundary evidence, not a seed-signing failure.
13. Before archiving a release, compare `CFBundleShortVersionString` in the containing app and every
    nested extension source plist, then inspect the packaged IPA values. `stupid-app release bump`
    synchronizes `CFBundleVersion`, not marketing versions. App Store Connect warning `ITMS-90473`
    means a nested extension's marketing version differs from its containing app even when upload and
    TestFlight processing otherwise succeed.
14. Internal TestFlight validity does not prove external-beta eligibility. Submission error
    `ENTITY_UNPROCESSABLE.BUILD_SDK_NOT_ALLOWED_FOR_EXTERNAL_TESTING` means Apple will not review that
    already-uploaded binary because of its Xcode/SDK version. Check Apple's current TestFlight release
    notes, inspect every installed Xcode, and select a supported installation with `DEVELOPER_DIR`
    before creating a new build number; an existing build cannot be repaired or resubmitted with a
    different SDK.
15. Before assuming a TestFlight SDK rejection means the toolchain itself is unsupported, verify the
    packaged IPA's build-system Info.plist keys exactly. `stupid-app` (before 0.0.9 with the fix)
    omitted `DTPlatformBuild`/`DTSDKBuild` and mis-encoded `DTXcode` (`266` instead of the canonical
    `2660` for Xcode 26.6), which makes App Store Connect report "Unsupported SDK or Xcode version"
    or "beta version of Xcode" for an otherwise valid binary. Check `DTXcode`, `DTXcodeBuild`,
    `DTSDKBuild`, and `DTSDKName` in `Payload/<app>.app/Info.plist` (`unzip -p <ipa>` then
    `plutil -p`); genuine Xcode archives always include the SDK build keys. A genuine-Xcode build can
    be used as a probe to isolate a packaging defect from a policy change.
16. Enabling App Groups capability on an App ID does not associate any concrete App Group. A development
    profile can still be created and later fail signing with an App Group entitlement value mismatch.
    In Certificates, Identifiers & Profiles, open the exact App ID, configure App Groups, select the
    production group, save, and regenerate every affected profile. If profile creation reports duplicate
    display names, use a unique `stupid-app signing setup --profile-name` prefix rather than deleting
    profiles during diagnosis.
17. Backend tests use the native `better-sqlite3` module. A failure that reports mismatched
    `NODE_MODULE_VERSION` values means the current shell runtime differs from the runtime that built
    `server/node_modules`; it is not a schema or application-test failure. Select the repository's Node
    22 toolchain consistently. If the native module was rebuilt under another runtime, run the existing
    Bun install with `--force` under Node 22 before retesting; do not commit ignored `node_modules` output.
18. If an installed `stupid-app` aborts before `doctor` with `could not load resource bundle`, inspect
    whether `stupid-app_SigningKit.bundle` still exists beside that exact executable or in its original
    Swift build configuration. This is a CLI-launcher packaging failure, not a project diagnostic. Use
    the matching build executable that still has its adjacent bundle, or reinstall the CLI and bundle,
    before changing wallet configuration.
19. Stupid Webhooks subscription creation uses `chainIds` as an array and requires the destination
    `webhookId`; the response wraps created records in `subscriptions`. Chain discovery communicates
    support through status: HTTP 200 means supported and HTTP 404 means unsupported. Do not invent a
    `supported` response field or collapse non-404 failures into an unsupported result.
20. Immediately after publishing a custom Worker domain, public resolvers can succeed while a physical
    iPhone retains a negative DNS result. Run a bounded Worker tail and a privacy-safe D1 count while
    foregrounding the app: no request plus no row change locates the failure before the Worker. Refresh
    the phone's network state only with user approval, then require both cleared UI error state and a
    persisted installation before calling enrollment successful.
21. Apple limits active team-scoped APNs authentication keys. A portal rejection at that limit is an
    account-capacity boundary, not a signing or entitlement defect. Do not delete keys or silently reuse
    an all-topics key; reuse requires explicit approval because it broadens credential authority, and a
    narrower replacement should remain follow-up work when account capacity permits.
22. Wrangler cron triggers are arrays of cron strings, for example `"crons": ["*/15 * * * *"]`. An
    object such as `{ "cron": "*/15 * * * *", "request": "..." }` can be ignored without a deployment
    error, leaving D1 outbox rows pending indefinitely. Require deploy output to list `schedule:` and
    verify at least one scheduled dispatch rather than treating configuration presence as proof.
23. For a bounded operator recovery when an upstream outbox row exists but has not been dispatched, the
    Cloudflare Queue dashboard can send a JSON message containing only the expected queue discriminator
    and numeric operation ID. Resolve IDs from a privacy-safe D1 query, send only explicitly approved
    operations, and verify terminal outbox state plus non-null provider subscription IDs independently.
    This dispatches the normal consumer; it is not permission to fabricate installations or bypass
    upstream capability checks.
24. Stupid Webhooks deliveries use `webhook-id`, `webhook-timestamp`, and `webhook-signature`. The
    timestamp is Unix **seconds**, while JavaScript `Date.now()` is milliseconds; convert before applying
    the ±5-minute replay window. Verify a lowercase hexadecimal HMAC-SHA256 over
    `<seconds>.<exact-body>` and parse the outer
    `{id,type,createdAt,data}` envelope before normalizing activity. The older `x-wallet-hook-*`,
    `<id>.<timestamp>.<body>`, Base64URL, or flat-body assumptions reject every real delivery even when
    local fixtures built around those assumptions pass.
25. Notification toggle, APNs registration callback, foreground entry, and test-push actions can converge
    on the same installation reconciliation. Coalesce them behind one in-flight task and wait for it before
    final-installation deletion; otherwise a successful create can race another mutation and briefly show
    the generic service-retry error.
26. Diagnose APNs separately from upstream activity with a signed, rate-limited installation test route
    that queues a synthetic categorical alert without creating a cursor event. Require three distinct
    observations: HTTP acceptance of the signed test request, APNs queue consumption, and the persisted
    APNs provider outcome. Provider `accepted` proves APNs accepted the token/payload, not that iOS
    presented a banner; verify Notification Center and the service-extension result on the physical phone.
27. For activity classification, decimal transaction value `"0"` is not native movement. Treat only a
    value greater than zero as native, and match the provider's exact effect kinds (`erc20`, `erc721`)
    rather than searching serialized effects for the words `token` or `nft`. A swap commonly has zero
    native value plus one or more token effects.
28. When the event row and APNs ledger carry a specific `eventKind` but the phone displays the base alert
    unchanged, debug Notification Service Extension presentation separately from ingestion and transport.
    First verify that the containing app actually writes the non-secret App Group display map; an extension
    reader without a writer can never resolve an account label/address seed. Keep the APNs base title
    categorical from the bounded `eventKind`, because that information is already in the payload and is a
    safe fallback when iOS skips or terminates the extension. Capture a filtered physical-device log with
    `idevicesyslog -p StupidWalletNotificationService` during the next push to distinguish no launch from
    a launch-time failure. The Apple Notification Service Extension point is exactly
    `com.apple.usernotifications.service`; `com.apple.usernotifications.serviceextension` looks plausible
    but does not register the extension for mutable alert delivery.
29. A WhatsApp-style left-side avatar requires Communication Notifications, not a
    `UNNotificationAttachment`. Put `com.apple.developer.usernotifications.communication` and, for
    `INSendMessageIntent` donation, `com.apple.developer.siri` on the containing app; add
    `INSendMessageIntent` to its top-level `NSUserActivityTypes`. Keep those entitlements off the
    Notification Service Extension unless a profile proves a separate requirement. In the extension,
    use the local PNG as `INPerson.image`, donate an incoming `INInteraction`, wait for donation success,
    then call `UNNotificationContent.updating(from:)`. Preserve a bounded ordinary-alert fallback and an
    exactly-once timeout handler. Apple's public App Store Connect OpenAPI capability enum can enable
    `SIRIKIT` but currently omits Communication Notifications, so enable that capability in the Developer
    portal before regenerating profiles. A portal capability change invalidates profiles; if setup reports
    duplicate default profile names, use a unique `--profile-name` rather than deleting unknown profiles.
30. Communication notification layouts do not reliably render `UNMutableNotificationContent.subtitle`.
    Put the intended message line in both `INSendMessageIntent.content` and the mutable notification's
    `body` before calling `updating(from:)`; an empty mutable body can produce the correct sender avatar
    and title with no visible detail line even when intent donation succeeds.
31. If a communication notification shows only the chain and its blockie does not match the active account,
    the extension has fallen back because its App Group display map lacks the payload's opaque registration
    ID. Check for `notificationDisplay.json` in the App Group. During format migration, a Keychain identity
    may already contain the installation ID while older persisted notification state does not. Reconciliation
    must copy the existing identity's installation ID into state on every success, not only after creating a
    new backend installation, before deriving and writing registration-ID aliases. Repair and write the local
    display map during local alias refresh too; do not make notification presentation depend on a successful
    remote enrollment pass when an existing installation can already receive pushes.
    Do not cache a temporary-directory fallback during early singleton initialization; that permanently isolates
    the containing app's map from the extension. For this small Codable map, use the shared App Group
    `UserDefaults` suite, which is cross-process and avoids file-container URL availability. Refresh the alias
    explicitly when opening the notification screen, where the active address and account label are definitive.

## Stack Map

Trace requests in this order:

1. Dapp calls `window.ethereum.request` in `SafariExtension/Resources/provider.js`.
2. `provider.js` posts a request to isolated-world `bridge.js`.
3. `bridge.js` sends `ethereum.request` to `background.js` and polls durable approvals.
4. `background.js` derives origin from Safari sender context, classifies the method, and
   calls native messaging.
5. `Sources/StupidWalletSafari/SafariWebExtensionHandler.swift` validates the envelope and
   dispatches to `WalletService`.
6. `Sources/StupidWalletCore/WalletService.swift` owns policy, preparation, canonical
   persistence, approval, signing, broadcast, and durable terminal errors.
7. `PendingRequestStore`, `ChainStore`, `ConnectedSitesStore`, and `WalletStore` persist
   shared state in the App Group; `KeychainSigner` performs authenticated signing.
8. `RPCClient` and `RPCResolver` call `https://evm.stupidtech.net/v1/{decimalChainId}`.

Keep method normalization separate from transport. Classification is case-insensitive, but
generic passthrough must forward the dapp's original case-sensitive JSON-RPC method string.

## Triage Workflow

### 1. Reproduce Precisely

- Record the chain, method or user action, input amount, token direction, and whether the
  failure occurs before preparation, in the popup, during authentication, or after approve.
- Populate Uniswap tokens through URL parameters when possible:

```text
https://app.uniswap.org/swap?chain=base&inputCurrency=NATIVE&outputCurrency=<token>
https://app.uniswap.org/swap?chain=base&inputCurrency=<token>&outputCurrency=NATIVE
```

- Use accessibility navigation first. Use OCR immediately before coordinate taps.
- To trigger a simulator context or edit menu, issue a real held touch with
  `idb ui tap <x> <y> --duration 1.5 --udid <udid>`. The simulator skill's current
  `gesture.py --long-press` implementation taps and then waits on the host, so it does not
  hold the touch or open an iOS long-press menu.
- Treat dapp text such as “Swap failed” or “adjust slippage” as non-authoritative until the
  provider/native error is known.
- After replacing an installed iOS Safari extension, a page reload can retain the old content-script
  or background-worker context even though Safari still shows the extension enabled. If a previously
  working dapp suddenly has no provider and native receives no pending request, verify profile access
  under Settings > Apps > Safari > Extensions, then force-quit and relaunch Safari before diagnosing
  the provider bridge. For profile tests, confirm the extension is enabled separately for each profile
  and inspect the page-menu badge/popup from a tab in that profile; never infer isolation from the
  containing app alone.
- A crash after saving an in-place SwiftUI `List` header field can be a UIKit first-responder update
  assertion rather than persistence corruption. Look for
  `UICollectionView _resignOrRebaseFirstResponderViewWithIndexPathMapping` in the crash report. Bind
  the editable fields to `FocusState`, clear focus, and allow that state transition to run before
  publishing list data or replacing the editable row/header hierarchy.
- A containing app whose registry adoption starts asynchronously must distinguish “initial state not
  loaded” from a successfully loaded empty registry. Default empty published values can otherwise
  flash setup or no-wallet UI before the persisted home account arrives. Gate the root content and
  account toolbar on an explicit initial-load completion flag; do not infer emptiness until adoption
  returns.

### 2. Locate The Boundary

Use these observations:

- No new pending record: failure is in the dapp, provider routing, passthrough RPC, native
  envelope parsing, transaction preparation, or typed-data preparation.
- Pending record with `pending`: popup or approval has not completed.
- `failed`: inspect its structured `error`; signing/serialization/broadcast failed.
- `rejected` or `expired`: do not reuse it; reproduce a fresh request normally.
- `consumed`: inspect `result`, then verify the signature or transaction independently.

Activity details intentionally omit Data, Message, or Signature values when their SQLite columns are
null or empty. Current-rebuild `PendingRequests` files are unsupported migration inputs and must not be
read to reconstruct those fields. Preserve Dawn activity rows as stored; missing historical content
remains missing unless a separately reviewed source proves it without importing unsupported request
authority.

Activity lists are local SQLite data and should render before receipt polling. If global Activity or
a connected-app Activity section shows a blocking spinner for approximately one or more RPC
timeouts, inspect the view's load order: awaiting `refreshTransactionActivity()` first serially polls
every unresolved transaction and can delay the query even though persisted rows are already
available. A realistic database with many unresolved rows exposes this more clearly than a small
fixture.

Current multi-account pending records require binding version 2 and an explicit revision. An
unsupported current-rebuild record is not migrated, terminalized, listed, or used for activity
backfill. Never edit or delete one to make startup pass; a current-rebuild-only installation is outside
the approved upgrade scope and must not be converted into a partial registry.

On an ad-hoc iOS simulator build, App Group files may be shared while an app and its Safari extension
still observe separate App Group `UserDefaults` suite files in their process data containers. Prove the
problem before blaming migration: connect through the old extension, then open Connected Apps in the
old containing app before upgrading. If it already reports no connections, that simulator cannot prove
grant preservation; use a properly signed physical upgrade rather than copying preferences or adding a
simulator-only migration path.

Find the booted simulator and App Group pending files without changing them:

```bash
xcrun simctl list devices booted
stat -f '%m %Sm %N' -t '%Y-%m-%d %H:%M:%S' \
  "$HOME/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Shared/AppGroup/"*/PendingRequests/*.json \
  | sort -rn
jq '{id,kind,method,status,chainId,error,result}' '<pending-file>'
```

Do not print or retain full params unless they are necessary for local diagnosis. Never put
wallet addresses, sensitive payloads, transaction hashes tied to a user, or secrets in
public implementation notes.

### 1b. Apple Silicon Mac Notes

- The tracked XcodeGen project enumerates source membership. After adding Swift source files, run
  `xcodegen generate --spec Mac/project.yml` before diagnosing missing-type build errors; an old
  `project.pbxproj` can compile a stale subset even when the files exist in the worktree.
- The current `stupid-app run --mac` rejects extension-bearing projects because its public
  installer cannot create the launch records native messaging needs. Mac native-messaging testing
  routes through the tracked XcodeGen project at `Mac/` (build with `xcodebuild
  -project Mac/StupidWalletMac.xcodeproj -scheme StupidWallet -destination
  'platform=macOS,arch=arm64'`, install by running in Xcode on "My Mac (Designed for iPad/iPhone)").
- A keychain probe from a terminal is **not** evidence a `.userPresence` wallet key is missing:
  those items are ACL-protected and invisible to `security find-generic-password` /
  `dump-keychain`, which report item-not-found even when signing succeeds. Judge signing by a
  consumed pending record and by `cast wallet verify` on the returned signature, not by the CLI.
- If the signed Xcode build lacks App Group/keychain behavior, check `codesign -d --entitlements
  :-` first. Keep the tracked `Mac/` entitlements explicit and verify `CODE_SIGN_ENTITLEMENTS`
  after regeneration rather than changing production identifiers.
- Wallet keys are `ThisDeviceOnly` and do not sync between the iPhone and the Mac; the Mac needs
  its own user-authorized import.
- **Duplicate requests when switching windows/tabs:** transport loss may retry a request. Retry
  identity is the stable page-session `requestKey` plus the canonical `intentDigest`; native
  `prepare` converges only when both match. Never deduplicate by intent alone because two deliberate
  identical transactions must remain separate. A record without `requestKey` is not deduplicated.
  Confirm retries by comparing `requestKey`, `intentDigest`, and record IDs in App Group
  `PendingRequests/` without exposing full params.
- **Empty popup despite pending records:** check for duplicate `stupid wallet` extensions in
  Safari and for disable-on-reinstall. `pluginkit -m -v` / Safari's `WebExtensions/Extensions.plist`
  (`~/Library/Containers/com.apple.SafariTechnologyPreview/…`) reveal a second registration (e.g.,
  a stale `…dev.extension` from the `ios-wallet` reference, or a `run --mac` `.MacInstall`
  instance). Unregister stale paths with `pluginkit -r <appex>` and relaunch Safari. An Xcode
  Run re-install re-registers the plugin and can reset the extension to **disabled**; re-enable
  it in Safari settings before drawing conclusions, otherwise `popup.list` can fail before native
  code (no `BEGIN`/`list` log).
- Safari Settings can retain two enabled `stupid wallet` rows with the **same production bundle
  identity** but different manifest versions even when `pluginkit -m -v` lists only one current
  registration. Inspect the displayed version for every row, disable only the stale version, and
  keep the current row enabled. If that removes the shared toolbar item, restore the current item
  through View → Customize Toolbar. A stale web-extension row can keep page/popup JavaScript old
  while the native plugin executable is current.
- Installing the TestFlight app can repoint the production PlugInKit registration even while a
  current Xcode row remains visible. Map every Safari version row to its actual manifest, quit
  Safari, unregister only the exact stale TestFlight or `.MacInstall` appex paths, rerun the tracked
  Xcode scheme, and enable only the current row. Never unregister by bundle identifier alone.
- **Derived accounts clipped in the popup:** a fixed-height Safari popover needs the account-picker
  panel bounded by the viewport with its own vertical overflow and overscroll containment. If the
  lowest account rows are clipped while wheel input moves the dapp underneath, the page—not the
  picker—owns the scroll.
- On macOS, the popup's canonical `list`/`approve`/`reject` operations should reach native directly
  so page-status polling cannot starve the review surface. Preserve a background-worker fallback
  for Safari environments where direct popup-to-native transport reports an error. If a pending
  record exists but no native `list` arrives when the popup opens, inspect which manifest-version
  row supplied the popup before weakening store or Safari-profile validation.
- **Badge remains after direct popup rejection:** direct popup-to-native decisions bypass the
  background worker's in-memory request map. After native success, notify the worker of the decided
  request before closing the popup so it deletes the ID and updates its badge. Render zero pending
  requests with `browser.action.setBadgeText({ text: "" })`; the string `"0"` is still badge text,
  not a request to clear it. Regression-test both the one-to-zero transition and the empty string.
- **Consumed signature followed by “Request no longer available”:** inspect the retained request
  before blaming signing. Popup approval holds the one-time claim through authentication and its
  terminal write; a concurrent provider status poll can observe the canonical pending record while
  failing to acquire that claim. Claim contention is transient pending state, not absence. Recheck
  the persisted profile and binding before returning pending, then let the next poll read the
  consumed result. Keep a regression test that owns the claim during `status`.
- Xcode Debug's split executable (`ENABLE_DEBUG_DYLIB`) can leave Safari launching a stale
  monolithic plugin image while `.XCInstall` contains a current stub + debug dylib. Symptoms are
  current source strings in `.XCInstall`, but fresh records retain an old schema and current native
  diagnostics never appear. Set `ENABLE_DEBUG_DYLIB: NO` in the tracked Mac XcodeGen project,
  increment the diagnostic build number if needed, quit Safari Technology Preview before Xcode
  Run, then inspect the running plugin with `pgrep -alf StupidWalletSafari` and `lsof -p <pid>`.
  Do not infer the executing version from `.XCInstall` alone.
- Open the Mac Safari toolbar popup through its accessibility label with Computer Use rather than
  assuming a toolbar button index or guessing Retina-scaled coordinates.

### 3. Inspect JavaScript Envelopes

- `bridge.js` expects `{ __envelope: true, ok, result|pendingId|error }`.
- For a wallet missing from an MIPD/Wagmi connector list, inspect the page bundle and window
  events before blaming connector filtering. A conforming EIP-6963 wallet must both announce
  during initialization and listen for `eip6963:requestProvider` so it can re-announce after a
  late consumer registers its listener. A one-shot announcement creates a load-order race.
- To separate page filtering from wallet discovery, dispatch an
  `eip6963:announceProvider` event with the wallet's existing metadata after the page has
  initialized. If its connector appears, inspect request/re-announcement timing and provider
  metadata rather than changing the dapp's connector configuration.
- If a LAN-hosted HTTP fixture reports provider-not-found while the extension is enabled and allowed,
  inspect provider initialization for secure-context-only APIs. iOS Safari exposes
  `crypto.randomUUID` on HTTPS and trusted loopback but not ordinary LAN HTTP; use
  `crypto.getRandomValues` for cryptographically random development-origin session IDs.
- Preserve structured errors as `{ code, message, data? }` through every layer.
- Native replies use `{ ok, data }` for success and `{ ok: false, error }` for failure. A background
  route must inspect the operation value inside `data` and forward `error`; treating the outer native
  envelope as the operation result can resolve a failed durable mutation as provider success.
- In the popup, never render an object with `String(error)`; read `error.message` and retain
  the code/data for diagnosis.
- Remove all temporary alerts/logging before the final build. Never log complete signing
  payloads or user-linked activity.
- Safari caches MV3 workers aggressively. Bump `manifest.json` after extension JavaScript
  changes so the simulator loads the corrected worker, then reinstall through `stupid-app`.
- For app-driven disconnect or account removal, return to the existing Safari page before adding
  polling. `bridge.js` refreshes native `visibleAccounts` on initial injection, `pageshow`, window
  focus, and visible `visibilitychange`; `provider.js` emits `accountsChanged` only when that snapshot
  differs. A connected dapp becoming disconnected without reload after returning from the containing
  app proves this route. Repeatedly pressing Connect creates deliberate calls with new `requestKey`
  values, so press it once and inspect the resulting canonical request instead of tapping again.

### 4. Inspect Popup And Queue Behavior

- Open Safari Page Menu, choose **Stupid Wallet**, and read the card with OCR.
- Safari accent-tints a monochrome action icon blue when the extension can access the current
  page. This is expected active-state UI, not evidence that the packaged general icon changed.
  To retain an intentional color, provide genuinely colored transparent PNGs through
  `action.default_icon`; if that key is absent, Safari falls back to the general extension icon.
- In the iOS 26 compact bottom toolbar, Page Menu is the rectangle-over-lines control to the
  left of the address. The ellipsis opens tab actions and does not expose extensions.
- Long transaction cards may need a swipe beginning inside the popup:

```bash
idb ui swipe 200 800 200 500 --duration 0.5 --udid <udid>
```

- One dapp action may produce multiple sequential requests. A token-to-native Uniswap swap
  can include an ERC-20 allowance transaction, Permit2 typed-data signature, then swap.
  Diagnose each canonical record separately.
- A send popup's `Network Fee` is a display-only estimate from `eth_estimateGas` and the
  effective fee cap. `Unable to estimate` identifies a summary-time RPC failure; it does not
  populate `resolvedParams` or change the canonical request. Approval resolves nonce, gas,
  and fees again immediately before signing, so never treat the displayed estimate as the
  signed gas fields.
- Only the oldest pending request is approvable. Never reorder or mutate persisted files.
- **Empty popup with a valid fresh pending record:** native `list` may be failing the whole
  store, not returning zero. A retained `PendingRequests/*.json` written by an older build
  (the pre-`revision`/pre-`bindingVersion` schema: a UUID record with only
  `id,method,chainId,origin,result,payloadDigest,params,expiresAt,status,account,kind,createdAt`
  and no `revision`) fails the current `WalletPendingRequest` decode, `store.pending()` aborts
  with `PendingRequestStoreError.corrupt`, and popup `refresh()` renders the empty standby.
  Prove it without guessing: add a temporary `os.Logger` in `SafariWebExtensionHandler`'s
  `list` case, rebuild/reinstall, reinstall through `stupid-app run --simulator`, then capture
  `/usr/bin/log stream --predicate 'subsystem == "SOMESUBSYSTEM"'` and look for
  `LIST ok profile=- count=N` vs `LIST threw error=corrupt`. `jq . <record>` parses fine while
  Swift `Codable` still rejects it, so validate with the real decoder, not `jq`.

### 5. Inspect Native Preparation And Signing

- For `eth_sendTransaction`, compare the canonical record against supported fields, active
  account, chain, nonce, gas, fee model, value, destination, and calldata.
- Missing transaction nonce/gas fields intentionally remain absent from canonical `params`
  while pending and are resolved immediately before signing. A consumed/failed send records
  the actual signing transaction in `resolvedParams`. If quick successive sends fail with
  `nonce too low`, verify each approval made a fresh `eth_getTransactionCount(..., "pending")`
  call after the preceding broadcast rather than comparing only the immutable intent.
- For `eth_signTypedData_v4`, decode standard `[address, jsonString]` params and test the
  exact EIP-712 digest independently. Avoid host `Int` for `uintN`; EIP-712 permits full
  256-bit values and must enforce the declared width.
- Authentication cancellation and invalid signing parameters are different failures. A
  fresh `.userPresence` keychain read should happen exactly once for each signature.
- If one installation exposes a per-app Face ID control in Settings and another does not, inspect
  `NSFaceIDUsageDescription` in both the source and packaged app/extension plists, then compare upgrade
  history. iOS can retain authorization state for an upgraded bundle ID, while a fresh install cannot
  request Face ID without the usage description. Trigger one legitimate protected operation before
  concluding that a fresh installation will never expose the control.
- LocalAuthentication temporarily moves the containing app to SwiftUI scene phase `.inactive` while
  the system prompt is visible. Privacy-sensitive reveal state must clear on `.background`, navigation
  away, and its timeout, but not on every non-active phase; otherwise a successful reveal flashes and
  immediately disappears when authentication completes.
- During create/import, no verification prompt means failure occurred at the keychain add,
  before authenticated reload or App Group registration. After uninstall/reinstall,
  `errSecDuplicateItem` can mean the protected key survived while `wallet-address.conf` did
  not. Never delete or overwrite it to recover: authenticate the existing item, require it
  to match the imported secret, repeat sign-and-recover verification, then restore only the
  non-secret registration.
- If an upgraded Dawn user sees the existing-wallet load error and then a generic save error with no
  authentication prompt, treat the save error as potentially secondary: wallet-group creation first
  requires a ready registry and may not have reached key generation. Inspect Dawn ciphertext lookup and
  the migration pending marker. Legacy reads must bind the production access group and empty Dawn
  generic-password service without falling back to an access-group wildcard; an already-saved pending
  key resumes at authenticated new-format proof, and must never be deleted or replaced to make migration
  retry.
- Denying the Dawn decrypt or new-format verification prompt is intentionally fail-closed: migration
  remains incomplete, old material stays intact, and wallet creation still requires the unavailable
  registry. `errSecUserCanceled`, `errSecAuthFailed`, and `errSecInteractionNotAllowed` should surface as
  cancelled-or-unavailable recovery with passcode guidance, not as a generic wallet save failure. With no
  device passcode, `.userPresence` storage and release are unavailable; enable a passcode and retry the
  in-place migration rather than creating or deleting key material.
- Never preflight authentication, cache an unlocked key, or sign arbitrary popup params.

### 6. Verify RPC Behavior

- Reproduce a failing passthrough call with the exact original method spelling and params.
- Compare native behavior with a direct public-safe request:

```bash
curl -sS -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  https://evm.stupidtech.net/v1/8453
```

- A dapp may issue unsupported wallet probes such as `wallet_getCapabilities`; do not add
  fake success responses. Confirm whether the dapp tolerates the error and falls back.
- For `wallet_addEthereumChain`, inspect both `eth_chainId` probes when the Stupidtech default
  does not serve a development chain such as Anvil. Approval may persist only the displayed first
  `rpcUrls` entry after exact-chain and transport validation; an existing user override still wins.
- Do not retry state-changing RPC methods casually. Same-endpoint retries for reads require
  a concrete failure and regression coverage.
- For first-time EIP-7702 batch estimation, never send a valid signed authorization to an
  RPC before the outer transaction is ready to broadcast. Verify the implementation runtime
  hash, estimate with that runtime applied to the account through a state override, and add
  authorization overhead locally. A signed authorization retained by an RPC can become usable
  after the account nonce advances even if the wallet's approval flow was cancelled.
- Capability reporting and authorization must compare the full implementation runtime hash,
  not merely check for nonempty code. Foreign delegation designators and malformed account code
  must never be replaced by a dapp-triggered `wallet_sendCalls` request.
- Atomic batching is eligible on every chain recorded in `NetworkStore`, not a hardcoded chain
  list. If the pinned implementation is missing, approval deploys the reviewed creation code
  through the hash-pinned canonical CREATE2 factory, waits for its successful receipt, verifies
  the runtime, and only then reads the nonce for the authorization batch. Expect one type-2
  deployment followed by one type-4 batch on a fresh chain.
- A positive implementation verification is cached by chain. RPC override changes invalidate it;
  loopback RPCs deliberately bypass persistent deployment caching because Anvil or another local
  chain can reset at the same URL. If a non-loopback chain unexpectedly appears stale, inspect
  `simple-7702-deployments.json` and the selected RPC before weakening runtime checks.
- For a self-sponsored first-time type-4 batch, the outer transaction uses the current pending
  nonce and the authorization uses that nonce plus one. When the authority is also the sender,
  successful processing advances the account nonce twice; the next ordinary type-2 batch should
  therefore use the original pending nonce plus two. Verify this against the mined transaction,
  receipt, installed `0xef0100 || delegate` designator, and latest account nonce before sending a
  follow-up batch.

### 7. Verify Cryptography And Transactions

- Pin deterministic vectors in Swift tests and cross-check with viem or Foundry.
- For EIP-712, compare `EIP712.prefixedHash` with viem `hashTypedData`.
- Do not hand-transcribe typed JSON payloads into test vectors. A single hex nibble error in any
  64-byte-address-encoded field changes the digest and can look like a wallet hashing bug. Build
  vectors by decoding the exact captured JSON, and cross-check the digest with `viem`/`ethers`/`cast`.
- For `eth_signTypedData_v4`, recover the signer with `viem` `recoverAddress({ hash, signature })`
  against the canonical EIP-712 digest. A recovered account that differs from the recorded account
  (for every `from` variant and recovery id) means the signer sealed a different digest/identity
  than the request corresponds — reproduce live and capture the digest the signer actually seals
  before changing hashing code.
- The wallet signs the digest it computes, so a "wrong" signature is usually self-consistent: it
  recovers to the account under the wallet's own digest but not under a standard tool's digest. When
  that split appears, diff the wallet's domain hash against viem `hashDomain`. A frequent root cause
  is EIP-712's *implied* `EIP712Domain`: a compliant dapp omits it from its `types` map, and a hasher
  that reads domain fields from `types["EIP712Domain"]` hashes an empty domain struct instead. Confirm
  by re-hashing with `EIP712Domain` injected into `types` — if the digest then matches viem, the hasher
  must synthesize the implied domain fields (name/version/chainId/verifyingContract/salt) itself.
- After an authorized broadcast, verify independently:

```bash
cast tx <hash> --rpc-url https://evm.stupidtech.net/v1/8453 --json
cast receipt <hash> --rpc-url https://evm.stupidtech.net/v1/8453 --json
```

- Check recovered sender, chain, nonce, destination, value, receipt status, and expected
  transfer logs. Do not execute a transaction unless the user explicitly authorizes it.
- A consumed request and returned hash do not prove propagation. Check the hash through the
  configured endpoint and an independent node, then compare `latest` and `pending`
  `eth_getTransactionCount`. If both nonces remain unchanged and neither node knows the
  hash, treat it as dropped; create a fresh canonical replacement at that nonce rather than
  mutating a consumed record or assuming a second spend occurred.

## Fix And Verification Ladder

1. Add a deterministic regression test whenever possible.
2. Make the smallest fix at the layer that violated its contract.
3. Format changed Swift with `swift format --in-place`.
4. Format/lint extension JavaScript with the repository's established `oxfmt`/`oxlint`
   commands and run `node --check` on changed scripts.
5. Run `swift test`.
6. Run `stupid-app doctor` when packaging, entitlements, extension loading, or device
   behavior is involved.
7. Reinstall and launch with:

```bash
stupid-app run --simulator --udid 6552DF1D-95CE-48E3-801F-8F80F0AA8D29
```

8. Repeat the real dapp flow. Verify the durable record and independent chain outcome; do
   not claim success from serialization or UI alone.
9. Update `docs/engineering-handover.md` when current behavior changes and append a
   public-safe entry to `docs/implementation-notes.md`.
10. Update this skill when the investigation reveals a reusable command, simulator
    interaction, failure signature, stack boundary, or safety rule.
