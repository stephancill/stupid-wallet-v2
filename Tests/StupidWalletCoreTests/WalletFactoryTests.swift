import Foundation
import Security
import Testing

@testable import StupidWalletCore

/// Hermetic tests for `WalletFactory` key handling. The real keychain save/load is
/// exercised only on-device (Gate 3/5); here we validate the address derivation and the
/// account-tying contract that the extension's `KeychainSigner` depends on.
struct WalletFactoryTests {
  @Test("a freshly derived keypair yields a valid EIP-55 address")
  func validAddress() throws {
    var bytes = [UInt8](repeating: 0, count: 32)
    bytes[31] = 1
    let pair = try EthereumKeypair.from(secret: bytes)
    #expect(pair.address.hasPrefix("0x"))
    #expect(pair.address.count == 42)
    // Recovery from a signature over a digest returns the same address.
    let digest = Keccak.keccak256(Array("wallet factory".utf8))
    let sig = try EthereumSigner.sign(digest: digest, keypair: pair)
    let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: sig)
    #expect(recovered == pair.address)
  }

  @Test("the wallet address default key matches the migration writer")
  func addressKeyContract() {
    #expect(WalletFactory.walletAddressKey == "sw2.walletAddress")
  }

  @Test("wallet registration removes only the expected active account")
  func removeExpectedAddress() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("WalletStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try WalletStore.setAddress("0xAbC", directory: directory)
    #expect(throws: WalletStore.StoreError.accountMismatch) {
      try WalletStore.removeAddress("0xDef", directory: directory)
    }
    #expect(WalletStore.activeAddress(directory: directory) == "0xAbC")

    try WalletStore.removeAddress("0xaBc", directory: directory)
    #expect(WalletStore.activeAddress(directory: directory) == nil)
  }

  @Test("import recovers a matching keychain item that survived uninstall")
  func recoversMatchingOrphanedKey() throws {
    let secret = testSecret(1)
    let store = StubWalletKeyStore(existingKey: secret)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let address = try WalletFactory.provision(
      secret: secret,
      appGroup: "test.wallet",
      store: store,
      walletDirectory: directory
    )

    #expect(store.loadCount == 1)
    #expect(store.deleteCount == 0)
    #expect(WalletStore.activeAddress(directory: directory) == address)
  }

  @Test("import does not replace a mismatched surviving keychain item")
  func rejectsMismatchedOrphanedKey() throws {
    let store = StubWalletKeyStore(existingKey: testSecret(2))
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: WalletFactory.CreateError.verificationFailed) {
      try WalletFactory.provision(
        secret: testSecret(1),
        appGroup: "test.wallet",
        store: store,
        walletDirectory: directory
      )
    }
    #expect(store.loadCount == 1)
    #expect(store.deleteCount == 0)
    #expect(WalletStore.activeAddress(directory: directory) == nil)
  }

  private func testSecret(_ value: UInt8) -> [UInt8] {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = value
    return secret
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("WalletFactoryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private final class StubWalletKeyStore: WalletKeyStoring {
  private let existingKey: [UInt8]
  private(set) var loadCount = 0
  private(set) var deleteCount = 0

  init(existingKey: [UInt8]) {
    self.existingKey = existingKey
  }

  func save(key: [UInt8], account: String) throws {
    throw KeychainKeyStore.StorageError.saveFailed(errSecDuplicateItem)
  }

  func load(account: String, reason: String) throws -> [UInt8] {
    loadCount += 1
    return existingKey
  }

  func delete(account: String) throws {
    deleteCount += 1
  }
}
