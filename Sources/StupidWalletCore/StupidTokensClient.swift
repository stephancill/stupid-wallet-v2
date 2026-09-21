import Foundation

public enum TokenSearchError: Error, Sendable, Equatable, LocalizedError {
  case unavailable
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .unavailable: "Token search could not be reached. Please retry."
    case .invalidResponse: "Token search returned an invalid response."
    }
  }
}

/// One token identity for a bulk price request. `native` is the catalog's literal address for a
/// chain's native currency.
public struct PriceRequest: Sendable, Hashable {
  public let chainID: String
  public let address: String

  public init?(chainID: String, address: String) {
    guard let chain = ChainStore.normalize(chainID),
      let normalized = StupidTokensClient.normalizeTokenAddress(address)
    else { return nil }
    self.chainID = chain
    self.address = normalized
  }
}

/// One catalog identity's USD price, reported 24-hour change, and display metadata. The metadata is
/// carried on the same bulk prices response so the home screen needs no per-token metadata request.
public struct PriceQuote: Sendable, Equatable {
  /// The USD price, or nil when the catalog has no current price (for example a stale source).
  public let priceUSD: String?
  /// Signed 24-hour change in percent, e.g. `4.25` or `-0.01`, when the catalog reports one.
  public let change24h: String?
  /// Catalog display metadata, present for identities the catalog knows.
  public let symbol: String?
  public let decimals: UInt8?
  public let imageURL: URL?

  public var hasMetadata: Bool { symbol != nil || decimals != nil || imageURL != nil }

  public init(
    priceUSD: String?, change24h: String? = nil, symbol: String? = nil, decimals: UInt8? = nil,
    imageURL: URL? = nil
  ) {
    self.priceUSD = priceUSD
    self.change24h = change24h
    self.symbol = symbol
    self.decimals = decimals
    self.imageURL = imageURL
  }
}

/// One catalog match from the Stupid Tokens search API. This is discovery metadata only:
/// canonical token metadata is always read on chain before a token can be imported.
public struct TokenSearchResult: Sendable, Equatable, Identifiable {
  public let chainID: String
  public let address: String
  public let name: String
  public let symbol: String
  public let decimals: UInt8?
  public let imageURL: URL?
  /// Decimal USD market cap as reported by the catalog, used only for ranking. Display-only.
  public let marketCap: String?

  public var id: String { "\(chainID):\(address.lowercased())" }

  public init(
    chainID: String, address: String, name: String, symbol: String, decimals: UInt8? = nil,
    imageURL: URL? = nil, marketCap: String? = nil
  ) {
    self.chainID = chainID
    self.address = address
    self.name = name
    self.symbol = symbol
    self.decimals = decimals
    self.imageURL = imageURL
    self.marketCap = marketCap
  }
}

/// Compact USD display for catalog market caps, scaled from the exact decimal string so no
/// floating-point rounding is involved. A fractional part is truncated for display.
public enum MarketCapFormatter {
  public static func compact(_ value: String?) -> String? {
    guard let value, let digits = integerDigits(value) else { return nil }
    var scale = 12
    var suffix = "T"
    for unit in [(3, 0, ""), (6, 3, "K"), (9, 6, "M"), (12, 9, "B")] where digits.count <= unit.0 {
      scale = unit.1
      suffix = unit.2
      break
    }
    var text = String(digits.prefix(digits.count - scale))
    if scale > 0, digits.count > scale {
      let fraction = digits[digits.index(digits.startIndex, offsetBy: digits.count - scale)]
      if fraction != "0" { text += ".\(fraction)" }
    }
    return "$\(text)\(suffix)"
  }

  /// The significant integer digits of a non-negative decimal string, or nil when unusable.
  static func integerDigits(_ value: String) -> String? {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, let whole = parts.first, !whole.isEmpty,
      whole.allSatisfy(\.isNumber), parts.count == 1 || parts[1].allSatisfy(\.isNumber)
    else { return nil }
    let digits = String(whole.drop { $0 == "0" })
    return digits.isEmpty ? "0" : digits
  }
}

/// Keyless read client for `https://tokens.stupidtech.net`.
///
/// The service is free and unauthenticated and asks callers to cache responses, so identical
/// searches and prices are served from bounded in-memory caches. A bulk prices response carries each
/// identity's display metadata as well, so the home screen resolves native symbols, decimals, and
/// icons from the same call. Price caching also respects the response's HTTP freshness; a transient
/// failure is not a cached missing price.
public actor StupidTokensClient {
  public static let defaultBaseURL = URL(string: "https://tokens.stupidtech.net")!
  public static let shared = StupidTokensClient()

  private static let maximumResponseBytes = 524_288
  private static let maximumSearchLimit = 100

  private let session: URLSession
  private let baseURL: URL
  private let timeout: TimeInterval
  private let cacheLifetime: TimeInterval
  private let cacheLimit: Int
  private let priceLifetime: TimeInterval
  private var cache: [String: (expiresAt: Date, results: [TokenSearchResult])] = [:]
  private var priceCache: [PriceRequest: (expiresAt: Date, quote: PriceQuote?)] = [:]
  private var lastKnownPrices: [PriceRequest: PriceQuote] = [:]

  public init(
    session: URLSession = .shared,
    baseURL: URL = StupidTokensClient.defaultBaseURL,
    timeout: TimeInterval = 15,
    cacheLifetime: TimeInterval = 60,
    cacheLimit: Int = 64,
    priceLifetime: TimeInterval = 60
  ) {
    self.session = session
    self.baseURL = baseURL
    self.timeout = timeout
    self.cacheLifetime = cacheLifetime
    self.cacheLimit = cacheLimit
    self.priceLifetime = priceLifetime
  }

  /// Case-insensitive name/symbol substring or exact address search on one chain.
  public func search(query: String, chainID: String, limit: Int = 20) async throws
    -> [TokenSearchResult]
  {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let chain = ChainStore.normalize(chainID),
      (1...Self.maximumSearchLimit).contains(limit)
    else { throw TokenSearchError.invalidResponse }
    let key = "\(chain)|\(limit)|\(trimmed.lowercased())"
    if let cached = cache[key], cached.expiresAt > Date() { return cached.results }
    let results = try await fetch(query: trimmed, chainID: chain, limit: limit)
    if cache.count >= cacheLimit {
      cache = cache.filter { $0.value.expiresAt > Date() }
    }
    if cache.count >= cacheLimit { cache.removeAll() }
    cache[key] = (Date().addingTimeInterval(cacheLifetime), results)
    return results
  }

  private func fetch(query: String, chainID: String, limit: Int) async throws
    -> [TokenSearchResult]
  {
    guard
      var components = URLComponents(
        url: baseURL.appendingPathComponent("v1/search"), resolvingAgainstBaseURL: false)
    else { throw TokenSearchError.invalidResponse }
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "chainId", value: chainID),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    guard let url = components.url else { throw TokenSearchError.invalidResponse }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = timeout

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TokenSearchError.unavailable
    }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw TokenSearchError.unavailable }
    // A rejected request means this client built an invalid query, not a transport problem.
    if http.statusCode == 400 { throw TokenSearchError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else { throw TokenSearchError.unavailable }
    guard data.count <= Self.maximumResponseBytes,
      case .object(let root)? = try? JSONValue.parse(data),
      case .array(let items)? = root["tokens"]
    else { throw TokenSearchError.invalidResponse }

    var results: [TokenSearchResult] = []
    for item in items {
      guard let result = Self.result(from: item, chainID: chainID) else { continue }
      results.append(result)
    }
    // Unusable entries are dropped, but a response where nothing was usable means the catalog
    // contract changed and must not be reported as "no matches".
    if results.isEmpty, !items.isEmpty { throw TokenSearchError.invalidResponse }
    return results
  }

  /// Bulk USD prices and display metadata for the requested identities, keyed by request. The
  /// catalog returns its last known price for any freshness status, so an identity with a quoted
  /// price or usable metadata is present and one with no known price is absent. The last known price
  /// is also retained across refreshes, so a later response with no price never blanks a value already
  /// shown. Requests are sent in the catalog's canonical order, 50 per call.
  public func prices(for requests: [PriceRequest]) async -> [PriceRequest: PriceQuote] {
    var resolved: [PriceRequest: PriceQuote] = [:]
    var missing: [PriceRequest] = []
    for request in Set(requests) {
      guard let cached = priceCache[request], cached.expiresAt > Date() else {
        missing.append(request)
        continue
      }
      if let quote = cached.quote {
        resolved[request] = quote
        remember(quote, for: request)
      }
    }
    var index = 0
    let ordered = missing.sorted { "\($0.chainID):\($0.address)" < "\($1.chainID):\($1.address)" }
    while index < ordered.count {
      let chunk = Array(ordered[index..<min(index + 50, ordered.count)])
      if let batch = await fetchPrices(chunk) {
        for request in chunk {
          if let quote = batch.quotes[request] {
            resolved[request] = quote
            remember(quote, for: request)
          }
          if batch.cacheable.contains(request) {
            priceCache[request] = (
              Date().addingTimeInterval(batch.cacheLifetime), batch.quotes[request]
            )
          }
        }
      }
      index += 50
    }
    // Stale-while-revalidate: keep showing the last known price when this refresh has none.
    for request in Set(requests) where resolved[request]?.priceUSD == nil {
      guard let last = lastKnownPrices[request] else { continue }
      resolved[request] = Self.merging(resolved[request], with: last)
    }
    return resolved
  }

  /// Retains the most recent quote that carried a price, for stale-while-revalidate display.
  private func remember(_ quote: PriceQuote, for request: PriceRequest) {
    guard quote.priceUSD != nil else { return }
    lastKnownPrices[request] = quote
  }

  /// A quote's own metadata with a fallback quote's price and change.
  static func merging(_ quote: PriceQuote?, with last: PriceQuote) -> PriceQuote {
    guard let quote, quote.priceUSD == nil else { return quote ?? last }
    return PriceQuote(
      priceUSD: last.priceUSD, change24h: last.change24h,
      symbol: quote.symbol ?? last.symbol, decimals: quote.decimals ?? last.decimals,
      imageURL: quote.imageURL ?? last.imageURL)
  }

  private struct PriceBatch {
    /// Quotes with a price or usable metadata; absent when the catalog does not know the identity.
    let quotes: [PriceRequest: PriceQuote]
    /// Requests whose outcome is stable enough to cache: a price or a definitive not-found.
    let cacheable: Set<PriceRequest>
    let cacheLifetime: TimeInterval
  }

  private func fetchPrices(_ requests: [PriceRequest]) async -> PriceBatch? {
    guard !requests.isEmpty,
      var components = URLComponents(
        url: baseURL.appendingPathComponent("v1/prices"), resolvingAgainstBaseURL: false)
    else { return nil }
    components.queryItems = [
      URLQueryItem(
        name: "tokens",
        value: requests.map { "\($0.chainID):\($0.address)" }.joined(separator: ","))
    ]
    guard let url = components.url else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = timeout
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count <= Self.maximumResponseBytes,
      case .object(let root)? = try? JSONValue.parse(data),
      root["currency"]?.stringValue == "usd",
      case .array(let entries)? = root["prices"]
    else { return nil }
    var quotes: [PriceRequest: PriceQuote] = [:]
    var cacheable: Set<PriceRequest> = []
    let requested = Set(requests)
    for entry in entries {
      guard case .object(let object) = entry,
        case .number(let chainNumber)? = object["chainId"], chainNumber.rounded() == chainNumber,
        chainNumber >= 1, chainNumber <= Double(Int.max),
        let chain = ChainStore.normalize(String(Int(chainNumber))),
        let address = object["address"]?.stringValue,
        let key = PriceRequest(chainID: chain, address: address), requested.contains(key)
      else { continue }
      let status = object["status"]?.stringValue
      // The catalog returns its last known price for any status; only a shared budget or a source
      // failure with no known price leaves it null.
      let price: String?
      if let raw = object["priceUsd"]?.stringValue, DecimalValue.parse(raw) != nil {
        price = raw
      } else {
        price = nil
      }
      // Price changes are withheld for every non-ok status.
      let quote = PriceQuote(
        priceUSD: price,
        change24h: status == "ok" ? Self.change24h(from: object) : nil,
        symbol: object["symbol"]?.stringValue,
        decimals: Self.decimals(from: object["decimals"]),
        imageURL: Self.imageURL(from: object["imageUrl"]))
      if price != nil || quote.hasMetadata { quotes[key] = quote }
      // A concrete price or a definitive miss is stable enough to cache; a response that retains no
      // price is retried instead of cached as a miss.
      if price != nil || status == "not_found" { cacheable.insert(key) }
    }
    let directives = (http.value(forHTTPHeaderField: "Cache-Control") ?? "")
      .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var lifetime = priceLifetime
    if directives.contains("no-store") || directives.contains("no-cache") {
      lifetime = 0
    } else if let directive = directives.first(where: { $0.hasPrefix("max-age=") }),
      let maximumAge = TimeInterval(
        directive.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
      maximumAge.isFinite, maximumAge >= 0
    {
      let age = TimeInterval(http.value(forHTTPHeaderField: "Age") ?? "0") ?? 0
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      let responseDate = http.value(forHTTPHeaderField: "Date").flatMap(formatter.date(from:))
      let elapsed = responseDate.map { max(0, Date().timeIntervalSince($0)) } ?? 0
      let currentAge = max(elapsed, age.isFinite ? max(0, age) : maximumAge)
      lifetime = min(lifetime, max(0, maximumAge - currentAge))
    }
    return PriceBatch(quotes: quotes, cacheable: cacheable, cacheLifetime: lifetime)
  }

  /// The catalog's signed 24-hour percent change, or nil when absent or unusable.
  static func change24h(from entry: [String: JSONValue]) -> String? {
    guard case .object(let change)? = entry["priceChange"],
      let raw = change["h24"]?.stringValue
    else { return nil }
    return DecimalValue.signed(raw)
  }

  /// Accepts a contract address or the catalog's `native` literal.
  static func normalizeTokenAddress(_ value: String) -> String? {
    value == "native" ? "native" : (try? WalletToken.normalizeAddress(value))
  }

  static func result(from item: JSONValue, chainID: String) -> TokenSearchResult? {
    guard case .object(let entry) = item,
      case .number(let chainNumber)? = entry["chainId"],
      chainNumber.rounded() == chainNumber,
      chainNumber >= 1, chainNumber <= Double(Int.max),
      let chain = ChainStore.normalize(String(Int(chainNumber))), chain == chainID,
      let rawAddress = entry["address"]?.stringValue,
      let normalized = Self.normalizeTokenAddress(rawAddress),
      let symbol = entry["symbol"]?.stringValue, Self.isUsableSymbol(symbol)
    else { return nil }
    let name = entry["name"]?.stringValue
    return TokenSearchResult(
      chainID: chain,
      address: normalized,
      name: name.flatMap { $0.isEmpty ? nil : $0 } ?? symbol,
      symbol: symbol,
      decimals: Self.decimals(from: entry["decimals"]),
      imageURL: Self.imageURL(from: entry["imageUrl"]),
      marketCap: Self.marketCap(from: entry["marketCapUsd"]))
  }

  private static func decimals(from value: JSONValue?) -> UInt8? {
    guard case .number(let number)? = value, number.rounded() == number, number >= 0,
      number <= 255
    else { return nil }
    return UInt8(number)
  }

  /// The catalog reports market cap as a decimal string, which may carry a fractional part.
  private static func marketCap(from value: JSONValue?) -> String? {
    guard let raw = value?.stringValue else { return nil }
    return MarketCapFormatter.integerDigits(raw)
  }

  private static func imageURL(from value: JSONValue?) -> URL? {
    guard let raw = value?.stringValue, let url = URL(string: raw), let scheme = url.scheme,
      ["https", "http"].contains(scheme), url.host != nil
    else { return nil }
    return url
  }

  private static func isUsableSymbol(_ symbol: String) -> Bool {
    !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && symbol.utf8.count <= 64
      && !symbol.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}
