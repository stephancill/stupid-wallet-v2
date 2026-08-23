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

    try store.setIncluded(false, chainID: "137")
    #expect(try store.network(chainID: "0x89")?.includeInBalance == false)
    #expect(defaults.stringArray(forKey: "excludedFromBalance")?.contains("0x89") == true)
  }

  @Test("RPC overrides persist by normalized decimal chain ID")
  func rpcOverridesPersist() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RPCOverrideStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = RPCOverrideStore(directory: directory)
    let url = try #require(URL(string: "https://rpc.example.test"))
    try store.set(url, forChainID: "0x2105")

    #expect(try store.all() == ["8453": url])
    #expect(RPCResolver.persisted(store: store).resolve(chainID: "8453") == url)

    try store.remove(forChainID: "8453")
    #expect(try store.all().isEmpty)
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
