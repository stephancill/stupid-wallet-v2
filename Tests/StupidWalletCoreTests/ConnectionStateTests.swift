import Foundation
import Testing

@testable import StupidWalletCore

struct ConnectionStateTests {
  @Test("connection state persists grants, active mappings, and default account")
  func persistence() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "conn-\(UUID().uuidString)"
    let firstA = try address(secret: 1)
    let secondA = try address(secret: 2)

    let store = ConnectionStateStore(suiteName: suite, directory: directory)
    _ = try store.getOrCreate(
      ConnectionState(
        revision: 0,
        defaultAccount: firstA,
        grants: [exact(account: firstA, origin: "https://dapp.example", profile: "profile-a")],
        activeConnections: [
          ActiveConnection(origin: "https://dapp.example", profileID: "profile-a", account: firstA)
        ]))

    _ = try store.update(expectedRevision: 0) { current in
      ConnectionState(
        revision: 1,
        defaultAccount: secondA,
        grants: current.grants
          + [exact(account: secondA, origin: "https://dapp.example", profile: "profile-a")],
        activeConnections: [
          ActiveConnection(
            origin: "https://dapp.example", profileID: "profile-a", account: secondA)
        ])
    }

    let reloaded = try ConnectionStateStore(suiteName: suite, directory: directory).load()
    #expect(try #require(reloaded).revision == 1)
    #expect(reloaded?.defaultAccount == secondA)
    #expect(reloaded?.activeConnections.count == 1)
  }

  @Test("empty state restarts at revision zero and getOrCreate is idempotent")
  func emptyThenUpdate() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "conn-\(UUID().uuidString)"
    let store = ConnectionStateStore(suiteName: suite, directory: directory)
    let empty = ConnectionState(revision: 0)
    let created = try store.getOrCreate(empty)
    #expect(try store.load() == created)
    let again = try store.getOrCreate(empty)
    #expect(again == created)
    #expect(again.revision == 0)
  }

  @Test("default account changes without changing active connections")
  func defaultAndActiveAreIndependent() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "conn-\(UUID().uuidString)"
    let first = try address(secret: 1)
    let second = try address(secret: 2)
    let store = ConnectionStateStore(suiteName: suite, directory: directory)
    _ = try store.getOrCreate(
      ConnectionState(
        revision: 0, defaultAccount: first,
        grants: [
          exact(account: first, origin: "https://dapp.example", profile: nil),
          exact(account: second, origin: "https://dapp.example", profile: nil),
        ],
        activeConnections: [
          ActiveConnection(origin: "https://dapp.example", profileID: nil, account: first)
        ]))

    let updated = try store.mutate { $0.defaultAccount = second }
    #expect(updated.defaultAccount == second)
    #expect(updated.activeConnections.map(\.account) == [first])
    #expect(updated.grants.count == 2)
  }

  @Test("active connection without a matching exact grant is rejected")
  func activeRequiresGrant() throws {
    let account = try address(secret: 1)
    #expect(throws: ConnectionStateError.invalid(.activeWithoutGrant)) {
      try ConnectionState(
        revision: 0,
        grants: [],
        activeConnections: [
          ActiveConnection(origin: "https://dapp.example", profileID: nil, account: account)
        ]
      ).validate()
    }
  }

  @Test("duplicate active per origin/profile is rejected")
  func duplicateActive() throws {
    let first = try address(secret: 1)
    let second = try address(secret: 2)
    #expect(throws: ConnectionStateError.invalid(.duplicateActive)) {
      try ConnectionState(
        revision: 0,
        grants: [
          exact(account: first, origin: "https://dapp.example", profile: nil),
          exact(account: second, origin: "https://dapp.example", profile: nil),
        ],
        activeConnections: [
          ActiveConnection(origin: "https://dapp.example", profileID: nil, account: first),
          ActiveConnection(origin: "https://dapp.example", profileID: nil, account: second),
        ]
      ).validate()
    }
  }

  @Test("exact grant requires matching normalized origin and lowercase domain")
  func exactGrantShape() throws {
    let account = try address(secret: 1)
    #expect(throws: ConnectionStateError.invalid(.invalidExactGrant)) {
      try ConnectionState(
        revision: 0,
        grants: [
          ConnectionGrant(
            account: account, origin: "Other", legacyDomain: account,
            profileID: nil, connectedAt: .now, precision: .exact)
        ]
      ).validate()
    }
  }

  @Test("legacy grant keeps hostname precision and rejects an origin")
  func legacyGrantShape() throws {
    let account = try address(secret: 1)
    #expect(throws: ConnectionStateError.invalid(.invalidLegacyGrant)) {
      try ConnectionState(
        revision: 0,
        grants: [
          ConnectionGrant(
            account: account, origin: "https://example.com", legacyDomain: "example.com",
            profileID: nil, connectedAt: .now, precision: .hostname)
        ]
      ).validate()
    }
    try ConnectionState(
      revision: 0,
      grants: [
        ConnectionGrant(
          account: account, origin: nil, legacyDomain: "example.com",
          profileID: nil, connectedAt: .now, precision: .hostname)
      ]
    ).validate()
  }

  @Test("non-canonical addresses and malformed defaults are rejected")
  func addressValidation() throws {
    let canonical = try address(secret: 1)
    #expect(throws: ConnectionStateError.invalid(.invalidAddress)) {
      try ConnectionState(
        revision: 0,
        grants: [
          ConnectionGrant(
            account: canonical.lowercased(), origin: nil, legacyDomain: "example.com",
            profileID: nil, connectedAt: .now, precision: .hostname)
        ]
      ).validate()
    }
    #expect(throws: ConnectionStateError.invalid(.invalidDefault)) {
      try ConnectionState(revision: 0, defaultAccount: "0x12345").validate()
    }
  }

  @Test("connect commits reject duplicate request IDs")
  func commitIdentity() throws {
    let account = try address(secret: 1)
    let origin = "https://dapp.example"
    let requestID = UUID()
    let commit = ConnectCommit(
      requestID: requestID, requestRevision: 0, connectionRevision: 1,
      origin: origin, profileID: nil, account: account,
      bindingDigest: String(repeating: "a", count: 64),
      result: .array([.string(account)]), committedAt: .now)
    #expect(throws: ConnectionStateError.invalid(.duplicateCommit)) {
      try ConnectionState(
        revision: 1, defaultAccount: account,
        grants: [exact(account: account, origin: origin, profile: nil)],
        activeConnections: [ActiveConnection(origin: origin, profileID: nil, account: account)],
        connectCommits: [commit, commit]
      ).validate()
    }
  }

  @Test("connect commits require a canonical result, digest, revision, and matching commit state")
  func commitValidation() throws {
    let account = try address(secret: 1)
    let origin = "https://dapp.example"
    let grant = exact(account: account, origin: origin, profile: nil)
    let active = ActiveConnection(origin: origin, profileID: nil, account: account)
    let base = ConnectCommit(
      requestID: UUID(), requestRevision: 0, connectionRevision: 1,
      origin: origin, profileID: nil, account: account,
      bindingDigest: String(repeating: "a", count: 64),
      result: .array([.string(account)]), committedAt: .now)

    try ConnectionState(
      revision: 1, defaultAccount: account, grants: [grant], activeConnections: [active],
      connectCommits: [base]
    ).validate()
    #expect(throws: ConnectionStateError.invalid(.invalidCommit)) {
      try ConnectionState(revision: 0, connectCommits: [base]).validate()
    }
    let badResult = ConnectCommit(
      requestID: base.requestID, requestRevision: 0, connectionRevision: 1,
      origin: origin, profileID: nil, account: account,
      bindingDigest: base.bindingDigest, result: .array([]), committedAt: .now)
    #expect(throws: ConnectionStateError.invalid(.invalidCommit)) {
      try ConnectionState(
        revision: 1, defaultAccount: account, grants: [grant], activeConnections: [active],
        connectCommits: [badResult]
      ).validate()
    }
    #expect(throws: ConnectionStateError.invalid(.invalidCommit)) {
      try ConnectionState(revision: 1, connectCommits: [base]).validate()
    }
  }

  @Test("Dawn hostname grants migrate without changing account or precision")
  func dawnMigration() throws {
    let suite = "conn-migrate-\(UUID().uuidString)"
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConnectionStateStore(suiteName: suite, directory: directory)
    let defaults = UserDefaults(suiteName: suite) ?? .standard

    let legacyAccount = try address(secret: 2)
    defaults.set(
      ["legacy.example": ["address": legacyAccount, "connectedAt": "2026-01-02T00:00:00Z"]],
      forKey: "connectedSites")

    let state = try store.initialMigratedState(defaultAccount: legacyAccount)
    let legacy = try #require(state.grants.first)
    #expect(legacy.precision == .hostname)
    #expect(legacy.account == legacyAccount)
    #expect(legacy.legacyDomain == "legacy.example")
    #expect(state.activeConnections.isEmpty)
    #expect(state.defaultAccount == legacyAccount)
  }

  @Test("current-rebuild normalized grants are ignored, including malformed values")
  func currentRebuildGrantsIgnored() throws {
    let suite = "conn-ignore-v2-\(UUID().uuidString)"
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConnectionStateStore(suiteName: suite, directory: directory)
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let account = try address(secret: 1)
    defaults.set(Data("not-json".utf8), forKey: "connectedOriginsV2")

    let state = try store.initialMigratedState(defaultAccount: account)
    #expect(state.grants.isEmpty)
    #expect(state.activeConnections.isEmpty)
    #expect(state.defaultAccount == account)
  }

  @Test("corrupt Dawn migration source fails closed")
  func corruptMigrationSources() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let legacySuite = "conn-corrupt-legacy-\(UUID().uuidString)"
    let legacyStore = ConnectionStateStore(suiteName: legacySuite, directory: directory)
    UserDefaults(suiteName: legacySuite)?.set(
      ["dapp.example": ["connectedAt": "not-a-date"]], forKey: "connectedSites")
    #expect(throws: ConnectionStateError.corrupt) {
      try legacyStore.initialMigratedState()
    }
  }

  @Test("legacy mirror reflects authoritative grants after a write")
  func legacyMirror() throws {
    let suite = "conn-mirror-\(UUID().uuidString)"
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = try address(secret: 1)
    let store = ConnectionStateStore(suiteName: suite, directory: directory)
    _ = try store.getOrCreate(
      ConnectionState(
        revision: 0,
        grants: [exact(account: account, origin: "https://dapp.example", profile: nil)]))

    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let dict = defaults.dictionary(forKey: "connectedSites") as? [String: [String: Any]]
    #expect(dict?["dapp.example"]?["address"] as? String == account)
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
    let suite = "conn-concurrent-\(UUID().uuidString)"
    let account = try address(secret: 1)
    let first = ConnectionStateStore(suiteName: suite, directory: directory)
    let second = ConnectionStateStore(suiteName: suite, directory: directory)
    _ = try first.getOrCreate(
      ConnectionState(
        revision: 0,
        grants: [exact(account: account, origin: "https://dapp.example", profile: nil)]))

    let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
      for store in [first, second] {
        group.addTask {
          do {
            _ = try store.update(expectedRevision: 0) { current in
              ConnectionState(
                revision: 1, defaultAccount: current.defaultAccount, grants: current.grants)
            }
            return .success
          } catch ConnectionStateError.staleRevision(expected: 0, actual: 1) {
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

  @Test(
    "connection writes are atomic across failures and interruptions",
    arguments: [
      (PersistenceFaultPoint.connectionBeforeWrite, false),
      (PersistenceFaultPoint.connectionAfterWrite, true),
    ])
  func faultedWrites(point: PersistenceFaultPoint, commits: Bool) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "conn-fault-\(UUID().uuidString)"
    let account = try address(secret: 1)
    let initialStore = ConnectionStateStore(directory: directory, suiteName: suite)
    let initial = try initialStore.getOrCreate(
      ConnectionState(
        revision: 0,
        grants: [exact(account: account, origin: "https://dapp.example", profile: nil)]))
    let interruptedStore = ConnectionStateStore(
      directory: directory,
      suiteName: suite,
      faultInjector: OneShotPersistenceFaultInjector(point))

    #expect(throws: PersistenceFaultSimulationError.interruption(point)) {
      try interruptedStore.update(expectedRevision: 0) { current in
        ConnectionState(
          revision: 1, defaultAccount: account, grants: current.grants,
          activeConnections: [
            ActiveConnection(origin: "https://dapp.example", profileID: nil, account: account)
          ])
      }
    }

    let recovered = try #require(try initialStore.load())
    if commits {
      #expect(recovered.revision == 1)
      #expect(recovered.defaultAccount == account)
      #expect(recovered.activeConnections.count == 1)
      #expect(throws: ConnectionStateError.staleRevision(expected: 0, actual: 1)) {
        try initialStore.update(expectedRevision: 0) { $0 }
      }
    } else {
      #expect(recovered == initial)
    }
  }

  private func exact(account: String, origin: String, profile: String?) -> ConnectionGrant {
    ConnectionGrant(
      account: account,
      origin: origin,
      legacyDomain: Origin.downHost(of: origin).lowercased(),
      profileID: profile,
      connectedAt: Date(timeIntervalSince1970: 1),
      precision: .exact)
  }

  private func address(secret value: UInt8) throws -> String {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = value
    return try EthereumKeypair.from(secret: secret).address
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConnectionStateTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
