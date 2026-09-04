import CryptoKit
import Foundation
import Security

public enum NotificationInstallationKeyStoreError: Error, Sendable {
  case unavailable(OSStatus)
  case corrupt
}

public struct NotificationInstallationIdentity: Sendable, Equatable {
  public let privateKey: Data
  public var installationID: String?

  public init(privateKey: Data, installationID: String? = nil) {
    self.privateKey = privateKey
    self.installationID = installationID
  }

  public var publicKeySPKIBase64URL: String? {
    guard let key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else { return nil }
    return NotificationBase64URL.encode(key.publicKey.derRepresentation)
  }

  public func sign(_ message: Data) throws -> String {
    let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
    return NotificationBase64URL.encode(try key.signature(for: message).rawRepresentation)
  }
}

/// App-only, non-synchronizing installation identity. Unlike wallet keys this has no
/// user-presence ACL and can never produce an Ethereum signature.
public struct NotificationInstallationKeyStore: Sendable {
  public static let productionAppOnlyAccessGroup =
    "6JKMV57Y77.co.za.stephancill.stupid-wallet.safari"

  public static var defaultAccessGroup: String? {
    #if os(macOS) || targetEnvironment(simulator)
      nil
    #else
      productionAppOnlyAccessGroup
    #endif
  }

  private let service: String
  private let accessGroup: String?

  public init(
    service: String = "co.za.stephancill.stupid-wallet.notifications.installation",
    accessGroup: String? = Self.defaultAccessGroup
  ) {
    self.service = service
    self.accessGroup = accessGroup
  }

  public func loadOrCreate() throws -> NotificationInstallationIdentity {
    if let data = try read(account: "identity") { return try decode(data) }
    let identity = NotificationInstallationIdentity(
      privateKey: P256.Signing.PrivateKey().rawRepresentation)
    try write(try encode(identity), account: "identity", addOnly: true)
    return identity
  }

  public func saveInstallationID(_ installationID: String) throws {
    var identity = try loadOrCreate()
    identity.installationID = installationID
    try write(try encode(identity), account: "identity", addOnly: false)
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery(account: "identity") as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NotificationInstallationKeyStoreError.unavailable(status)
    }
  }

  private func read(account: String) throws -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw NotificationInstallationKeyStoreError.unavailable(status)
    }
    return data
  }

  private func write(_ data: Data, account: String, addOnly: Bool) throws {
    var query = baseQuery(account: account)
    if !addOnly {
      let status = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if status == errSecSuccess { return }
      guard status == errSecItemNotFound else {
        throw NotificationInstallationKeyStoreError.unavailable(status)
      }
    }
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NotificationInstallationKeyStoreError.unavailable(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    return query
  }

  private func encode(_ identity: NotificationInstallationIdentity) throws -> Data {
    try JSONEncoder().encode([
      "privateKey": NotificationBase64URL.encode(identity.privateKey),
      "installationID": identity.installationID ?? "",
    ])
  }

  private func decode(_ data: Data) throws -> NotificationInstallationIdentity {
    guard
      let object = try? JSONDecoder().decode([String: String].self, from: data),
      let encoded = object["privateKey"],
      let privateKey = NotificationBase64URL.decode(encoded),
      (try? P256.Signing.PrivateKey(rawRepresentation: privateKey)) != nil
    else { throw NotificationInstallationKeyStoreError.corrupt }
    let installationID = object["installationID"].flatMap { $0.isEmpty ? nil : $0 }
    return NotificationInstallationIdentity(privateKey: privateKey, installationID: installationID)
  }
}
