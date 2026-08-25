import Foundation
import Testing

@testable import StupidWalletCore

struct BalanceCacheTests {
  @Test("balance cache holds multiple account entries and removes only one")
  func multiAccount() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BalanceCache(directory: directory)
    let first = "0x1234567890abcdef1234567890abcdef12345678"
    let second = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"

    try store.save(balance: "3.000000", account: first)
    try store.save(balance: "9.500000", account: second)
    #expect(try store.balance(account: first) == "3.000000")
    #expect(try store.balance(account: second) == "9.500000")

    try store.remove(account: first)
    #expect(try store.balance(account: first) == nil)
    #expect(try store.balance(account: second) == "9.500000")
  }

  @Test("account lookups normalize case and expose the full entry")
  func caseInsensitiveAndEntry() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BalanceCache(directory: directory)
    let account = "0xAbC1234567890abcdef1234567890abcdef1234"

    try store.save(balance: "1.100000", account: account, registryRevision: 7)
    #expect(try store.balance(account: account.uppercased()) == "1.100000")
    let entry = try #require(try store.entry(account: account))
    #expect(entry.registryRevision == 7)
    #expect(entry.updatedAt > Date(timeIntervalSince1970: 0))
  }

  @Test("each successful save advances the cache revision")
  func revisionMonotonic() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BalanceCache(directory: directory)
    let account = "0x1234567890abcdef1234567890abcdef12345678"
    #expect(try store.revision() == nil)

    try store.save(balance: "1.000000", account: account)
    #expect(try store.revision() == 1)
    try store.save(balance: "2.000000", account: account)
    #expect(try store.revision() == 2)
  }

  @Test("unsupported singleton snapshot fails loudly")
  func singletonSnapshotRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = "0x1234567890abcdef1234567890abcdef12345678"
    let legacy: [String: String] = ["account": account, "balance": "25.000000"]
    try JSONEncoder().encode(legacy).write(
      to: directory.appendingPathComponent("native-balance-cache.json"))

    let store = BalanceCache(directory: directory)
    #expect(throws: BalanceCacheError.unavailable) {
      try store.load()
    }
  }

  @Test("corrupt and absent payloads fail loudly or return nil")
  func corruptAndAbsent() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BalanceCache(directory: directory)
    #expect(try store.load() == nil)
    #expect(try store.balance(account: "0x1234567890abcdef1234567890abcdef12345678") == nil)

    try Data("not-json".utf8).write(
      to: directory.appendingPathComponent("native-balance-cache.json"))
    #expect(throws: BalanceCacheError.unavailable) {
      try store.load()
    }
  }

  @Test("removeAll clears every account entry")
  func removeAllAccounts() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BalanceCache(directory: directory)
    let first = "0x1234567890abcdef1234567890abcdef12345678"
    let second = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"

    try store.save(balance: "1.000000", account: first)
    try store.save(balance: "2.000000", account: second)
    try store.removeAll()
    #expect(try store.balance(account: first) == nil)
    #expect(try store.balance(account: second) == nil)
  }

  @Test("independent stores preserve concurrent account saves")
  func concurrentSaves() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = BalanceCache(directory: directory)
    let second = BalanceCache(directory: directory)
    let firstAccount = "0x1234567890abcdef1234567890abcdef12345678"
    let secondAccount = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"

    async let saveFirst: Void = first.save(balance: "1.000000", account: firstAccount)
    async let saveSecond: Void = second.save(balance: "2.000000", account: secondAccount)
    _ = try await (saveFirst, saveSecond)

    #expect(try first.balance(account: firstAccount) == "1.000000")
    #expect(try first.balance(account: secondAccount) == "2.000000")
    #expect(try first.revision() == 2)
  }

  @Test(
    "cache writes are atomic across failures and interruptions",
    arguments: [
      (PersistenceFaultPoint.cacheBeforeWrite, false),
      (PersistenceFaultPoint.cacheAfterWrite, true),
    ])
  func faultedWrites(point: PersistenceFaultPoint, commits: Bool) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAccount = "0x1234567890abcdef1234567890abcdef12345678"
    let secondAccount = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
    let initialStore = BalanceCache(directory: directory)
    try initialStore.save(balance: "1.000000", account: firstAccount)
    let interruptedStore = BalanceCache(
      directory: directory,
      faultInjector: OneShotPersistenceFaultInjector(point))

    #expect(throws: PersistenceFaultSimulationError.interruption(point)) {
      try interruptedStore.save(balance: "2.000000", account: secondAccount)
    }

    #expect(try initialStore.balance(account: firstAccount) == "1.000000")
    #expect(
      try initialStore.balance(account: secondAccount)
        == (commits ? "2.000000" : nil))
    #expect(try initialStore.revision() == (commits ? 2 : 1))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BalanceCacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
