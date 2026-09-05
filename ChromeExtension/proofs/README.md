# Shared-storage access probe

`storage-access.swift` is an opt-in physical-Mac diagnostic, separate from the Chrome host and ordinary
unit tests. It requests no key bytes or keychain attributes, performs no keychain writes, and never
initializes wallet stores or adoption. Its stdout contains only status codes and booleans, not native
messaging frames: do not register it as a Chrome host.

The first query uses a random nonexistent account in the exact production access group and explicitly
selects `kSecUseDataProtectionKeychain`. Only `errSecItemNotFound` allows the subsequent App Group
lookup. The probe then reads the existing registry through `NSFileCoordinator` and checks each active
source with an exact, noninteractive keychain query. It prints no addresses, group IDs, labels, or
container paths. A successful probe establishes metadata/existence access, not decrypted key access,
full registry validation, concurrent-write safety, or authentication correctness.

Compile locally under the owner-authorized proof exception:

```sh
mkdir -p .build/chrome-storage-proof
xcrun swiftc -swift-version 6 \
  -module-cache-path .build/chrome-storage-proof/module-cache \
  ChromeExtension/proofs/storage-access.swift -o .build/chrome-storage-proof/probe
```

For the negative control, sign with the existing Apple Development identity without shared
entitlements. On the tested Mac this returned `-34018` (`errSecMissingEntitlement`).

For the entitled test, place the executable at `StorageAccessProof.app/Contents/MacOS/StorageAccessProof`,
add an Info.plist with the application identifier authorized by the matching **macOS** development
profile, and embed that profile at `Contents/embedded.provisionprofile`. Sign the bundle with its
matching certificate and only the authorized application identifier, team, production App Group,
and exact production keychain group. Keep resolved entitlements and profiles private and untracked.
Do not reuse an iOS profile, invent entitlements, or change the installed wallet identity.

Verify with `codesign --verify --strict <proof-bundle>`, then directly execute the bundled binary
in the logged-in user's context. On 2026-09-05 the existing profile retrieved from the Apple account
matched the available certificate and shared group. The provisioned probe returned:

```text
dataProtectionKeychainStatus=-25300
missingEntitlement=false
itemNotFound=true
appGroupResolved=true
registryReadSucceeded=true
registeredProtectedSourcesPresent=true
```

Exit status was zero and stderr was empty. No authentication or wallet mutation occurred. The
registered Chrome transport helper is still the earlier proof executable with wallet access disabled.

Apple's [Mac keychain technical note](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
explains the data-protection selector and profile requirement. Its
[restricted-entitlement packaging guidance](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
describes the minimal bundle needed to embed a profile. This helper bundle does not imply a second
wallet UI or a system daemon; data-protection keychain access requires the user's login context.

## Lifecycle checkpoint host

`LifecycleHost/main.swift` builds as `StupidWalletChromeProofHost`. It reuses the bounded native
protocol, but creates no wallet service and has no keychain operations. Only `list` writes a synthetic
checkpoint under the resolved App Group's `chrome-lifecycle-proof-v1/` directory; all other wallet
operations remain disabled. A stable `NSFileCoordinator` claim serializes read/modify/atomic-replace
commits. Duplicate operation IDs recover their original revision only for the same profile. Corrupt
state fails closed. Records are capped at 1,000. Do not ship this diagnostic as wallet behavior.

```sh
swift build --product StupidWalletChromeProofHost
python3 ChromeExtension/proofs/test-lifecycle.py .build/debug/StupidWalletChromeProofHost
```

The subprocess test uses a disposable directory. On 2026-09-05 it retained all 40 concurrent commits,
recovered after SIGKILL before and after commit, rejected profile rebinding, and refused corrupt state.
It needs access to the system file-coordination service; execution inside a restrictive tool sandbox
failed, while normal user-context execution passed.

The signed, provisioned bundle was temporarily registered in Chrome with only its App Group claims
and no explicit keychain-access-groups entitlement. Native Computer Use observed checkpoint 1 on
first popup open, 2 after dismissal/reopening, 3 after killing the exact helper process, and 4 after
`chrome://restart`. The original transport helper registration was restored and the extension reloaded
afterward. Synthetic checkpoint files remain in the dedicated proof directory; no production wallet
record was edited.

This proves process-crash checkpoint persistence, not power-loss durability, an in-flight signing
runner, natural worker suspension, or concurrent writes by the installed app and Safari extension.
