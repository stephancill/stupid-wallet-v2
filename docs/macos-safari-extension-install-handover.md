# macOS Safari Extension Installation Handover

## Purpose

This document records the resolved local-install boundary for the iOS Safari Web Extension on an
Apple Silicon Mac and the supported verification paths. The current architecture and gates remain
in `docs/engineering-handover.md`; chronological evidence is in `docs/implementation-notes.md`.

## Current Boundary

The product remains one iOS app distributed through TestFlight and run on macOS through Apple's
iPhone/iPad compatibility environment. The current `stupid-app run --mac` rejects projects with
app extensions because its LaunchServices-only installation path cannot create the
MobileInstallation/PlugInKit launch records Safari needs to spawn the native appex.

Xcode and TestFlight use Apple's entitled installer and do create those records. By explicit owner
decision, local native-messaging work therefore uses the tracked XcodeGen project in `Mac/` and
Xcode's **My Mac (Designed for iPad/iPhone)** Run destination. This is a development-only install
exception: it compiles the existing `Sources/` and does not replace `stupid-app` as the product's
normal build, signing, or release authority.

## Proven Local Path

The Xcode path is proven end to end for the current source:

- Safari spawns `StupidWalletSafari.appex` and delivers native messages.
- The app and extension share the configured App Group and keychain access group.
- Connection grants persist and are consumed correctly.
- A popup-approved signature invokes device-owner authentication and recovers to the registered
  account.
- The popup lists canonical pending requests promptly, rejection reaches the page, and the badge
  clears instead of displaying a red zero.

Mac transaction broadcast with a network-verified receipt remains outstanding. TestFlight still
must prove that the distribution install has the same behavior; a development Xcode install is not
evidence for Gate 8 distribution acceptance.

## Build And Install

1. Regenerate `Mac/StupidWalletMac.xcodeproj` from `Mac/project.yml` after project-file changes.
2. Keep `ENABLE_DEBUG_DYLIB: NO`. Safari can otherwise retain a stale monolithic plugin while the
   newly installed artifact contains a stub plus debug dylib.
3. Increment both app and extension `CFBundleVersion` when a fresh Safari install is required.
4. Quit Safari before Xcode Run, Run the `StupidWallet` scheme on **My Mac (Designed for
   iPad/iPhone)**, then reopen Safari.
5. Re-enable the extension if Xcode's reinstall reset it to disabled.

An `xcodebuild build` validates compilation but does not perform the compatibility-app installation.
Use Xcode Run for the local install transaction.

## Installation Diagnostics

- `pluginkit -m -v` should show one current production extension registration. Unregister a known
  stale appex with `pluginkit -r <appex-path>`.
- Safari Settings may retain two rows with the same production bundle identity and different
  manifest versions even when PlugInKit reports only one registration. Inspect every displayed
  version, disable only the stale row, and keep the current row enabled.
- Do not infer the executing code from `.XCInstall` alone. Compare the running
  `StupidWalletSafari` process and loaded executable with `pgrep` and `lsof`.
- If signing or shared storage fails, inspect the built products' code-signing entitlements before
  changing identifiers or weakening validation.
- A terminal keychain probe cannot establish that a `.userPresence` item is absent. Verify signing
  through a consumed pending record and independent signature recovery.

## Rejected Approaches

These did not create the missing entitled install record and are not retained:

- alternate development-profile kinds or application-identifier derivations;
- macOS profile embedding, code-page-size changes, or CMS timestamp changes;
- direct InstallCoordination access or treating `xcodebuild install` as device installation;
- using an Xcode test host to broker installation of an externally built artifact.

## Remaining TestFlight Gate

Install the iOS TestFlight build on a compatible Apple Silicon Mac and verify provider discovery,
native messaging, shared storage, popup review, rejection, authenticated signing, generic RPC
passthrough, and a network-accepted transaction while Safari stays foregrounded. Record only
public-safe evidence; never record wallet keys, user-linked addresses, signing payloads, or account
and device identifiers.

## Relevant Files

- `Mac/project.yml`
- `Mac/StupidWalletMac.xcodeproj`
- `docs/macos-safari-request-propagation-handover.md`
- `skills/stupid-wallet-debugging/SKILL.md`
- `../stupid-ios-dev/Sources/stupid-app/RunCommand.swift`
