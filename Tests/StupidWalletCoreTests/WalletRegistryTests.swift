import Foundation
import Testing

@testable import StupidWalletCore

struct WalletRegistryTests {
  @Test("private-key and seed groups persist with separate home selection")
  func persistence() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)
    let privateGroup = privateKeyGroup(address: firstAddress)
    let migrating = WalletRegistry(
      revision: 0,
      adoptionState: .migrating,
      groups: [privateGroup],
      homeSelectedAddress: firstAddress,
      legacyWalletAddressFallbackRemoved: false)

    let store = WalletRegistryStore(directory: directory)
    try store.create(migrating)
    #expect(throws: WalletRegistryError.adoptionIncomplete) {
      try store.loadReady()
    }
    #expect(WalletStore.activeAddress(directory: directory) == firstAddress)

    _ = try store.update(expectedRevision: 0) { current in
      WalletRegistry(
        revision: 1, adoptionState: .migrating, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    let complete = try store.update(expectedRevision: 1) { current in
      WalletRegistry(
        revision: 2, adoptionState: .complete, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }
    let seed = seedGroup(addresses: [secondAddress])
    let registry = try store.update(expectedRevision: 2) { current in
      WalletRegistry(
        revision: 3, adoptionState: current.adoptionState, groups: current.groups + [seed],
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }

    #expect(try store.load() == registry)
    #expect(try store.loadReady() == registry)
    #expect(try WalletRegistryStore(directory: directory).load() == registry)
    #expect(complete.revision == 2)

    try Data("stale\n".utf8).write(
      to: directory.appendingPathComponent("wallet-address.conf"))
    _ = try store.load()
    #expect(WalletStore.activeAddress(directory: directory) == firstAddress)
  }

  @Test("registry validation enforces private-key and seed group shapes")
  func groupValidation() throws {
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)
    let now = Date(timeIntervalSince1970: 1)

    #expect(throws: WalletRegistryError.invalid(.invalidPrivateKeyGroup)) {
      try registry(
        groups: [
          WalletGroup(
            id: UUID(), kind: .privateKey, createdAt: now, nextDerivationIndex: nil,
            accounts: [
              WalletAccount(address: firstAddress, derivationIndex: nil, createdAt: now),
              WalletAccount(address: secondAddress, derivationIndex: nil, createdAt: now),
            ], lifecycle: .active)
        ], home: firstAddress
      ).validate()
    }

    #expect(throws: WalletRegistryError.invalid(.invalidSeedDerivationOrder)) {
      try registry(
        groups: [seedGroup(addresses: [firstAddress, secondAddress], indexes: [1, 0])],
        home: firstAddress
      ).validate()
    }

    #expect(throws: WalletRegistryError.invalid(.invalidNextDerivationIndex)) {
      try registry(
        groups: [seedGroup(addresses: [firstAddress], indexes: [1], nextIndex: 1)],
        home: firstAddress
      ).validate()
    }

    var finalAccountDeleting = seedGroup(addresses: [firstAddress])
    finalAccountDeleting.accounts[0].lifecycle = .deleting
    #expect(throws: WalletRegistryError.invalid(.invalidSeedGroup)) {
      try registry(groups: [finalAccountDeleting], home: nil).validate()
    }
  }

  @Test("registry rejects malformed, duplicate, and noncanonical addresses")
  func addressValidation() throws {
    let canonical = try address(secret: 1)
    let duplicate = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: Date(timeIntervalSince1970: 1),
      nextDerivationIndex: nil,
      accounts: [WalletAccount(address: canonical, derivationIndex: nil, createdAt: .now)],
      lifecycle: .active)

    #expect(throws: WalletRegistryError.invalid(.duplicateAddress)) {
      try registry(
        groups: [privateKeyGroup(address: canonical), duplicate], home: canonical
      ).validate()
    }

    #expect(throws: WalletRegistryError.invalid(.invalidAddress)) {
      try registry(
        groups: [privateKeyGroup(address: canonical.lowercased())], home: nil
      ).validate()
    }
  }

  @Test("home selection must resolve to an active group")
  func homeSelection() throws {
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)
    var deleting = privateKeyGroup(address: firstAddress)
    deleting.lifecycle = .deleting

    #expect(throws: WalletRegistryError.invalid(.invalidHomeSelection)) {
      try registry(groups: [deleting], home: firstAddress).validate()
    }
    #expect(throws: WalletRegistryError.invalid(.invalidHomeSelection)) {
      try registry(groups: [privateKeyGroup(address: firstAddress)], home: secondAddress)
        .validate()
    }
  }

  @Test("legacy fallback blocks complete and multi-account registries")
  func fallbackBarrier() throws {
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)

    #expect(throws: WalletRegistryError.invalid(.legacyFallbackStillEnabled)) {
      try WalletRegistry(
        revision: 0, adoptionState: .complete,
        groups: [privateKeyGroup(address: firstAddress)], homeSelectedAddress: firstAddress,
        legacyWalletAddressFallbackRemoved: false
      ).validate()
    }
    #expect(throws: WalletRegistryError.invalid(.legacyFallbackStillEnabled)) {
      try WalletRegistry(
        revision: 0, adoptionState: .migrating,
        groups: [
          privateKeyGroup(address: firstAddress), privateKeyGroup(address: secondAddress),
        ], homeSelectedAddress: firstAddress, legacyWalletAddressFallbackRemoved: false
      ).validate()
    }

    try WalletRegistry(
      revision: 0, adoptionState: .migrating,
      groups: [privateKeyGroup(address: firstAddress)], homeSelectedAddress: firstAddress,
      legacyWalletAddressFallbackRemoved: false
    ).validate()
  }

  @Test("unknown schemas and corrupt files fail loudly")
  func corruptPersistence() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WalletRegistryStore(directory: directory)
    #expect(try store.load() == nil)

    let unsupported = WalletRegistry(
      schemaVersion: 3, revision: 0, adoptionState: .complete, groups: [],
      homeSelectedAddress: nil, legacyWalletAddressFallbackRemoved: true)
    #expect(throws: WalletRegistryError.unsupportedSchemaVersion(3)) {
      try store.create(unsupported)
    }

    try Data("not-json".utf8).write(
      to: directory.appendingPathComponent("wallet-registry.json"))
    #expect(throws: WalletRegistryError.corrupt) {
      try store.load()
    }
  }

  @Test("schema one migrates labels and seed identity in one revision")
  func migratesSchemaOne() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "revision": 7,
      "adoptionState": "complete",
      "groups": [
        [
          "id": UUID().uuidString,
          "kind": "seed",
          "createdAt": 1_000,
          "nextDerivationIndex": 2,
          "accounts": [
            ["address": firstAddress, "derivationIndex": 0, "createdAt": 1_000],
            ["address": secondAddress, "derivationIndex": 1, "createdAt": 1_000],
          ],
          "lifecycle": "active",
        ]
      ],
      "homeSelectedAddress": firstAddress,
      "legacyWalletAddressFallbackRemoved": true,
    ]
    try JSONSerialization.data(withJSONObject: payload).write(
      to: directory.appendingPathComponent("wallet-registry.json"))

    let migrated = try #require(try WalletRegistryStore(directory: directory).loadReady())

    #expect(migrated.schemaVersion == WalletRegistry.currentSchemaVersion)
    #expect(migrated.revision == 8)
    #expect(migrated.groups[0].label == "Wallet 1")
    #expect(migrated.groups[0].seedIdentityAddress == firstAddress)
    #expect(migrated.groups[0].accounts.map(\.label) == ["Account 1", "Account 2"])
    #expect(migrated.groups[0].accounts.allSatisfy { $0.lifecycle == .active })
  }

  @Test("schema two requires explicit labels and account lifecycle")
  func schemaTwoRequiresNewFields() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let address = try address(secret: 1)
    let store = WalletRegistryStore(directory: directory)
    try store.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating,
        groups: [privateKeyGroup(address: address)], homeSelectedAddress: address,
        legacyWalletAddressFallbackRemoved: false))
    let file = directory.appendingPathComponent("wallet-registry.json")
    var root = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var groups = try #require(root["groups"] as? [[String: Any]])
    var accounts = try #require(groups[0]["accounts"] as? [[String: Any]])
    accounts[0].removeValue(forKey: "lifecycle")
    groups[0]["accounts"] = accounts
    root["groups"] = groups
    try JSONSerialization.data(withJSONObject: root).write(to: file)

    #expect(throws: WalletRegistryError.corrupt) {
      try store.load()
    }
  }

  @Test("updates require one monotonic revision and release the lock after failure")
  func revisionAndLockRelease() throws {
    enum TestError: Error { case stop }

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WalletRegistryStore(directory: directory)
    let address = try address(secret: 1)
    try store.create(migratingRegistry(address: address))

    #expect(throws: TestError.stop) {
      try store.update(expectedRevision: 0) { _ in throw TestError.stop }
    }
    #expect(throws: WalletRegistryError.invalidRevision) {
      try store.update(expectedRevision: 0) { $0 }
    }

    let updated = try store.update(expectedRevision: 0) { current in
      WalletRegistry(
        revision: 1, adoptionState: .migrating, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    #expect(updated.revision == 1)
    #expect(try store.load()?.revision == 1)
  }

  @Test("independent stores serialize revision-checked updates")
  func concurrentUpdates() async throws {
    enum Outcome: Sendable, Equatable {
      case success
      case stale
      case unexpected
    }

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let address = try address(secret: 1)
    let first = WalletRegistryStore(directory: directory)
    let second = WalletRegistryStore(directory: directory)
    try first.create(migratingRegistry(address: address))

    let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
      for store in [first, second] {
        group.addTask {
          do {
            try store.update(expectedRevision: 0) { current in
              WalletRegistry(
                revision: 1, adoptionState: .migrating, groups: current.groups,
                homeSelectedAddress: current.homeSelectedAddress,
                legacyWalletAddressFallbackRemoved: true)
            }
            return .success
          } catch WalletRegistryError.staleRevision(expected: 0, actual: 1) {
            return .stale
          } catch {
            return .unexpected
          }
        }
      }
      var values: [Outcome] = []
      for await value in group { values.append(value) }
      return values
    }

    #expect(outcomes.filter({ $0 == .success }).count == 1)
    #expect(outcomes.filter({ $0 == .stale }).count == 1)
    #expect(!outcomes.contains(.unexpected))
    #expect(try first.load()?.revision == 1)
  }

  @Test("an interrupted transition commits projection and registry forward")
  func transitionRecovery() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)
    let store = WalletRegistryStore(directory: directory)
    try store.create(migratingRegistry(address: firstAddress))
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
    let seed = seedGroup(addresses: [secondAddress])
    let withSeed = try store.update(expectedRevision: 2) { current in
      WalletRegistry(
        revision: 3, adoptionState: current.adoptionState, groups: current.groups + [seed],
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }
    let selectedSeed = WalletRegistry(
      revision: 4, adoptionState: .complete, groups: withSeed.groups,
      homeSelectedAddress: secondAddress, legacyWalletAddressFallbackRemoved: true)
    let transition = WalletRegistryTransition(
      previousRegistry: .present(withSeed), nextRegistry: selectedSeed,
      previousProjection: .present(Data("\(firstAddress)\n".utf8)),
      intendedProjection: .absent)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(transition).write(
      to: directory.appendingPathComponent("wallet-registry-transition.json"))

    #expect(try store.load() == selectedSeed)
    #expect(WalletStore.activeAddress(directory: directory) == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("wallet-registry-transition.json").path))
  }

  @Test(
    "actual registry commit interruptions recover forward",
    arguments: [
      PersistenceFaultPoint.journalAfterWrite,
      .projectionBeforeWrite,
      .projectionAfterWrite,
      .registryBeforeWrite,
      .registryAfterWrite,
    ])
  func injectedTransitionRecovery(point: PersistenceFaultPoint) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let address = try address(secret: 1)
    let initialStore = WalletRegistryStore(directory: directory)
    try initialStore.create(migratingRegistry(address: address))
    let interruptedStore = WalletRegistryStore(
      directory: directory,
      faultInjector: OneShotPersistenceFaultInjector(point))

    #expect(throws: PersistenceFaultSimulationError.interruption(point)) {
      try interruptedStore.update(expectedRevision: 0) { current in
        WalletRegistry(
          revision: 1, adoptionState: .migrating, groups: current.groups,
          homeSelectedAddress: current.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: true)
      }
    }

    let recovered = try #require(try WalletRegistryStore(directory: directory).load())
    #expect(recovered.revision == 1)
    #expect(recovered.legacyWalletAddressFallbackRemoved)
    #expect(WalletStore.activeAddress(directory: directory) == address)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("wallet-registry-transition.json").path))
  }

  @Test("an ordinary projection failure restores the previous authority")
  func projectionFailureRollsBack() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let address = try address(secret: 1)
    let initialStore = WalletRegistryStore(directory: directory)
    let initial = migratingRegistry(address: address)
    try initialStore.create(initial)
    let failedStore = WalletRegistryStore(
      directory: directory,
      faultInjector: OneShotPersistenceFaultInjector(.projectionBeforeWrite, outcome: .failure))

    #expect(throws: PersistenceFaultSimulationError.failure(.projectionBeforeWrite)) {
      try failedStore.update(expectedRevision: 0) { current in
        WalletRegistry(
          revision: 1, adoptionState: .migrating, groups: current.groups,
          homeSelectedAddress: current.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: true)
      }
    }
    #expect(try initialStore.load() == initial)
    #expect(WalletStore.activeAddress(directory: directory) == address)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("wallet-registry-transition.json").path))
  }

  #if os(macOS)
    @Test("registry advisory lock excludes a separate process")
    func crossProcessLockExclusion() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let lockURL = directory.appendingPathComponent("wallet-registry.lock")
      let child = Process()
      let output = Pipe()
      let input = Pipe()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      child.arguments = [
        "-c",
        "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.buffer.read(1)",
        lockURL.path,
      ]
      child.standardOutput = output
      child.standardInput = input
      try child.run()
      let handshake = output.fileHandleForReading.readData(ofLength: 7)
      #expect(String(decoding: handshake, as: UTF8.self) == "locked\n")

      let completion = DispatchSemaphore(value: 0)
      let worker = Thread {
        do {
          _ = try WalletRegistryStore(directory: directory).load()
        } catch {
          Issue.record(error)
        }
        completion.signal()
      }
      worker.start()
      #expect(completion.wait(timeout: .now() + 0.2) == .timedOut)
      try input.fileHandleForWriting.write(contentsOf: Data([0x01]))
      input.fileHandleForWriting.closeFile()
      #expect(completion.wait(timeout: .now() + 2) == .success)
      child.waitUntilExit()
      #expect(child.terminationStatus == 0)
    }
  #endif

  @Test("registry transitions cannot regress monotonic state")
  func monotonicTransitions() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)
    let store = WalletRegistryStore(directory: directory)
    try store.create(migratingRegistry(address: firstAddress))

    #expect(throws: WalletRegistryError.invalidTransition) {
      try store.update(expectedRevision: 0) { current in
        WalletRegistry(
          revision: 1, adoptionState: .migrating,
          groups: current.groups + [privateKeyGroup(address: secondAddress)],
          homeSelectedAddress: current.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: true)
      }
    }

    #expect(throws: WalletRegistryError.invalidTransition) {
      try store.update(expectedRevision: 0) { current in
        WalletRegistry(
          revision: 1, adoptionState: .complete, groups: current.groups,
          homeSelectedAddress: current.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: true)
      }
    }

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
    #expect(throws: WalletRegistryError.invalidTransition) {
      try store.update(expectedRevision: 2) { current in
        WalletRegistry(
          revision: 3, adoptionState: .migrating, groups: current.groups,
          homeSelectedAddress: current.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: true)
      }
    }

    let seed = seedGroup(addresses: [secondAddress])
    let withSeed = try store.update(expectedRevision: 2) { current in
      WalletRegistry(
        revision: 3, adoptionState: current.adoptionState, groups: current.groups + [seed],
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }
    #expect(throws: WalletRegistryError.invalidTransition) {
      try store.update(expectedRevision: 3) { current in
        var groups = current.groups
        groups[1].nextDerivationIndex = 5
        return WalletRegistry(
          revision: 4, adoptionState: current.adoptionState, groups: groups,
          homeSelectedAddress: current.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
      }
    }
    #expect(withSeed.revision == 3)
  }

  @Test("recovery rejects a journal whose projection does not match its registry")
  func inconsistentJournal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let address = try address(secret: 1)
    let store = WalletRegistryStore(directory: directory)
    try store.create(migratingRegistry(address: address))
    let current = try #require(try store.load())
    let next = WalletRegistry(
      revision: 1, adoptionState: .migrating, groups: current.groups,
      homeSelectedAddress: current.homeSelectedAddress,
      legacyWalletAddressFallbackRemoved: true)
    let transition = WalletRegistryTransition(
      previousRegistry: .present(current), nextRegistry: next,
      previousProjection: .present(Data("\(address)\n".utf8)),
      intendedProjection: .present(Data("wrong\n".utf8)))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(transition).write(
      to: directory.appendingPathComponent("wallet-registry-transition.json"))

    #expect(throws: WalletRegistryError.corrupt) {
      try store.load()
    }
  }

  @Test("new registry values are normalized to persisted date precision")
  func dateNormalization() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAddress = try address(secret: 1)
    let secondAddress = try address(secret: 2)
    let store = WalletRegistryStore(directory: directory)
    try store.create(migratingRegistry(address: firstAddress))
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

    let createdAt = Date()
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [
        WalletAccount(address: secondAddress, derivationIndex: nil, createdAt: createdAt)
      ], lifecycle: .active)
    let updated = try store.update(expectedRevision: 2) { current in
      WalletRegistry(
        revision: 3, adoptionState: current.adoptionState, groups: current.groups + [group],
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }

    #expect(try store.load() == updated)
  }

  private func registry(
    groups: [WalletGroup],
    home: String?,
    revision: UInt64 = 0
  ) -> WalletRegistry {
    WalletRegistry(
      revision: revision, adoptionState: .complete, groups: groups,
      homeSelectedAddress: home, legacyWalletAddressFallbackRemoved: true)
  }

  private func privateKeyGroup(address: String) -> WalletGroup {
    let createdAt = Date(timeIntervalSince1970: 1)
    return WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
      accounts: [WalletAccount(address: address, derivationIndex: nil, createdAt: createdAt)],
      lifecycle: .active)
  }

  private func migratingRegistry(address: String) -> WalletRegistry {
    WalletRegistry(
      revision: 0, adoptionState: .migrating,
      groups: [privateKeyGroup(address: address)], homeSelectedAddress: address,
      legacyWalletAddressFallbackRemoved: false)
  }

  private func seedGroup(
    addresses: [String],
    indexes: [UInt32]? = nil,
    nextIndex: UInt32? = nil
  ) -> WalletGroup {
    let createdAt = Date(timeIntervalSince1970: 1)
    let indexes = indexes ?? Array(0..<UInt32(addresses.count))
    return WalletGroup(
      id: UUID(), kind: .seed, createdAt: createdAt,
      nextDerivationIndex: nextIndex ?? UInt32(addresses.count),
      accounts: zip(addresses, indexes).map {
        WalletAccount(address: $0.0, derivationIndex: $0.1, createdAt: createdAt)
      }, lifecycle: .active)
  }

  private func address(secret value: UInt8) throws -> String {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = value
    return try EthereumKeypair.from(secret: secret).address
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WalletRegistryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
