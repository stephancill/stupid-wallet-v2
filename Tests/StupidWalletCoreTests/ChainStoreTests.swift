import Foundation
import Testing

@testable import StupidWalletCore

struct ChainStoreTests {
  private func directory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ChainStoreTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("chain IDs persist in normalized decimal form")
  func persistence() throws {
    let directory = directory()
    let first = ChainStore(directory: directory)
    #expect(try first.currentChainID() == "1")
    try first.setChainID("0x2105")
    #expect(try first.currentChainID() == "8453")
    #expect(try ChainStore(directory: directory).currentChainID() == "8453")
    #expect(ChainStore.hexChainID("8453") == "0x2105")
  }

  @Test("invalid chain IDs are rejected")
  func invalid() throws {
    let directory = directory()
    let store = ChainStore(directory: directory)
    #expect(throws: ChainStoreError.invalidChainID) {
      try store.setChainID("0x0")
    }
    #expect(ChainStore.normalize("not-a-chain") == nil)
    try Data("corrupt\n".utf8).write(to: directory.appendingPathComponent("active-chain.conf"))
    #expect(throws: ChainStoreError.invalidChainID) {
      try store.currentChainID()
    }
  }

  @Test("approved switch persists target while add-chain does not switch")
  func approvedMutation() async throws {
    let chainStore = ChainStore(directory: directory())
    let pendingDirectory = directory()
    let service = WalletService(
      store: PendingRequestStore(directory: pendingDirectory),
      signing: StubSigner(),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: chainStore)
    await service.connect(origin: "https://dapp.example")

    let add = try await service.prepare(
      method: "wallet_addEthereumChain",
      params: .array([.object(["chainId": .string("0x89")])]),
      origin: "https://dapp.example")
    #expect(try await service.approve(request: add) == .null)
    #expect(try chainStore.currentChainID() == "1")

    let change = try await service.prepare(
      method: "wallet_switchEthereumChain",
      params: .array([.object(["chainId": .string("0x2105")])]),
      origin: "https://dapp.example")
    #expect(try await service.approve(request: change) == .null)
    #expect(try chainStore.currentChainID() == "8453")
    #expect(try await service.activeChainID() == "8453")
  }

  @Test("invalid chain params never become pending")
  func invalidParams() async throws {
    let service = WalletService(
      store: PendingRequestStore(directory: directory()), signing: StubSigner(),
      grantsSuite: UUID().uuidString)
    await service.connect(origin: "https://dapp.example")
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "wallet_switchEthereumChain", params: .array([.object([:])]),
        origin: "https://dapp.example")
    }
    #expect(try await service.list().isEmpty)
  }

  @Test("unconnected origins cannot prepare global chain changes")
  func unauthorized() async throws {
    let service = WalletService(
      store: PendingRequestStore(directory: directory()), signing: StubSigner(),
      grantsSuite: UUID().uuidString)
    await #expect(throws: WalletError.unauthorized) {
      try await service.prepare(
        method: "wallet_switchEthereumChain",
        params: .array([.object(["chainId": .string("0x2105")])]),
        origin: "https://dapp.example")
    }
  }

  @Test("chain authorization is revalidated before approval")
  func disconnectedBeforeApproval() async throws {
    let chainStore = ChainStore(directory: directory())
    let service = WalletService(
      store: PendingRequestStore(directory: directory()), signing: StubSigner(),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: chainStore)
    await service.connect(origin: "https://dapp.example")
    let id = try await service.prepare(
      method: "wallet_switchEthereumChain",
      params: .array([.object(["chainId": .string("0x2105")])]),
      origin: "https://dapp.example")
    await service.disconnect(origin: "https://dapp.example")

    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(4100),
          "message": .string("Origin disconnected before approval"),
        ]))
    ) {
      try await service.approve(request: id)
    }
    #expect(await service.status(for: id)?.status == "failed")
    #expect(try chainStore.currentChainID() == "1")
  }

  @Test("unfinished switch journal recovers according to durable request consumption")
  func journalRecovery() async throws {
    let root = directory()
    let chainStore = ChainStore(directory: root)
    let pendingStore = PendingRequestStore(directory: root)
    let service = WalletService(
      store: pendingStore, signing: StubSigner(),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: chainStore)

    let interrupted = UUID()
    try chainStore.beginSwitch(
      requestID: interrupted, previousChainID: "1", targetChainID: "8453")
    try chainStore.setChainID("8453")
    guard let liveClaim = chainStore.claimSwitch() else {
      Issue.record("expected switch lock")
      return
    }
    #expect(chainStore.claimSwitch() == nil)
    #expect(try chainStore.currentChainID() == "8453")
    chainStore.releaseSwitch(liveClaim)
    #expect(try await service.activeChainID() == "1")
    #expect(try chainStore.pendingSwitch() == nil)

    let consumed = UUID()
    let params = JSONValue.array([.object(["chainId": .string("0x2105")])])
    try await pendingStore.insert(
      WalletPendingRequest(
        id: consumed, kind: .chain, method: "wallet_switchEthereumChain",
        origin: "https://dapp.example", chainId: "1", account: service.account,
        params: params, payloadDigest: CanonicalRequest.digest(of: params, keyedBy: consumed),
        status: .consumed, result: .null))
    try chainStore.beginSwitch(
      requestID: consumed, previousChainID: "1", targetChainID: "8453")
    try chainStore.setChainID("1")
    #expect(try await service.activeChainID() == "8453")
    #expect(try chainStore.pendingSwitch() == nil)
  }

  @Test("requests prepared before a chain change fail terminally")
  func staleRequest() async throws {
    let chainStore = ChainStore(directory: directory())
    let service = WalletService(
      store: PendingRequestStore(directory: directory()), signing: StubSigner(),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: chainStore)
    let id = try await service.prepare(
      method: "personal_sign",
      params: .array([.string("0x6869"), .string(service.account)]),
      origin: "https://dapp.example", chainId: "1")
    try chainStore.setChainID("8453")

    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(4901),
          "message": .string("Active chain changed before approval"),
        ]))
    ) {
      try await service.approve(request: id)
    }
    #expect(await service.status(for: id)?.status == "failed")
  }
}
