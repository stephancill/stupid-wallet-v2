# Chrome on macOS local integration

The installed Chrome extension connects to the existing Stupid Wallet on this Mac. It supports the
shared WalletService method set and requires native authentication for signing. Local connection,
RPC, message signing and typed-data signing passed; both signatures independently recovered to the
selected account. Transaction/batch broadcast and public distribution remain unverified.

## Build and install locally

```sh
cd ChromeExtension
bun install --frozen-lockfile
cd ..
node ChromeExtension/build.mjs
swift build --product StupidWalletChromeHost
uv run --no-project python ChromeExtension/install-local.py --profile <private-macos-profile>
```

The profile must already authorize the existing production App Group, keychain group and available
Apple Development certificate. The installer validates those requirements and strictly verifies the
signature. It creates no Apple account resources, exports no credentials, and does not modify
stupid-app. The owner authorized direct codesign for this local installation only.

Load `.build/chrome-extension` in Google Chrome at `chrome://extensions`, enable Developer mode,
and choose Load unpacked. On updates, reload the extension and existing dapp tabs. Pin **stupid wallet**
to the toolbar. On Chrome 127+, a new review request from the active foreground dapp opens the toolbar
popup automatically. Older Chrome or a refused popup keeps the badge/manual toolbar flow. Background
tabs do not interrupt you. On first use, choose Manage Chrome pairing and compare the code in setup
with the native helper before confirming. Then choose the wallet from a dapp's picker, review the
toolbar request and complete macOS authentication; there is no second native review. Account management remains in the existing wallet app.

The helper lives at `~/Library/Application Support/StupidWalletChrome/StupidWalletChromeHost.app`;
Chrome's user-level NativeMessagingHosts registration points to its executable. The exact development
extension ID is `pnefobbcijpfceblkkcbfklpldfhmbof`, host name `net.stupidtech.stupid_wallet`. Keep the
unpacked directory present. This identity is not yet reserved in Chrome Web Store. Arc launch remains
unproven; acceptance uses Google Chrome and native Computer Use, per owner instruction.

Protocol 3 uses bounded 256-KiB frames, one worker-owned port and a persisted Chrome profile identity.
One-time pairing enrolls a separate non-exportable P-256 Web Crypto key stored in extension IndexedDB.
The helper retains only its public key in the entitled data-protection keychain. Pairing uses a fresh
comparison code and proof of possession, expires after two minutes and requires native confirmation.
Manage Chrome pairing also provides explicit native-confirmed unpairing; wallet keys and site grants
are retained. Clearing extension storage requires setup again.

Each approval submits the displayed canonical ID, revision and binding digest. The helper verifies a
signed, ten-second, one-use challenge bound to those fields and the Chrome profile before accessing
wallet keys. The worker checks the original document before/after creating the proof. Native verifies
the pairing still exists at challenge consumption. Navigation/closed tabs cancel protected operations;
port disconnects never replay approvals. Incognito is denied. Chrome inherits no Safari legacy grants.

Pairing protects against an unpaired caller imitating the native protocol. It does not protect against
malware controlling Chrome or stealing the browser credential: non-exportability is a browser API
restriction, not guaranteed hardware-backed storage. Fresh wallet authentication remains mandatory.
Use extension 0.0.6 with helper 0.0.4; protocol 2 is intentionally incompatible.

Chrome bundles pinned Zod 4.5.4 and esbuild 0.28.2; use the committed Bun lockfile. Zod validates privileged
transport envelopes. Shared browser resources remain framework-free and all private-key operations
remain native. The minimums are Chrome 111 and macOS 14.

## Acceptance

```sh
node --test Tests/JavaScript/*.test.mjs
swift test
mkdir -p .build/chrome-acceptance
ChromeExtension/node_modules/.bin/esbuild Tests/ChromeAcceptance/wallet.js --bundle --format=esm --outfile=.build/chrome-acceptance/wallet.js
cp Tests/ChromeAcceptance/wallet.html .build/chrome-acceptance/index.html
uv run --no-project python -m http.server 8766 --bind 127.0.0.1 --directory .build/chrome-acceptance
```

`Tests/ChromeAcceptance/wallet.html` and `wallet.js` provide the local integration fixture. Bundle
wallet.js with esbuild (it imports the prototype's viem for independent public-signature recovery),
serve it on loopback, and connect only with the owner's authorization. The fixture has no transfer or
token-approval actions. Never log user account addresses or signature payloads in public notes.
The earlier missing-host fixture and isolated storage/lifecycle diagnostics remain under `proofs/`.

Local installation is development-signed and depends on the profile/certificate remaining valid.
The GitHub beta uses Developer ID and notarization through the owner-authorized repository-local
packaging exception. See RELEASE-INSTALL.md for installation. The following contract remains the
intended future stupid-app integration; stupid-app is unchanged.

## Required stupid-app support

A native-host project configuration must explicitly declare the macOS executable product, minimum
OS, host name, exact extension origins, executable installation path, registration scope, signing
identity and entitlements. Keep this separate from the iOS app/extension bundle graph.

The pipeline must:

1. Build the declared macOS SwiftPM executable and validate Mach-O platform and deployment target.
2. Validate exact host-name grammar and extension IDs; generate an absolute-path stdio manifest.
3. Require the selected team's Developer ID Application identity, hardened runtime and secure
   timestamp. Reject missing identity or unprovisioned entitlements; never fall back to ad-hoc or
   Apple Development signing for the selected helper package.
4. Verify the signed artifact before registering it. For the initial proof use a deliberate
   user-level registration, and detect Arc's actual host lookup location empirically.
5. Extend doctor to check the host manifest, exact executable, signature, entitlements and protocol
   compatibility without opening protected wallet items.
6. Before release, implement signed/notarized package installation, atomic update/repair, receipt-
   scoped uninstall and independent host/extension version compatibility checks. Uninstall must
   leave wallet keys, App Group data and Safari installations untouched.

Production registration scope and the store-reserved extension identity remain owner/release
choices. A Developer ID Application identity and matching direct-distribution profile are now provisioned
for the beta release. Apple Development suffices for the isolated local
transport proof, but does not establish notarized distribution or production keychain access.


The Chrome toolbar uses a light arrow variant for dark browser themes; assets at 16/19/32/38 pixels
live in `ChromeExtension/icons`. General extension and Safari icons retain their existing design.

Chrome opens the toolbar review popup for new requests from the active tab in a focused window.
The Chrome build omits Safari’s in-page pending banner. If Chrome refuses automatic opening,
the pending badge and toolbar button remain available; request polling continues normally.

## Beta release commands

Build the optimized arm64 helper with `swift build -c release --product StupidWalletChromeHost`
and the extension with `node ChromeExtension/build.mjs`. Run
`uv run --no-project python ChromeExtension/package-release.py --profile <private-direct-profile> --identity <Developer-ID-SHA1>`.
The profile must authorize all Macs, the exact existing helper identity, shared App Group and
keychain group, and the selected Developer ID certificate; development profiles are rejected.

Submit `.release/chrome/helper-notarization.zip` with `xcrun notarytool submit`, using the existing
App Store Connect key via `--key`, `--key-id`, and `--issuer`. Keep submission responses private.
After Apple reports Accepted, run `uv run --no-project python ChromeExtension/finalize-release.py`.
This staples and validates the app, requires Gatekeeper acceptance, and creates the public helper
ZIP, extension ZIP, installation guide and SHA256SUMS. Upload only those four files. Never upload
the entire .release directory, staging metadata, credentials, or a development profile. The signed
app necessarily embeds its Apple-authorized direct-distribution profile.
