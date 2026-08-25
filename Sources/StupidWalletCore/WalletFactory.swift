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
    return try provision(
      secret: secret,
      appGroup: appGroup,
      store: KeychainKeyStore(service: keychainService)
    )
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
    return try provision(
      secret: secret,
      appGroup: appGroup,
      store: KeychainKeyStore(service: keychainService)
    )
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
    return try provision(
      secret: secret,
      appGroup: appGroup,
      store: KeychainKeyStore(service: keychainService)
    )
  }

  public static func exportPrivateKey(
    account: String,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    keychainService: String = "co.za.stephancill.stupid-wallet.keys"
  ) throws -> String {
    try WalletAccountResolver(
      appGroup: appGroup, keyStore: KeychainKeyStore(service: keychainService)
    ).exportPrivateKey(address: account)
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

  static func provision(
    secret: [UInt8],
    appGroup: String,
    store: any WalletKeyStoring,
    walletDirectory: URL? = nil
  ) throws -> String {
    guard WalletStore.activeAddress(appGroup: appGroup, directory: walletDirectory) == nil else {
      throw CreateError.walletAlreadyExists
    }
    guard let pair = try? EthereumKeypair.from(secret: secret) else {
      throw CreateError.invalidPrivateKey
    }

    let insertedKey: Bool
    do {
      try store.save(key: secret, account: pair.address)
      insertedKey = true
    } catch KeychainKeyStore.StorageError.saveFailed(let status)
      where status == errSecDuplicateItem
    {
      // Keychain items survive uninstall. Reuse one only after authenticated verification
      // proves it is exactly the key the user is importing.
      insertedKey = false
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
      guard loaded == secret else { throw Self.CreateError.verificationFailed }
      let loadedPair = try EthereumKeypair.from(secret: loaded)
      let digest = Keccak.keccak256(Array("stupid-wallet provisioning proof".utf8))
      let signature = try EthereumSigner.sign(digest: digest, keypair: loadedPair)
      let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: signature)
      guard let recovered, recovered.caseInsensitiveCompare(pair.address) == .orderedSame else {
        throw Self.CreateError.verificationFailed
      }
    } catch {
      if insertedKey { try? store.delete(account: pair.address) }
      throw Self.CreateError.verificationFailed
    }

    do {
      try WalletStore.setAddress(
        pair.address, appGroup: appGroup, directory: walletDirectory)
    } catch {
      if insertedKey { try? store.delete(account: pair.address) }
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

  /// Unsupported rebuild registration key retained only so registry startup can remove
  /// downgrade residue. It is never a wallet identity or migration source.
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
