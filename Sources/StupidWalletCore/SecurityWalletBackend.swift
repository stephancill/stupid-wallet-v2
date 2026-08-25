import Foundation
import Security

/// Production `OldWalletBackend` over the old app's persisted format:
/// - address in App Group defaults under `"walletAddress"`
/// - ECIES ciphertext in a generic-password keychain item keyed by the address
/// - a Secure Enclave P-256 key tagged by the address, used with
///   `.eciesEncryptionCofactorVariableIVX963SHA256AESGCM` decryption (which presents the
///   device-owner prompt automatically).
public struct SecurityWalletBackend: OldWalletBackend {
  private let appGroup: String
  private let keyStore: KeychainKeyStore

  public init(
    appGroup: String = "group.co.za.stephancill.stupid-wallet",
    newKeychainService: String = "co.za.stephancill.stupid-wallet.keys"
  ) {
    self.appGroup = appGroup
    self.keyStore = KeychainKeyStore(service: newKeychainService)
  }

  private func defaults() -> UserDefaults {
    UserDefaults(suiteName: appGroup) ?? .standard
  }

  public func oldAddress() -> String? { defaults().string(forKey: constants.oldAddressKey) }

  public func hasNewWallet() -> Bool {
    (try? WalletRegistryStore(appGroup: appGroup).load()) != nil
  }

  public func isMigrated() -> Bool {
    defaults().bool(forKey: constants.migratedKey)
  }

  public func ciphertext(for address: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: address,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  public func decryptCiphertext(_ ciphertext: Data, for address: String) throws -> [UInt8] {
    guard let secret = secureEnclaveKey(for: address) else {
      throw WalletMigrationFailure.malformedCiphertext
    }
    var error: Unmanaged<CFError>?
    guard
      let plain = SecKeyCreateDecryptedData(
        secret, .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
        ciphertext as CFData, &error
      ) as Data?
    else {
      throw Self.mapDecryptError(error?.takeRetainedValue())
    }
    return [UInt8](plain)
  }

  public func saveKey(_ key: [UInt8], account: String) throws {
    do { try keyStore.save(key: key, account: account) } catch {
      throw WalletMigrationFailure.saveFailed
    }
  }

  public func loadKey(account: String) throws -> [UInt8] {
    do { return try keyStore.load(account: account) } catch {
      throw WalletMigrationFailure.selfTestFailed
    }
  }

  public func markPending(account: String) {
    defaults().set(account, forKey: constants.pendingKey)
  }

  public func markMigrated(address: String) {
    defaults().set(true, forKey: constants.migratedKey)
    defaults().removeObject(forKey: constants.pendingKey)
  }

  public func clearPending() { defaults().removeObject(forKey: constants.pendingKey) }

  public func cleanupOldMaterial(address: String) {
    deleteGenericPassword(address)
    deleteSecureEnclaveKey(address)
  }

  /// Explicit account forgetting is the point at which retained, already-migrated legacy
  /// material may be removed. Clearing the old address also prevents automatic re-migration
  /// on the next app launch.
  public func forgetMigrationMaterial(address: String) {
    if oldAddress()?.caseInsensitiveCompare(address) == .orderedSame {
      cleanupOldMaterial(address: address)
      defaults().removeObject(forKey: constants.oldAddressKey)
    }
    defaults().removeObject(forKey: constants.rebuildWalletKey)
    defaults().removeObject(forKey: constants.rebuildMigratedKey)
    defaults().removeObject(forKey: constants.rebuildPendingKey)
    defaults().removeObject(forKey: constants.migratedKey)
    defaults().removeObject(forKey: constants.pendingKey)
  }

  // MARK: - Old-format specific reads

  private func secureEnclaveKey(for address: String) -> SecKey? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
      kSecAttrApplicationTag as String: address.data(using: .utf8)!,
      kSecReturnRef as String: true,
    ]
    var raw: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess else { return nil }
    return raw as! SecKey?
  }

  private func deleteGenericPassword(_ address: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: address,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func deleteSecureEnclaveKey(_ address: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: address.data(using: .utf8)!,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private static func mapDecryptError(_ failure: CFError?) -> WalletMigrationFailure {
    guard let failure else { return .malformedCiphertext }
    let code = CFErrorGetCode(failure)
    if code == -128 /* userCanceled */ || code == -25293 /* authFailed */
      || code == -12808 /* interactionNotAllowed */
    {
      return .cancelled
    }
    return .malformedCiphertext
  }

  private let constants = BackendConstants()

  private struct BackendConstants {
    let oldAddressKey = "walletAddress"
    let rebuildWalletKey = WalletFactory.walletAddressKey
    let rebuildMigratedKey = "sw2.authenticatedMigration"
    let rebuildPendingKey = "sw2.authenticatedMigration.pending"
    let migratedKey = "sw3.dawnAuthenticatedMigration"
    let pendingKey = "sw3.dawnAuthenticatedMigration.pending"
  }
}
