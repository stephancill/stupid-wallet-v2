import Foundation
import Security
import Testing

@testable import StupidWalletCore

struct WalletGroupManagerTests {
  private let mnemonic = "test test test test test test test test test test test junk"

  @Test("seed import registers protected entropy and account zero")
  func importsSeedGroup() throws {
    let environment = try Environment()
    defer { environment.remove() }

    let group = try environment.manager.importSeedGroup(mnemonic: mnemonic)
    let loaded = try environment.registry.loadReady()
    let registry = try #require(loaded)

    #expect(group.kind == .seed)
    #expect(group.nextDerivationIndex == 1)
    #expect(group.accounts.map(\.derivationIndex) == [0])
    #expect(group.accounts[0].address == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
    #expect(registry.groups.last == group)
    #expect(environment.seeds.contains(groupID: group.id))
    #expect(registry.homeSelectedAddress == environment.existingAddress)
  }

  @Test("derivation appends the next account without persisting a child key")
  func derivesNextAccount() throws {
    let environment = try Environment()
    defer { environment.remove() }
    let group = try environment.manager.importSeedGroup(mnemonic: mnemonic)

    let account = try environment.manager.deriveAccount(groupID: group.id)
    let loaded = try environment.registry.loadReady()
    let registry = try #require(loaded)
    let updated = try #require(registry.groups.first { $0.id == group.id })

    #expect(account.derivationIndex == 1)
    #expect(account.address == "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
    #expect(updated.accounts.map(\.derivationIndex) == [0, 1])
    #expect(updated.nextDerivationIndex == 2)
    #expect(environment.seeds.savedGroupIDs == [group.id])
  }

  @Test("concurrent derivations allocate distinct monotonic indexes")
  func concurrentDerivations() async throws {
    let environment = try Environment()
    defer { environment.remove() }
    let group = try environment.manager.importSeedGroup(mnemonic: mnemonic)

    let accounts = try await withThrowingTaskGroup(of: WalletAccount.self) { tasks in
      for _ in 0..<2 {
        tasks.addTask { try environment.manager.deriveAccount(groupID: group.id) }
      }
      var values: [WalletAccount] = []
      for try await account in tasks { values.append(account) }
      return values
    }

    #expect(accounts.compactMap(\.derivationIndex).sorted() == [1, 2])
    let loaded = try environment.registry.loadReady()
    let registry = try #require(loaded)
    let updated = try #require(registry.groups.first { $0.id == group.id })
    #expect(updated.accounts.map(\.derivationIndex) == [0, 1, 2])
    #expect(updated.nextDerivationIndex == 3)
  }

  @Test("duplicate seed import is rejected without retaining another entropy item")
  func rejectsDuplicateSeed() throws {
    let environment = try Environment()
    defer { environment.remove() }
    let first = try environment.manager.importSeedGroup(mnemonic: mnemonic)

    #expect(throws: WalletGroupManagerError.duplicateAccount) {
      try environment.manager.importSeedGroup(mnemonic: mnemonic)
    }
    #expect(environment.seeds.savedGroupIDs == [first.id])
  }

  @Test("private-key import registers exactly one non-derived account")
  func importsPrivateKeyGroup() throws {
    let keys = StubKeyStore()
    let environment = try Environment(keys: keys)
    defer { environment.remove() }
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 2

    let group = try environment.manager.importPrivateKey(
      privateKey: "0x" + Hex.encode(secret))

    #expect(group.kind == .privateKey)
    #expect(group.accounts.count == 1)
    #expect(group.accounts[0].derivationIndex == nil)
    #expect(group.nextDerivationIndex == nil)
    #expect(keys.contains(account: group.accounts[0].address))
    #expect(throws: WalletGroupManagerError.wrongGroupKind) {
      try environment.manager.deriveAccount(groupID: group.id)
    }
    #expect(throws: WalletGroupManagerError.duplicateAccount) {
      try environment.manager.importPrivateKey(privateKey: "0x" + Hex.encode(secret))
    }
  }

  @Test("failed authenticated verification rolls back the new entropy item")
  func rollsBackFailedVerification() throws {
    let seeds = StubSeedStore(loadOverride: [UInt8](repeating: 0, count: 16))
    let environment = try Environment(seeds: seeds)
    defer { environment.remove() }

    #expect(throws: WalletGroupManagerError.verificationFailed) {
      try environment.manager.importSeedGroup(mnemonic: mnemonic)
    }
    #expect(seeds.savedGroupIDs.isEmpty)
    #expect(try environment.registry.loadReady()?.groups.count == 1)
  }

  @Test("seed accounts sign and export from one protected entropy item")
  func seedSignerAndExport() throws {
    let environment = try Environment()
    defer { environment.remove() }
    let group = try environment.manager.importSeedGroup(mnemonic: mnemonic)
    let accountOne = try environment.manager.deriveAccount(groupID: group.id)
    let resolver = WalletAccountResolver(
      registryStore: environment.registry,
      keyStore: environment.keys,
      seedStore: environment.seeds,
      lifecycle: WalletGroupLifecycleCoordinator(directory: environment.directory))
    let signer = try resolver.signer(address: accountOne.address)
    let digest = Keccak.keccak256(Array("seed signer test".utf8))

    let signature = try signer.signDigest(digest)
    let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: signature)
    let exported = try resolver.exportPrivateKey(address: accountOne.address)
    var entropy = try EthereumSeedPhrase.entropy(mnemonic: mnemonic)
    defer { entropy.resetBytes(in: entropy.indices) }
    var expected = try EthereumSeedPhrase.privateKey(entropy: entropy, index: 1)
    defer { expected.resetBytes(in: expected.indices) }

    #expect(recovered == accountOne.address)
    #expect(exported == "0x" + Hex.encode(expected))
    #expect(environment.seeds.loadCount(groupID: group.id) == 4)
    #expect(!environment.keys.contains(account: accountOne.address))
  }

  @Test("group deletion removes only that group's pending, connection, cache, and secret state")
  func deletesGroup() async throws {
    let environment = try Environment()
    defer { environment.remove() }
    let group = try environment.manager.importSeedGroup(mnemonic: mnemonic)
    let second = try environment.manager.deriveAccount(groupID: group.id)
    let origin = "https://delete.example"
    let currentConnection = try #require(try environment.connection.load())
    _ = try environment.connection.update(expectedRevision: currentConnection.revision) { state in
      let grant = ConnectionGrant(
        account: second.address, origin: origin, legacyDomain: "delete.example", profileID: nil,
        connectedAt: Date(), precision: .exact)
      return ConnectionState(
        revision: state.revision + 1,
        defaultAccount: second.address,
        grants: [grant],
        activeConnections: [
          ActiveConnection(origin: origin, profileID: nil, account: second.address)
        ])
    }
    try environment.cache.save(balance: "2.000000", account: second.address)
    let request = WalletPendingRequest(
      kind: .message, method: "personal_sign", origin: origin, chainId: "1",
      account: second.address, params: .array([]), payloadDigest: "test", bindingVersion: 2)
    try await environment.pending.insert(request)

    try environment.manager.deleteGroup(groupID: group.id)

    let registry = try #require(try environment.registry.loadReady())
    let connection = try #require(try environment.connection.load())
    let terminal = try #require(try await environment.pending.record(request.id))
    #expect(!registry.groups.contains { $0.id == group.id })
    #expect(registry.homeSelectedAddress == environment.existingAddress)
    #expect(!environment.seeds.contains(groupID: group.id))
    #expect(connection.defaultAccount == environment.existingAddress)
    #expect(connection.grants.isEmpty)
    #expect(connection.activeConnections.isEmpty)
    #expect(try environment.cache.entry(account: second.address) == nil)
    #expect(terminal.status == .failed)
    #expect(terminal.error?.nestedString(at: ["message"])?.contains("removed") == true)
  }

  @Test("deleting registry barrier resumes after secret deletion failure")
  func resumesDeletion() throws {
    let seeds = StubSeedStore(deleteFailures: 1)
    let environment = try Environment(seeds: seeds)
    defer { environment.remove() }
    let group = try environment.manager.importSeedGroup(mnemonic: mnemonic)

    #expect(throws: WalletGroupManagerError.secureStorage) {
      try environment.manager.deleteGroup(groupID: group.id)
    }
    let interrupted = try #require(try environment.registry.loadReady())
    #expect(interrupted.groups.first { $0.id == group.id }?.lifecycle == .deleting)
    #expect(seeds.contains(groupID: group.id))

    let resolver = WalletAccountResolver(
      registryStore: environment.registry, keyStore: environment.keys, seedStore: seeds,
      lifecycle: WalletGroupLifecycleCoordinator(directory: environment.directory))
    #expect(throws: SigningError.accountUnavailable) {
      try resolver.signer(address: group.accounts[0].address)
    }

    try environment.manager.resumeDeletingGroups()
    #expect(try environment.registry.loadReady()?.groups.contains { $0.id == group.id } == false)
    #expect(!seeds.contains(groupID: group.id))
  }
}

private struct Environment {
  let directory: URL
  let existingAddress: String
  let registry: WalletRegistryStore
  let keys: StubKeyStore
  let seeds: StubSeedStore
  let connection: ConnectionStateStore
  let cache: BalanceCache
  let pending: PendingRequestStore
  let manager: WalletGroupManager

  init(
    keys: StubKeyStore = StubKeyStore(),
    seeds: StubSeedStore = StubSeedStore()
  ) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WalletGroupManagerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 1
    existingAddress = try EthereumKeypair.from(secret: secret).address
    registry = WalletRegistryStore(directory: directory)
    self.keys = keys
    self.seeds = seeds
    let suite = "WalletGroupManagerTests-\(UUID().uuidString)"
    connection = ConnectionStateStore(directory: directory, suiteName: suite)
    cache = BalanceCache(directory: directory)
    pending = PendingRequestStore(
      directory: directory.appendingPathComponent("PendingRequests", isDirectory: true))

    let createdAt = Date(timeIntervalSince1970: 1)
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [
        WalletAccount(address: existingAddress, derivationIndex: nil, createdAt: createdAt)
      ], lifecycle: .active)
    try registry.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: [group],
        homeSelectedAddress: existingAddress, legacyWalletAddressFallbackRemoved: false))
    _ = try registry.update(expectedRevision: 0) { current in
      WalletRegistry(
        revision: 1, adoptionState: .migrating, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    _ = try registry.update(expectedRevision: 1) { current in
      WalletRegistry(
        revision: 2, adoptionState: .complete, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    _ = try connection.getOrCreate(
      ConnectionState(revision: 0, defaultAccount: existingAddress))
    manager = WalletGroupManager(
      registryStore: registry,
      keyStore: keys,
      seedStore: seeds,
      lifecycle: WalletGroupLifecycleCoordinator(directory: directory),
      connectionStore: connection,
      balanceCache: cache,
      pendingStore: pending,
      migrationBackend: SecurityWalletBackend(appGroup: suite))
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class StubKeyStore: WalletKeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: [UInt8]] = [:]

  func save(key: [UInt8], account: String) throws {
    try lock.withLock {
      guard values[account.lowercased()] == nil else {
        throw KeychainKeyStore.StorageError.saveFailed(errSecDuplicateItem)
      }
      values[account.lowercased()] = key
    }
  }

  func load(account: String, reason: String) throws -> [UInt8] {
    try lock.withLock {
      guard let key = values[account.lowercased()] else {
        throw KeychainKeyStore.StorageError.notFound
      }
      return key
    }
  }

  func delete(account: String) throws {
    _ = lock.withLock { values.removeValue(forKey: account.lowercased()) }
  }

  func contains(account: String) -> Bool {
    lock.withLock { values[account.lowercased()] != nil }
  }
}

private final class StubSeedStore: WalletSeedStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: [UInt8]] = [:]
  private let loadOverride: [UInt8]?
  private var remainingDeleteFailures: Int
  private var loadCounts: [UUID: Int] = [:]

  init(loadOverride: [UInt8]? = nil, deleteFailures: Int = 0) {
    self.loadOverride = loadOverride
    remainingDeleteFailures = deleteFailures
  }

  var savedGroupIDs: [UUID] {
    lock.withLock { values.keys.sorted { $0.uuidString < $1.uuidString } }
  }

  func save(entropy: [UInt8], groupID: UUID) throws {
    lock.withLock { values[groupID] = entropy }
  }

  func load(groupID: UUID, reason: String) throws -> [UInt8] {
    try lock.withLock {
      loadCounts[groupID, default: 0] += 1
      if let loadOverride { return loadOverride }
      guard let entropy = values[groupID] else { throw KeychainSeedStore.StorageError.notFound }
      return entropy
    }
  }

  func contains(groupID: UUID) -> Bool {
    lock.withLock { values[groupID] != nil }
  }

  func delete(groupID: UUID) throws {
    try lock.withLock {
      if remainingDeleteFailures > 0 {
        remainingDeleteFailures -= 1
        throw KeychainSeedStore.StorageError.deleteFailed
      }
      values.removeValue(forKey: groupID)
    }
  }

  func loadCount(groupID: UUID) -> Int {
    lock.withLock { loadCounts[groupID, default: 0] }
  }
}
