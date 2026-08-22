# Project Agent Instructions

## Mandatory Context

Before planning, editing code, changing configuration, adding a dependency, running a
signing or release workflow, or making architectural recommendations:

1. Read this file completely.
2. Read `docs/engineering-handover.md` completely.
3. Read `docs/implementation-notes.md`, focusing on the latest entries and entries
   related to the task.
4. Inspect the current repository state, configured `stupid-app` version, relevant Apple
   SDK behavior, and tests rather than assuming the handover is perfectly current.
5. Inspect `../ios-wallet` when work concerns feature parity or persisted-format
   migration, but treat it as a reference rather than a design authority.

If code and documentation disagree, investigate the discrepancy. Do not silently choose
one. Correct the handover in the same work when implementation has legitimately
superseded it, or correct the implementation when it violates a locked decision.

When debugging any app, Safari extension, provider, approval, signing, persistence, RPC,
or transaction issue, read and follow `skills/stupid-wallet-debugging/SKILL.md`. Update
that skill in the same work whenever the investigation discovers a reusable debugging
tip, command, failure signature, stack boundary, or safety rule.

## Documentation Responsibilities

`docs/engineering-handover.md` is the maintained current source of truth. Update it when
work changes:

- Scope, feature priority, or acceptance criteria.
- Architecture, target ownership, or request/data-flow boundaries.
- Supported EIP-1193 methods, denied methods, passthrough policy, or error behavior.
- RPC resolution, chain behavior, network overrides, or connectivity assumptions.
- Authentication, keychain storage, signing, migration, origin binding, or approval
  behavior.
- Bundle identifiers, App Groups, entitlements, deployment targets, or supported project
  shapes.
- Dependencies, cryptographic provenance, compatibility, risks, open decisions, or
  recommended next work.
- Implementation-gate status.

`docs/implementation-notes.md` is the append-only chronological public engineering log.
Append a dated entry after meaningful implementation, investigation, verification,
migration, architectural, or release work. Record what changed, why, decisions,
verification and outcomes, failures, limitations, and follow-up work.

Before committing, inspect both documents and update them where necessary. Never defer a
required documentation update because the code is complete. Documentation-only planning
work should also receive an implementation-note entry when it establishes or changes the
project direction.

Implementation notes and handover text must be safe for public publication. Required
public product identifiers may be recorded when they are necessary for upgrade
compatibility, but never record personal information, wallet addresses tied to a person,
private keys, seed phrases, credentials, tokens, certificate contents, account or device
identifiers, private hostnames, sensitive signing payloads, or secret-bearing output.

Do not put timeline estimates in planning documents. Use ordered dependencies,
acceptance gates, and concrete exit conditions. If relative estimation is genuinely
useful, use points rather than days or weeks.

## Product Invariants

- Build, run, sign, and release through `stupid-app`; do not introduce an Xcode project
  as a second source of build truth.
- Preserve the existing production app, extension, App Group, and keychain identities
  exactly unless the project owner explicitly changes the upgrade strategy.
- Existing installed-wallet migration is a release requirement. Do not delete or replace
  old key material before a new-format authenticated sign-and-recover proof succeeds.
- Safari remains foregrounded during the primary dapp signing flow.
- The Safari toolbar popup is the primary review surface. A webpage-injected element may
  provide status or instructions but is never approval authority.
- Native Face ID or device-passcode authentication is required for every signature,
  transaction, or private-key export.
- A native signer accepts only a persisted, canonical, one-time pending request ID. It
  must not sign arbitrary params supplied in an approval message.
- Explicitly handle the wallet-owned method subset, explicitly deny reviewed unsafe
  signing methods, and pass every other JSON-RPC method unchanged to the active RPC.
- Default every chain to `https://evm.stupidtech.net/v1/{decimalChainId}`.
- Dapp-supplied RPC URLs never silently override user preferences.
- Prefer failing loudly over fallback behavior that weakens origin validation, chain
  validation, key protection, authentication, or signing correctness.
- Do not add compatibility behavior without an existing persisted format, shipped
  behavior, external consumer, or explicit requirement.
- Widgets and Live Activities are not signing authorization boundaries.

## Architecture Direction

- Keep the containing SwiftUI app, shared `WalletCore`, Safari native extension, and
  vendored secp256k1 target separate.
- Keep wallet policy, canonical request types, key access, Ethereum serialization, RPC
  resolution, and persistent stores in `WalletCore` rather than duplicating them in the
  app and extension.
- Keep JavaScript small and framework-free. It owns EIP-1193 compatibility, EIP-6963
  discovery, Safari messaging, popup rendering, and tab completion routing only.
- Derive origins and tab identity from Safari's extension sender context. Ignore origin
  metadata supplied by page JavaScript.
- Persist canonical pending requests natively in the App Group. Browser storage may keep
  only non-authoritative routing state needed to survive service-worker suspension.
- Use normalized origins, including scheme and effective port, for connected-site grants.
- Use one RPC resolver for app reads, previews, sending, polling, and generic passthrough.
- Preserve arbitrary JSON values, `null`, and structured JSON-RPC errors end to end.
- Keep one active signing confirmation at a time and queue additional requests until the
  handover records a different tested concurrency policy.

## Dependency Rules

- Prefer Apple system frameworks and small project-owned protocol implementations.
- Use a pinned, vendored upstream `libsecp256k1` C target for secp256k1 rather than
  writing novel elliptic-curve arithmetic.
- Record every vendored revision, build option, license, provenance, and local adaptation
  in implementation notes and repository notices.
- Do not add React, Vite, Tailwind, viem, Web3.swift, PromiseKit, BigInt, CryptoSwift,
  Dawn Key Management, or a general wallet SDK without a concrete reviewed need.
- Do not retain an old dependency solely for migration when the persisted format can be
  read safely through system APIs.
- Do not place private-key operations in JavaScript or WebAssembly.

## Security Rules

- Never commit `.env.local`, wallet secrets, seed phrases, private keys, signing
  credentials, provisioning profiles, authentication artifacts, or secret-bearing test
  fixtures.
- Never log decrypted key material, raw LocalAuthentication output, complete sensitive
  signing payloads, or user-linked wallet activity.
- Store new wallet key material with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and a user-presence access control in the
  shared keychain group.
- Use a fresh `LAContext` for every protected operation, disable authentication reuse,
  and invalidate the context afterward.
- Never preflight authentication or cache an unlocked key.
- Keep plaintext key bytes in the narrowest possible scope and overwrite mutable buffers
  where practical.
- Bind approvals to request ID, origin, Safari profile when available, chain, method,
  canonical payload digest, expiry, and unconsumed state.
- Reject replay, payload mutation, origin changes, tab navigation, expired requests, and
  duplicate completion.
- Validate custom RPC endpoints with `eth_chainId` before saving them.
- Treat App Group pending records, activity data, and connected-site grants as sensitive
  user data even though they are not private keys.

## Engineering Style

- Make the smallest correct change.
- Prefer explicit value types and data flow over hidden global state.
- Prefer named parameters and typed configuration.
- Keep one function until a boundary is reusable or materially improves auditability or
  testability.
- Avoid speculative abstractions and compatibility layers.
- Add comments only when a security reason or non-obvious invariant needs explanation.
- Keep errors actionable and distinguish page/provider errors, node JSON-RPC errors,
  transport failures, authentication cancellation, and signing failures.
- Use Swift concurrency deliberately; do not bridge async work with blocking semaphores.
- Avoid force unwraps, `try!`, and lossy `[String: Any]` casting in request or signing
  paths.

## Swift And JavaScript Conventions

- Use Swift 6 language checking compatible with the repository's SwiftPM manifest.
- Use value types and actor isolation for mutable stores and request coordination.
- Keep security-critical APIs internal by default and expose the narrowest operation.
- Format Swift with the repository's configured formatter. If none exists when
  substantial Swift work starts, establish `swift format` and record it in the handover.
- Run configured Swift linting after Swift changes when available.
- Keep JavaScript dependency-free unless the handover records an approved exception.
- Use modern standards-based JavaScript supported by the minimum Safari version; avoid a
  build step unless a concrete language-compatibility need requires one.
- Validate JavaScript message envelopes explicitly. Never spread untrusted page objects
  into privileged messages.
- If JavaScript tooling is added, use the repository-selected package manager and run its
  formatter and linter after modifications.

## Testing And Verification

- Every reproducible bug fix includes a regression test when deterministic coverage is
  possible.
- Unit-test JSON values, method classification, origin normalization, state transitions,
  RPC errors, migration behavior, and Ethereum vectors without credentials.
- Cross-check cryptographic and transaction vectors against independent implementations.
- Keep credentialed, Safari lifecycle, and physical-device tests separate from ordinary
  unit tests.
- Always reinstall and launch on the preferred iOS simulator after changing iOS app code.
- Prove Safari popup and LocalAuthentication behavior on a physical device before
  claiming the signing flow works while Safari remains foregrounded.
- Prove migration by upgrading a real old-version installation; a synthetic keychain
  fixture is not sufficient.
- Run `stupid-app doctor` when project configuration, entitlements, extension packaging,
  signing, or device behavior changes.
- Build through `stupid-app build` after Swift, resource, package, plist, entitlement, or
  project-config changes.
- Record exact public-safe verification commands and outcomes in implementation notes.
- Do not claim signing success based only on serialization, a local signature, or bundle
  structure. Verify recovered signer and, for transactions, accepted network behavior.

## External References

- `../ios-wallet` is the existing feature and persisted-format reference.
- `../stupid-ios-dev` is the source of truth for `stupid-app` behavior and extension
  packaging.
- Apple documentation and EIPs are protocol references, but current SDK interfaces and
  runtime behavior must be verified.
- When copying or adapting source, preserve license requirements and record provenance in
  implementation notes and repository notices.
