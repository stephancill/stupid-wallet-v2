import Foundation
import LocalAuthentication
import Security

let context = LAContext()
context.interactionNotAllowed = true
context.touchIDAuthenticationAllowableReuseDuration = 0
defer { context.invalidate() }
// A deliberately nonexistent account tests entitlement enforcement without enumerating
// wallet items, requesting attributes/data, or presenting authentication.
let query: [String: Any] = [
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: "net.stupidtech.stupid_wallet.storage-proof",
  kSecAttrAccount as String: UUID().uuidString,
  kSecAttrAccessGroup as String: "6JKMV57Y77.co.za.stephancill.stupid-wallet",
  kSecUseDataProtectionKeychain as String: true,
  kSecUseAuthenticationContext as String: context,
  kSecReturnData as String: false,
  kSecReturnAttributes as String: false,
  kSecMatchLimit as String: kSecMatchLimitOne,
]
let status = SecItemCopyMatching(query as CFDictionary, nil)
print("dataProtectionKeychainStatus=\(status)")
print("missingEntitlement=\(status == errSecMissingEntitlement)")
print("itemNotFound=\(status == errSecItemNotFound)")

// The negative control must reach the intended protection domain before any wallet
// metadata is considered. Never fall back to the login keychain or a filesystem path.
if status == errSecItemNotFound {
  struct Registry: Decodable {
    struct Group: Decodable {
      struct Account: Decodable { let address: String }
      let id: UUID
      let kind: String
      let lifecycle: String
      let accounts: [Account]
    }
    let schemaVersion: Int
    let adoptionState: String
    let groups: [Group]
  }

  if let container = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.co.za.stephancill.stupid-wallet")
  {
    print("appGroupResolved=true")
    var coordinationError: NSError?
    var registry: Registry?
    NSFileCoordinator().coordinate(
      readingItemAt: container.appendingPathComponent("wallet-registry.json"),
      options: [], error: &coordinationError
    ) { url in
      registry = try? JSONDecoder().decode(Registry.self, from: Data(contentsOf: url))
    }
    print("registryReadSucceeded=\(coordinationError == nil && registry != nil)")
    if let registry, registry.schemaVersion == 2, registry.adoptionState == "complete" {
      let active = registry.groups.filter { $0.lifecycle == "active" }
      var allPresent = !active.isEmpty
      for group in active {
        let account: String
        let service: String
        switch group.kind {
        case "seed":
          account = group.id.uuidString.lowercased()
          service = "co.za.stephancill.stupid-wallet.seeds"
        case "privateKey":
          guard group.accounts.count == 1, let first = group.accounts.first else {
            allPresent = false
            continue
          }
          account = first.address
          service = "co.za.stephancill.stupid-wallet.keys"
        default:
          allPresent = false
          continue
        }
        let itemContext = LAContext()
        itemContext.interactionNotAllowed = true
        itemContext.touchIDAuthenticationAllowableReuseDuration = 0
        var exactQuery = query
        exactQuery[kSecAttrService as String] = service
        exactQuery[kSecAttrAccount as String] = account
        exactQuery[kSecUseAuthenticationContext as String] = itemContext
        let itemStatus = SecItemCopyMatching(exactQuery as CFDictionary, nil)
        itemContext.invalidate()
        allPresent =
          allPresent && (itemStatus == errSecSuccess || itemStatus == errSecInteractionNotAllowed)
      }
      print("registeredProtectedSourcesPresent=\(allPresent)")
    }
  } else {
    print("appGroupResolved=false")
  }
}
