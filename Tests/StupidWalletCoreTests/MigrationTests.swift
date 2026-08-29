import Foundation
import Testing

@testable import StupidWalletCore

private func key(_ byte: UInt8) -> [UInt8] {
  var s = [UInt8](repeating: 0, count: 32)
  s[31] = byte
  return s
}

private func addr(_ k: [UInt8]) -> String { try! EthereumKeypair.from(secret: k).address }

private struct SaveFailingKeyStore: WalletKeyStoring {
  let status: OSStatus

  func save(key: [UInt8], account: String) throws {
    throw KeychainKeyStore.StorageError.saveFailed(status)
  }

  func load(account: String, reason: String) throws -> [UInt8] { [] }
  func contains(account: String) -> Bool { false }
  func delete(account: String) throws {}
}

/// Deterministic in-memory `OldWalletBackend` for the migration state machine.
private final class FakeBackend: OldWalletBackend, @unchecked Sendable {
  var oldAddressValue: String?
  var ciphertextValue: Data?
  var migrationMarked = false
  var newWalletExists = false
  var decryptResult: Result<[UInt8], WalletMigrationFailure> = .success(key(0x11))
  var saveFailure: WalletMigrationFailure?
  var saveAsExistingItem = false
  var selfTestLoadFailure: WalletMigrationFailure?
  var pendingAccount: String?
  private(set) var savedKeys: [String: [UInt8]] = [:]
  private(set) var cleanupCalled = false
  private(set) var decryptCount = 0
  private(set) var saveCount = 0
  private(set) var loadCount = 0

  func retainSavedKey(_ key: [UInt8], account: String) {
    savedKeys[account] = key
  }

  func oldAddress() -> String? { oldAddressValue }
  func hasNewWallet() -> Bool { newWalletExists }
  func isMigrated() -> Bool { migrationMarked }
  func pendingMigrationAccount() -> String? { pendingAccount }
  func ciphertext(for address: String) -> Data? { ciphertextValue }
  func decryptCiphertext(_ data: Data, for address: String) throws -> [UInt8] {
    decryptCount += 1
    switch decryptResult {
    case .success(let k): return k
    case .failure(let e): throw e
    }
  }
  func saveKey(_ k: [UInt8], account: String) throws {
    saveCount += 1
    if let saveFailure { throw saveFailure }
    if saveAsExistingItem { return }
    savedKeys[account] = k
  }
  func loadKey(account: String) throws -> [UInt8] {
    loadCount += 1
    if let selfTestLoadFailure { throw selfTestLoadFailure }
    return savedKeys[account] ?? []
  }
  func markPending(account: String) { pendingAccount = account }
  func markMigrated(address: String) {
    migrationMarked = true
    pendingAccount = nil
  }
  func clearPending() {}
  func cleanupOldMaterial(address: String) { cleanupCalled = true }
}

private func fakeOldWallet(secret k: [UInt8]) -> FakeBackend {
  FakeBackend().apply {
    $0.oldAddressValue = addr(k)
    $0.ciphertextValue = Data([0x01])
    $0.decryptResult = .success(k)
  }
}

extension FakeBackend {
  fileprivate func apply(_ config: (FakeBackend) -> Void) -> FakeBackend {
    config(self)
    return self
  }
}

struct MigrationTests {
  @Test("a valid old wallet migrates and re-derives the same address")
  func success() {
    let k = key(0x11)
    let b = fakeOldWallet(secret: k)
    guard case .success(.migrated(let address)) = WalletMigration.migrate(backend: b) else {
      Issue.record("expected migrated")
      return
    }
    #expect(address == addr(k))
    #expect(b.isMigrated() == true)
    #expect(b.savedKeys[address] == k)
    #expect(b.cleanupCalled == false)  // old material retained until explicit cleanup
  }

  @Test("no old wallet yields noOldWallet")
  func noOldWallet() {
    let b = FakeBackend()
    #expect(WalletMigration.migrate(backend: b) == .success(.noOldWallet))
  }

  @Test("already migrated is idempotent")
  func idempotent() {
    let b = FakeBackend().apply { $0.migrationMarked = true }
    #expect(WalletMigration.migrate(backend: b) == .success(.alreadyMigrated))
  }

  @Test("skips when a new wallet already exists")
  func skipNewWallet() {
    let b = FakeBackend().apply { $0.newWalletExists = true }
    #expect(WalletMigration.migrate(backend: b) == .success(.skippedNewWalletExists))
  }

  @Test("missing ciphertext fails")
  func noCiphertext() {
    let b = FakeBackend().apply { $0.oldAddressValue = "0xAbCd" }
    guard case .failure(.noCiphertext) = WalletMigration.migrate(backend: b) else {
      Issue.record("expected noCiphertext")
      return
    }
  }

  @Test("malformed ciphertext fails and leaves state unmigrated")
  func malformed() {
    let b = FakeBackend().apply {
      $0.oldAddressValue = "0xAbCd"
      $0.ciphertextValue = Data([1])
      $0.decryptResult = .failure(.malformedCiphertext)
    }
    guard case .failure(.malformedCiphertext) = WalletMigration.migrate(backend: b) else {
      Issue.record("expected malformed")
      return
    }
    #expect(b.isMigrated() == false)
  }

  @Test("user cancellation maps to cancelled and does not complete")
  func cancelled() {
    let b = FakeBackend().apply {
      $0.oldAddressValue = "0xAbCd"
      $0.ciphertextValue = Data([1])
      $0.decryptResult = .failure(.cancelled)
    }
    guard case .failure(.cancelled) = WalletMigration.migrate(backend: b) else {
      Issue.record("expected cancelled")
      return
    }
    #expect(b.isMigrated() == false)
  }

  @Test("wrong address is rejected and leaves old usable")
  func wrongAddress() {
    let old = "0x9999999999999999999999999999999999999999"
    let b = FakeBackend().apply {
      $0.oldAddressValue = old
      $0.ciphertextValue = Data([2])
      $0.decryptResult = .success(key(0x22))
    }
    guard case .failure(.addressMismatch(let e, _)) = WalletMigration.migrate(backend: b) else {
      Issue.record("expected addressMismatch")
      return
    }
    #expect(e.lowercased() == old.lowercased())
    #expect(b.isMigrated() == false)
  }

  @Test("save failure surfaces and leaves old material intact")
  func saveFailure() {
    let b = fakeOldWallet(secret: key(0x33))
    b.saveFailure = .saveFailed
    guard case .failure(.saveFailed) = WalletMigration.migrate(backend: b) else { return }
    #expect(b.isMigrated() == false)
  }

  @Test("self-test failure (key not readable) does not complete")
  func selfTestFailure() {
    let b = fakeOldWallet(secret: key(0x44))
    b.selfTestLoadFailure = .selfTestFailed
    guard case .failure(.selfTestFailed) = WalletMigration.migrate(backend: b) else { return }
    #expect(b.isMigrated() == false)
  }

  @Test("cancelling pending key verification remains a retryable cancellation")
  func pendingVerificationCancellation() {
    let k = key(0x49)
    let account = addr(k)
    let b = fakeOldWallet(secret: k)
    b.pendingAccount = account
    b.retainSavedKey(k, account: account)
    b.selfTestLoadFailure = .cancelled

    #expect(WalletMigration.migrate(backend: b) == .failure(.cancelled))
    #expect(!b.isMigrated())
    #expect(b.pendingAccount == account)
  }

  @Test("an interrupted pending migration resumes at authenticated verification")
  func pendingMigrationResumes() {
    let k = key(0x45)
    let account = addr(k)
    let b = fakeOldWallet(secret: k)
    b.pendingAccount = account
    b.retainSavedKey(k, account: account)

    #expect(WalletMigration.migrate(backend: b) == .success(.migrated(address: account)))
    #expect(b.decryptCount == 0)
    #expect(b.saveCount == 0)
    #expect(b.loadCount == 1)
    #expect(b.isMigrated())
  }

  @Test("the Security backend resumes when the new protected item already exists")
  func duplicateProtectedItemResumes() throws {
    let suite = "migration-duplicate-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    try SecurityWalletBackend(
      appGroup: suite, keyStore: SaveFailingKeyStore(status: errSecDuplicateItem)
    ).saveKey(key(0x46), account: addr(key(0x46)))

    #expect(throws: WalletMigrationFailure.saveFailed) {
      try SecurityWalletBackend(
        appGroup: suite, keyStore: SaveFailingKeyStore(status: errSecNotAvailable)
      ).saveKey(key(0x46), account: addr(key(0x46)))
    }
  }

  @Test("a duplicate protected item before the pending marker completes only after proof")
  func preMarkerDuplicateResumes() {
    let k = key(0x47)
    let account = addr(k)
    let b = fakeOldWallet(secret: k)
    b.saveAsExistingItem = true
    b.retainSavedKey(k, account: account)

    #expect(WalletMigration.migrate(backend: b) == .success(.migrated(address: account)))
    #expect(b.decryptCount == 1)
    #expect(b.saveCount == 1)
    #expect(b.loadCount == 1)
    #expect(b.pendingAccount == nil)
    #expect(b.isMigrated())
  }

  @Test("Dawn migration uses the production shared access group")
  func legacyAccessGroupContract() {
    #expect(SecurityWalletBackend.legacyAccessGroup == KeychainKeyStore.productionAccessGroup)
    #expect(KeychainKeyStore.productionAccessGroup == "6JKMV57Y77.co.za.stephancill.stupid-wallet")
    #expect(SecurityWalletBackend.legacyCiphertextService.isEmpty)

    let account = addr(key(0x48))
    let ciphertextQuery = SecurityWalletBackend.legacyCiphertextQuery(address: account)
    #expect(ciphertextQuery[kSecAttrAccount as String] as? String == account)
    #expect(ciphertextQuery[kSecAttrService as String] as? String == "")
    #expect(
      ciphertextQuery[kSecAttrAccessGroup as String] as? String
        == KeychainKeyStore.productionAccessGroup)

    let enclaveQuery = SecurityWalletBackend.legacySecureEnclaveKeyQuery(address: account)
    #expect(enclaveQuery[kSecAttrApplicationTag as String] as? Data == account.data(using: .utf8))
    #expect(
      enclaveQuery[kSecAttrAccessGroup as String] as? String
        == KeychainKeyStore.productionAccessGroup)
  }

  @Test("Security authentication cancellation and unavailability statuses remain retryable")
  func authenticationCancellationStatuses() {
    #expect(SecurityWalletBackend.authenticationCancelledOrUnavailable(errSecUserCanceled))
    #expect(SecurityWalletBackend.authenticationCancelledOrUnavailable(errSecAuthFailed))
    #expect(SecurityWalletBackend.authenticationCancelledOrUnavailable(errSecInteractionNotAllowed))
    #expect(!SecurityWalletBackend.authenticationCancelledOrUnavailable(errSecDecode))
  }

  @Test("cleanup is independent and idempotent")
  func cleanup() {
    let b = fakeOldWallet(secret: key(0x55))
    _ = WalletMigration.migrate(backend: b)
    let a = addr(key(0x55))
    b.cleanupOldMaterial(address: a)
    #expect(b.cleanupCalled == true)
    b.cleanupOldMaterial(address: "x")
    #expect(b.cleanupCalled == true)
  }
}
