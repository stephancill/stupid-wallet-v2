import Foundation
import Security

/// Shared secure storage for new-format wallet key material.
///
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// - a `SecAccessControl` `.userPresence` policy, so release and signing require the
///   device owner (Face ID / passcode) for every operation
/// - a fresh `LAContext` on each call (callers own the context then invalidate it)
/// - overwritten buffers, never cached plaintext
///
/// The concrete keychain access group is supplied at runtime so the app and its Safari
/// extension resolve the same team-prefixed group; physical-device access-group
/// continuity is proven in the device gates.
public final class KeychainKeyStore: Sendable {
  public enum StorageError: Error, Equatable {
    case saveFailed
    case readFailed
    case notFound
    case deleteFailed
  }

  public let service: String
  public let accessGroup: String?

  public init(service: String = "co.za.stephancill.stupid-wallet.keys", accessGroup: String? = nil)
  {
    self.service = service
    self.accessGroup = accessGroup
  }

  /// Saves a new key for `account`. The access-control policy is not revocable later.
  public func save(key: [UInt8], account: String) throws {
    var accessError: Unmanaged<CFError>?
    let accessControl = SecAccessControlCreateWithFlags(
      kCFAllocatorDefault,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      .userPresence,
      &accessError
    )
    guard accessControl != nil else {
      throw StorageError.saveFailed
    }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessControl as String: accessControl!,
      kSecValueData as String: Data(key),
    ]
    query[kSecAttrAccessGroup as String] = accessGroup

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw StorageError.saveFailed }
  }

  /// Reads and auto-decrypts the key. Callers must present a fresh, valid authenticated
  /// `LAContext` (or follow Security framework callback authentication) and release the
  /// returned bytes promptly.
  public func load(account: String) throws -> [UInt8] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      throw storageError(status)
    }
    let key = [UInt8](data)
    return key
  }

  public func delete(account: String) {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    SecItemDelete(query as CFDictionary)
  }

  private func storageError(_ status: OSStatus) -> StorageError {
    status == errSecItemNotFound ? .notFound : .readFailed
  }
}
