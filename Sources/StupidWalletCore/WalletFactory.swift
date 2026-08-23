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
    case invalidPrivateKey
    case walletAlreadyExists
    case saveFailed
    case verificationFailed
    case registrationFailed
  }

  public enum ForgetError: Error, Sendable {
    case accountMismatch
    case deletionFailed
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
    return try provision(secret: secret, appGroup: appGroup, keychainService: keychainService)
  }

  @discardableResult
  public static func importPrivateKey(
    _ privateKey: String,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    keychainService: String = "co.za.stephancill.stupid-wallet.keys"
  ) throws -> String {
    guard var secret = Hex.data(privateKey), secret.count == 32 else {
      throw CreateError.invalidPrivateKey
    }
    defer {
      for index in secret.indices { secret[index] = 0 }
    }
    return try provision(secret: secret, appGroup: appGroup, keychainService: keychainService)
  }

  @discardableResult
  public static func importSeedPhrase(
    _ mnemonic: String,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    keychainService: String = "co.za.stephancill.stupid-wallet.keys"
  ) throws -> String {
    var secret = try EthereumSeedPhrase.privateKey(mnemonic: mnemonic)
    defer {
      for index in secret.indices { secret[index] = 0 }
    }
    return try provision(secret: secret, appGroup: appGroup, keychainService: keychainService)
  }

  public static func exportPrivateKey(
    account: String,
    keychainService: String = "co.za.stephancill.stupid-wallet.keys"
  ) throws -> String {
    var secret = try KeychainKeyStore(service: keychainService).load(
      account: account,
      reason: "Unlock your wallet to reveal your private key"
    )
    defer {
      for index in secret.indices { secret[index] = 0 }
    }
    guard secret.count == 32, (try? EthereumKeypair.from(secret: secret)) != nil else {
      throw CreateError.invalidPrivateKey
    }
    return "0x" + Hex.encode(secret)
  }

  /// Removes the active new-format signing key and its shared registration. If keychain
  /// deletion fails, the registration is restored so the app does not silently present a
  /// wallet whose key was never forgotten.
  public static func forget(
    account: String,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    keychainService: String = "co.za.stephancill.stupid-wallet.keys"
  ) throws {
    guard let active = WalletStore.activeAddress(appGroup: appGroup),
      active.caseInsensitiveCompare(account) == .orderedSame
    else { throw ForgetError.accountMismatch }

    do {
      try WalletStore.removeAddress(account, appGroup: appGroup)
    } catch {
      throw ForgetError.deletionFailed
    }

    do {
      try KeychainKeyStore(service: keychainService).delete(account: account)
    } catch {
      try? WalletStore.setAddress(account, appGroup: appGroup)
      throw ForgetError.deletionFailed
    }

    SecurityWalletBackend(appGroup: appGroup, newKeychainService: keychainService)
      .forgetMigrationMaterial(address: account)
  }

  private static func provision(
    secret: [UInt8],
    appGroup: String,
    keychainService: String
  ) throws -> String {
    guard WalletStore.activeAddress(appGroup: appGroup) == nil else {
      throw CreateError.walletAlreadyExists
    }
    guard let pair = try? EthereumKeypair.from(secret: secret) else {
      throw CreateError.invalidPrivateKey
    }

    let store = KeychainKeyStore(service: keychainService)
    do {
      try store.save(key: secret, account: pair.address)
    } catch {
      throw Self.CreateError.saveFailed
    }

    do {
      var loaded = try store.load(
        account: pair.address,
        reason: "Unlock your wallet to verify it was saved securely")
      defer {
        for index in loaded.indices { loaded[index] = 0 }
      }
      let loadedPair = try EthereumKeypair.from(secret: loaded)
      let digest = Keccak.keccak256(Array("stupid-wallet provisioning proof".utf8))
      let signature = try EthereumSigner.sign(digest: digest, keypair: loadedPair)
      let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: signature)
      guard let recovered, recovered.caseInsensitiveCompare(pair.address) == .orderedSame else {
        throw Self.CreateError.verificationFailed
      }
    } catch {
      try? store.delete(account: pair.address)
      throw Self.CreateError.verificationFailed
    }

    do {
      try WalletStore.setAddress(pair.address, appGroup: appGroup)
    } catch {
      try? store.delete(account: pair.address)
      throw Self.CreateError.registrationFailed
    }
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
