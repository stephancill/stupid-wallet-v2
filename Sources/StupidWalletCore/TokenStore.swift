import Darwin
import Foundation

public struct TokenSnapshot: Sendable, Equatable {
  public let revision: UInt64
  public let tokens: [WalletToken]
  public let balances: [String: [String: TokenBalanceEntry]]
  var portfolios: [String: PortfolioCacheEntry] = [:]

  public func balance(account: String, tokenID: String) -> TokenBalanceEntry? {
    balances[account.lowercased()]?[tokenID]
  }
}

/// Definitions and account caches share one atomic file so removal cannot leave orphan balances.
public struct TokenStore: Sendable {
  private struct Payload: Codable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var tokens: [WalletToken] = []
    var balances: [String: [String: TokenBalanceEntry]] = [:]
    var refreshes: [String: UUID] = [:]
    // Optional because shipped schema-1 stores predate persisted portfolio prices.
    var portfolios: [String: PortfolioCacheEntry]?
  }

  private let fileURL: URL?
  private let lockURL: URL?

  public init(directory: URL? = nil, appGroup: String = PendingRequestStore.defaultAppGroup) {
    let directory = directory ?? WalletStore.containerURL(appGroup: appGroup)
    fileURL = directory?.appendingPathComponent("tokens.json")
    lockURL = directory?.appendingPathComponent("tokens.lock")
  }

  public func load() throws -> TokenSnapshot {
    try withLock {
      let payload = try read()
      return TokenSnapshot(
        revision: payload.revision, tokens: payload.tokens, balances: payload.balances,
        portfolios: payload.portfolios ?? [:])
    }
  }

  func add(imported: TokenImport, expectedRevision: UInt64) throws {
    try mutate { payload in
      guard payload.revision == expectedRevision else { throw TokenError.configurationChanged }
      guard !payload.tokens.contains(where: { $0.id == imported.token.id }) else {
        throw TokenError.duplicate
      }
      payload.tokens.append(imported.token)
      payload.balances[imported.account, default: [:]][imported.token.id] = imported.balance
      try configurationChanged(payload: &payload)
    }
  }

  public func remove(tokenID: String) throws {
    try mutate { payload in
      guard payload.tokens.contains(where: { $0.id == tokenID }) else { return }
      payload.tokens.removeAll { $0.id == tokenID }
      for account in payload.balances.keys {
        payload.balances[account]?.removeValue(forKey: tokenID)
      }
      for account in (payload.portfolios ?? [:]).keys {
        payload.portfolios?[account]?.prices.removeValue(forKey: tokenID)
      }
      try configurationChanged(payload: &payload)
    }
  }

  func remove(chainID: String) throws {
    try mutate { payload in
      let ids = Set(payload.tokens.filter { $0.chainID == chainID }.map(\.id))
      payload.tokens.removeAll { ids.contains($0.id) }
      for account in payload.balances.keys {
        payload.balances[account] = payload.balances[account]?.filter { !ids.contains($0.key) }
      }
      for (account, cached) in payload.portfolios ?? [:] {
        var portfolio = cached
        portfolio.nativeBalances.removeValue(forKey: chainID)
        portfolio.prices = portfolio.prices.filter { !$0.key.hasPrefix("\(chainID):") }
        payload.portfolios?[account] = portfolio
      }
      try configurationChanged(payload: &payload)
    }
  }

  func removeBalances(account: String) throws {
    try mutate { payload in
      payload.balances.removeValue(forKey: account.lowercased())
      payload.refreshes.removeValue(forKey: account.lowercased())
      payload.portfolios?.removeValue(forKey: account.lowercased())
    }
  }

  func beginRefresh(account: String, revision: UInt64) throws -> UUID {
    try mutate { payload in
      guard payload.revision == revision else { throw TokenError.configurationChanged }
      let id = UUID()
      payload.refreshes[account.lowercased()] = id
      return id
    }
  }

  func saveBalances(
    account: String, revision: UInt64, refreshID: UUID, entries: [String: TokenBalanceEntry],
    nativeBalances: [String: TokenBalanceEntry] = [:]
  ) throws {
    try mutate { payload in
      try checkRefresh(payload: payload, account: account, revision: revision, refreshID: refreshID)
      let ids = Set(payload.tokens.map(\.id))
      guard entries.keys.allSatisfy({ ids.contains($0) }) else {
        throw TokenError.configurationChanged
      }
      for (id, entry) in entries {
        payload.balances[account.lowercased(), default: [:]][id] = entry
      }
      if !nativeBalances.isEmpty {
        var portfolio = payload.portfolios?[account.lowercased()] ?? PortfolioCacheEntry()
        portfolio.nativeBalances.merge(nativeBalances) { _, fresh in fresh }
        if payload.portfolios == nil { payload.portfolios = [:] }
        payload.portfolios?[account.lowercased()] = portfolio
      }
    }
  }

  func savePrices(
    account: String, revision: UInt64, refreshID: UUID, quotes: [PriceRequest: PriceQuote]
  ) throws {
    try mutate { payload in
      try checkRefresh(payload: payload, account: account, revision: revision, refreshID: refreshID)
      var portfolio = payload.portfolios?[account.lowercased()] ?? PortfolioCacheEntry()
      for (request, quote) in quotes {
        let id = "\(request.chainID):\(request.address)"
        let retained = portfolio.prices[id]
        let merged = retained.map { StupidTokensClient.merging(quote, with: $0.quote) } ?? quote
        portfolio.prices[id] = PortfolioPriceEntry(quote: merged)
      }
      if payload.portfolios == nil { payload.portfolios = [:] }
      payload.portfolios?[account.lowercased()] = portfolio
    }
  }

  func withRefresh<T>(account: String, revision: UInt64, refreshID: UUID, body: () throws -> T)
    throws -> T
  {
    try withLock {
      try checkRefresh(payload: read(), account: account, revision: revision, refreshID: refreshID)
      return try body()
    }
  }

  private func checkRefresh(payload: Payload, account: String, revision: UInt64, refreshID: UUID)
    throws
  {
    guard payload.revision == revision, payload.refreshes[account.lowercased()] == refreshID else {
      throw TokenError.configurationChanged
    }
  }

  private func configurationChanged(payload: inout Payload) throws {
    guard payload.revision < UInt64.max else { throw TokenError.unavailable }
    payload.revision += 1
    payload.refreshes = [:]
  }

  private func read() throws -> Payload {
    guard let fileURL else { throw TokenError.unavailable }
    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile
    { return Payload() } catch { throw TokenError.unavailable }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      let payload = try decoder.decode(Payload.self, from: data)
      try validate(payload: payload)
      return payload
    } catch { throw TokenError.corrupt }
  }

  private func validate(payload: Payload) throws {
    guard payload.schemaVersion == 1, Set(payload.tokens.map(\.id)).count == payload.tokens.count
    else {
      throw TokenError.corrupt
    }
    for token in payload.tokens {
      guard
        token
          == (try WalletToken(
            chainID: token.chainID, address: token.address, symbol: token.symbol,
            decimals: token.decimals))
      else {
        throw TokenError.corrupt
      }
    }
    let ids = Set(payload.tokens.map(\.id))
    for (account, entries) in payload.balances {
      guard try WalletToken.normalizeAddress(account) == account else { throw TokenError.corrupt }
      for (id, entry) in entries {
        guard ids.contains(id), entry.raw.count == 32,
          entry.updatedAt.timeIntervalSince1970.isFinite,
          entry.endpoint.host != nil, ["https", "http"].contains(entry.endpoint.scheme)
        else { throw TokenError.corrupt }
      }
    }
    for account in payload.refreshes.keys {
      guard try WalletToken.normalizeAddress(account) == account else { throw TokenError.corrupt }
    }
    for (account, portfolio) in payload.portfolios ?? [:] {
      guard try WalletToken.normalizeAddress(account) == account else { throw TokenError.corrupt }
      for (chain, entry) in portfolio.nativeBalances {
        guard ChainStore.normalize(chain) == chain, entry.raw.count == 32,
          entry.updatedAt.timeIntervalSince1970.isFinite,
          entry.endpoint.host != nil, ["https", "http"].contains(entry.endpoint.scheme)
        else { throw TokenError.corrupt }
      }
      for (id, price) in portfolio.prices {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
          let request = PriceRequest(chainID: String(parts[0]), address: String(parts[1])),
          id == "\(request.chainID):\(request.address)",
          request.address == "native" || ids.contains(id),
          price.priceUSD.map({ DecimalValue.parse($0) != nil }) ?? true,
          price.change24h.map({ DecimalValue.signed($0) != nil }) ?? true,
          price.updatedAt.timeIntervalSince1970.isFinite,
          price.changeUpdatedAt?.timeIntervalSince1970.isFinite ?? true
        else { throw TokenError.corrupt }
      }
    }
  }

  private func mutate<T>(_ body: (inout Payload) throws -> T) throws -> T {
    try withLock {
      var payload = try read()
      let value = try body(&payload)
      try validate(payload: payload)
      guard let fileURL else { throw TokenError.unavailable }
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      encoder.outputFormatting = [.sortedKeys]
      do {
        try WalletRegistryStore.durableReplace(data: encoder.encode(payload), at: fileURL)
      } catch { throw TokenError.unavailable }
      return value
    }
  }

  private func withLock<T>(_ body: () throws -> T) throws -> T {
    guard let lockURL else { throw TokenError.unavailable }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw TokenError.unavailable }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw TokenError.unavailable }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }
}
