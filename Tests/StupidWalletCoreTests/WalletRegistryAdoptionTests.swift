import Foundation
import Testing

@testable import StupidWalletCore

private struct StubSecretProbe: ProtectedSecretProbing {
  let addresses: [String]
  func secretExists(account: String) -> Bool {
    addresses.contains { $0.caseInsensitiveCompare(account) == .orderedSame }
  }
}

private struct StubSeedProbe: ProtectedSeedProbing {
  let groupIDs: Set<UUID>
  func seedExists(groupID: UUID) -> Bool { groupIDs.contains(groupID) }
}

/// Deterministic in-memory `OldWalletBackend` for the Dawn adoption path.
private final class AdoptionFakeBackend: OldWalletBackend, @unchecked Sendable {
  var oldAddressValue: String?
  var ciphertextValue: Data?
  var decryptResult: Result<[UInt8], WalletMigrationFailure>
  private(set) var savedKeys: [String: [UInt8]] = [:]
  var migrated = false
  private(set) var cleanupCalled = false

  init(
    oldAddress: String?,
    ciphertext: Data? = Data([0x01]),
    decryptResult: Result<[UInt8], WalletMigrationFailure>
  ) {
    oldAddressValue = oldAddress
    ciphertextValue = ciphertext
    self.decryptResult = decryptResult
  }

  func oldAddress() -> String? { oldAddressValue }
  func hasNewWallet() -> Bool { false }
  func isMigrated() -> Bool { migrated }
  func ciphertext(for address: String) -> Data? { ciphertextValue }
  func decryptCiphertext(_ data: Data, for address: String) throws -> [UInt8] {
    switch decryptResult {
    case .success(let key): return key
    case .failure(let failure): throw failure
    }
  }
  func saveKey(_ key: [UInt8], account: String) throws { savedKeys[account] = key }
  func loadKey(account: String) throws -> [UInt8] { savedKeys[account] ?? [] }
  func markPending(account: String) {}
  func markMigrated(address: String) { migrated = true }
  func cleanupOldMaterial(address: String) { cleanupCalled = true }
}

private struct AdoptionEnv {
  let directory: URL
  let suite: String

  func defaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  static func make() throws -> AdoptionEnv {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WalletRegistryAdoptionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return AdoptionEnv(directory: directory, suite: "adopt-\(UUID().uuidString)")
  }

  func writeAddressFile(_ address: String) throws {
    try Data("\(address)\n".utf8).write(
      to: directory.appendingPathComponent("wallet-address.conf"))
  }

}

struct WalletRegistryAdoptionTests {
  @Test("active seed groups require their exact protected entropy item")
  func seedSourceReadiness() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let privateAccount = try address(secret: 1)
    let seedAccount = try address(secret: 2)
    try completeRegistry(in: env.directory, account: privateAccount)
    let store = WalletRegistryStore(directory: env.directory)
    let loaded = try store.loadReady()
    let current = try #require(loaded)
    let createdAt = Date(timeIntervalSince1970: 2)
    let seedGroup = WalletGroup(
      id: UUID(), kind: .seed, createdAt: createdAt, nextDerivationIndex: 1,
      accounts: [WalletAccount(address: seedAccount, derivationIndex: 0, createdAt: createdAt)],
      lifecycle: .active)
    _ = try store.update(expectedRevision: current.revision) { registry in
      WalletRegistry(
        revision: registry.revision + 1, adoptionState: .complete,
        groups: registry.groups + [seedGroup], homeSelectedAddress: registry.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }

    let missing = WalletRegistryAdoption(
      directory: env.directory,
      appGroup: env.suite,
      probe: StubSecretProbe(addresses: [privateAccount]),
      seedProbe: StubSeedProbe(groupIDs: []),
      migrationBackend: AdoptionFakeBackend(oldAddress: nil, decryptResult: .success([])))
    await #expect(throws: WalletRegistryAdoptionError.noSeedForGroup(seedGroup.id)) {
      try await missing.ensureAdopted()
    }

    let available = WalletRegistryAdoption(
      directory: env.directory,
      appGroup: env.suite,
      probe: StubSecretProbe(addresses: [privateAccount]),
      seedProbe: StubSeedProbe(groupIDs: [seedGroup.id]),
      migrationBackend: AdoptionFakeBackend(oldAddress: nil, decryptResult: .success([])))
    #expect(try await available.ensureAdopted().kind == .alreadyAdopted)
  }

  @Test("current-rebuild registration is not a registry migration source")
  func rebuildIsUnsupported() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    try env.writeAddressFile(account)
    let defaults = env.defaults()
    defaults.set(account, forKey: WalletFactory.walletAddressKey)
    let backend = AdoptionFakeBackend(
      oldAddress: account, decryptResult: .success(secret(1)))

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]), migrationBackend: backend)
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .noWallet)
    #expect(result.registry == nil)
    #expect(WalletStore.activeAddress(directory: env.directory) == account)
    #expect(defaults.string(forKey: WalletFactory.walletAddressKey) == account)
    #expect(!backend.migrated)
    #expect(backend.savedKeys.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: env.directory.appendingPathComponent("wallet-registry.json").path))
  }

  @Test("empty installation bootstraps ready empty authority")
  func noWallet() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: []))
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .noWallet)
    #expect(result.registry?.adoptionState == .complete)
    #expect(result.registry?.groups.isEmpty == true)
    #expect(result.registry?.homeSelectedAddress == nil)
    #expect(result.registry?.legacyWalletAddressFallbackRemoved == true)
    #expect(WalletStore.activeAddress(directory: env.directory) == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: env.directory.appendingPathComponent("wallet-registry.json").path))
    #expect(
      FileManager.default.fileExists(
        atPath: env.directory.appendingPathComponent("connection-state.json").path))
    #expect(
      try ConnectionStateStore(directory: env.directory, suiteName: env.suite).load()?.revision == 0
    )
  }

  @Test("old Dawn wallet migrates then adopts the proven address")
  func dawnMigrationAdoption() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let secret = secret(0x11)
    let account = try address(secret: 0x11)
    let backend = AdoptionFakeBackend(
      oldAddress: account, decryptResult: .success(secret))

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]), migrationBackend: backend)
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .adopted)
    #expect(result.registry?.homeSelectedAddress?.caseInsensitiveCompare(account) == .orderedSame)
    #expect(backend.migrated)
    #expect(WalletStore.activeAddress(directory: env.directory) == account)
    // Old key material is never deleted by adoption; only explicit cleanup removes it.
    #expect(!backend.cleanupCalled)
    #expect(backend.savedKeys[account] == secret)
  }

  @Test("authenticated Dawn migration without its protected secret fails loudly")
  func missingSecret() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let backend = AdoptionFakeBackend(
      oldAddress: account, decryptResult: .success(secret(1)))

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: []), migrationBackend: backend)
    await #expect(throws: WalletRegistryAdoptionError.noSecretForAddress) {
      try await adoption.ensureAdopted()
    }
  }

  @Test("an incomplete migrating registry resumes and completes")
  func resumeInterruptedAdoption() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let store = WalletRegistryStore(directory: env.directory)
    let createdAt = Date(timeIntervalSince1970: 1)
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [WalletAccount(address: account, derivationIndex: nil, createdAt: createdAt)],
      lifecycle: .active)
    try store.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: [group],
        homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: false))
    // The fallback still exists because the interrupted run never removed it.
    env.defaults().set(account, forKey: WalletFactory.walletAddressKey)

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]))
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .adopted)
    let registry = try #require(result.registry)
    #expect(registry.adoptionState == .complete)
    #expect(registry.legacyWalletAddressFallbackRemoved)
    #expect(env.defaults().string(forKey: WalletFactory.walletAddressKey) == nil)
  }

  @Test("migration failure surfaces as a structured adoption error")
  func migrationFailure() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let backend = AdoptionFakeBackend(
      oldAddress: account, decryptResult: .failure(.decryptionFailed))

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: []), migrationBackend: backend)
    await #expect(
      throws: WalletRegistryAdoptionError.migrationFailed(.decryptionFailed)
    ) {
      try await adoption.ensureAdopted()
    }
  }

  @Test("a waiting wallet stays in setup with empty authority files")
  func noWalletFiles() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: []))
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .noWallet)
    let contents = try FileManager.default.contentsOfDirectory(atPath: env.directory.path)
    #expect(contents.filter { $0 == "wallet-registry.json" }.count == 1)
    #expect(contents.filter { $0 == "connection-state.json" }.count == 1)
  }

  @Test("adoption recovers an interrupted projection-first transition and completes")
  func interruptedTransitionRecovery() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    try env.writeAddressFile(account)
    let store = WalletRegistryStore(directory: env.directory)
    let createdAt = Date(timeIntervalSince1970: 1)
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [WalletAccount(address: account, derivationIndex: nil, createdAt: createdAt)],
      lifecycle: .active)
    let migrating = WalletRegistry(
      revision: 0, adoptionState: .migrating, groups: [group],
      homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: false)
    try store.create(migrating)
    // Craft a journal for the fallback-removal step that was interrupted before commit.
    let next = WalletRegistry(
      revision: 1, adoptionState: .migrating, groups: migrating.groups,
      homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: true)
    let transition = WalletRegistryTransition(
      previousRegistry: .present(migrating), nextRegistry: next,
      previousProjection: .present(Data("\(account)\n".utf8)),
      intendedProjection: .present(Data("\(account)\n".utf8)))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(transition).write(
      to: env.directory.appendingPathComponent("wallet-registry-transition.json"))
    env.defaults().set(account, forKey: WalletFactory.walletAddressKey)

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]))
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .adopted)
    let registry = try #require(result.registry)
    #expect(registry.adoptionState == .complete)
    #expect(registry.legacyWalletAddressFallbackRemoved)
    #expect(env.defaults().string(forKey: WalletFactory.walletAddressKey) == nil)
  }

  // MARK: Adoption-gated WalletService barrier

  @Test("a migrating registry fails request handling closed")
  func migratingRegistryFailsClosed() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let store = WalletRegistryStore(directory: env.directory)
    let createdAt = Date(timeIntervalSince1970: 1)
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [WalletAccount(address: account, derivationIndex: nil, createdAt: createdAt)],
      lifecycle: .active)
    try store.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: [group],
        homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: false))

    let chainDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AdoptionBarrierChain-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: chainDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: chainDirectory) }
    let svc = WalletService(
      store: PendingRequestStore(directory: env.directory),
      signing: StubSigner(account: account),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: ChainStore(directory: chainDirectory),
      networkStore: NetworkStore(directory: chainDirectory, legacySuiteName: UUID().uuidString),
      registryStore: store)

    await #expect(throws: WalletError.notReady) {
      try await svc.prepare(
        method: "personal_sign",
        params: .array([.string("0x1234"), .string("0x6869")]),
        origin: "https://dapp.example")
    }
    await #expect(throws: WalletError.notReady) {
      _ = try await svc.list()
    }
  }

  @Test("an absent registry fails registry-gated request handling closed")
  func absentRegistryFailsClosed() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let chainDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AdoptionMissingChain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: chainDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: chainDirectory) }
    let service = WalletService(
      store: PendingRequestStore(directory: env.directory),
      signing: StubSigner(account: account),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: ChainStore(directory: chainDirectory),
      networkStore: NetworkStore(directory: chainDirectory, legacySuiteName: UUID().uuidString),
      registryStore: WalletRegistryStore(directory: env.directory))

    await #expect(throws: WalletError.notReady) {
      try await service.activeChainID()
    }
  }

  @Test("an adopted service ignores and refuses an unsupported pending binding")
  func unsupportedBindingFailsClosed() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    try completeRegistry(in: env.directory, account: account)

    let id = UUID()
    let legacy = WalletPendingRequest(
      id: id,
      kind: .message,
      method: "personal_sign",
      origin: "https://dapp.example",
      chainId: "1",
      account: account,
      params: .array([.string("0x1234"), .string("0x6869")]),
      payloadDigest: "legacy-digest",
      createdAt: Date(),
      expiresAt: Date().addingTimeInterval(600)
    )
    let pendingStore = PendingRequestStore(directory: env.directory)
    try await pendingStore.insert(legacy)

    let chainDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AdoptionLegacyChain-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: chainDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: chainDirectory) }
    let svc = WalletService(
      store: pendingStore,
      signing: StubSigner(account: account),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: ChainStore(directory: chainDirectory),
      networkStore: NetworkStore(directory: chainDirectory, legacySuiteName: UUID().uuidString),
      registryStore: WalletRegistryStore(directory: env.directory))

    #expect(await svc.status(for: id) == nil)
    #expect(try await svc.list().isEmpty)
    await #expect(throws: WalletError.bindingMismatch) {
      try await svc.approve(request: id)
    }
    let recorded = try #require(try await svc.store.record(id))
    #expect(recorded.status == .pending)
  }

  @Test("an adopted service still approves canonical v2 records")
  func v2RecordApprovesUnderAdoption() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    try completeRegistry(in: env.directory, account: account)

    let chainDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AdoptionV2Chain-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: chainDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: chainDirectory) }
    let svc = WalletService(
      store: PendingRequestStore(directory: env.directory),
      signing: StubSigner(account: account),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: ChainStore(directory: chainDirectory),
      networkStore: NetworkStore(directory: chainDirectory, legacySuiteName: UUID().uuidString),
      registryStore: WalletRegistryStore(directory: env.directory))

    let id = try await svc.prepare(
      method: "personal_sign",
      params: .array([.string("0x1234"), .string("0x6869")]),
      origin: "https://dapp.example")
    let result = try await svc.approve(request: id)
    #expect(result.stringValue?.hasPrefix("0x") == true)
    #expect(await svc.status(for: id)?.status == "consumed")
  }

  @Test("an already adopted registry removes a downgrade-reintroduced fallback")
  func downgradeFallbackRemovedEveryEntry() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    try env.writeAddressFile(account)
    try completeRegistry(in: env.directory, account: account)
    // A downgraded build wrote the rebuild fallback after adoption completed.
    env.defaults().set(account, forKey: WalletFactory.walletAddressKey)

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]))
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .alreadyAdopted)
    #expect(env.defaults().string(forKey: WalletFactory.walletAddressKey) == nil)
  }

  @Test("a migrating registry with fallback already removed resumes to complete")
  func resumeWhenFallbackAlreadyRemoved() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let store = WalletRegistryStore(directory: env.directory)
    let createdAt = Date(timeIntervalSince1970: 1)
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [WalletAccount(address: account, derivationIndex: nil, createdAt: createdAt)],
      lifecycle: .active)
    try store.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: [group],
        homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: true))
    // Connection and cache were already adopted by the interrupted run.
    _ = try ConnectionStateStore(suiteName: env.suite, directory: env.directory).getOrCreate(
      ConnectionState(revision: 0, defaultAccount: account))
    try BalanceCache(directory: env.directory).save(balance: "1.000000", account: account)

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]))
    let result = try await adoption.ensureAdopted()
    #expect(result.kind == .adopted)
    #expect(result.registry?.adoptionState == .complete)
  }

  @Test("corrupt authoritative files fail adoption loudly")
  func corruptAuthorityFailsLoudly() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    try env.writeAddressFile(account)
    try completeRegistry(in: env.directory, account: account)
    try Data("not-json".utf8).write(
      to: env.directory.appendingPathComponent("connection-state.json"))

    let adoption = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]))
    // Adoption never treats corrupt shared state as empty; it fails loudly.
    await #expect(throws: ConnectionStateError.self) {
      try await adoption.ensureAdopted()
    }
  }

  @Test("concurrent adoption from independent stores converges to one complete registry")
  func concurrentAdoption() async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let backend = AdoptionFakeBackend(
      oldAddress: account, decryptResult: .success(secret(1)))

    let first = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]), migrationBackend: backend)
    let second = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]), migrationBackend: backend)

    async let firstResult = try first.ensureAdopted()
    async let secondResult = try second.ensureAdopted()
    let (a, b) = try await (firstResult, secondResult)
    let kinds = [a.kind, b.kind]
    #expect(kinds.contains(.adopted))
    #expect(kinds.contains(.alreadyAdopted))

    let final = try WalletRegistryStore(directory: env.directory).load()
    #expect(final?.adoptionState == .complete)
    #expect(final?.groups.count == 1)
    #expect(
      try ConnectionStateStore(suiteName: env.suite, directory: env.directory).load()?
        .defaultAccount?.caseInsensitiveCompare(account) == .orderedSame)
  }

  #if os(macOS)
    @Test("adoption coordination excludes a separate process")
    func crossProcessCoordination() async throws {
      let env = try AdoptionEnv.make()
      defer { try? FileManager.default.removeItem(at: env.directory) }
      let lockURL = env.directory.appendingPathComponent("wallet-registry-adoption.lock")
      let readyURL = env.directory.appendingPathComponent("coordinator-ready")
      let releaseURL = env.directory.appendingPathComponent("coordinator-release")
      let completedURL = env.directory.appendingPathComponent("adoption-completed")
      let sourceURL = env.directory.appendingPathComponent("CoordinatorHelper.swift")
      let executableURL = env.directory.appendingPathComponent("coordinator-helper")
      let source = """
        import Foundation

        let lockURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let readyURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let releaseURL = URL(fileURLWithPath: CommandLine.arguments[3])
        _ = FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: lockURL, options: [], error: &coordinationError) { _ in
          _ = FileManager.default.createFile(atPath: readyURL.path, contents: Data())
          while !FileManager.default.fileExists(atPath: releaseURL.path) {
            Thread.sleep(forTimeInterval: 0.01)
          }
        }
        if coordinationError != nil { exit(1) }
        """
      try Data(source.utf8).write(to: sourceURL)

      let compiler = Process()
      compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      compiler.arguments = ["swiftc", sourceURL.path, "-o", executableURL.path]
      compiler.standardOutput = Pipe()
      compiler.standardError = Pipe()
      try compiler.run()
      compiler.waitUntilExit()
      #expect(compiler.terminationStatus == 0)
      guard compiler.terminationStatus == 0 else { return }

      let child = Process()
      child.executableURL = executableURL
      child.arguments = [lockURL.path, readyURL.path, releaseURL.path]
      try child.run()
      defer {
        _ = FileManager.default.createFile(atPath: releaseURL.path, contents: Data())
        if child.isRunning { child.terminate() }
      }
      let deadline = Date().addingTimeInterval(5)
      while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(FileManager.default.fileExists(atPath: readyURL.path))

      let adoption = WalletRegistryAdoption(directory: env.directory, appGroup: env.suite)
      let adoptionTask = Task {
        let result = try await adoption.ensureAdopted()
        _ = FileManager.default.createFile(atPath: completedURL.path, contents: Data())
        return result
      }
      try await Task.sleep(for: .milliseconds(250))
      #expect(!FileManager.default.fileExists(atPath: completedURL.path))
      _ = FileManager.default.createFile(atPath: releaseURL.path, contents: Data())

      let result = try await adoptionTask.value
      #expect(result.kind == .noWallet)
      #expect(FileManager.default.fileExists(atPath: completedURL.path))
      child.waitUntilExit()
      #expect(child.terminationStatus == 0)
    }
  #endif

  @Test(
    "every adoption persistence interruption resumes to one complete state",
    arguments: [
      PersistenceFaultPoint.adoptionClaimBefore,
      .journalAfterWrite,
      .projectionBeforeWrite,
      .projectionAfterWrite,
      .registryBeforeWrite,
      .registryAfterWrite,
      .connectionBeforeWrite,
      .connectionAfterWrite,
      .fallbackBeforeRemove,
      .fallbackAfterRemove,
      .fallbackStateBeforeCommit,
      .completionStateBeforeCommit,
    ])
  func adoptionFaultRecovery(point: PersistenceFaultPoint) async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let account = try address(secret: 1)
    let backend = AdoptionFakeBackend(
      oldAddress: account, decryptResult: .success(secret(1)))
    let defaults = env.defaults()

    let interrupted = WalletRegistryAdoption(
      directory: env.directory,
      appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]),
      migrationBackend: backend,
      faultInjector: OneShotPersistenceFaultInjector(point))
    await #expect(throws: PersistenceFaultSimulationError.interruption(point)) {
      try await interrupted.ensureAdopted()
    }

    let recovered = WalletRegistryAdoption(
      directory: env.directory,
      appGroup: env.suite,
      probe: StubSecretProbe(addresses: [account]),
      migrationBackend: backend)
    let result = try await recovered.ensureAdopted()
    let registry = try #require(result.registry)
    #expect(registry.adoptionState == .complete)
    #expect(registry.legacyWalletAddressFallbackRemoved)
    #expect(registry.homeSelectedAddress == account)
    #expect(WalletStore.activeAddress(directory: env.directory) == account)
    #expect(defaults.string(forKey: WalletFactory.walletAddressKey) == nil)
    #expect(
      try ConnectionStateStore(directory: env.directory, suiteName: env.suite).load()?
        .defaultAccount == account)
    #expect(try BalanceCache(directory: env.directory).load() == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: env.directory.appendingPathComponent("wallet-registry-transition.json").path))
    #expect(try await recovered.ensureAdopted().kind == .alreadyAdopted)
  }

  @Test(
    "every empty bootstrap interruption resumes to ready setup state",
    arguments: [
      PersistenceFaultPoint.adoptionClaimBefore,
      .journalAfterWrite,
      .projectionBeforeWrite,
      .projectionAfterWrite,
      .registryBeforeWrite,
      .registryAfterWrite,
      .connectionBeforeWrite,
      .connectionAfterWrite,
      .fallbackBeforeRemove,
      .fallbackAfterRemove,
      .fallbackStateBeforeCommit,
      .completionStateBeforeCommit,
    ])
  func emptyBootstrapFaultRecovery(point: PersistenceFaultPoint) async throws {
    let env = try AdoptionEnv.make()
    defer { try? FileManager.default.removeItem(at: env.directory) }
    let interrupted = WalletRegistryAdoption(
      directory: env.directory,
      appGroup: env.suite,
      probe: StubSecretProbe(addresses: []),
      faultInjector: OneShotPersistenceFaultInjector(point))
    await #expect(throws: PersistenceFaultSimulationError.interruption(point)) {
      try await interrupted.ensureAdopted()
    }

    let recovered = WalletRegistryAdoption(
      directory: env.directory, appGroup: env.suite, probe: StubSecretProbe(addresses: []))
    let result = try await recovered.ensureAdopted()
    let registry = try #require(result.registry)
    #expect(registry.adoptionState == .complete)
    #expect(registry.groups.isEmpty)
    #expect(registry.homeSelectedAddress == nil)
    #expect(registry.legacyWalletAddressFallbackRemoved)
    #expect(
      try ConnectionStateStore(directory: env.directory, suiteName: env.suite).load()?.revision == 0
    )
    #expect(WalletStore.activeAddress(directory: env.directory) == nil)
  }

  private func completeRegistry(in directory: URL, account: String) throws {
    let store = WalletRegistryStore(directory: directory)
    let createdAt = Date(timeIntervalSince1970: 1)
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [WalletAccount(address: account, derivationIndex: nil, createdAt: createdAt)],
      lifecycle: .active)
    try store.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: [group],
        homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: false))
    _ = try store.update(expectedRevision: 0) { current in
      WalletRegistry(
        revision: 1, adoptionState: .migrating, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    _ = try store.update(expectedRevision: 1) { current in
      WalletRegistry(
        revision: 2, adoptionState: .complete, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }
    _ = try ConnectionStateStore(directory: directory, suiteName: nil).getOrCreate(
      ConnectionState(revision: 0, defaultAccount: account))
  }

  private func secret(_ byte: UInt8) -> [UInt8] {
    var s = [UInt8](repeating: 0, count: 32)
    s[31] = byte
    return s
  }

  private func address(secret value: UInt8) throws -> String {
    try EthereumKeypair.from(secret: secret(value)).address
  }
}
