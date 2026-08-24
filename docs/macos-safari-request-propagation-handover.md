# macOS Safari Request Propagation Handover

## Purpose

This document records the resolved Mac failure where a dapp request reached native code but the
Safari toolbar popup did not reliably show it. It preserves reusable failure signatures and the
remaining network-verification item.

## Resolution

The defect crossed installation, Safari resource selection, and request routing:

1. Safari was able to retain a stale native plugin process across an Xcode reinstall. Disabling
   Xcode's debug-dylib split, quitting Safari before Run, incrementing the bundle build when needed,
   and inspecting the running plugin—not merely `.XCInstall`—made the executing image explicit.
2. Safari Settings retained two enabled rows with the same production extension identity but
   different manifest versions. PlugInKit listed only the current registration, so the stale web
   resources were invisible to that check. Disabling the stale Safari row selected the current
   provider, worker, and popup.
3. Page status polling could occupy the worker while the popup waited for a canonical list. On
   macOS the popup now sends `list`, `approve`, and `reject` directly to native, retaining the
   background route as an iOS-compatible fallback.
4. After a direct popup decision, the popup notifies the worker before closing. The worker removes
   that request and represents zero pending requests with an empty badge string, not `"0"`.
5. Completion does not depend on a retained worker callback. The isolated bridge polls the durable
   native record and resolves the original page request when it is consumed or rejected.

Manifest `0.1.24` includes these fixes. Live rejection proved that a one-item badge clears
immediately and that the dapp receives the expected user-rejection error without signing.

## Retry Identity

Transport loss can cause a bridge to retry the same provider request. Intent equality alone is not
retry identity: a user may deliberately submit two identical transactions. Each page session now
assigns a stable `requestKey` to every provider call. Native `prepare` deduplicates only a pending
record with both the same `requestKey` and the same canonical `intentDigest`, under a cross-process
file lock. Separate identical requests remain separate. A request without a key is never
deduplicated, preserving compatibility without guessing.

The prepare lock is part of the correctness boundary. Failure to acquire it now fails loudly
instead of silently degrading to an in-process-only check.

## Reusable Diagnostics

- After Xcode Run, check whether Safari reset the extension to disabled.
- Inspect every same-name row and displayed manifest version in Safari Settings; PlugInKit alone
  cannot reveal stale web-extension rows with the same bundle identity.
- Compare the running `StupidWalletSafari` process and loaded executable with `pgrep` and `lsof`.
  Current strings in `.XCInstall` do not prove current code is running.
- Restore a missing toolbar item through Safari's toolbar customization UI.
- Use accessibility/Computer Use to activate the toolbar item semantically; do not guess
  Retina-scaled coordinates.
- Do not weaken profile matching. Current-build evidence showed popup and page requests both used
  `profile=nil`; stale/expired records had caused the misleading empty list.
- Do not edit App Group pending records to force progress or retain sensitive diagnostic payloads.

## Proven And Outstanding

Proven on the local Xcode-installed Mac build:

- current native handler execution and native request preparation;
- canonical popup listing through direct native transport;
- distinct retry versus separate-identical-request behavior in hermetic tests;
- popup rejection, page error propagation, and immediate badge clearing;
- connect and authenticated signature recovery.

Still outstanding: `eth_sendTransaction` broadcast on the Mac with a network-verified receipt, and
the equivalent full flow from the TestFlight distribution install.

## Relevant Files

- `SafariExtension/Resources/provider.js`
- `SafariExtension/Resources/bridge.js`
- `SafariExtension/Resources/background.js`
- `SafariExtension/Resources/popup.js`
- `Sources/StupidWalletCore/PendingWalletRequest.swift`
- `Sources/StupidWalletCore/WalletService.swift`
- `Sources/StupidWalletSafari/SafariWebExtensionHandler.swift`
- `Tests/JavaScript/`
- `Tests/StupidWalletCoreTests/ConnectedSitesTests.swift`
- `skills/stupid-wallet-debugging/SKILL.md`
