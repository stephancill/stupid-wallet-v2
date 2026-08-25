import Foundation
import Testing

@testable import StupidWalletCore

struct Gate6AppCoreTests {
  @Test("network store imports old inclusion preferences and persists manual networks")
  func networksPersist() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NetworkStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "NetworkStoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["0x1"], forKey: "excludedFromBalance")
    defaults.set(["0x89": ["chainName": "Legacy Polygon"]], forKey: "customChains")
    let store = NetworkStore(directory: directory, legacySuiteName: suite)

    #expect(try store.network(chainID: "1")?.includeInBalance == false)
    #expect(try store.network(chainID: "137")?.name == "Legacy Polygon")
    try store.add(name: "Zora", chainID: "7777777")
    #expect(try store.network(chainID: "7777777")?.name == "Zora")
    try store.record(chainID: "7777777", suggestedName: "Dapp Name")
    #expect(try store.network(chainID: "7777777")?.name == "Zora")
    try store.record(chainID: "999999")
    try store.record(chainID: "999999", suggestedName: "Suggested Network")
    #expect(try store.network(chainID: "999999")?.name == "Suggested Network")

    try store.remove(chainID: "1")
    try store.remove(chainID: "7777777")
    let reloaded = NetworkStore(directory: directory, legacySuiteName: suite)
    #expect(try reloaded.network(chainID: "1") == nil)
    #expect(try reloaded.network(chainID: "7777777") == nil)
    try reloaded.record(chainID: "1")
    try reloaded.record(chainID: "7777777", suggestedName: "Restored Zora")
    #expect(try reloaded.network(chainID: "1")?.name == "Ethereum")
    #expect(try reloaded.network(chainID: "7777777")?.name == "Restored Zora")

    try store.setIncluded(false, chainID: "137")
    #expect(try store.network(chainID: "0x89")?.includeInBalance == false)
    #expect(defaults.stringArray(forKey: "excludedFromBalance")?.contains("0x89") == true)
  }

  @Test("network records ignore obsolete provenance fields")
  func obsoleteNetworkProvenance() throws {
    let legacy = Data(
      #"{"id":"137","name":"Polygon","isDefault":false,"includeInBalance":true}"#.utf8)
    let network = try JSONDecoder().decode(WalletNetwork.self, from: legacy)

    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(network))
    guard case .object(let object) = encoded else {
      Issue.record("Expected encoded network object")
      return
    }
    #expect(object["isPreseeded"] == nil)
    #expect(object["isDefault"] == nil)
  }

  @Test("RPC overrides persist by normalized decimal chain ID")
  func rpcOverridesPersist() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RPCOverrideStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = RPCOverrideStore(directory: directory)
    let deployments = Simple7702AccountDeploymentStore(directory: directory)
    let code: [UInt8] = [0x60, 0x00]
    let runtimeHash = "0x" + Hex.encode(Keccak.keccak256(code))
    let firstRPC = URL(string: "https://rpc.example/first")!
    let secondRPC = URL(string: "https://rpc.example/second")!
    try deployments.recordVerified(chainID: "8453", code: code, rpcURL: firstRPC)
    #expect(
      deployments.verifiedCode(chainID: "8453", runtimeHash: runtimeHash, rpcURL: firstRPC)
        == code)
    #expect(
      deployments.verifiedCode(chainID: "8453", runtimeHash: runtimeHash, rpcURL: secondRPC) == nil)
    let url = try #require(URL(string: "https://rpc.example.test"))
    try store.set(url, forChainID: "0x2105")

    #expect(try store.all() == ["8453": url])
    #expect(RPCResolver.persisted(store: store).resolve(chainID: "8453") == url)
    #expect(
      deployments.verifiedCode(chainID: "8453", runtimeHash: runtimeHash, rpcURL: firstRPC) == nil)

    try deployments.recordVerified(chainID: "8453", code: code, rpcURL: secondRPC)
    try store.remove(forChainID: "8453")
    #expect(try store.all().isEmpty)
    #expect(
      deployments.verifiedCode(chainID: "8453", runtimeHash: runtimeHash, rpcURL: secondRPC) == nil)
  }

  @Test("transaction submission claims are exclusive per account and chain")
  func transactionSubmissionClaims() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TransactionSubmissionLockTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let submissionLock = TransactionSubmissionLock(directory: directory)
    let account = "0x0000000000000000000000000000000000000001"

    let first = try #require(submissionLock.claim(account: account, chainID: "1"))
    #expect(submissionLock.claim(account: account.uppercased(), chainID: "0x1") == nil)
    let otherChain = try #require(submissionLock.claim(account: account, chainID: "8453"))
    otherChain.release()
    first.release()
    #expect(submissionLock.claim(account: account, chainID: "1") != nil)
  }

  @Test("native balance formatting supports full-width Ethereum quantities")
  func nativeBalanceFormatting() {
    #expect(NativeBalanceService.formatEther(bytes: [0]) == "0.000000")
    #expect(
      NativeBalanceService.formatEther(bytes: Hex.quantityData(hex: "0xde0b6b3a7640000")!)
        == "1.000000")
    #expect(
      NativeBalanceService.formatEther(bytes: [UInt8](repeating: 0xff, count: 32))
        == "115792089237316195423570985008687907853269984665640564039457.584007")
  }

  @Test("cached total balance is account-bound and removable")
  func cachedTotalBalance() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BalanceCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BalanceCache(directory: directory)
    let account = "0x1234567890abcdef1234567890abcdef12345678"

    #expect(try store.balance(account: account) == nil)
    try store.save(balance: "3.000000", account: account)
    #expect(try store.balance(account: account.uppercased()) == "3.000000")
    #expect(
      try store.balance(account: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd") == nil)
    try store.remove(account: account)
    #expect(try store.balance(account: account) == nil)
  }

  @Test("native balances aggregate wei values across networks")
  func nativeBalanceAggregation() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AggregateBalanceURLProtocol.self]
    let service = NativeBalanceService(
      resolver: RPCResolver(), client: RPCClient(session: URLSession(configuration: configuration)))

    let details = await service.balances(
      account: "0x1234567890abcdef1234567890abcdef12345678", chainIDs: ["1", "137"])
    #expect(details.map(\.chainID) == ["1", "137"])
    #expect(details.allSatisfy { $0.hasNonZeroBalance })
    #expect(
      details.map { $0.wei.map(NativeBalanceService.formatEther) } == ["1.000000", "2.000000"])
    #expect(NativeNetworkBalance(chainID: "10", wei: [0]).hasNonZeroBalance == false)
    #expect(NativeNetworkBalance(chainID: "10", wei: nil).hasNonZeroBalance == false)
    #expect(
      try await service.aggregateBalance(
        account: "0x1234567890abcdef1234567890abcdef12345678", chainIDs: ["1", "137"])
        == "3.000000")
    #expect(NativeBalanceService.isGreater([1, 0], than: [255]))
    #expect(NativeBalanceService.isGreater([0, 2], than: [1]))
    #expect(NativeBalanceService.isGreater([1], than: [0, 1]) == false)
    #expect(NativeBalanceService.isGreater([0, 1], than: [1]) == false)
  }
}

private final class AggregateBalanceURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let result =
      request.url?.lastPathComponent == "1"
      ? "0xde0b6b3a7640000" : "0x1bc16d674ec80000"
    client?.urlProtocol(self, didReceive: httpResponse(), cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self, didLoad: jsonObject(["jsonrpc": "2.0", "id": 1, "result": result]))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
