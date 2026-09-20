import Combine
import Foundation
import Testing

@testable import StupidWalletCore

struct TokenBalanceTests {
  @Test("token identity normalizes network and address without conflating chains")
  func identity() throws {
    let first = try token(chain: "0x1")
    let second = try WalletToken(
      chainID: "1", address: first.address.uppercased().replacingOccurrences(of: "0X", with: "0x"),
      symbol: "USDC", decimals: 6)
    #expect(first == second)
    #expect(first.id != (try token(chain: "8453")).id)
    #expect(throws: TokenError.invalidAddress) { try token(address: "0x1234") }
    #expect(throws: TokenError.invalidMetadata) { try token(symbol: "\nUSDC") }
    #expect(throws: TokenError.invalidMetadata) { try token(symbol: "") }
  }

  @Test("amounts retain uint256 precision and tiny positive balances never display as zero")
  func amounts() throws {
    let usdc = try token()
    #expect(usdc.exactBalance(raw: word(1_250_000)) == "1.25")
    #expect(usdc.displayBalance(raw: word(0)) == "0")
    let ether = try token(decimals: 18)
    #expect(ether.displayBalance(raw: word(1)) == "<0.000001")
    #expect(ether.exactBalance(raw: word(1)) == "0.000000000000000001")
    #expect(
      try token(decimals: 0).exactBalance(raw: [UInt8](repeating: 255, count: 32))
        == "115792089237316195423570985008687907853269984665640564039457584007913129639935")
    #expect(try token(decimals: 8).exactBalance(raw: word(123_456_789)) == "1.23456789")
    #expect(
      try token(decimals: 255).exactBalance(raw: word(1)) == "0."
        + String(repeating: "0", count: 254) + "1")
  }

  @Test("batch responses match IDs, preserve null and independent structured errors")
  func batchResponses() async throws {
    let stub = BalanceRPCStub()
    defer { stub.close() }
    stub.respond = { request in
      let reads = try requestReads(request)
      #expect(reads.count == 3)
      return .array([
        response(
          id: 3,
          error: .object(["code": .number(-1), "message": .string("reverted"), "data": .null])),
        response(id: 2, result: .null), response(id: 1, result: .string("0x0")),
      ])
    }
    let reads = (0..<3).map { _ in RPCRead(method: "eth_getBalance", params: .array([])) }
    let result = try await stub.client.readBatch(url: stub.url(chain: "1"), reads: reads)
    #expect(result[0] == .result(.string("0x0")))
    #expect(result[1] == .result(.null))
    #expect(
      result[2]
        == .error(.object(["code": .number(-1), "message": .string("reverted"), "data": .null])))
  }

  @Test("ambiguous batch response IDs fail loudly", arguments: [0, 1, 2, 3])
  func invalidBatch(mode: Int) async throws {
    let stub = BalanceRPCStub()
    defer { stub.close() }
    stub.respond = { _ in
      switch mode {
      case 0: return .array([response(id: 1), response(id: 1)])
      case 1: return .array([response(id: 3)])
      case 2:
        return .array([.object(["jsonrpc": .string("2.0"), "id": .number(1.5), "result": .null])])
      default:
        return .array([
          .object(["jsonrpc": .string("2.0"), "id": .number(1), "result": .null, "error": .null])
        ])
      }
    }
    await #expect(throws: RPCClientError.invalidResponse) {
      try await stub.client.readBatch(
        url: stub.url(chain: "1"),
        reads: [
          RPCRead(method: "eth_call", params: .array([])),
          RPCRead(method: "eth_call", params: .array([])),
        ])
    }
  }

  @Test("missing batch responses fail their own read and mutation methods are rejected before HTTP")
  func missingBatch() async throws {
    let stub = BalanceRPCStub()
    defer { stub.close() }
    stub.respond = { _ in .array([response(id: 2)]) }
    let reads = (0..<2).map { _ in RPCRead(method: "eth_call", params: .array([])) }
    let result = try await stub.client.readBatch(url: stub.url(chain: "1"), reads: reads)
    guard case .error = result[0] else {
      Issue.record("missing response must fail")
      return
    }
    #expect(result[1] == .result(.string("0x0")))
    await #expect(throws: RPCClientError.invalidResponse) {
      try await stub.client.readBatch(
        url: stub.url(chain: "1"),
        reads: [RPCRead(method: "eth_sendRawTransaction", params: .array([]))])
    }
    #expect(stub.requests.count == 1)
  }

  @Test("metadata import uses one batch and exact balanceOf calldata")
  func metadata() async throws {
    let stub = BalanceRPCStub()
    defer { stub.close() }
    let account = "0x1111111111111111111111111111111111111111"
    stub.respond = { request in
      let reads = try requestReads(request)
      #expect(reads.count == 4)
      guard case .object(let item) = reads[3], case .array(let params) = item["params"],
        case .object(let call) = params[0]
      else {
        throw TokenError.invalidBalance
      }
      #expect(
        call["data"]
          == .string("0x70a08231" + String(repeating: "0", count: 24) + account.dropFirst(2)))
      return metadataResponse()
    }
    let imported = try await ERC20Reader(client: stub.client).inspect(
      chainID: "1", address: token().address,
      account: account, endpoint: stub.url(chain: "1"))
    #expect(imported.token.symbol == "USDC")
    #expect(imported.token.decimals == 6)
    #expect(imported.balance.raw == word(1_250_000))
  }

  @Test(
    "missing metadata, invalid decimals, malformed uint256, and EOAs cannot be imported",
    arguments: [0, 1, 2, 3, 4])
  func invalidMetadata(mode: Int) async throws {
    let stub = BalanceRPCStub()
    defer { stub.close() }
    stub.respond = { _ in
      var responses = metadataResponses()
      switch mode {
      case 0: responses[0] = response(id: 1, result: .string("0x"))
      case 1:
        responses[1] = response(id: 2, result: .string("0x" + String(repeating: "ff", count: 96)))
      case 2: responses[2] = response(id: 3, result: .string("0x" + Hex.encode(word(256))))
      case 3: responses[3] = response(id: 4, result: .string("0x1"))
      default:
        responses[1] = response(
          id: 2,
          error: .object(["code": .number(-32000), "message": .string("metadata unavailable")]))
      }
      return .array(responses)
    }
    await #expect(throws: TokenError.self) {
      try await ERC20Reader(client: stub.client).inspect(
        chainID: "1", address: token().address,
        account: "0x1111111111111111111111111111111111111111", endpoint: stub.url(chain: "1"))
    }
  }

  @Test("watchlist is shared while cached balances remain account and network specific")
  func persistence() throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let first = try environment.addToken(chain: "1")
    let second = try environment.addToken(chain: "8453")
    let service = environment.service
    let context = try service.context(account: environment.accounts[1])
    let refreshID = try service.begin(context: context)
    try service.commit(
      context: context, refreshID: refreshID,
      result: NetworkBalanceResult(
        native: nil,
        tokens: [TokenBalanceRead(tokenID: first.id, result: .success(environment.entry(9)))]))
    let loaded = try TokenStore(directory: environment.directory).load()
    #expect(loaded.tokens.count == 2)
    #expect(
      loaded.balance(account: environment.accounts[0], tokenID: first.id)?.raw == word(1_250_000))
    #expect(loaded.balance(account: environment.accounts[1], tokenID: first.id)?.raw == word(9))
    #expect(loaded.balance(account: environment.accounts[1], tokenID: second.id) == nil)
    #expect(throws: TokenError.duplicate) { try environment.addToken(chain: "1") }
  }

  @Test("new refreshes and token/account removal invalidate late writes")
  func staleWrites() throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let token = try environment.addToken()
    let service = environment.service
    let context = try service.context(account: environment.accounts[0])
    let first = try service.begin(context: context)
    let second = try service.begin(context: context)
    let result = NetworkBalanceResult(
      native: nil,
      tokens: [TokenBalanceRead(tokenID: token.id, result: .success(environment.entry(9)))])
    #expect(throws: TokenError.configurationChanged) {
      try service.commit(context: context, refreshID: first, result: result)
    }
    try service.commit(context: context, refreshID: second, result: result)
    try service.tokens.removeBalances(account: context.account)
    #expect(throws: TokenError.configurationChanged) {
      try service.commit(context: context, refreshID: second, result: result)
    }
    let third = try service.begin(context: context)
    try service.tokens.remove(tokenID: token.id)
    #expect(throws: TokenError.configurationChanged) {
      try service.commit(context: context, refreshID: third, result: result)
    }
    #expect(try service.tokens.load().balances.values.allSatisfy(\.isEmpty))
    #expect(try service.tokens.load().tokens.isEmpty)
  }

  @Test("RPC changes reject old imports and balance writes")
  func changedRPC() throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    _ = try environment.addToken()
    let service = environment.service
    let context = try service.context(account: environment.accounts[0])
    let refresh = try service.begin(context: context)
    try RPCOverrideStore(directory: environment.directory).set(
      URL(string: "https://other.example")!, forChainID: "1")
    #expect(throws: TokenError.configurationChanged) {
      try service.commit(
        context: context, refreshID: refresh, result: NetworkBalanceResult(native: nil, tokens: []))
    }
    #expect(throws: TokenError.configurationChanged) {
      try service.add(
        imported: TokenImport(
          token: token(address: "0x2222222222222222222222222222222222222222"),
          balance: environment.entry(1), account: context.account), context: context)
    }
  }

  @Test(
    "network deletion clears all account balances and recovers before explicit readdition",
    arguments: [false, true])
  func deleteNetwork(interrupted: Bool) throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let removed = try environment.addToken(chain: "1")
    let retained = try environment.addToken(chain: "8453")
    let context = try environment.service.context(account: environment.accounts[1])
    let refresh = try environment.service.begin(context: context)
    try environment.service.commit(
      context: context, refreshID: refresh,
      result: NetworkBalanceResult(
        native: nil,
        tokens: [TokenBalanceRead(tokenID: removed.id, result: .success(environment.entry(8)))]))
    if interrupted {
      try JSONEncoder().encode("1").write(
        to: environment.directory.appendingPathComponent("network-removal.json"))
    } else {
      try environment.networks.remove(chainID: "1")
    }
    try environment.networks.record(chainID: "1")
    let snapshot = try environment.service.tokens.load()
    #expect(snapshot.tokens.map(\.id) == [retained.id])
    #expect(snapshot.balances.values.allSatisfy { $0[removed.id] == nil })
    #expect(try RPCOverrideStore(directory: environment.directory).all()["1"] == nil)
    #expect(try environment.networks.network(chainID: "1") != nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: environment.directory.appendingPathComponent("network-removal.json").path))
    #expect(throws: TokenError.configurationChanged) {
      try environment.service.commit(
        context: context, refreshID: refresh, result: NetworkBalanceResult(native: nil, tokens: []))
    }
  }

  @Test("corrupt token persistence is preserved and cannot be overwritten")
  func corruptStore() throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let file = environment.directory.appendingPathComponent("tokens.json")
    let data = Data("not-json".utf8)
    try data.write(to: file)
    #expect(throws: TokenError.corrupt) { try environment.service.tokens.load() }
    #expect(throws: TokenError.corrupt) {
      try environment.service.tokens.remove(tokenID: "anything")
    }
    #expect(try Data(contentsOf: file) == data)
  }

  @Test("SWR hydrates immediately, retains failed rows, and commits successful zero balances")
  @MainActor func swr() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    _ = try environment.addToken()
    let second = try environment.addToken(address: "0x2222222222222222222222222222222222222222")
    try BalanceCache(directory: environment.directory).save(
      balance: "4.000000", account: environment.accounts[0])
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[0])
    #expect(model.nativeTotal == "4.000000")
    #expect(model.rows.count == 2)
    #expect(model.rows.allSatisfy { $0.entry?.raw == word(1_250_000) && $0.isCached })
    environment.stub.respond = { request in
      .array(
        try requestReads(request).map { read in
          let id = read.objectValue?["id"] ?? .null
          if read.nestedString(at: ["method"]) == "eth_call",
            case .array(let params) = read.objectValue?["params"],
            params[0].nestedString(at: ["to"]) == second.address
          {
            return .object([
              "jsonrpc": .string("2.0"), "id": id, "result": .string("0x" + Hex.encode(word(0))),
            ])
          }
          return .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(-1), "message": .string("offline")]),
          ])
        })
    }
    await model.refresh()
    #expect(model.nativeTotal == "4.000000")
    #expect(model.rows.first { $0.id == second.id }?.entry?.raw == word(0))
    #expect(model.rows.first { $0.id != second.id }?.entry?.raw == word(1_250_000))
    #expect(model.rows.first { $0.id != second.id }?.error != nil)
    #expect(model.rows.first { $0.id == second.id }?.isCached == false)
    let relaunched = WalletBalanceModel(service: environment.service)
    relaunched.selectAccount(environment.accounts[0])
    #expect(relaunched.rows.first { $0.id == second.id }?.entry?.raw == word(0))
    relaunched.selectAccount(environment.accounts[1])
    #expect(relaunched.rows.allSatisfy { $0.entry == nil })
  }

  @Test("cold failures show unavailable rather than zero")
  @MainActor func coldFailure() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    _ = try environment.addToken()
    environment.stub.respond = { _ in throw URLError(.notConnectedToInternet) }
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[1])
    await model.refresh()
    #expect(model.nativeTotal == "Unavailable")
    #expect(model.rows.count == 1)
    #expect(model.rows[0].entry == nil)
    #expect(model.rows[0].error != nil)
    #expect(!model.rows[0].isLoading)
  }

  @Test("reads are batched by network and excluded native networks still fetch tokens")
  @MainActor func grouping() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    _ = try environment.addToken()
    _ = try environment.addToken(address: "0x2222222222222222222222222222222222222222")
    _ = try environment.addToken(chain: "8453")
    try environment.networks.setIncluded(false, chainID: "8453")
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[0])
    await model.refresh()
    let requests = environment.stub.requests
    #expect(requests.count == 2)
    let ethereum = try #require(requests.first { $0.url?.lastPathComponent == "1" })
    let base = try #require(requests.first { $0.url?.lastPathComponent == "8453" })
    #expect(try requestReads(ethereum).count == 3)
    #expect(try requestReads(base).count == 1)
    #expect(try requestReads(base)[0].nestedString(at: ["method"]) == "eth_call")
    #expect(model.nativeTotal == "1.000000")
    #expect(model.rows.allSatisfy { !$0.isCached })
  }

  @Test("a completed network publishes token rows while a different network is still waiting")
  @MainActor func progressiveResults() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let ethereum = try environment.addToken()
    let base = try environment.addToken(chain: "8453")
    environment.stub.delayedChain = "8453"
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[0])
    let (updates, continuation) = AsyncStream<Void>.makeStream()
    let observation = model.$rows.sink { rows in
      if rows.contains(where: { $0.id == ethereum.id && !$0.isCached }) { continuation.yield() }
    }
    let refresh = Task { await model.refresh() }
    var iterator = updates.makeAsyncIterator()
    await iterator.next()
    #expect(model.isRefreshing)
    #expect(model.rows.first { $0.id == ethereum.id }?.entry?.raw == word(9))
    #expect(model.rows.first { $0.id == base.id }?.isLoading == true)
    #expect(model.rows.first { $0.id == base.id }?.entry?.raw == word(1_250_000))
    environment.stub.release()
    await refresh.value
    observation.cancel()
    #expect(model.rows.allSatisfy { !$0.isCached })
  }

  @Test("deleting a token during a suspended refresh removes its row and cached value")
  @MainActor func removalDuringRead() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let token = try environment.addToken()
    environment.stub.hold = true
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[0])
    let refresh = Task { await model.refresh() }
    await environment.stub.waitForRequest()
    await model.remove(tokenID: token.id)
    #expect(model.rows.isEmpty)
    environment.stub.release()
    await refresh.value
    await model.refresh()
    #expect(try environment.service.tokens.load().tokens.isEmpty)
    #expect(try environment.service.tokens.load().balances.values.allSatisfy(\.isEmpty))
    #expect(model.rows.isEmpty)
  }

  @Test("large token lists split into bounded batches with one native read")
  @MainActor func chunking() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    for index in 1...102 {
      _ = try environment.addToken(address: "0x" + String(format: "%040x", index))
    }
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[0])
    await model.refresh()
    let calls = try environment.stub.requests.map(requestReads)
    #expect(calls.map(\.count).sorted() == [3, 50, 50])
    #expect(
      calls.flatMap { $0 }.filter { $0.nestedString(at: ["method"]) == "eth_getBalance" }.count == 1
    )
    #expect(model.rows.count == 102)
  }

  @Test("overlapping refreshes share the same request")
  @MainActor func coalescing() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    _ = try environment.addToken()
    environment.stub.hold = true
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[0])
    let first = Task { await model.refresh() }
    await environment.stub.waitForRequest()
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let second = Task {
      continuation.yield()
      await model.refresh()
    }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    #expect(environment.stub.requests.count == 1)
    environment.stub.release()
    await first.value
    await second.value
    #expect(environment.stub.requests.count == 1)
  }

  @Test("account switching while a read is suspended cannot publish or cache the old response")
  @MainActor func switchDuringRead() async throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let token = try environment.addToken()
    environment.stub.hold = true
    let model = WalletBalanceModel(service: environment.service)
    model.selectAccount(environment.accounts[0])
    let first = Task { await model.refresh() }
    await environment.stub.waitForRequest()
    model.selectAccount(environment.accounts[1])
    #expect(model.rows[0].entry == nil)
    environment.stub.release()
    await first.value
    #expect(model.account == environment.accounts[1].lowercased())
    #expect(model.rows[0].entry == nil)
    #expect(
      try environment.service.tokens.load().balance(
        account: environment.accounts[0], tokenID: token.id)?.raw == word(1_250_000))
  }
}

extension JSONValue {
  fileprivate var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
}

func token(
  chain: String = "1", address: String = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
  symbol: String = "USDC", decimals: UInt8 = 6
) throws -> WalletToken {
  try WalletToken(chainID: chain, address: address, symbol: symbol, decimals: decimals)
}

func word(_ value: UInt64) -> [UInt8] {
  (0..<32).map { index in index < 24 ? 0 : UInt8(truncatingIfNeeded: value >> ((31 - index) * 8)) }
}

func response(id: Int, result: JSONValue = .string("0x0"), error: JSONValue? = nil)
  -> JSONValue
{
  var value: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .number(Double(id))]
  value[error == nil ? "result" : "error"] = error ?? result
  return .object(value)
}

func metadataResponse() -> JSONValue { .array(metadataResponses()) }

func metadataResponses() -> [JSONValue] {
  let string = word(32) + word(4) + Array("USDC".utf8) + [UInt8](repeating: 0, count: 28)
  return [
    response(id: 1, result: .string("0x6000")),
    response(id: 2, result: .string("0x" + Hex.encode(string))),
    response(id: 3, result: .string("0x" + Hex.encode(word(6)))),
    response(id: 4, result: .string("0x" + Hex.encode(word(1_250_000)))),
  ]
}

func requestReads(_ request: URLRequest) throws -> [JSONValue] {
  var data = request.httpBody
  if data == nil, let stream = request.httpBodyStream {
    stream.open()
    defer { stream.close() }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { throw TokenError.transport }
      if count == 0 { break }
      bytes += buffer.prefix(count)
    }
    data = Data(bytes)
  }
  guard let data, case .array(let reads) = try JSONDecoder().decode(JSONValue.self, from: data)
  else { throw TokenError.invalidBalance }
  return reads
}

struct BalanceEnvironment {
  let directory: URL
  let accounts: [String]
  let networks: NetworkStore
  let service: WalletBalanceService
  let stub = BalanceRPCStub()

  init(tokenSearch: StupidTokensClient? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TokenBalanceTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    accounts = try [1, 2].map { try EthereumKeypair.from(secret: word(UInt64($0))).address }
    let registry = WalletRegistryStore(directory: directory)
    let groups = accounts.map { address in
      WalletGroup(
        id: UUID(), kind: .privateKey, createdAt: .distantPast, nextDerivationIndex: nil,
        accounts: [WalletAccount(address: address, derivationIndex: nil, createdAt: .distantPast)],
        lifecycle: .active)
    }
    try registry.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: groups, homeSelectedAddress: accounts[0],
        legacyWalletAddressFallbackRemoved: true))
    _ = try registry.update(expectedRevision: 0) { current in
      WalletRegistry(
        revision: 1, adoptionState: .migrating, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress, legacyWalletAddressFallbackRemoved: true)
    }
    _ = try registry.update(expectedRevision: 1) { current in
      WalletRegistry(
        revision: 2, adoptionState: .complete, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress, legacyWalletAddressFallbackRemoved: true)
    }
    networks = NetworkStore(directory: directory, legacySuiteName: UUID().uuidString)
    try networks.setIncluded(false, chainID: "8453")
    try networks.setIncluded(false, chainID: "10")
    try networks.setIncluded(false, chainID: "42161")
    for chain in ["1", "8453", "10", "42161"] {
      try RPCOverrideStore(directory: directory).set(stub.url(chain: chain), forChainID: chain)
    }
    service = WalletBalanceService(
      directory: directory, client: stub.client, networkStore: networks,
      tokenSearch: tokenSearch)
  }

  @discardableResult func addToken(
    chain: String = "1", address: String = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
  ) throws -> WalletToken {
    let token = try token(chain: chain, address: address)
    let context = try service.context(account: accounts[0])
    try service.add(
      imported: TokenImport(
        token: token, balance: entry(1_250_000, chain: chain), account: accounts[0].lowercased()),
      context: context)
    return token
  }

  func entry(_ value: UInt64, chain: String = "1") -> TokenBalanceEntry {
    TokenBalanceEntry(
      raw: word(value), updatedAt: Date(timeIntervalSince1970: 1_000),
      endpoint: stub.url(chain: chain))
  }

  func close() {
    stub.close()
    try? FileManager.default.removeItem(at: directory)
  }
}

final class BalanceRPCStub: @unchecked Sendable {
  private let lock = NSLock()
  private let host = UUID().uuidString.lowercased() + ".example"
  private var recorded: [URLRequest] = []
  private var pending: [BalanceURLProtocol] = []
  private var waiter: CheckedContinuation<Void, Never>?
  private var held = false
  private var delayed: String?
  var delayedChain: String? {
    get { lock.withLock { delayed } }
    set { lock.withLock { delayed = newValue } }
  }
  private var handler: @Sendable (URLRequest) throws -> JSONValue = { request in
    .array(
      try requestReads(request).map { read in
        let result =
          read.nestedString(at: ["method"]) == "eth_getBalance"
          ? "0xde0b6b3a7640000" : "0x" + Hex.encode(word(9))
        return .object([
          "jsonrpc": .string("2.0"), "id": read.objectValue?["id"] ?? .null,
          "result": .string(result),
        ])
      })
  }

  init() { BalanceURLProtocol.register(host: host, stub: self) }
  var requests: [URLRequest] { lock.withLock { recorded } }
  var hold: Bool {
    get { lock.withLock { held } }
    set { lock.withLock { held = newValue } }
  }
  var respond: @Sendable (URLRequest) throws -> JSONValue {
    get { lock.withLock { handler } }
    set { lock.withLock { handler = newValue } }
  }
  var client: RPCClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BalanceURLProtocol.self]
    return RPCClient(session: URLSession(configuration: configuration))
  }
  func url(chain: String) -> URL { URL(string: "https://\(host)/\(chain)")! }
  func close() {
    release()
    BalanceURLProtocol.unregister(host: host)
  }
  func waitForRequest() async {
    await withCheckedContinuation { continuation in
      let already = lock.withLock {
        if recorded.isEmpty {
          waiter = continuation
          return false
        }
        return true
      }
      if already { continuation.resume() }
    }
  }
  func receive(_ transport: BalanceURLProtocol) {
    let (hold, waiter) = lock.withLock {
      recorded.append(transport.inputRequest ?? transport.request)
      let hold = held || (delayed != nil && transport.request.url?.lastPathComponent == delayed)
      if hold { pending.append(transport) }
      let waiter = self.waiter
      self.waiter = nil
      return (hold, waiter)
    }
    waiter?.resume()
    if !hold { transport.complete(using: respond) }
  }
  func release() {
    let values = lock.withLock {
      held = false
      delayed = nil
      let values = pending
      pending = []
      return values
    }
    for value in values { value.complete(using: respond) }
  }
}

final class BalanceURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var stubs: [String: BalanceRPCStub] = [:]
  private let stateLock = NSRecursiveLock()
  private var stopped = false
  fileprivate var inputRequest: URLRequest?
  static func register(host: String, stub: BalanceRPCStub) { lock.withLock { stubs[host] = stub } }
  static func unregister(host: String) { _ = lock.withLock { stubs.removeValue(forKey: host) } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      var normalized = request
      normalized.httpBody = try JSONEncoder().encode(JSONValue.array(requestReads(request)))
      inputRequest = normalized
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    guard let host = request.url?.host, let stub = Self.lock.withLock({ Self.stubs[host] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    stub.receive(self)
  }
  override func stopLoading() { stateLock.withLock { stopped = true } }
  func complete(using handler: (URLRequest) throws -> JSONValue) {
    stateLock.withLock {
      guard !stopped else { return }
      do {
        let data = try JSONEncoder().encode(handler(inputRequest ?? request))
        client?.urlProtocol(
          self,
          didReceive: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
  }
}
