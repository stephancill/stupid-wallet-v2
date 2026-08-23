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
5. Preserve unrelated worktree changes. Never edit App Group records to force progress.
6. If the simulator skill's live `log_monitor.py` does not terminate at its requested
   duration, stop it rather than waiting indefinitely. Continue with bounded `simctl`,
   App Group inspection, and RPC checks; a log-stream helper hang is not evidence that the
   app hung.

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

### 2. Locate The Boundary

Use these observations:

- No new pending record: failure is in the dapp, provider routing, passthrough RPC, native
  envelope parsing, transaction preparation, or typed-data preparation.
- Pending record with `pending`: popup or approval has not completed.
- `failed`: inspect its structured `error`; signing/serialization/broadcast failed.
- `rejected` or `expired`: do not reuse it; reproduce a fresh request normally.
- `consumed`: inspect `result`, then verify the signature or transaction independently.

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

### 3. Inspect JavaScript Envelopes

- `bridge.js` expects `{ __envelope: true, ok, result|pendingId|error }`.
- Preserve structured errors as `{ code, message, data? }` through every layer.
- In the popup, never render an object with `String(error)`; read `error.message` and retain
  the code/data for diagnosis.
- Remove all temporary alerts/logging before the final build. Never log complete signing
  payloads or user-linked activity.
- Safari caches MV3 workers aggressively. Bump `manifest.json` after extension JavaScript
  changes so the simulator loads the corrected worker, then reinstall through `stupid-app`.

### 4. Inspect Popup And Queue Behavior

- Open Safari Page Menu, choose **Stupid Wallet**, and read the card with OCR.
- In the iOS 26 compact bottom toolbar, Page Menu is the rectangle-over-lines control to the
  left of the address. The ellipsis opens tab actions and does not expose extensions.
- Long transaction cards may need a swipe beginning inside the popup:

```bash
idb ui swipe 200 800 200 500 --duration 0.5 --udid <udid>
```

- One dapp action may produce multiple sequential requests. A token-to-native Uniswap swap
  can include an ERC-20 allowance transaction, Permit2 typed-data signature, then swap.
  Diagnose each canonical record separately.
- Only the oldest pending request is approvable. Never reorder or mutate persisted files.

### 5. Inspect Native Preparation And Signing

- For `eth_sendTransaction`, compare the canonical record against supported fields, active
  account, chain, nonce, gas, fee model, value, destination, and calldata.
- For `eth_signTypedData_v4`, decode standard `[address, jsonString]` params and test the
  exact EIP-712 digest independently. Avoid host `Int` for `uintN`; EIP-712 permits full
  256-bit values and must enforce the declared width.
- Authentication cancellation and invalid signing parameters are different failures. A
  fresh `.userPresence` keychain read should happen exactly once for each signature.
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
- Do not retry state-changing RPC methods casually. Same-endpoint retries for reads require
  a concrete failure and regression coverage.

### 7. Verify Cryptography And Transactions

- Pin deterministic vectors in Swift tests and cross-check with viem or Foundry.
- For EIP-712, compare `EIP712.prefixedHash` with viem `hashTypedData`.
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
