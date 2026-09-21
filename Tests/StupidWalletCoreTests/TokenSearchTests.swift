import Foundation
import Testing

@testable import StupidWalletCore

struct TokenSearchTests {
  @Test("catalog matches are normalized and carry display metadata")
  func clientParsing() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    stub.respond = { _ in
      (
        200,
        searchBody([
          entry(
            chain: 1, address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", name: "USD Coin",
            symbol: "USDC", image: "https://example.com/usdc.png",
            marketCap: "74090707373.5601"),
          entry(
            chain: 1, address: "0x6b175474e89094c44da98b954eedeac495271d0f", name: "Dai",
            symbol: "DAI"),
        ])
      )
    }
    let results = try await stub.client().search(query: "usdc", chainID: "1", limit: 5)
    #expect(results.count == 2)
    #expect(results[0].address == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(results[0].name == "USD Coin")
    #expect(results[0].symbol == "USDC")
    #expect(results[0].imageURL == URL(string: "https://example.com/usdc.png"))
    #expect(results[0].marketCap == "74090707373")
    #expect(results[0].id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(results[1].imageURL == nil)
    #expect(results[1].chainID == "1")
  }

  @Test("the catalog request is scoped to one chain, bounded, and cached")
  func clientRequestShapeAndCache() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    stub.respond = { _ in (200, searchBody([])) }
    let client = stub.client()
    _ = try await client.search(query: "  usdc  ", chainID: "8453", limit: 7)
    _ = try await client.search(query: "USDC", chainID: "8453", limit: 7)
    _ = try await client.search(query: "usdc", chainID: "1", limit: 7)
    let requests = stub.requests
    #expect(requests.count == 2)
    let first = try #require(requests.first)
    #expect(first.httpMethod == "GET")
    let query = try queryItems(of: first)
    #expect(query["q"] == "usdc")
    #expect(query["chainId"] == "8453")
    #expect(query["limit"] == "7")
    #expect(try queryItems(of: requests[1])["chainId"] == "1")
  }

  @Test("unusable catalog entries are dropped but an unusable response fails")
  func clientValidation() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let client = stub.client()

    stub.respond = { _ in
      (
        200,
        searchBody([
          entry(chain: 1, address: "0x6b175474e89094c44da98b954eedeac495271d0f", symbol: "DAI"),
          entry(chain: 1, address: "0xnothex", symbol: "BAD"),
          entry(chain: 1, address: "0x6b175474e89094c44da98b954eedeac495271d0f", symbol: ""),
        ])
      )
    }
    let partial = try await client.search(query: "dai", chainID: "1")
    #expect(partial.map(\.symbol) == ["DAI"])

    stub.respond = { _ in
      (200, searchBody([entry(chain: 8453, address: "0x6b175474e89094c44da98b954eedeac495271d0f")]))
    }
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "wrong-chain", chainID: "1")
    }

    stub.respond = { _ in (200, Data(#"{"tokens":{}}"#.utf8)) }
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "not-an-array", chainID: "1")
    }

    stub.respond = { _ in (200, Data(repeating: 0x20, count: 600_000)) }
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "oversized", chainID: "1")
    }

    stub.respond = { _ in (400, Data(#"{"error":{"code":"invalid_request"}}"#.utf8)) }
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "rejected", chainID: "1")
    }

    stub.respond = { _ in (503, Data()) }
    await #expect(throws: TokenSearchError.unavailable) {
      try await client.search(query: "down", chainID: "1")
    }

    stub.respond = { _ in throw URLError(.notConnectedToInternet) }
    await #expect(throws: TokenSearchError.unavailable) {
      try await client.search(query: "offline", chainID: "1")
    }
  }

  @Test("invalid search arguments never reach the network")
  func clientArguments() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let client = stub.client()
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "   ", chainID: "1")
    }
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "usdc", chainID: "not-a-chain")
    }
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "usdc", chainID: "1", limit: 0)
    }
    await #expect(throws: TokenSearchError.invalidResponse) {
      try await client.search(query: "usdc", chainID: "1", limit: 101)
    }
    #expect(stub.requests.isEmpty)
  }

  @Test("catalog search merges configured networks by market cap and marks tracked tokens")
  func searchMergesNetworks() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let environment = try BalanceEnvironment(tokenSearch: stub.client())
    defer { environment.close() }
    let tracked = try environment.addToken(chain: "8453")

    stub.respond = { request in
      switch (try? queryItems(of: request)["chainId"]) ?? "" {
      case "1":
        return (
          200,
          searchBody([
            entry(
              chain: 1, address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", name: "USD Coin",
              symbol: "USDC", marketCap: "74228944289"),
            entry(
              chain: 1, address: "0x6b175474e89094c44da98b954eedeac495271d0f", name: "Dai",
              symbol: "DAI", marketCap: "5000000000"),
          ])
        )
      case "8453":
        return (
          200,
          searchBody([
            entry(
              chain: 8453, address: tracked.address, name: "USD Coin", symbol: "USDC",
              marketCap: "7000000000")
          ])
        )
      default:
        return (200, searchBody([]))
      }
    }

    let context = try environment.service.context(account: environment.accounts[0])
    let outcome = try await environment.service.searchTokens(context: context, query: "usdc")
    #expect(outcome.failedNetworkCount == 0)
    #expect(
      outcome.candidates.map(\.id) == [
        "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "8453:\(tracked.address)",
        "1:0x6b175474e89094c44da98b954eedeac495271d0f",
      ])
    // Ordered by market cap across networks, not grouped by network.
    #expect(outcome.candidates.map(\.isTracked) == [false, true, false])
    #expect(outcome.candidates[0].networkName == "Ethereum")
    #expect(outcome.candidates[0].name == "USD Coin")
    #expect(outcome.candidates[0].marketCapDisplay == "$74.2B")
    #expect(outcome.candidates[1].networkName == "Base")
    #expect(outcome.candidates[1].symbol == tracked.symbol)
    #expect(outcome.candidates[1].marketCapDisplay == "$7B")
    #expect(outcome.candidates[2].name == "Dai")
    #expect(outcome.candidates[2].marketCapDisplay == "$5B")
  }

  @Test("market cap leads and equal or unknown caps interleave configured networks")
  func searchRankingTies() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let environment = try BalanceEnvironment(tokenSearch: stub.client())
    defer { environment.close() }
    stub.respond = { request in
      switch (try? queryItems(of: request)["chainId"]) ?? "" {
      case "1":
        return (
          200,
          searchBody([
            entry(
              chain: 1, address: "0x0000000000000000000000000000000000000001", name: "No Cap",
              symbol: "NOCAP"),
            entry(
              chain: 1, address: "0x0000000000000000000000000000000000000002", name: "Second",
              symbol: "SECOND"),
          ])
        )
      case "8453":
        return (
          200,
          searchBody([
            entry(
              chain: 8453, address: "0x0000000000000000000000000000000000000003", name: "Base One",
              symbol: "BASEONE"),
            entry(
              chain: 8453, address: "0x0000000000000000000000000000000000000004",
              name: "Base Second", symbol: "BASESECOND"),
          ])
        )
      case "42161":
        return (
          200,
          searchBody([
            entry(
              chain: 42161, address: "0x0000000000000000000000000000000000000005", name: "Capped",
              symbol: "CAPPED", marketCap: "1000000000"),
            entry(
              chain: 42161, address: "0x0000000000000000000000000000000000000006", name: "Tie A",
              symbol: "TIEA", marketCap: "1000000000"),
          ])
        )
      default:
        return (200, searchBody([]))
      }
    }
    let context = try environment.service.context(account: environment.accounts[0])
    let outcome = try await environment.service.searchTokens(context: context, query: "cap")
    // Capped tokens first, then catalog rank interleaved across the configured networks.
    #expect(
      outcome.candidates.map(\.symbol) == [
        "CAPPED", "TIEA", "NOCAP", "BASEONE", "SECOND", "BASESECOND",
      ])
    #expect(
      outcome.candidates.map(\.marketCapDisplay) == ["$1B", "$1B", nil, nil, nil, nil])
  }

  @Test("market caps scale exactly from the decimal string")
  func marketCapFormatting() {
    #expect(MarketCapFormatter.compact("0") == "$0")
    #expect(MarketCapFormatter.compact("0000") == "$0")
    #expect(MarketCapFormatter.compact("999") == "$999")
    #expect(MarketCapFormatter.compact("1000") == "$1K")
    #expect(MarketCapFormatter.compact("12345") == "$12.3K")
    #expect(MarketCapFormatter.compact("1000000") == "$1M")
    #expect(MarketCapFormatter.compact("74228944289") == "$74.2B")
    #expect(MarketCapFormatter.compact("2000000000000") == "$2T")
    #expect(MarketCapFormatter.compact("999999999999999") == "$999.9T")
    // The catalog may report a fractional market cap; the fraction is truncated for display.
    #expect(MarketCapFormatter.compact("74090707373.5601") == "$74B")
    #expect(MarketCapFormatter.compact("7000000000.9") == "$7B")
    #expect(MarketCapFormatter.compact(" 12345 ") == "$12.3K")
    #expect(MarketCapFormatter.compact(nil) == nil)
    #expect(MarketCapFormatter.compact("") == nil)
    #expect(MarketCapFormatter.compact("1e9") == nil)
    #expect(MarketCapFormatter.compact(".5") == nil)
    #expect(MarketCapFormatter.compact("1.2.3") == nil)
    #expect(MarketCapFormatter.compact("-5") == nil)
  }

  @Test("bulk prices carry each identity's price and display metadata")
  func clientNativeAndPrices() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let client = stub.client()

    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"ok","priceUsd":"2622.6440903517046","symbol":"ETH","decimals":18,"imageUrl":"https://example.com/eth.png","priceChange":{"h1":"1.2","h24":"4.248456574507254","d7":"6.5"}},{"chainId":8453,"address":"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913","status":"ok","priceUsd":"0.9997420860108598","symbol":"USDC","decimals":6,"priceChange":{"h24":"-0.00661178995570606"}},{"chainId":10,"address":"0x4200000000000000000000000000000000000042","status":"not_found","priceUsd":null}]}"#
            .utf8)
      )
    }

    let nativeRequest = try #require(PriceRequest(chainID: "1", address: "native"))
    let usdc = try #require(
      PriceRequest(chainID: "8453", address: "0x833589FCD6eDb6E08f4C7C32D4f71b54bdA02913"))
    let missing = try #require(
      PriceRequest(chainID: "10", address: "0x4200000000000000000000000000000000000042"))
    let prices = await client.prices(for: [nativeRequest, usdc, missing, nativeRequest])
    #expect(prices[nativeRequest]?.priceUSD == "2622.6440903517046")
    #expect(prices[nativeRequest]?.change24h == "4.248456574507254")
    #expect(prices[nativeRequest]?.symbol == "ETH")
    #expect(prices[nativeRequest]?.decimals == 18)
    #expect(prices[nativeRequest]?.imageURL == URL(string: "https://example.com/eth.png"))
    #expect(prices[usdc]?.priceUSD == "0.9997420860108598")
    #expect(prices[usdc]?.change24h == "-0.00661178995570606")
    #expect(prices[usdc]?.symbol == "USDC")
    #expect(prices[usdc]?.decimals == 6)
    #expect(prices[missing] == nil)

    // The request carries canonical identities and is cached after the first call.
    let priceRequests = stub.requests.filter { $0.url?.path.hasSuffix("/prices") == true }
    #expect(priceRequests.count == 1)
    let query = try #require(priceRequests.first?.url?.query)
    #expect(
      query
        == "tokens=10:0x4200000000000000000000000000000000000042,1:native,8453:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
    )
    _ = await client.prices(for: [usdc, nativeRequest, missing])
    #expect(stub.requests.filter { $0.url?.path.hasSuffix("/prices") == true }.count == 1)

    #expect(PriceRequest(chainID: "not-a-chain", address: "native") == nil)
    #expect(PriceRequest(chainID: "1", address: "0x1234") == nil)
  }

  @Test("a stale identity contributes metadata without caching a price")
  func staleMetadata() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let client = stub.client()
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"stale","priceUsd":null,"symbol":"ETH","decimals":18,"imageUrl":"https://example.com/eth.png"}]}"#
            .utf8)
      )
    }
    let quote = await client.prices(for: [request])[request]
    #expect(quote?.priceUSD == nil)
    #expect(quote?.symbol == "ETH")
    #expect(quote?.decimals == 18)
    #expect(quote?.imageURL == URL(string: "https://example.com/eth.png"))
    #expect(stub.requests.count == 1)
    // Transient outcomes are not cached, so the next call re-requests.
    _ = await client.prices(for: [request])
    #expect(stub.requests.count == 2)
  }

  @Test("a stale price is shown and cached, with changes withheld")
  func stalePrice() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let client = stub.client()
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"stale","priceUsd":"2600","symbol":"ETH","decimals":18,"priceChange":{"h24":"4.2"}}]}"#
            .utf8)
      )
    }
    let quote = await client.prices(for: [request])[request]
    #expect(quote?.priceUSD == "2600")
    #expect(quote?.symbol == "ETH")
    #expect(quote?.change24h == nil)
    #expect(stub.requests.count == 1)
    _ = await client.prices(for: [request])
    #expect(stub.requests.count == 1)
  }

  @Test("a later response with no price keeps the last known price")
  func staleWhileRevalidate() async throws {
    let stub = SearchHTTPStub(responseHeaders: ["Cache-Control": "no-store"])
    defer { stub.close() }
    let client = stub.client()
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"ok","priceUsd":"2600"}]}"#
            .utf8)
      )
    }
    #expect(await client.prices(for: [request])[request]?.priceUSD == "2600")
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"price_unavailable","priceUsd":null}]}"#
            .utf8)
      )
    }
    #expect(await client.prices(for: [request])[request]?.priceUSD == "2600")
    #expect(stub.requests.count == 2)
  }

  @Test(
    "transient price statuses recover on the next refresh rather than caching a missing value",
    arguments: ["stale", "price_unavailable", "upstream_error", "rate_limited"])
  func transientPrices(status: String) async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let client = stub.client()
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    stub.respond = { _ in
      (
        200,
        Data(
          "{\"currency\":\"usd\",\"prices\":[{\"chainId\":1,\"address\":\"native\",\"status\":\"\(status)\",\"priceUsd\":null}]}"
            .utf8)
      )
    }
    #expect(await client.prices(for: [request]).isEmpty)
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"ok","priceUsd":"2600"}]}"#
            .utf8)
      )
    }
    #expect(await client.prices(for: [request])[request]?.priceUSD == "2600")
    #expect(await client.prices(for: [request])[request]?.priceUSD == "2600")
    #expect(stub.requests.count == 2)
  }

  @Test("failed price requests are not cached as missing prices")
  func failedPrices() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let client = stub.client()
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    stub.respond = { _ in throw URLError(.timedOut) }
    #expect(await client.prices(for: [request]).isEmpty)
    stub.respond = { _ in (503, Data()) }
    #expect(await client.prices(for: [request]).isEmpty)
    stub.respond = { _ in (200, Data(#"{"currency":"usd","prices":{}}"#.utf8)) }
    #expect(await client.prices(for: [request]).isEmpty)
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"ok","priceUsd":"2600"}]}"#
            .utf8)
      )
    }
    #expect(await client.prices(for: [request])[request]?.priceUSD == "2600")
    #expect(stub.requests.count == 4)
  }

  @Test(
    "price memory caching does not extend HTTP freshness",
    arguments: [
      ["Cache-Control": "public, max-age=0"],
      ["Cache-Control": "public, max-age=3", "Age": "3"],
      ["Cache-Control": "public, max-age=60", "Date": "Wed, 01 Jan 2020 00:00:00 GMT"],
      ["Cache-Control": "no-store"],
      ["Cache-Control": "no-cache, max-age=60"],
    ])
  func priceHTTPFreshness(headers: [String: String]) async throws {
    let stub = SearchHTTPStub(responseHeaders: headers)
    defer { stub.close() }
    let client = stub.client()
    let request = try #require(PriceRequest(chainID: "1", address: "native"))
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"ok","priceUsd":"2600"}]}"#
            .utf8)
      )
    }
    #expect(await client.prices(for: [request])[request]?.priceUSD == "2600")
    stub.respond = { _ in
      (
        200,
        Data(
          #"{"currency":"usd","prices":[{"chainId":1,"address":"native","status":"ok","priceUsd":"2700"}]}"#
            .utf8)
      )
    }
    #expect(await client.prices(for: [request])[request]?.priceUSD == "2700")
    #expect(stub.requests.count == 2)
  }

  @Test("one unreachable network still returns the other networks' matches")
  func searchToleratesPartialFailure() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let environment = try BalanceEnvironment(tokenSearch: stub.client())
    defer { environment.close() }
    stub.respond = { request in
      guard (try? queryItems(of: request)["chainId"]) == "1" else { throw URLError(.timedOut) }
      return (
        200,
        searchBody([
          entry(chain: 1, address: "0x6b175474e89094c44da98b954eedeac495271d0f", symbol: "DAI")
        ])
      )
    }
    let context = try environment.service.context(account: environment.accounts[0])
    let outcome = try await environment.service.searchTokens(context: context, query: "dai")
    #expect(outcome.candidates.count == 1)
    #expect(outcome.failedNetworkCount == 3)
  }

  @Test("a completely unreachable catalog surfaces the failure")
  func searchFailsLoudly() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let environment = try BalanceEnvironment(tokenSearch: stub.client())
    defer { environment.close() }
    stub.respond = { _ in throw URLError(.cannotConnectToHost) }
    let context = try environment.service.context(account: environment.accounts[0])
    await #expect(throws: TokenSearchError.unavailable) {
      try await environment.service.searchTokens(context: context, query: "usdc")
    }
  }

  @Test("an address resolves on the selected network without touching the catalog")
  func addressCandidate() async throws {
    let stub = SearchHTTPStub()
    defer { stub.close() }
    let environment = try BalanceEnvironment(tokenSearch: stub.client())
    defer { environment.close() }
    let address = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    let tracked = try environment.addToken(chain: "10", address: address)

    environment.stub.respond = { request in
      switch request.url?.lastPathComponent {
      case "1": return metadataResponse()
      case "8453":
        return .array(
          metadataResponses().enumerated().map { index, value in
            index == 0 ? response(id: 1, result: .string("0x")) : value
          })
      default: throw URLError(.timedOut)
      }
    }

    let context = try environment.service.context(account: environment.accounts[0])
    let ethereum = await environment.service.addressCandidate(
      context: context, chainID: "1", address: address.uppercased())
    let candidate = try #require(try? ethereum.get())
    #expect(candidate.symbol == "USDC")
    #expect(candidate.networkName == "Ethereum")
    #expect(candidate.name == nil)
    #expect(candidate.isTracked == false)
    #expect(candidate.marketCapDisplay == nil)

    let base = await environment.service.addressCandidate(
      context: context, chainID: "8453", address: address)
    #expect(throws: TokenError.notContract) { try base.get() }

    let optimism = await environment.service.addressCandidate(
      context: context, chainID: "10", address: address)
    let trackedCandidate = try #require(try? optimism.get())
    #expect(trackedCandidate.isTracked)
    #expect(trackedCandidate.symbol == tracked.symbol)

    let arbitrum = await environment.service.addressCandidate(
      context: context, chainID: "42161", address: address)
    #expect(throws: TokenError.transport) { try arbitrum.get() }

    let unconfigured = await environment.service.addressCandidate(
      context: context, chainID: "56", address: address)
    #expect(throws: TokenError.configurationChanged) { try unconfigured.get() }

    #expect(stub.requests.isEmpty)
  }

}

private func searchBody(_ entries: [String]) -> Data {
  Data("{\"tokens\":[\(entries.joined(separator: ","))]}".utf8)
}

private func entry(
  chain: Int, address: String, name: String = "USDC", symbol: String = "USDC", image: String? = nil,
  marketCap: String? = nil
) -> String {
  let imageField = image.map { ",\"imageUrl\":\"\($0)\"" } ?? ""
  let capField = marketCap.map { ",\"marketCapUsd\":\"\($0)\"" } ?? ""
  return
    "{\"chainId\":\(chain),\"address\":\"\(address)\",\"name\":\"\(name)\",\"symbol\":\"\(symbol)\",\"decimals\":6\(imageField)\(capField)}"
}

private func queryItems(of request: URLRequest) throws -> [String: String] {
  let url = try #require(request.url)
  let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
  return Dictionary(
    uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
      item.value.map { (item.name, $0) }
    })
}

final class SearchHTTPStub: @unchecked Sendable {
  private let lock = NSLock()
  private let host = UUID().uuidString.lowercased() + ".example"
  private let responseHeaders: [String: String]
  private var recorded: [URLRequest] = []
  private var pending: [SearchURLProtocol] = []
  private var waiter: CheckedContinuation<Void, Never>?
  private var held = false
  private var handler: @Sendable (URLRequest) throws -> (Int, Data) = { _ in
    (200, Data(#"{"tokens":[]}"#.utf8))
  }

  init(responseHeaders: [String: String] = [:]) {
    self.responseHeaders = responseHeaders
    SearchURLProtocol.register(host: host, stub: self)
  }

  var requests: [URLRequest] { lock.withLock { recorded } }

  var hold: Bool {
    get { lock.withLock { held } }
    set { lock.withLock { held = newValue } }
  }

  func waitForRequest(after count: Int = 0) async {
    await withCheckedContinuation { continuation in
      let already = lock.withLock {
        if recorded.count <= count {
          waiter = continuation
          return false
        }
        return true
      }
      if already { continuation.resume() }
    }
  }

  var respond: @Sendable (URLRequest) throws -> (Int, Data) {
    get { lock.withLock { handler } }
    set { lock.withLock { handler = newValue } }
  }

  func client(now: @escaping @Sendable () -> Date = { Date() }) -> StupidTokensClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SearchURLProtocol.self]
    return StupidTokensClient(
      session: URLSession(configuration: configuration), baseURL: URL(string: "https://\(host)")!,
      now: now)
  }

  func close() {
    release()
    SearchURLProtocol.unregister(host: host)
  }

  func receive(_ transport: SearchURLProtocol) {
    let (hold, waiter) = lock.withLock {
      recorded.append(transport.request)
      if held { pending.append(transport) }
      let waiter = self.waiter
      self.waiter = nil
      return (held, waiter)
    }
    waiter?.resume()
    if !hold { transport.complete(using: respond, headers: responseHeaders) }
  }

  func release() {
    let values = lock.withLock {
      held = false
      let values = pending
      pending = []
      return values
    }
    for value in values { value.complete(using: respond, headers: responseHeaders) }
  }
}

final class SearchURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private let stateLock = NSRecursiveLock()
  private var stopped = false
  nonisolated(unsafe) private static var stubs: [String: SearchHTTPStub] = [:]

  static func register(host: String, stub: SearchHTTPStub) {
    lock.withLock { stubs[host] = stub }
  }

  static func unregister(host: String) {
    _ = lock.withLock { stubs.removeValue(forKey: host) }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let host = request.url?.host, let stub = Self.lock.withLock({ Self.stubs[host] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    stub.receive(self)
  }

  override func stopLoading() { stateLock.withLock { stopped = true } }

  func complete(using handler: (URLRequest) throws -> (Int, Data), headers: [String: String]) {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !stopped else { return }
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    do {
      let (status, data) = try handler(request)
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
        cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}
