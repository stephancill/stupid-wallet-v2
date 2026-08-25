import Foundation
import LocalAuthentication
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
    case saveFailed(OSStatus = 0)
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
      throw StorageError.saveFailed()
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
    guard status == errSecSuccess else { throw StorageError.saveFailed(status) }
  }

  /// Reads and auto-decrypts the key with a fresh, authenticated `LAContext` bound to the
  /// read. Release the returned bytes promptly. Yes, presents the device-owner Face ID /
  /// passcode prompt once per call.
  public func load(
    account: String,
    reason: String = "Unlock your wallet to sign"
  ) throws -> [UInt8] {
    let context = LAContext()
    context.localizedReason = reason
    context.touchIDAuthenticationAllowableReuseDuration = 0
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    context.invalidate()
    guard status == errSecSuccess, let data = item as? Data else {
      throw storageError(status)
    }
    let key = [UInt8](data)
    return key
  }

  /// Whether a key exists for `account` without attempting to release its bytes. This is
  /// an existence probe only: it does not present the device-owner prompt, unlike
  /// `load`, so it is safe to call ahead of an approval.
  public func contains(account: String) -> Bool {
    let context = LAContext()
    context.interactionNotAllowed = true
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: false,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    context.invalidate()
    return Self.existenceStatusIndicatesPresent(status)
  }

  static func existenceStatusIndicatesPresent(_ status: OSStatus) -> Bool {
    status == errSecSuccess || status == errSecInteractionNotAllowed
  }

  /// All accounts that have a key stored under this service and access group.
  /// Used to discover the active wallet's signing key for its insecure-against-each-key
  /// exclusive read path when no registry entry exists yet.
  public func accounts() -> [String] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  public func delete(account: String) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StorageError.deleteFailed
    }
  }

  private func storageError(_ status: OSStatus) -> StorageError {
    status == errSecItemNotFound ? .notFound : .readFailed
  }
}

protocol WalletKeyStoring {
  func save(key: [UInt8], account: String) throws
  func load(account: String, reason: String) throws -> [UInt8]
  func delete(account: String) throws
}

extension KeychainKeyStore: WalletKeyStoring {}
