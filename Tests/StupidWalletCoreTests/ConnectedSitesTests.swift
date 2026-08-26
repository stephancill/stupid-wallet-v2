import Foundation
import Testing

@testable import StupidWalletCore

/// Hermetic tests for the durable connection-grant store: legacy App Group key shape,
/// idempotent connect/disconnect, and grant persistence across connect approvals.
struct ConnectedSitesTests {
  private static func tmpStore() -> PendingRequestStore {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ConnectedSitesTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return PendingRequestStore(directory: dir)
  }

  private func svc(_ suite: String) -> WalletService {
    WalletService(store: Self.tmpStore(), signing: StubSigner(), grantsSuite: suite)
  }

  @Test("multiple accounts retain grants while one remains active")
  func connectGrant() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    let first = try address(secret: 1)
    let second = try address(secret: 2)
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example",
        address: first,
        origin: "https://dapp.example",
        profileID: "profile-a"))
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example", address: second, origin: "https://dapp.example",
        profileID: "profile-a"))

    let sites = try await store.all()
    #expect(sites.count == 2)
    #expect(Set(sites.map(\.address)) == [first, second])
    #expect(
      try await store.isConnected(
        origin: "https://dapp.example", address: second, profileID: "profile-a"))
    #expect(
      !(try await store.isConnected(
        origin: "https://dapp.example", address: first, profileID: "profile-a")))
    #expect(
      !(try await store.hasExactGrant(
        origin: "https://dapp.example", address: first, profileID: "profile-a")))
    #expect(
      try await store.hasExactGrant(
        origin: "https://dapp.example", address: second, profileID: "profile-a"))
  }

  @Test("legacy hostname grant remains authorized until a normalized reconnect")
  func legacyGrantCompatibility() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    let account = try address(secret: 1)
    try await store.connect(site: ConnectedSite(domain: "legacy.example", address: account))

    #expect(
      try await store.isConnected(
        origin: "http://legacy.example:8080", address: account, profileID: "profile-a"))
  }

  @Test("visible account is resolved from one origin and profile snapshot")
  func visibleAccountSnapshot() async throws {
    let store = ConnectedSitesStore(suiteName: "grants-\(UUID().uuidString)")
    let first = try address(secret: 1)
    let second = try address(secret: 2)
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example", address: first, origin: "https://dapp.example",
        profileID: "profile-a"))
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example", address: second, origin: "https://dapp.example",
        profileID: "profile-b"))

    #expect(
      try await store.visibleAccount(origin: "https://dapp.example", profileID: "profile-a")
        == first)
    #expect(
      try await store.visibleAccount(origin: "https://dapp.example", profileID: "profile-b")
        == second)
    #expect(
      try await store.visibleAccount(origin: "https://dapp.example", profileID: nil) == nil)
  }

  @Test("disconnect removes only the selected account grant")
  func disconnectRemoves() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    let first = try address(secret: 1)
    let second = try address(secret: 2)
    for account in [first, second] {
      try await store.connect(
        site: ConnectedSite(
          domain: "dapp.example", address: account, origin: "https://dapp.example"))
    }
    try await store.disconnect(account: first, origin: "https://dapp.example")
    let sites = try await store.all()
    #expect(sites.map(\.address) == [second])
    #expect(try await store.isConnected(origin: "https://dapp.example", address: second))
  }

  @Test("exact disconnect preserves a retained hostname grant")
  func exactDisconnectPreservesLegacy() async throws {
    let store = ConnectedSitesStore(suiteName: "grants-\(UUID().uuidString)")
    let account = try address(secret: 1)
    try await store.connect(site: ConnectedSite(domain: "dapp.example", address: account))
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example", address: account, origin: "https://dapp.example"))

    try await store.disconnect(
      site: ConnectedSite(
        domain: "dapp.example", address: account, origin: "https://dapp.example"))

    let remaining = try await store.grants(account: account)
    #expect(remaining.count == 1)
    #expect(remaining.first?.origin == nil)
    #expect(
      try await store.isConnected(
        origin: "http://dapp.example:8080", address: account, profileID: "profile-a"))
  }

  @Test("provider disconnect also revokes the effective hostname fallback")
  func providerDisconnectRevokesLegacyFallback() async throws {
    let store = ConnectedSitesStore(suiteName: "grants-\(UUID().uuidString)")
    let account = try address(secret: 1)
    try await store.connect(site: ConnectedSite(domain: "dapp.example", address: account))
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example", address: account, origin: "https://dapp.example"))

    try await store.disconnect(account: account, origin: "https://dapp.example")

    #expect(try await store.grants(account: account).isEmpty)
    #expect(
      !(try await store.isConnected(
        origin: "https://dapp.example", address: account, profileID: nil)))
  }

  @Test("forgetting an account revokes only that account's grants")
  func disconnectAllForAccount() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    let first = try address(secret: 1)
    let second = try address(secret: 2)
    try await store.connect(
      site: ConnectedSite(
        domain: "a.example", address: first, origin: "https://a.example"))
    try await store.connect(site: ConnectedSite(domain: "legacy.example", address: first))
    try await store.connect(
      site: ConnectedSite(
        domain: "b.example", address: second, origin: "https://b.example"))

    try await store.disconnectAll(account: first)

    let sites = try await store.all()
    #expect(sites.map(\.domain) == ["b.example"])
  }

  @Test("repeat connect refreshes instead of duplicating")
  func reconnectRefreshes() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    let account = try address(secret: 1)
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example", address: account, connectedAt: .distantPast,
        origin: "https://dapp.example"))
    try await store.connect(
      site: ConnectedSite(
        domain: "dapp.example", address: account, origin: "https://dapp.example"))
    let sites = try await store.all()
    #expect(sites.count == 1)
    #expect(sites.first?.connectedAt ?? .distantPast > .distantPast)
  }

  @Test("independent stores preserve concurrent grant updates")
  func concurrentGrantUpdates() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConnectedSitesTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try ConnectionStateStore(directory: directory, suiteName: suite)
      .getOrCreate(ConnectionState(revision: 0))
    let firstStore = ConnectedSitesStore(suiteName: suite, directory: directory)
    let secondStore = ConnectedSitesStore(suiteName: suite, directory: directory)
    let first = try address(secret: 1)
    let second = try address(secret: 2)

    async let firstWrite: Void = firstStore.connect(
      site: ConnectedSite(
        domain: "one.example", address: first, origin: "https://one.example"))
    async let secondWrite: Void = secondStore.connect(
      site: ConnectedSite(
        domain: "two.example", address: second, origin: "https://two.example"))
    _ = try await (firstWrite, secondWrite)

    let sites = try await firstStore.all()
    #expect(Set(sites.map(\.address)) == [first, second])
    #expect(Set(sites.map(\.domain)) == ["one.example", "two.example"])
  }

  #if os(macOS)
    @Test("a separate-process grant update is retained by the next mutation")
    func crossProcessGrantUpdate() async throws {
      let suite = "grants-\(UUID().uuidString)"
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ConnectedSitesTests-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      _ = try ConnectionStateStore(directory: directory, suiteName: suite)
        .getOrCreate(ConnectionState(revision: 0))
      let first = try address(secret: 1)
      let second = try address(secret: 2)
      let child = Process()
      let output = Pipe()
      let input = Pipe()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      child.arguments = [
        "-c",
        """
        import fcntl,json,os,sys,tempfile
        lock=open(sys.argv[1],'a+'); fcntl.flock(lock,fcntl.LOCK_EX)
        with open(sys.argv[2]) as source: state=json.load(source)
        state['revision'] += 1
        state['grants'].append({'account':sys.argv[3],'legacyDomain':'one.example','connectedAt':1000,'precision':'hostname'})
        fd,temp=tempfile.mkstemp(dir=os.path.dirname(sys.argv[2]))
        with os.fdopen(fd,'w') as target: json.dump(state,target,separators=(',',':')); target.flush(); os.fsync(target.fileno())
        os.replace(temp,sys.argv[2]); print('written',flush=True); sys.stdin.buffer.read(1)
        """,
        directory.appendingPathComponent("connection-state.lock").path,
        directory.appendingPathComponent("connection-state.json").path,
        first,
      ]
      child.standardOutput = output
      child.standardInput = input
      try child.run()
      #expect(
        String(decoding: output.fileHandleForReading.readData(ofLength: 8), as: UTF8.self)
          == "written\n")

      let store = ConnectedSitesStore(suiteName: suite, directory: directory)
      async let secondWrite: Void = store.connect(
        site: ConnectedSite(
          domain: "two.example", address: second, origin: "https://two.example"))
      try await Task.sleep(for: .milliseconds(100))
      try input.fileHandleForWriting.write(contentsOf: Data([0x01]))
      input.fileHandleForWriting.closeFile()
      try await secondWrite
      child.waitUntilExit()

      #expect(child.terminationStatus == 0)
      let sites = try await store.all()
      #expect(Set(sites.map(\.address)) == [first, second])
      #expect(Set(sites.map(\.domain)) == ["one.example", "two.example"])
    }
  #endif

  @Test("connection mutation rejects an account after its group becomes inactive")
  func rejectsDeletingGroup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConnectedSitesTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "grants-\(UUID().uuidString)"
    let account = try address(secret: 1)
    let group = WalletGroup(
      id: UUID(), kind: .privateKey, createdAt: Date(timeIntervalSince1970: 1),
      nextDerivationIndex: nil,
      accounts: [
        WalletAccount(
          address: account, derivationIndex: nil, createdAt: Date(timeIntervalSince1970: 1))
      ], lifecycle: .active)
    let registry = WalletRegistryStore(directory: directory, appGroup: suite)
    try registry.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: [group],
        homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: false))
    _ = try registry.update(expectedRevision: 0) { current in
      WalletRegistry(
        revision: 1, adoptionState: .migrating, groups: current.groups,
        homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: true)
    }
    _ = try registry.update(expectedRevision: 1) { current in
      WalletRegistry(
        revision: 2, adoptionState: .complete, groups: current.groups,
        homeSelectedAddress: account, legacyWalletAddressFallbackRemoved: true)
    }
    _ = try ConnectionStateStore(directory: directory, suiteName: suite)
      .getOrCreate(ConnectionState(revision: 0, defaultAccount: account))
    let store = ConnectedSitesStore(appGroupID: suite, directory: directory)

    _ = try registry.update(expectedRevision: 2) { current in
      var deleting = current.groups
      deleting[0].lifecycle = .deleting
      return WalletRegistry(
        revision: 3, adoptionState: .complete, groups: deleting,
        homeSelectedAddress: nil, legacyWalletAddressFallbackRemoved: true)
    }

    await #expect(throws: ConnectionStateError.invalid(.unregisteredDefault)) {
      try await store.isConnected(origin: "https://dapp.example", address: account)
    }
    await #expect(throws: ConnectionStateError.invalid(.unregisteredDefault)) {
      try await store.hasExactGrant(origin: "https://dapp.example", address: account)
    }
    await #expect(throws: ConnectionStateError.invalid(.unregisteredDefault)) {
      try await store.connect(
        site: ConnectedSite(
          domain: "dapp.example", address: account, origin: "https://dapp.example"))
    }
    #expect(
      try ConnectionStateStore(directory: directory, suiteName: suite).load()?.grants.isEmpty
        == true)
  }

  @Test("approving eth_requestAccounts persists the connection grant")
  func approvePersistsGrant() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    let id = try await svc.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: "https://dapp.example")
    _ = try await svc.approve(request: id)
    #expect(try await svc.isConnected(origin: "https://dapp.example"))
  }

  @Test("re-sent identical request converges to one pending record")
  func idempotentPrepare() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    let params: JSONValue = .array([.string("0x1234"), .string("0x6869")])

    let first = try await svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    // The dapp retried after a messaging interruption; native prepare must not
    // enqueue a duplicate.
    let retry = try await svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    #expect(retry == first)

    let listed = try await svc.list()
    #expect(listed.count == 1)

    // A consumed record is not reused: the next identical request is a fresh pending one.
    _ = try await svc.approve(request: first)
    let later = try await svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    #expect(later != first)
  }

  @Test("separate identical requests remain distinct")
  func identicalButSeparateRequests() async throws {
    let svc = svc("grants-\(UUID().uuidString)")
    let params: JSONValue = .array([.string("0x1234"), .string("0x6869")])
    let first = try await svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    let second = try await svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:2")
    #expect(first != second)
    #expect(try await svc.list().count == 2)
  }

  @Test("concurrent identical prepares converge to one pending record")
  func concurrentIdempotentPrepare() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    let params: JSONValue = .array([.string("0x1234"), .string("0x6869")])
    async let first: UUID = try svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    async let second: UUID = try svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    let (a, b) = try await (first, second)
    #expect(a == b)
    #expect(try await svc.list().count == 1)
  }

  @Test("identical prepares across store instances converge (app vs extension)")
  func crossInstanceIdempotentPrepare() async throws {
    // Two independent store actors on the same directory model the app and the Safari
    // extension racing on identical re-sent requests; the OS prepare lock must serialize.
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("XPrepare-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let appStore = PendingRequestStore(directory: dir)
    let extensionStore = PendingRequestStore(directory: dir)
    let appSvc = WalletService(store: appStore, signing: StubSigner(), grantsSuite: dir.path)
    let extensionSvc = WalletService(
      store: extensionStore, signing: StubSigner(), grantsSuite: dir.path)
    let params: JSONValue = .array([.string("0x1234"), .string("0x6869")])
    async let appID: UUID = try appSvc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    async let extensionID: UUID = try extensionSvc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-session:1")
    let (a, b) = try await (appID, extensionID)
    #expect(a == b)
    #expect(try await appStore.pending().count == 1)
  }

  @Test("pending approval is bound to the native Safari profile")
  func approvalProfileBinding() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    let id = try await svc.prepare(
      method: "eth_requestAccounts",
      params: .array([]),
      origin: "https://dapp.example",
      profileID: "profile-a")

    await #expect(throws: WalletError.bindingMismatch) {
      try await svc.approve(request: id, profileID: "profile-b")
    }
    _ = try await svc.approve(request: id, profileID: "profile-a")
    #expect(try await svc.isConnected(origin: "https://dapp.example", profileID: "profile-a"))
    #expect(!(try await svc.isConnected(origin: "https://dapp.example", profileID: "profile-b")))
  }

  @Test("approving a message does not create a connection grant")
  func messageApprovalDoesNotGrant() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    let id = try await svc.prepare(
      method: "personal_sign",
      params: .array([.string("0x1234"), .string("0x6869")]),
      origin: "https://dapp.example")
    _ = try await svc.approve(request: id)
    #expect(!(try await svc.isConnected(origin: "https://dapp.example")))
  }

  @Test("disconnect via WalletService revokes the grant")
  func serviceDisconnect() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    try await svc.connect(origin: "https://dapp.example")
    #expect(try await svc.isConnected(origin: "https://dapp.example"))
    try await svc.disconnect(origin: "https://dapp.example")
    #expect(!(try await svc.isConnected(origin: "https://dapp.example")))
  }

  private func address(secret value: UInt8) throws -> String {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = value
    return try EthereumKeypair.from(secret: secret).address
  }
}
