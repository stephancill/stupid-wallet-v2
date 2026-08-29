import Foundation
import LocalAuthentication
import Security

/// Protected BIP-39 entropy storage. One item exists per seed-backed wallet group.
public final class KeychainSeedStore: Sendable {
  public enum StorageError: Error, Equatable {
    case saveFailed(OSStatus = 0)
    case readFailed
    case notFound
    case deleteFailed
  }

  public let service: String
  public let accessGroup: String?

  public init(
    service: String = "co.za.stephancill.stupid-wallet.seeds",
    accessGroup: String? = KeychainKeyStore.defaultAccessGroup
  ) {
    self.service = service
    self.accessGroup = accessGroup
  }

  public func save(entropy: [UInt8], groupID: UUID) throws {
    var accessError: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .userPresence,
        &accessError)
    else {
      throw StorageError.saveFailed()
    }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.account(groupID),
      kSecAttrAccessControl as String: accessControl,
      kSecValueData as String: Data(entropy),
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw StorageError.saveFailed(status) }
  }

  public func load(
    groupID: UUID,
    reason: String = "Unlock your wallet to use this seed"
  ) throws -> [UInt8] {
    let context = LAContext()
    context.localizedReason = reason
    context.touchIDAuthenticationAllowableReuseDuration = 0
    defer { context.invalidate() }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.account(groupID),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      throw status == errSecItemNotFound ? StorageError.notFound : StorageError.readFailed
    }
    return [UInt8](data)
  }

  public func contains(groupID: UUID) -> Bool {
    let context = LAContext()
    context.interactionNotAllowed = true
    defer { context.invalidate() }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.account(groupID),
      kSecReturnData as String: false,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess || status == errSecInteractionNotAllowed
  }

  public func delete(groupID: UUID) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.account(groupID),
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StorageError.deleteFailed
    }
  }

  private static func account(_ groupID: UUID) -> String {
    groupID.uuidString.lowercased()
  }
}

protocol WalletSeedStoring: Sendable {
  func save(entropy: [UInt8], groupID: UUID) throws
  func load(groupID: UUID, reason: String) throws -> [UInt8]
  func contains(groupID: UUID) -> Bool
  func delete(groupID: UUID) throws
}

extension KeychainSeedStore: WalletSeedStoring {}
