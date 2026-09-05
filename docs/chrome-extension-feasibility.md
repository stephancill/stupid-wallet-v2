# Chrome Extension Feasibility On macOS

Status: local Chrome integration installed and authenticated signing proven; release gates remain open.

Chrome on macOS is implemented for owner-authorized local use with the existing iOS-on-Mac wallet.
The unpacked Chrome extension uses the shared provider, popup and `NativeWalletDispatcher`; the
provisioned `StupidWalletChromeHost.app` opens the existing App Group and explicit data-protection
keychain group. It requires a ready registry and never runs migration or creates wallet material.
Production app, Safari, App Group and keychain identities are unchanged. Google Chrome is the selected
acceptance browser; Arc's native-host launch remains unproven.

The local installer uses an existing compatible macOS development profile and Apple Development
identity, under the owner's direct-codesign exception. It installs only a helper bundle and exact
Chrome user-level registration. No stupid-app source or Apple account resources are modified.
`stupid-app` 0.0.16 remains the iOS build authority. Developer ID, notarization, clean-machine package
installation and a reserved Web Store identity remain distribution requirements.

Protocol version 3 requires one-time Chrome-profile pairing before native approval. The extension
stores a non-exportable P-256 signing CryptoKey in its origin-owned IndexedDB; the helper stores only
the paired public key in an entitled data-protection keychain item. These credentials are distinct
from Ethereum wallet keys. Setup uses proof of possession and a two-minute nonce-bound transcript;
the extension and native helper display the same 48-bit comparison code before native confirmation
persists trust. Pairing changes and revocation require a native confirmation, not wallet authentication.
The owner explicitly accepted the browser-profile-compromise tradeoff: Web Crypto non-exportability
is an API restriction, not a hardware-backed guarantee against local profile theft or browser control.

Normal approvals now follow toolbar review → fresh macOS authentication, with no second native review.
The popup submits its displayed request ID, revision and canonical binding digest. Native code compares
these with the persisted summary, creates a ten-second one-use challenge, and verifies the paired
P-256/SHA-256 proof over domain, profile, nonce, request, revision and digest before protected access.
The worker signs only a challenge matching that outstanding popup approval and verifies the original
top-level document before and after creating the proof. Native checks the key remains paired when
consuming the challenge. Replays, wrong keys, expiry and changed bindings fail closed. Existing core
origin/account/chain/digest/expiry/one-time request checks and fresh LAContext protection remain.

The service worker owns the native port and does not replay mutations after disconnect. Navigation,
closed tabs and port EOF invalidate active protected operations. Chrome profiles cannot inherit old
Safari hostname grants. Manage Chrome pairing opens an extension-owned setup tab; unpaired profiles
show setup guidance instead of approval controls. Unpairing leaves wallet keys and site grants intact.
Extension storage survives normal restarts; clearing it requires setup again. Extension 0.0.4 and
helper 0.0.4 use protocol 3 and must be updated together; older protocol versions are rejected.

Protocol-3 physical Chrome acceptance passed matching-code pairing, independently recovered message
signing with owner-confirmed authentication-only UX, explicit unpairing with approval controls removed,
restored pairing, full browser restart persistence and independently recovered EIP-712 signing after
restart. The profile is left paired. Tests pass: 317 Swift / 33 JavaScript.

The Chrome transport bundles pinned Zod 4.5.4 for strict privileged message validation and esbuild
0.28.2, satisfying the owner's Zod requirement. These are an explicit Chrome-only exception to the
no-dependency/no-build preference; Safari resources remain framework-free. Chrome adds webNavigation
permission solely to verify the original document and revoke stale requests. Minimum Chrome is 111;
minimum macOS helper target is 14.

Physical-Mac acceptance on 2026-09-05 passed connection to an existing selected account, chain/block
RPC reads, authenticated personal_sign and EIP-712 signatures independently recovered by viem to the
connected account, toolbar rejection and native-review cancellation (4001). Synthetic checkpoint
proofs additionally passed 40 concurrent commits and recovery across helper SIGKILL and Chrome restart.
These results establish local signing usability, not all release gates: actual transaction/batch
broadcast, multiple physical Chrome profiles, lock/sleep/authentication failure, in-flight signing
interruption and mixed app/Safari/Chrome persistence acceptance remain unproven. No transaction or
token approval was requested during local acceptance.

Selected packaging direction: retain the current iOS-on-Mac wallet app and ship a minimal helper-only
macOS integration package. Do not introduce a second wallet UI or a separate desktop wallet app
merely to host Chrome integration.

## Verdict

A secure Stupid Wallet extension for Google Chrome on macOS is feasible, but it is not a
Chrome-extension-only port. It requires both:

1. A Manifest V3 Chrome extension that owns provider compatibility, trusted browser sender
   context, the toolbar review UI, and completion routing.
2. An installed, signed, and notarized native macOS messaging host that owns canonical persistence,
   App Group and keychain access, LocalAuthentication, signing, and RPC policy.

The selected shape is a helper-only package alongside the current iOS-on-Mac wallet app, with no
second wallet UI. Chrome requires a registered executable that implements its
standard-input/standard-output protocol; the current iOS-on-Mac/TestFlight app executable and Safari
extension do not implement that protocol and cannot be used unchanged.

It also cannot be added as a standalone helper to the existing iOS/iPadOS application package.
Apple defines helper-tool locations for macOS app bundles, while iOS App Store validation permits
standalone executables only as the main executable of supported bundles. A Mac Catalyst or native
macOS wallet can share this repository, product identity, and App Store universal-purchase record,
but Apple requires it to be built and uploaded as a separate macOS binary/archive.

This can preserve the existing security model because the private key remains in Apple-protected
native storage and every protected operation can still use a fresh `LAContext`. A design that stores
or unwraps wallet key material in extension JavaScript, WebAssembly, browser storage, or WebCrypto
is rejected.

The work is materially smaller than a new wallet because the provider, bridge, popup, canonical
request model, Ethereum implementation, stores, and most policy code already exist. It is still more
than a manifest conversion: Chrome native-host packaging, lifecycle, profile binding, independent
versioning, and release tooling are new product surfaces.

Windows and Linux are intentionally outside this investigation and proposal.

## Scope Boundary

The product owner approved Chrome-on-macOS implementation scope and the helper-only package on
2026-09-05. This approval permits the proof-gated Chrome extension and native macOS helper work. It
does not change current iOS/Safari acceptance criteria, establish priority relative to unfinished Gate
I work, or authorize a second build-and-release source of truth. `stupid-app` must be extended to
build, sign, package, and release the native macOS host before production release work.

The first implementation should be a macOS proof target, not a production release. Existing wallet
or migration data must not be modified destructively during the proof. Use a Developer-ID-signed
helper package that coexists with the current iOS-on-Mac app and has no second wallet UI. Chrome
controls host process lifetime, may start multiple instances, and requires standard output to contain
protocol frames only.

## Required Architecture

### Browser extension

The Chrome extension should retain these responsibilities:

- Inject the EIP-1193 provider in the page's MAIN world and announce it through EIP-6963.
- Validate page-to-extension envelopes in the isolated bridge.
- Derive the dapp origin from Chrome's `runtime.MessageSender.origin`, with a validated tab URL only
  as a documented compatibility fallback. Ignore page-supplied origin metadata.
- Classify wallet-owned, denied, and RPC-passthrough methods consistently with Safari.
- Render only native canonical summaries in the toolbar popup.
- Route approve and reject actions through the service worker to the native host.
- Recover request completion after popup closure, service-worker suspension, host restart, and
  browser restart without trusting in-memory state.

The extension must not hold private keys, decrypted seeds, key-encryption keys, arbitrary native
signing parameters, or authoritative pending-request state.

### Native messaging host

The native host should be a small signed Swift executable that:

- Reads and writes Chrome native-messaging frames on standard input and output.
- Writes no logs or diagnostics to standard output; framed protocol responses are the only allowed
  output there.
- Validates every message against a strict versioned schema and rejects unknown privileged fields.
- Uses an explicit protocol handshake so independently updated extension and host versions fail
  clearly when incompatible.
- Uses `StupidWalletCore` for wallet policy, canonical pending records, authentication, Ethereum
  serialization, RPC resolution, and activity persistence.
- Accepts only canonical persisted request IDs plus the reviewed revision for approval and
  rejection. It never signs parameters supplied in an approval message.
- Explicitly configures the production keychain access group. The current
  `KeychainKeyStore.defaultAccessGroup` is `nil` on macOS and is not sufficient for the helper.
- Uses the same App Group coordination and recoverable persistence boundaries as the app and Safari
  extension.
- Uses a fresh, zero-reuse `LAContext` for every signature, transaction, or private-key export and
  invalidates it afterward.

The dispatch policy previously in private `SafariWebExtensionHandler.Server` has been extracted into
`StupidWalletCore.NativeWalletDispatcher`, with a typed `NativeWalletEnvelope`. Safari now calls that
shared dispatcher after its existing adoption barrier and property-list conversion. The initial
Chrome host rejects wallet actions; after the required shared-storage and authentication proofs,
its framed-JSON adapter must call this dispatcher with an explicitly configured native service rather
than duplicate privileged behavior.

### Message flow

The intended protected-request flow is:

1. The dapp calls the injected provider.
2. The isolated bridge forwards a validated request envelope to the service worker.
3. The service worker derives the origin from Chrome sender context and adds only extension-owned
   routing context, including the native profile ID.
4. The native host validates and persists the canonical one-time request, including origin, profile,
   account, chain, method, payload digest, revision, expiry, and unconsumed state.
5. The native host returns a request ID; browser storage may retain only non-authoritative tab
   routing data.
6. The toolbar popup asks the service worker for the native canonical summary.
7. Approval sends only request ID and reviewed revision through the service worker.
8. The native host reloads and revalidates the persisted request, presents fresh system
   authentication, signs, records the terminal result, and consumes the request atomically.
9. The service worker returns or later recovers the durable result only for the original origin and
   valid tab context.

The popup is review UI, not an execution lifetime. Touch ID can move focus away from or close the
popup without canceling the durable native operation.

## Chrome-Specific Constraints

### Native messaging

Chrome starts native hosts as independent processes and uses UTF-8 JSON preceded by a 32-bit
native-endian length. Chrome permits messages up to 64 MiB from extension to host and 1 MiB from host
to extension. The wallet should impose a substantially smaller reviewed protocol limit and reject
oversized input before decoding nested request data.

`runtime.sendNativeMessage()` starts a new process for each message and accepts only its first
response. `runtime.connectNative()` keeps a host process and a port alive. The Chrome service worker
should own a `connectNative()` port while handling review and authentication, reconnect after host
exit, and continue to treat native persistence as authoritative. A live port is a lifecycle aid, not
a correctness requirement.

The existing Safari host name `co.za.stephancill.stupid-wallet` is invalid for Chrome because Chrome
host names permit only lowercase alphanumerics, underscores, and dots. A Chrome-specific name such
as `net.stupidtech.stupid_wallet` is required.

The native host manifest must contain the final exact Chrome extension origin in `allowed_origins`;
wildcards are forbidden. The host should also validate the caller-origin argument. This identifies
the extension, not the dapp.

### Origin and profile identity

Chrome passes the calling extension origin to the native process, but not the dapp origin, tab, or
Chrome profile. Therefore:

- The service worker is the trusted Chrome boundary for dapp origin and tab identity.
- A random profile ID should be generated and retained in `chrome.storage.local`, then bound to all
  native grants and pending records. It is extension-owned context and must never be accepted from
  page JavaScript.
- Reinstall or storage loss should create a new profile identity and require reconnecting sites
  rather than attempting an unsafe identity fallback.
- Initial Chrome support should reject incognito requests. Incognito can be considered only after
  split-mode storage, profile binding, UI, and deletion behavior have dedicated acceptance tests.

The exact browser profile name is not needed and should not be collected.

### Popup and service-worker lifecycle

The current Safari popup first calls native messaging directly. Chrome should instead send popup
actions to the service worker, which owns the native port. This avoids coupling an authentication
operation to popup lifetime when system UI changes focus.

All request state and results remain native and durable. Browser-side state may remember the
request-to-tab route, but delivery must re-check the current tab origin and must not deliver after
navigation, profile change, expiry, or duplicate completion.

### JavaScript namespace compatibility

The existing resources use `browser.*`, while their manifest declares Chrome 111 as the minimum.
Chrome only added the `browser` namespace in Chrome 148. A Chrome artifact must either:

- use a small shared adapter that selects `globalThis.browser ?? globalThis.chrome`; or
- raise its actual minimum Chrome version to 148.

The adapter is preferable if older maintained Chrome versions are a requirement. It must not alter
message validation or privileged data flow.

## Reuse And New Work

### Reusable with limited adaptation

- `provider.js`: EIP-1193 and EIP-6963 behavior.
- `bridge.js`: isolated-world validation and durable status polling.
- `popup.html`, `popup.css`, and most of `popup.js`: canonical request review.
- Most of `background.js`: method policy, trusted sender-origin derivation, routing, and badge logic.
- `StupidWalletCore`: canonical requests, stores, signing, RPC, Ethereum serialization, migration
  reading, activity, and tests. The package already declares macOS 14 support.
- Vendored secp256k1 and independent cryptographic vectors.

### New or changed components

- A Chrome-specific manifest/build artifact and valid native-host name.
- A transport-neutral privileged dispatcher shared by Safari and Chrome.
- A framed-JSON native messaging executable with strict size and schema limits.
- Service-worker-owned persistent native-port coordination and popup routing.
- Profile identity generation and native binding; explicit incognito denial.
- Explicit macOS keychain access-group configuration and signed host entitlements.
- A signed/notarized installer, host registration/unregistration, update strategy, and diagnostics.
- `stupid-app` native-host support under the contract recorded in `ChromeExtension/README.md`.
- Chrome Web Store listing, permission explanations, privacy disclosures, and support instructions.
- Version-skew, browser-lifecycle, installation, and physical-Mac authentication tests.

## Security Analysis

The native companion preserves the important boundary: compromise of page JavaScript cannot read a
private key or ask native code to sign arbitrary parameters. The page can create requests only
through the extension protocol; the native side canonicalizes them before review, and approval
references that persisted record.

The extension package and service worker become trusted for Chrome sender context because Chrome
does not pass the dapp origin through native messaging. This is acceptable only if:

- only reviewed local extension code is shipped;
- remotely hosted code and dynamic code loading remain absent;
- the native-host manifest permits only the production extension ID;
- page messages cannot supply or overwrite native origin, profile, request ID, revision, or digest
  bindings; and
- native approval always reloads the canonical record and displays its native summary before fresh
  authentication.

A same-user local process can invoke a native executable outside Chrome and can imitate ordinary
standard input. Caller arguments are therefore defense in depth, not authorization. Safety must
continue to come from canonical one-time records, paired extension approval, fresh authentication, strict
revision/digest checks, and replay rejection.

No proof may weaken migration safety. Existing protected key material must remain untouched until
the helper has demonstrated authenticated access and recovered-signer correctness. A failed helper
experiment must leave the Safari wallet usable.

## Distribution Constraints

The Chrome Web Store distributes the extension but not its native executable. Production therefore
needs the selected signed and notarized helper-only package to install the executable and register its
manifest under a documented Chrome `NativeMessagingHosts` location. Onboarding must detect a missing
or incompatible host and link to the integration-package installer without presenting the wallet as
ready.

The current iOS-on-Mac/TestFlight app is sandboxed and is not, by itself, a Chrome native-host
installer. Reusing it unchanged would still leave no supported mechanism to place Chrome's manifest
outside the app container or provide Chrome's stdio entry point. The selected product shape is a
minimal helper-only package alongside the current app. It requires a separate macOS build artifact
and Chrome registration and cannot be shipped inside the existing iOS/iPadOS binary. The exact
registration scope and update flow remain release decisions.

The final Chrome Web Store extension ID must be known before producing the host manifest. Reserve the
store item before release packaging, and use a fixed development extension identity for repeatable
testing. Installer updates and extension updates are independent, so both sides need a compatibility
range and actionable fail-closed errors.

The listing and onboarding must explain `nativeMessaging`, storage, and all-site access. The current
`<all_urls>` content-script access is functionally required for an injected wallet provider but is a
sensitive permission and must not be used for unrelated page inspection.

## Ordered Proof Gates

No production-readiness claim should be made until Gates 0 through 4 pass. Later release work depends
on those security proofs.

### Gate 0: scope, identity, and release authority

- Product owner approval of macOS Chrome scope and the helper-package install requirement is complete.
- Keep `stupid-app` as build, signing, packaging, and release authority and define its required native
  host/package support before release implementation.
- Reserve a stable Chrome extension ID and choose a valid native-host name.

Exit: product scope, identifiers, ownership, and release authority are documented without changing
existing production identities.

### Gate 1: transport and lifecycle proof

Partial proof (2026-09-05): the separate `StupidWalletChromeProofHost` retained synthetic App Group
checkpoints across Chrome popup dismissal, helper SIGKILL, and `chrome://restart`. A 40-operation
concurrent subprocess test proved serialized commits, before/after-commit crash recovery, idempotence,
profile binding and corrupt-state refusal. The integrated wallet host subsequently replaced the proof registration.
This does not prove an in-flight authenticated operation, natural worker suspension, or power loss.

- Build a signed throwaway native host and fixed-ID unpacked extension.
- Prove framing, strict input limits, protocol handshake, host absence, version mismatch, malformed
  JSON, host crash, reconnect, browser restart, and service-worker suspension behavior.
- Prove no diagnostic bytes reach standard output.
- Route popup actions through the service worker's native port and prove popup closure does not lose
  the operation.

Exit: durable request/result exchange survives every tested browser and host lifecycle boundary and
fails clearly when the helper is missing or incompatible.

### Gate 2: shared Apple storage proof

Partial physical-Mac proof on 2026-09-05: a separately bundled diagnostic using an existing macOS
development profile and matching Apple Development certificate resolved the production App Group,
read the registry, and found registered protected sources without retrieving key bytes or presenting
authentication. The unentitled control returned -34018; the entitled nonexistent-item control
returned -25300. No production records changed. See `ChromeExtension/proofs/README.md`. This does not
close mixed-process interruption gates. The integrated host subsequently passed real connection and
authenticated message/typed-data signing with independent recovery. The shared-keychain entitlement requires an embedded macOS profile in a minimal app-like
helper bundle. Native macOS must explicitly select `kSecUseDataProtectionKeychain`; an access-group
string alone does not select the iOS-on-Mac protection domain.

- Sign the helper with the same team and the required App Group and keychain entitlements.
- On a physical Mac, prove read/write coordination against the same App Group container used by the
  installed iOS-on-Mac app and Safari extension.
- Explicitly configure the keychain group and prove metadata and non-interactive protected-item
  existence checks without exposing key bytes.
- Exercise concurrent app, Safari extension, and Chrome-host persistence interruption tests.

Exit: all three processes share the intended records and protection domains without corruption,
identity duplication, fallback storage, or migration mutation.

### Gate 3: canonical authority and profile proof

- Prove page-supplied origin/profile metadata is ignored and Chrome sender context is persisted.
- Prove separate normal Chrome profiles receive separate native identities and grants.
- Prove incognito fails closed.
- Prove request mutation, stale revision, expiry, replay, duplicate completion, tab navigation, and
  origin changes are rejected.
- Prove arbitrary params sent with an approval cannot influence what native code signs.

Exit: native records preserve origin, profile, account, chain, method, digest, expiry, revision, and
one-time-consumption bindings across process restarts.

### Gate 4: authentication and key-access proof

- On a physical Touch ID Mac, approve from the Chrome toolbar and prove the native helper presents
  fresh device-owner authentication while Chrome remains the active dapp application.
- Prove popup destruction or focus loss does not cancel, duplicate, or detach the canonical request.
- Prove one fresh `LAContext`, zero reuse duration, and invalidation for every protected operation.
- Exercise cancellation, biometric failure, passcode fallback, lock, sleep, helper termination, and
  rapid repeated requests.
- Recover every produced signature to the selected wallet account before any migration write or
  old-key removal is permitted.

Exit: the Chrome path matches the existing native authentication and signer-correctness invariants
without caching an unlocked key or depending on popup lifetime.

### Gate 5: end-to-end wallet behavior

- Run provider, connection, signing, typed-data, transaction, batch, chain, generic passthrough, and
  structured JSON-RPC error suites against Chrome.
- Prove account and chain event routing does not cross origin, tab, or profile boundaries.
- Broadcast a transaction on a representative network and verify its recovered signer, acceptance,
  and receipt independently.
- Prove Safari remains functional against the same wallet after Chrome use.

Exit: supported and denied methods match documented policy, arbitrary JSON values remain lossless,
and an independently verified transaction completes.

### Gate 6: install and release proof

- Produce signed/notarized install, update, repair, and uninstall flows.
- Verify user-level and chosen production host registration on clean supported macOS installations.
- Test older/newer extension and host combinations against the compatibility matrix.
- Complete Chrome Web Store review materials, permission/privacy disclosures, and missing-host support
  guidance.
- Run `stupid-app doctor` and the approved build/release pipeline for every affected target.

Exit: clean installation and independent updates cannot strand secrets, weaken checks, or silently
select a different host.

## Open Owner Decisions

1. Chrome implementation is now prioritized by the owner; Gate I acceptance remains separate.
2. Whether the helper package registers its host per user or system-wide.
3. The proof artifact retains minimum Chrome 111 through a namespace adapter; verify that minimum
   independently before a supported-version release claim.
4. Whether the first release shares the production Safari wallet or starts with isolated proof data.
   Production sharing still requires Gate 2 regardless.
Incognito and non-macOS browser support are not open decisions for this proposal; they are excluded.

## References

- Chrome native messaging:
  <https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging>
- Chrome extension service-worker lifecycle:
  <https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle>
- Chrome runtime API and `MessageSender`:
  <https://developer.chrome.com/docs/extensions/reference/api/runtime>
- Chrome `browser` namespace:
  <https://developer.chrome.com/docs/extensions/develop/concepts/browser-namespace>
- Chrome content scripts and execution worlds:
  <https://developer.chrome.com/docs/extensions/reference/manifest/content-scripts>
- Chrome Web Store policies:
  <https://developer.chrome.com/docs/webstore/program-policies/policies>
- Apple keychain sharing:
  <https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps>
- Apple App Groups entitlement:
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups>
- Apple LocalAuthentication:
  <https://developer.apple.com/documentation/localauthentication/lacontext>
- Apple platform-specific bundle layout:
  <https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle>
- Apple Mac Catalyst distribution:
  <https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html>

External documentation is reference material. Current Chrome, macOS SDK, signing, packaging, and
runtime behavior must be demonstrated by the gates above before implementation claims feasibility
for release.
