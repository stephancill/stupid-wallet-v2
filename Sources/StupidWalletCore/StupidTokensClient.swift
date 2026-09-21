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
/// searches are served from a short-lived in-memory cache. Only search is used; prices and
/// catalog enumeration are deliberately not part of the wallet.
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
  private let metadataLifetime: TimeInterval
  private let priceLifetime: TimeInterval
  private var cache: [String: (expiresAt: Date, results: [TokenSearchResult])] = [:]
  private var metadata: [String: (expiresAt: Date, token: TokenSearchResult?)] = [:]
  private var priceCache: [PriceRequest: (expiresAt: Date, price: String?)] = [:]

  public init(
    session: URLSession = .shared,
    baseURL: URL = StupidTokensClient.defaultBaseURL,
    timeout: TimeInterval = 15,
    cacheLifetime: TimeInterval = 60,
    cacheLimit: Int = 64,
    metadataLifetime: TimeInterval = 3600,
    priceLifetime: TimeInterval = 60
  ) {
    self.session = session
    self.baseURL = baseURL
    self.timeout = timeout
    self.cacheLifetime = cacheLifetime
    self.cacheLimit = cacheLimit
    self.metadataLifetime = metadataLifetime
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

  /// Catalog metadata for one token or a chain's native currency, cached in memory.
  public func tokenMetadata(chainID: String, address: String) async -> TokenSearchResult? {
    guard let chain = ChainStore.normalize(chainID),
      let normalized = Self.normalizeTokenAddress(address)
    else { return nil }
    let key = "\(chain)|\(normalized)"
    if let cached = metadata[key], cached.expiresAt > Date() { return cached.token }
    let token = await fetchTokenMetadata(chainID: chain, address: normalized)
    if metadata.count >= cacheLimit {
      metadata = metadata.filter { $0.value.expiresAt > Date() }
    }
    if metadata.count >= cacheLimit { metadata.removeAll() }
    metadata[key] = (Date().addingTimeInterval(metadataLifetime), token)
    return token
  }

  /// The catalog icon for one token, or nil when the catalog has none or does not know it.
  public func imageURL(chainID: String, address: String) async -> URL? {
    await tokenMetadata(chainID: chainID, address: address)?.imageURL
  }

  /// USD prices for the requested tokens, keyed by request. Tokens without a usable price are
  /// absent. Requests are sent in the catalog's canonical order, 50 per call.
  public func prices(for requests: [PriceRequest]) async -> [PriceRequest: String] {
    var resolved: [PriceRequest: String] = [:]
    var missing: [PriceRequest] = []
    for request in Set(requests) {
      guard let cached = priceCache[request], cached.expiresAt > Date() else {
        missing.append(request)
        continue
      }
      if let price = cached.price { resolved[request] = price }
    }
    var index = 0
    let ordered = missing.sorted { lhs, rhs in
      let left = Int(lhs.chainID) ?? 0
      let right = Int(rhs.chainID) ?? 0
      if left != right { return left < right }
      return lhs.address < rhs.address
    }
    while index < ordered.count {
      let chunk = Array(ordered[index..<min(index + 50, ordered.count)])
      let prices = await fetchPrices(chunk)
      for request in chunk {
        let price = prices[request]
        priceCache[request] = (Date().addingTimeInterval(priceLifetime), price)
        if let price { resolved[request] = price }
      }
      index += 50
    }
    return resolved
  }

  private func fetchPrices(_ requests: [PriceRequest]) async -> [PriceRequest: String] {
    guard !requests.isEmpty,
      var components = URLComponents(
        url: baseURL.appendingPathComponent("v1/prices"), resolvingAgainstBaseURL: false)
    else { return [:] }
    components.queryItems = [
      URLQueryItem(
        name: "tokens",
        value: requests.map { "\($0.chainID):\($0.address)" }.joined(separator: ","))
    ]
    guard let url = components.url else { return [:] }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = timeout
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count <= Self.maximumResponseBytes,
      case .object(let root)? = try? JSONValue.parse(data),
      case .array(let entries)? = root["prices"]
    else { return [:] }
    var prices: [PriceRequest: String] = [:]
    for entry in entries {
      guard case .object(let object) = entry,
        case .number(let chainNumber)? = object["chainId"], chainNumber.rounded() == chainNumber,
        chainNumber >= 1, chainNumber <= Double(Int.max),
        let chain = ChainStore.normalize(String(Int(chainNumber))),
        let address = object["address"]?.stringValue,
        let key = PriceRequest(chainID: chain, address: address),
        object["status"]?.stringValue == "ok",
        let price = object["priceUsd"]?.stringValue, DecimalValue.parse(price) != nil
      else { continue }
      prices[key] = price
    }
    return prices
  }

  private func fetchTokenMetadata(chainID: String, address: String) async -> TokenSearchResult? {
    let url = baseURL.appendingPathComponent("v1/tokens/\(chainID)/\(address)")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = timeout
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, http.statusCode == 200,
      data.count <= Self.maximumResponseBytes,
      let parsed = try? JSONValue.parse(data)
    else { return nil }
    return Self.result(from: parsed, chainID: chainID)
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
