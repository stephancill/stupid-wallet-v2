import Foundation
import Security

/// Creates a brand-new wallet in the new format so a fresh install has a key for the
/// extension's `KeychainSigner` to resolve. The private key goes in the shared keychain
/// (`.userPresence`) keyed by the EIP-55 address; the address is recorded (non-secret) in
/// the shared App Group container via `WalletStore` so both the app and the Safari
/// extension read/write the same value across processes.
public enum WalletFactory {
  public enum CreateError: Error, Sendable {
    case randomFailure
    case saveFailed
  }

  @discardableResult
  public static func create(
    appGroup: String = PendingRequestStore.defaultAppGroup,
    keychainService: String = "co.za.stephancill.stupid-wallet.keys"
  ) throws -> String {
    var secret = try Self.randomSecret()
    defer {
      for index in secret.indices { secret[index] = 0 }
    }
    let pair = try EthereumKeypair.from(secret: secret)

    let store = KeychainKeyStore(service: keychainService)
    do {
      try store.save(key: secret, account: pair.address)
    } catch {
      throw Self.CreateError.saveFailed
    }
    WalletStore.setAddress(pair.address, appGroup: appGroup)
    return pair.address
  }

  /// The active new-format wallet address, or `nil` when none has been created or migrated.
  public static func activeAddress(
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) -> String? {
    WalletStore.activeAddress(appGroup: appGroup)
  }

  /// Legacy source-key read by callers that still use `UserDefaults(suiteName:)`. Prefer
  /// `activeAddress(appGroup:)` which reads the shared App Group file. Kept so migration
  /// can fall back to the previously-written `UserDefaults` value.
  public static func activeAddressFromUserDefaults(
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) -> String? {
    UserDefaults(suiteName: appGroup)?.string(forKey: Self.walletAddressKey)
  }

  public static let walletAddressKey = "sw2.walletAddress"

  private static func randomSecret() throws -> [UInt8] {
    for _ in 0..<8 {
      var bytes = [UInt8](repeating: 0, count: 32)
      let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      if status == errSecSuccess, (try? EthereumKeypair.from(secret: bytes)) != nil {
        return bytes
      }
    }
    throw CreateError.randomFailure
  }
}
