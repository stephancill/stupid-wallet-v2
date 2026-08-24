# Stupid Wallet v2

An experimental, auditable Ethereum wallet for iOS with a Safari Web Extension.

Stupid Wallet injects an EIP-1193 provider into Safari, keeps request review inside the
Safari-owned extension popup, and requires native Face ID or device-passcode authentication
for every signature and transaction.

> [!WARNING]
> This project is under active development and has not been independently audited. Do not use
> it with keys or funds you cannot afford to lose.

## Features

- Create one Ethereum account or import a private key or BIP-39 seed phrase.
- Migrate an account from the previous iOS app's persisted format.
- Inject EIP-1193 and EIP-6963 wallet providers into Safari.
- Connect and disconnect sites with origin- and Safari-profile-aware grants.
- Sign `personal_sign` messages and EIP-712 typed data.
- Prepare, sign, and broadcast legacy and EIP-1559 transactions.
- Review canonical request details in the Safari toolbar popup.
- Switch authorized networks and add network metadata without accepting dapp RPC overrides.
- Route unhandled JSON-RPC methods unchanged through the active RPC endpoint.
- Track transaction and redacted signature activity in SQLite.
- Aggregate native balances across included networks.

The default RPC endpoint for chain `N` is:

```text
https://evm.stupidtech.net/v1/N
```

Users can configure a per-chain HTTPS override after the endpoint proves its chain ID.

## Security Model

- The webpage is never an approval authority.
- Pending requests are canonicalized and persisted natively in the shared App Group.
- Approval messages contain only a one-time request ID and decision, never replacement params.
- Approvals bind the request ID, origin, Safari profile when available, chain, method, payload
  digest, expiry, and unconsumed state.
- Private keys are stored in the shared keychain with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and user-presence access control.
- Every signature, transaction, and private-key export uses a fresh `LAContext` with no
  authentication reuse.
- Ethereum signing uses pinned, vendored `libsecp256k1`; private-key operations never run in
  JavaScript or WebAssembly.

See [docs/engineering-handover.md](docs/engineering-handover.md) for the complete architecture,
security invariants, implementation status, and open work.

## Architecture

```text
Sources/
  StupidWallet/         SwiftUI containing app
  StupidWalletCore/     policy, persistence, RPC, Ethereum encoding, and signing
  StupidWalletSafari/   native Safari extension message handler
  CSecp256k1/           SwiftPM C bridge to vendored libsecp256k1

SafariExtension/
  Resources/            provider, bridge, worker, and popup HTML/CSS/JavaScript

PrototypeDapp/          wagmi/viem integration fixture
Tests/                  hermetic core and transaction regressions
```

The app and extension are SwiftPM products. [`stupid-app.yml`](stupid-app.yml) is the source of
truth for iOS assembly, bundle identities, entitlements, and extension resources; the project
does not use an Xcode project.

## Requirements

- macOS with Xcode and an iOS 17 or newer simulator, or a configured physical iOS device.
- Swift 6.2-compatible toolchain.
- [`stupid-app`](https://github.com/stephancill/stupid-app-cli) for iOS builds and deployment.
- Bun for the optional prototype dapp.

Physical-device installation additionally requires an Apple development identity and matching
provisioning profiles for the app and Safari extension.

## Build And Test

Run the hermetic Swift test suite:

```bash
swift test
```

Validate the host, credentials, and project configuration:

```bash
stupid-app doctor
```

Build the iOS app and bundled Safari extension:

```bash
stupid-app build
```

Install and launch on a simulator:

```bash
stupid-app simulators
stupid-app run --simulator --udid <simulator-udid>
```

Install and launch locally on Apple Silicon Mac as an iPhone/iPad compatibility app:

```bash
stupid-app signing setup --kind development --udid <mac-provisioning-udid>
stupid-app run --mac
```

After installation, enable Stupid Wallet under Safari's extension settings.

## Prototype Dapp

The integration fixture exercises connection, message signing, typed-data signing,
transactions, network switching, and disconnect behavior.

```bash
cd PrototypeDapp
bun install
bun run dev --host 0.0.0.0
```

Open the displayed URL in simulator or device Safari, connect Stupid Wallet, and use Safari's
Page Menu to open the extension popup when a request is pending.

## Project Documentation

- [Engineering handover](docs/engineering-handover.md): maintained architecture and current
  implementation status.
- [Implementation notes](docs/implementation-notes.md): chronological engineering log.
- [Debugging workflow](skills/stupid-wallet-debugging/SKILL.md): end-to-end Safari, native,
  persistence, signing, and RPC diagnosis.
- [Third-party notices](THIRD_PARTY_NOTICES.md): vendored source provenance and licenses.

## Current Scope

The secure wallet core is implemented and exercised on the simulator, with key migration and
authentication boundaries also proven on a physical device. The iOS compatibility app now runs
locally on Apple Silicon Mac and registers its Safari extension; the complete Mac Safari request
and signing flow still requires verification. Deferred work includes transaction simulation,
ABI/calldata decoding, richer clear-signing previews, and ENS/avatar resolution.
