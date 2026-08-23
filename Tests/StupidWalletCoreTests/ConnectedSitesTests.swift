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

  @Test("connect establishes a grant readable by origin and account")
  func connectGrant() async {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    await store.connect(
      site: ConnectedSite(
        domain: "dapp.example",
        address: "0x1234567890abcdef1234567890abcdef12345678",
        origin: "https://dapp.example",
        profileID: "profile-a"))
    let sites = await store.all()
    #expect(sites.count == 1)
    #expect(sites.first?.domain == "dapp.example")
    #expect(
      await store.isConnected(
        origin: "https://dapp.example",
        address: "0x1234567890abcdef1234567890abcdef12345678",
        profileID: "profile-a"))
    #expect(
      !(await store.isConnected(
        origin: "https://dapp.example:8443",
        address: "0x1234567890abcdef1234567890abcdef12345678",
        profileID: "profile-a")))
    #expect(
      !(await store.isConnected(
        origin: "https://dapp.example",
        address: "0x1234567890abcdef1234567890abcdef12345678",
        profileID: "profile-b")))
  }

  @Test("legacy hostname grant remains authorized until a normalized reconnect")
  func legacyGrantCompatibility() async {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    await store.connect(site: ConnectedSite(domain: "legacy.example", address: "0x1"))

    #expect(
      await store.isConnected(
        origin: "http://legacy.example:8080", address: "0x1", profileID: "profile-a"))
  }

  @Test("disconnect is idempotent and removes only the target origin")
  func disconnectRemoves() async {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    await store.connect(site: ConnectedSite(domain: "a.example", address: "0x1"))
    await store.connect(site: ConnectedSite(domain: "b.example", address: "0x1"))
    await store.disconnect(origin: "https://a.example")
    await store.disconnect(origin: "https://a.example")  // idempotent
    let sites = await store.all()
    #expect(sites.map(\.domain) == ["b.example"])
  }

  @Test("forgetting an account revokes only that account's grants")
  func disconnectAllForAccount() async {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    await store.connect(
      site: ConnectedSite(
        domain: "a.example", address: "0xAbC", origin: "https://a.example"))
    await store.connect(site: ConnectedSite(domain: "legacy.example", address: "0xabc"))
    await store.connect(
      site: ConnectedSite(
        domain: "b.example", address: "0xDef", origin: "https://b.example"))

    await store.disconnectAll(address: "0xABC")

    let sites = await store.all()
    #expect(sites.map(\.domain) == ["b.example"])
  }

  @Test("repeat connect refreshes instead of duplicating")
  func reconnectRefreshes() async {
    let suite = "grants-\(UUID().uuidString)"
    let store = ConnectedSitesStore(suiteName: suite)
    await store.connect(
      site: ConnectedSite(domain: "dapp.example", address: "0x1", connectedAt: .distantPast))
    await store.connect(site: ConnectedSite(domain: "dapp.example", address: "0x1"))
    let sites = await store.all()
    #expect(sites.count == 1)
    #expect(sites.first?.connectedAt ?? .distantPast > .distantPast)
  }

  @Test("approving eth_requestAccounts persists the connection grant")
  func approvePersistsGrant() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    let id = try await svc.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: "https://dapp.example")
    _ = try await svc.approve(request: id)
    #expect(await svc.isConnected(origin: "https://dapp.example"))
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
    #expect(await svc.isConnected(origin: "https://dapp.example", profileID: "profile-a"))
    #expect(!(await svc.isConnected(origin: "https://dapp.example", profileID: "profile-b")))
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
    #expect(!(await svc.isConnected(origin: "https://dapp.example")))
  }

  @Test("disconnect via WalletService revokes the grant")
  func serviceDisconnect() async throws {
    let suite = "grants-\(UUID().uuidString)"
    let svc = svc(suite)
    await svc.connect(origin: "https://dapp.example")
    #expect(await svc.isConnected(origin: "https://dapp.example"))
    await svc.disconnect(origin: "https://dapp.example")
    #expect(!(await svc.isConnected(origin: "https://dapp.example")))
  }
}
