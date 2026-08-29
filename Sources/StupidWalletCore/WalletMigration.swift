import Foundation

/// Outcomes of running the old-wallet upgrade migration.
public enum WalletMigrationResult: Sendable, Equatable {
  case noOldWallet
  case alreadyMigrated
  case skippedNewWalletExists
  case migrated(address: String)
}

public enum WalletMigrationFailure: Error, Sendable, Equatable {
  case noCiphertext
  case malformedCiphertext
  case decryptionFailed
  case cancelled
  case invalidKeyMaterial
  case addressMismatch(expected: String, actual: String)
  case saveFailed
  case selfTestFailed
}

/// Abstraction over the old persisted format so the migration state machine stays
/// hermetic-testable. The production implementation wraps Security/Keychain/Defaults.
public protocol OldWalletBackend: Sendable {
  /// The checksummed address persisted by the old app (App Group defaults), if any.
  func oldAddress() -> String?
  /// Whether a new-format wallet already exists (migration only runs when none does).
  func hasNewWallet() -> Bool
  /// Whether this store already completed a migration (idempotency guard).
  func isMigrated() -> Bool
  /// The account whose new-format key was saved but not yet authenticated and proven.
  func pendingMigrationAccount() -> String?
  /// The old ECIES ciphertext keyed by the old address.
  func ciphertext(for address: String) -> Data?
  /// Decrypts ciphertext to the raw 32-byte private key. Throws `.cancelled` when the
  /// user declines authentication, otherwise a decryption/malformed-key error.
  func decryptCiphertext(_ ciphertext: Data, for address: String) throws -> [UInt8]
  /// Persists the decrypted key in the new format.
  func saveKey(_ key: [UInt8], account: String) throws
  /// Reads the new-format key back (must require device-owner authentication).
  func loadKey(account: String) throws -> [UInt8]
  /// Marks the key written but not yet verified.
  func markPending(account: String)
  /// Marks the migration completed against an address.
  func markMigrated(address: String)
  /// Idempotent best-effort cleanup of the old keychain material.
  func cleanupOldMaterial(address: String)
}

/// Gate 4 upgrade-migration state machine.
public enum WalletMigration {
  public static func migrate(backend: OldWalletBackend) -> Result<
    WalletMigrationResult, WalletMigrationFailure
  > {
    // Idempotency and never clobber an existing wallet.
    if backend.isMigrated() { return .success(.alreadyMigrated) }
    if backend.hasNewWallet() { return .success(.skippedNewWalletExists) }
    guard let oldAddress = backend.oldAddress() else { return .success(.noOldWallet) }

    // A previous attempt may have saved the protected item and then been interrupted or
    // cancelled at its authenticated self-test. Resume from that durable boundary rather
    // than attempting another SecItemAdd, which would fail before showing authentication.
    if let pending = backend.pendingMigrationAccount(), sameAddress(pending, oldAddress) {
      if let failure = savedKeyVerificationFailure(backend: backend, account: pending) {
        return .failure(failure)
      }
      backend.markMigrated(address: pending)
      return .success(.migrated(address: pending))
    }

    guard let ciphertext = backend.ciphertext(for: oldAddress) else {
      return .failure(.noCiphertext)
    }

    let account: String
    var decrypted: [UInt8]
    do {
      var key = try backend.decryptCiphertext(ciphertext, for: oldAddress)
      defer { key = [UInt8](repeating: 0, count: key.count) }
      let derived = try deriveAddress(key)
      guard sameAddress(derived, oldAddress) else {
        return .failure(.addressMismatch(expected: oldAddress, actual: derived))
      }
      account = derived
      decrypted = key
    } catch let failure as WalletMigrationFailure {
      return .failure(failure)
    } catch {
      return .failure(.decryptionFailed)
    }

    // Persist the decrypted key in the new format (single authenticated decrypt; the
    // plaintext lives only within this narrow scope).
    do {
      try backend.saveKey(decrypted, account: account)
    } catch {
      return .failure(.saveFailed)
    }
    decrypted = [UInt8](repeating: 0, count: decrypted.count)
    backend.markPending(account: account)

    // Authenticated self-test: reload from the new store (a second device-owner prompt)
    // and recover the same signer.
    if let failure = savedKeyVerificationFailure(backend: backend, account: account) {
      return .failure(failure)
    }

    backend.markMigrated(address: account)
    return .success(.migrated(address: account))
  }

  private static func deriveAddress(_ key: [UInt8]) throws -> String {
    try EthereumKeypair.from(secret: key).address
  }

  private static func sameAddress(_ a: String, _ b: String) -> Bool {
    a.lowercased() == b.lowercased()
  }

  private static func savedKeyVerificationFailure(
    backend: OldWalletBackend, account: String
  ) -> WalletMigrationFailure? {
    do {
      var loaded = try backend.loadKey(account: account)
      defer { loaded.resetBytes(in: loaded.indices) }
      return selfTestRecovers(key: loaded, address: account) ? nil : .selfTestFailed
    } catch let failure as WalletMigrationFailure {
      return failure
    } catch {
      return .selfTestFailed
    }
  }

  private static func selfTestRecovers(key: [UInt8], address: String) -> Bool {
    guard
      let pair = try? EthereumKeypair.from(secret: key),
      pair.address.lowercased() == address.lowercased()
    else { return false }
    let digest = Keccak.keccak256(Array("migration proof".utf8))
    guard
      let signature = try? EthereumSigner.sign(digest: digest, keypair: pair),
      let recovered = try? EthereumSigner.recoverAddress(digest: digest, signature: signature)
    else { return false }
    return recovered.lowercased() == address.lowercased()
  }
}
