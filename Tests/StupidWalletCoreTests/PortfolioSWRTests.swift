import Combine
import Foundation
import Testing

@testable import StupidWalletCore

struct PortfolioSWRTests {
  @Test("a cold model hydrates the full portfolio before RPC and stays refreshing through prices")
  @MainActor func relaunchAndRevalidate() async throws {
    let catalog = SearchHTTPStub(responseHeaders: ["Cache-Control": "no-cache"])
    defer { catalog.close() }
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: "2")) }
    let environment = try BalanceEnvironment(tokenSearch: catalog.client())
    defer { environment.close() }
    _ = try environment.addToken()
    environment.stub.respond = { request in try balanceBody(request: request) }
    let original = WalletBalanceModel(service: environment.service)
    original.selectAccount(environment.accounts[0])
    await original.refresh()
    #expect(original.portfolioTotalDisplay == "$1,002.5")
    #expect(original.portfolioChangeDisplay != nil)

    // New service and catalog client: neither can inherit a session's remembered prices.
    let relaunched = model(environment: environment, catalog: catalog)
    relaunched.selectAccount(environment.accounts[0])
    #expect(relaunched.portfolioTotalDisplay == "$1,002.5")
    #expect(relaunched.portfolioChange == original.portfolioChange)
    #expect(relaunched.portfolioGroups.map(\.symbol) == ["ETH", "USDC"])
    #expect(relaunched.nativeRows.map(\.id) == ["1"])
    #expect(relaunched.portfolioHoldings.allSatisfy { $0.iconURL == nil })
    #expect(catalog.requests.count == 1)

    catalog.hold = true
    catalog.respond = { _ in (200, priceBody(nativePrice: "2000", tokenPrice: "4")) }
    let refresh = Task { await relaunched.refresh() }
    await catalog.waitForRequest(after: 1)
    #expect(relaunched.rows.allSatisfy { !$0.isLoading })
    #expect(relaunched.isRefreshing)
    #expect(relaunched.portfolioTotalDisplay == "$1,002.5")
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let overlap = Task {
      continuation.yield()
      await relaunched.refresh()
    }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    catalog.release()
    await refresh.value
    await overlap.value
    #expect(catalog.requests.count == 2)
    #expect(!relaunched.isRefreshing)
    #expect(relaunched.portfolioTotalDisplay == "$2,005")
    #expect(relaunched.error == nil)

    let nextLaunch = model(environment: environment, catalog: catalog)
    nextLaunch.selectAccount(environment.accounts[0])
    #expect(nextLaunch.portfolioTotalDisplay == "$2,005")
    nextLaunch.selectAccount(environment.accounts[1])
    #expect(nextLaunch.portfolioHoldings.isEmpty)
    #expect(nextLaunch.portfolioTotalUSD == nil)
    nextLaunch.selectAccount(environment.accounts[0])
    #expect(nextLaunch.portfolioTotalDisplay == "$2,005")
  }

  @Test(
    "relaunch retains prices and native holdings through offline or null-price responses",
    arguments: [false, true])
  @MainActor func failedRevalidation(nullPrices: Bool) async throws {
    let catalog = SearchHTTPStub()
    defer { catalog.close() }
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: "2")) }
    let environment = try BalanceEnvironment(tokenSearch: catalog.client())
    defer { environment.close() }
    _ = try environment.addToken()
    environment.stub.respond = { request in try balanceBody(request: request) }
    let original = WalletBalanceModel(service: environment.service)
    original.selectAccount(environment.accounts[0])
    await original.refresh()

    environment.stub.respond = { _ in throw URLError(.notConnectedToInternet) }
    catalog.respond = { _ in
      nullPrices
        ? (200, priceBody(nativePrice: nil, tokenPrice: nil))
        : (503, Data())
    }
    let relaunched = model(environment: environment, catalog: catalog)
    relaunched.selectAccount(environment.accounts[0])
    await relaunched.refresh()
    #expect(relaunched.portfolioTotalDisplay == "$1,002.5")
    #expect(relaunched.portfolioChange == original.portfolioChange)
    #expect(relaunched.portfolioHoldings.count == 2)
    #expect(!relaunched.isRefreshing)
    #expect(relaunched.rows.first?.error != nil)
    let nextLaunch = model(environment: environment, catalog: catalog)
    nextLaunch.selectAccount(environment.accounts[0])
    #expect(nextLaunch.portfolioTotalDisplay == "$1,002.5")
  }

  @Test("successful zero balances remove cached holdings and survive relaunch")
  @MainActor func zeroBalances() async throws {
    let catalog = SearchHTTPStub()
    defer { catalog.close() }
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: "2")) }
    let environment = try BalanceEnvironment(tokenSearch: catalog.client())
    defer { environment.close() }
    _ = try environment.addToken()
    let wallet = WalletBalanceModel(service: environment.service)
    wallet.selectAccount(environment.accounts[0])
    await wallet.refresh()
    #expect(wallet.portfolioHoldings.count == 2)
    environment.stub.respond = { request in
      try balanceBody(request: request, native: "0x0", tokenAmount: 0)
    }
    await wallet.refresh()
    #expect(wallet.portfolioHoldings.isEmpty)
    #expect(wallet.nativeTotal == "0.000000")
    let relaunched = model(environment: environment, catalog: catalog)
    relaunched.selectAccount(environment.accounts[0])
    #expect(relaunched.portfolioHoldings.isEmpty)
  }

  @Test("switching accounts during price loading cannot publish or persist the old quote")
  @MainActor func switchDuringPrices() async throws {
    let catalog = SearchHTTPStub()
    defer { catalog.close() }
    catalog.hold = true
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: "2")) }
    let environment = try BalanceEnvironment(tokenSearch: catalog.client())
    defer { environment.close() }
    _ = try environment.addToken()
    let wallet = WalletBalanceModel(service: environment.service)
    wallet.selectAccount(environment.accounts[0])
    let refresh = Task { await wallet.refresh() }
    await catalog.waitForRequest()
    wallet.selectAccount(environment.accounts[1])
    catalog.release()
    await refresh.value
    #expect(wallet.portfolioHoldings.isEmpty)
    #expect(wallet.portfolioTotalUSD == nil)
    #expect(!wallet.isRefreshing)
    let snapshot = try environment.service.tokens.load()
    #expect(snapshot.portfolios[environment.accounts[0].lowercased()]?.prices.isEmpty == true)
    #expect(snapshot.portfolios[environment.accounts[1].lowercased()] == nil)
  }

  @Test("portfolio persistence uses revision guards and token, network, and account cleanup")
  func cleanupAndLateWrites() throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let token = try environment.addToken()
    let request = try #require(PriceRequest(chainID: token.chainID, address: token.address))
    let native = try #require(PriceRequest(chainID: "8453", address: "native"))
    let service = environment.service
    let context = try service.context(account: environment.accounts[0])
    let old = try service.begin(context: context)
    let current = try service.begin(context: context)
    let quotes = [request: PriceQuote(priceUSD: "2"), native: PriceQuote(priceUSD: "1000")]
    #expect(throws: TokenError.configurationChanged) {
      try service.savePrices(context: context, refreshID: old, quotes: quotes)
    }
    try service.savePrices(context: context, refreshID: current, quotes: quotes)
    try service.tokens.remove(tokenID: token.id)
    #expect(try service.tokens.load().portfolios[context.account]?.prices[token.id] == nil)
    #expect(throws: TokenError.configurationChanged) {
      try service.savePrices(context: context, refreshID: current, quotes: quotes)
    }
    // A native-only network must clear its cache even when it has no tracked ERC-20s.
    try environment.networks.remove(chainID: "8453")
    #expect(try service.tokens.load().portfolios[context.account]?.prices.isEmpty == true)

    let next = try service.context(account: context.account)
    let refresh = try service.begin(context: next)
    let ether = try #require(PriceRequest(chainID: "1", address: "native"))
    try service.savePrices(
      context: next, refreshID: refresh, quotes: [ether: PriceQuote(priceUSD: "1")])
    try service.tokens.removeBalances(account: context.account)
    #expect(try service.tokens.load().portfolios[context.account] == nil)
    #expect(throws: TokenError.configurationChanged) {
      try service.savePrices(context: next, refreshID: refresh, quotes: [:])
    }
  }

  @Test("schema-1 stores without portfolio data remain readable and corrupt prices are preserved")
  func persistedFormat() throws {
    let environment = try BalanceEnvironment()
    defer { environment.close() }
    let token = try environment.addToken()
    let file = environment.directory.appendingPathComponent("tokens.json")
    var payload = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    payload.removeValue(forKey: "portfolios")
    try JSONSerialization.data(withJSONObject: payload).write(to: file)
    #expect(try environment.service.tokens.load().tokens == [token])
    #expect(try environment.service.tokens.load().portfolios.isEmpty)
    payload["portfolios"] = [
      environment.accounts[0].lowercased(): [
        "nativeBalances": [:],
        "prices": [token.id: ["priceUSD": "not-a-price", "updatedAt": 1000]],
      ]
    ]
    let corrupt = try JSONSerialization.data(withJSONObject: payload)
    try corrupt.write(to: file)
    #expect(throws: TokenError.corrupt) { try environment.service.tokens.load() }
    #expect(throws: TokenError.corrupt) { try environment.service.tokens.remove(tokenID: token.id) }
    #expect(try Data(contentsOf: file) == corrupt)
  }

  @Test("prices expire at 24 hours across session fallback, persistence, and relaunch")
  @MainActor func priceExpiry() async throws {
    let clock = PortfolioTestClock()
    let receivedAt = clock.date
    let catalog = SearchHTTPStub(responseHeaders: ["Cache-Control": "no-cache"])
    defer { catalog.close() }
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: "2")) }
    let environment = try BalanceEnvironment(tokenSearch: catalog.client(now: { clock.date }))
    defer { environment.close() }
    let token = try environment.addToken()
    environment.stub.respond = { request in try balanceBody(request: request) }
    let wallet = WalletBalanceModel(service: environment.service, now: { clock.date })
    wallet.selectAccount(environment.accounts[0])
    await wallet.refresh()
    #expect(wallet.portfolioTotalDisplay == "$1,002.5")

    catalog.respond = { _ in (503, Data()) }
    clock.advance(seconds: 86_399)
    await wallet.refresh()
    #expect(wallet.portfolioTotalDisplay == "$1,002.5")
    let retained = try environment.service.tokens.load().portfolios[wallet.account]
    #expect(retained?.prices[token.id]?.updatedAt == receivedAt)
    let beforeExpiry = model(environment: environment, catalog: catalog, now: { clock.date })
    beforeExpiry.selectAccount(environment.accounts[0])
    #expect(beforeExpiry.portfolioTotalDisplay == "$1,002.5")

    clock.advance(seconds: 1)
    await wallet.refresh()
    #expect(wallet.portfolioTotalUSD == nil)
    #expect(wallet.portfolioChange == nil)
    #expect(wallet.portfolioHoldings.count == 2)
    #expect(wallet.portfolioHoldings.allSatisfy { $0.valueUSD == nil && $0.change24h == nil })
    #expect(wallet.portfolioGroups.map(\.symbol) == ["ETH", "USDC"])
    #expect(wallet.nativeTotal == "1.000000")
    let afterExpiry = model(environment: environment, catalog: catalog, now: { clock.date })
    afterExpiry.selectAccount(environment.accounts[0])
    #expect(afterExpiry.portfolioTotalUSD == nil)
    await afterExpiry.refresh()
    #expect(afterExpiry.portfolioTotalUSD == nil)

    catalog.respond = { _ in (200, priceBody(nativePrice: "2000", tokenPrice: "4")) }
    await wallet.refresh()
    #expect(wallet.portfolioTotalDisplay == "$2,005")
    #expect(wallet.portfolioChange != nil)
    let recovered = try environment.service.tokens.load().portfolios[wallet.account]
    #expect(recovered?.prices[token.id]?.updatedAt == clock.date)
  }

  @Test("session cache hits and null-price fallbacks do not renew the 24-hour clock")
  func sessionPriceExpiry() async throws {
    let clock = PortfolioTestClock()
    let receivedAt = clock.date
    let catalog = SearchHTTPStub()
    defer { catalog.close() }
    let client = catalog.client(now: { clock.date })
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: nil)) }
    #expect(await client.prices(for: [request])[request]?.updatedAt == receivedAt)
    clock.advance(seconds: 30)
    #expect(await client.prices(for: [request])[request]?.updatedAt == receivedAt)
    #expect(catalog.requests.count == 1)
    catalog.respond = { _ in (200, priceBody(nativePrice: nil, tokenPrice: nil)) }
    clock.advance(seconds: 86_369)
    let retained = await client.prices(for: [request])[request]
    #expect(retained?.priceUSD == "1000")
    #expect(retained?.updatedAt == receivedAt)
    clock.advance(seconds: 1)
    let expired = await client.prices(for: [request])[request]
    #expect(expired?.priceUSD == nil)
    #expect(expired?.symbol == "ETH")
    #expect(expired?.decimals == 18)
    // The change arrived with the most recent response, so it keeps its own, later receipt time.
    #expect(expired?.change24h == "25")
  }

  @Test("a visible portfolio expires cached prices without another refresh")
  @MainActor func visiblePriceExpiry() async throws {
    let clock = PortfolioTestClock()
    let catalog = SearchHTTPStub(responseHeaders: ["Cache-Control": "no-cache"])
    defer { catalog.close() }
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: "2")) }
    let environment = try BalanceEnvironment(tokenSearch: catalog.client(now: { clock.date }))
    defer { environment.close() }
    _ = try environment.addToken()
    let wallet = WalletBalanceModel(service: environment.service, now: { clock.date })
    wallet.selectAccount(environment.accounts[0])
    await wallet.refresh()
    catalog.respond = { _ in (503, Data()) }
    clock.advance(seconds: 86_399)
    await wallet.refresh()
    #expect(wallet.portfolioTotalUSD != nil)
    let requestCount = catalog.requests.count
    let (expired, continuation) = AsyncStream<Bool>.makeStream()
    let observation = wallet.$portfolioTotalUSD.sink { value in
      if value == nil { continuation.yield(true) }
    }
    let deadline = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      continuation.yield(false)
    }
    defer {
      observation.cancel()
      deadline.cancel()
      continuation.finish()
    }
    clock.advance(seconds: 1)
    var iterator = expired.makeAsyncIterator()
    #expect(await iterator.next() == true)
    #expect(wallet.portfolioChange == nil)
    #expect(catalog.requests.count == requestCount)
  }

  @Test("a stale flip keeps a dominant holding's change instead of collapsing the total")
  @MainActor func retainedChangeAcrossStaleFlip() async throws {
    let catalog = SearchHTTPStub(responseHeaders: ["Cache-Control": "no-cache"])
    defer { catalog.close() }
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: "2")) }
    let environment = try BalanceEnvironment(tokenSearch: catalog.client())
    defer { environment.close() }
    _ = try environment.addToken()
    environment.stub.respond = { request in try balanceBody(request: request) }
    let wallet = WalletBalanceModel(service: environment.service)
    wallet.selectAccount(environment.accounts[0])
    await wallet.refresh()
    let priced = try #require(wallet.portfolioChange)
    #expect(priced.percent == "24.92")
    #expect(wallet.portfolioGroups.map(\.symbol) == ["ETH", "USDC"])

    // A non-`ok` status returns a price but no change for every identity.
    catalog.respond = { _ in
      (200, priceBody(nativePrice: "1000", tokenPrice: "2", withChanges: false))
    }
    await wallet.refresh()
    #expect(wallet.portfolioChange == priced)
    #expect(wallet.portfolioTotalDisplay == "$1,002.5")
    #expect(wallet.portfolioGroups.allSatisfy { $0.changeDisplay != nil })

    // The retained change is durable, not just session memory.
    let relaunched = model(environment: environment, catalog: catalog)
    relaunched.selectAccount(environment.accounts[0])
    #expect(relaunched.portfolioChange == priced)
  }

  @Test("a retained change expires on its own 24-hour clock while its price stays fresh")
  func retainedChangeExpiry() async throws {
    let clock = PortfolioTestClock()
    let receivedAt = clock.date
    let catalog = SearchHTTPStub(responseHeaders: ["Cache-Control": "no-cache"])
    defer { catalog.close() }
    let client = catalog.client(now: { clock.date })
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    catalog.respond = { _ in (200, priceBody(nativePrice: "1000", tokenPrice: nil)) }
    #expect(await client.prices(for: [request])[request]?.change24h == "25")

    catalog.respond = { _ in
      (200, priceBody(nativePrice: "1000", tokenPrice: nil, withChanges: false))
    }
    clock.advance(seconds: 60)
    let retained = await client.prices(for: [request])[request]
    #expect(retained?.change24h == "25")
    #expect(retained?.priceUSD == "1000")

    clock.advance(seconds: 86_339)
    let stillRetained = await client.prices(for: [request])[request]
    #expect(stillRetained?.change24h == "25")
    #expect(stillRetained?.updatedAt == clock.date)

    clock.advance(seconds: 1)
    let expired = await client.prices(for: [request])[request]
    #expect(expired?.change24h == nil)
    #expect(expired?.priceUSD == "1000")
    #expect(expired?.changeUpdatedAt == receivedAt)
  }

  @MainActor private func model(
    environment: BalanceEnvironment, catalog: SearchHTTPStub,
    now: @escaping @Sendable () -> Date = { Date() }
  )
    -> WalletBalanceModel
  {
    WalletBalanceModel(
      service: WalletBalanceService(
        directory: environment.directory, client: environment.stub.client,
        networkStore: environment.networks, tokenSearch: catalog.client(now: now)), now: now)
  }
}

private final class PortfolioTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 2_000_000_000)

  var date: Date { lock.withLock { value } }

  func advance(seconds: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(seconds) }
  }
}

private func priceBody(
  nativePrice: String?, tokenPrice: String?, withChanges: Bool = true
) -> Data {
  let native = nativePrice.map { "\"\($0)\"" } ?? "null"
  let token = tokenPrice.map { "\"\($0)\"" } ?? "null"
  let nativeChange = withChanges ? #","priceChange":{"h24":"25"}"# : ""
  let tokenChange = withChanges ? #","priceChange":{"h24":"0"}"# : ""
  return Data(
    """
    {"currency":"usd","prices":[
      {"chainId":1,"address":"native","status":"ok","priceUsd":\(native),"symbol":"ETH","decimals":18\(nativeChange),"imageUrl":"https://example.com/eth.png"},
      {"chainId":1,"address":"0xabcdefabcdefabcdefabcdefabcdefabcdefabcd","status":"ok","priceUsd":\(token),"symbol":"USDC","decimals":6\(tokenChange)}
    ]}
    """.utf8)
}

private func balanceBody(
  request: URLRequest, native: String = "0xde0b6b3a7640000", tokenAmount: UInt64 = 1_250_000
)
  throws -> JSONValue
{
  .array(
    try requestReads(request).enumerated().map { index, read in
      response(
        id: index + 1,
        result: .string(
          read.nestedString(at: ["method"]) == "eth_getBalance"
            ? native : "0x" + Hex.encode(word(tokenAmount))))
    })
}
