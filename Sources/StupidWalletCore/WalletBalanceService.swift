import Foundation

public struct BalanceContext: Sendable, Equatable {
  public let account: String
  public let registryRevision: UInt64
  public let networks: [WalletNetwork]
  public let overrides: [String: URL]
  public let tokenRevision: UInt64
  public let tokens: [WalletToken]

  public func endpoint(chainID: String) -> URL {
    RPCResolver(overrides: overrides).resolve(chainID: chainID)
  }
}

public struct TokenBalanceRead: Sendable {
  public let tokenID: String
  public let result: Result<TokenBalanceEntry, TokenError>
}

public struct NetworkBalanceResult: Sendable {
  public let native: NativeNetworkBalance?
  public let tokens: [TokenBalanceRead]
}

/// One importable or already-tracked token found by an add-token search.
public struct TokenCandidate: Sendable, Equatable, Identifiable {
  public let chainID: String
  public let networkName: String
  public let address: String
  public let symbol: String
  public let name: String?
  public var isTracked: Bool
  /// Catalog display metadata, present only for catalog matches.
  public let imageURL: URL?
  public let marketCap: String?

  public var id: String { "\(chainID):\(address.lowercased())" }

  /// Compact USD market cap for display, or nil when the catalog has no usable value.
  public var marketCapDisplay: String? { MarketCapFormatter.compact(marketCap) }
}

public struct TokenSearchOutcome: Sendable, Equatable {
  public let candidates: [TokenCandidate]
  public let failedNetworkCount: Int
}

public struct WalletBalanceService: Sendable {
  public let tokens: TokenStore
  private let registry: WalletRegistryStore
  private let networks: NetworkStore
  private let overrides: RPCOverrideStore
  private let nativeCache: BalanceCache
  private let client: RPCClient
  private let tokenSearch: StupidTokensClient

  public init(
    directory: URL? = nil, appGroup: String = PendingRequestStore.defaultAppGroup,
    client: RPCClient = RPCClient(), networkStore: NetworkStore? = nil,
    tokenSearch: StupidTokensClient? = nil
  ) {
    tokens = TokenStore(directory: directory, appGroup: appGroup)
    registry = WalletRegistryStore(directory: directory, appGroup: appGroup)
    networks = networkStore ?? NetworkStore(directory: directory, appGroup: appGroup)
    overrides = RPCOverrideStore(directory: directory, appGroup: appGroup)
    nativeCache = BalanceCache(directory: directory, appGroup: appGroup)
    self.client = client
    self.tokenSearch = tokenSearch ?? .shared
  }

  public func context(account: String) throws -> BalanceContext {
    let account = try WalletToken.normalizeAddress(account)
    return try registry.withLockedReady { registry in
      guard Self.contains(account: account, registry: registry) else {
        throw TokenError.configurationChanged
      }
      return try networks.withLockedNetworks { networks in
        try overrides.withLockedOverrides { overrides in
          let snapshot = try tokens.load()
          return BalanceContext(
            account: account, registryRevision: registry.revision,
            networks: networks, overrides: overrides, tokenRevision: snapshot.revision,
            tokens: snapshot.tokens)
        }
      }
    }
  }

  public func cachedNative(account: String) throws -> String? {
    try nativeCache.balance(account: account)
  }

  public func inspect(context: BalanceContext, chainID: String, address: String) async throws
    -> TokenImport
  {
    guard context.networks.contains(where: { $0.id == chainID }) else {
      throw TokenError.configurationChanged
    }
    let normalized = try WalletToken.normalizeAddress(address)
    guard !context.tokens.contains(where: { $0.chainID == chainID && $0.address == normalized })
    else {
      throw TokenError.duplicate
    }
    return try await ERC20Reader(client: client).inspect(
      chainID: chainID, address: normalized,
      account: context.account, endpoint: context.endpoint(chainID: chainID))
  }

  /// Searches the Stupid Tokens catalog across the configured networks for a name or symbol.
  ///
  /// Catalog metadata is display-only; every result is validated on chain before import.
  public func searchTokens(context: BalanceContext, query: String) async throws
    -> TokenSearchOutcome
  {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !context.networks.isEmpty else {
      return TokenSearchOutcome(candidates: [], failedNetworkCount: 0)
    }
    return try await searchCatalog(context: context, query: trimmed)
  }

  /// The catalog display icon for a tracked token, or nil when the catalog has none.
  public func tokenIcon(chainID: String, address: String) async -> URL? {
    await tokenSearch.imageURL(chainID: chainID, address: address)
  }

  /// Resolves one contract address on one configured network for the add-token address flow.
  public func addressCandidate(context: BalanceContext, chainID: String, address: String) async
    -> Result<TokenCandidate, TokenError>
  {
    guard let network = context.networks.first(where: { $0.id == chainID }) else {
      return .failure(.configurationChanged)
    }
    guard let normalized = try? WalletToken.normalizeAddress(address) else {
      return .failure(.invalidAddress)
    }
    if let tracked = context.tokens.first(where: {
      $0.chainID == chainID && $0.address == normalized
    }) {
      return .success(
        TokenCandidate(
          chainID: chainID, networkName: network.name, address: normalized,
          symbol: tracked.symbol, name: nil, isTracked: true, imageURL: nil, marketCap: nil))
    }
    do {
      let imported = try await ERC20Reader(client: client).inspect(
        chainID: chainID, address: normalized, account: context.account,
        endpoint: context.endpoint(chainID: chainID))
      return .success(
        TokenCandidate(
          chainID: chainID, networkName: network.name, address: imported.token.address,
          symbol: imported.token.symbol, name: nil, isTracked: false, imageURL: nil,
          marketCap: nil))
    } catch let error as TokenError {
      return .failure(error)
    } catch {
      return .failure(.transport)
    }
  }

  private func searchCatalog(context: BalanceContext, query: String) async throws
    -> TokenSearchOutcome
  {
    let search = tokenSearch
    let networks = context.networks
    let collected = await withTaskGroup(
      of: (String, Result<[TokenSearchResult], TokenSearchError>).self
    ) { group -> [String: Result<[TokenSearchResult], TokenSearchError>]? in
      var iterator = networks.makeIterator()
      for _ in 0..<4 {
        guard let network = iterator.next() else { break }
        group.addTask { (network.id, await Self.search(search, query: query, chainID: network.id)) }
      }
      var collected: [String: Result<[TokenSearchResult], TokenSearchError>] = [:]
      for await (chainID, result) in group {
        if Task.isCancelled {
          group.cancelAll()
          return nil
        }
        collected[chainID] = result
        if let network = iterator.next() {
          group.addTask {
            (network.id, await Self.search(search, query: query, chainID: network.id))
          }
        }
      }
      return collected
    }
    guard let collected else { throw CancellationError() }

    let failures = collected.values.filter { if case .failure = $0 { true } else { false } }
    if failures.count == networks.count,
      let first = failures.compactMap({ if case .failure(let error) = $0 { error } else { nil } })
        .first
    {
      throw first
    }

    var candidates: [TokenCandidate] = []
    var seen = Set<String>()
    var ranked: [(candidate: TokenCandidate, cap: (Int, String)?, network: Int, source: Int)] = []
    for (networkIndex, network) in networks.enumerated() {
      guard case .success(let results)? = collected[network.id] else { continue }
      for (sourceIndex, result) in results.enumerated() {
        guard result.chainID == network.id else { continue }
        let candidate = TokenCandidate(
          chainID: network.id, networkName: network.name, address: result.address,
          symbol: result.symbol, name: result.name == result.symbol ? nil : result.name,
          isTracked: Self.isTracked(
            context: context, chainID: network.id, address: result.address),
          imageURL: result.imageURL, marketCap: result.marketCap)
        guard seen.insert(candidate.id).inserted else { continue }
        ranked.append(
          (candidate, Self.marketCapRank(result.marketCap), networkIndex, sourceIndex))
      }
    }
    // Highest market cap first, unknown caps last; then catalog rank, so each configured
    // network's best match appears early instead of one network's long tail.
    candidates = ranked.sorted { lhs, rhs in
      switch (lhs.cap, rhs.cap) {
      case (let left?, let right?):
        if left != right { return left > right }
      case (nil, .some): return false
      case (.some, nil): return true
      case (nil, nil): break
      }
      if lhs.source != rhs.source { return lhs.source < rhs.source }
      return lhs.network < rhs.network
    }.map(\.candidate)
    return TokenSearchOutcome(candidates: candidates, failedNetworkCount: failures.count)
  }

  /// Ranks a decimal market-cap string without converting it to a fixed-width number.
  private static func marketCapRank(_ value: String?) -> (Int, String)? {
    guard let value, !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
    let digits = String(value.drop { $0 == "0" })
    return digits.isEmpty ? (1, "0") : (digits.count, digits)
  }

  private static func search(
    _ client: StupidTokensClient, query: String, chainID: String
  ) async -> Result<[TokenSearchResult], TokenSearchError> {
    do {
      return .success(try await client.search(query: query, chainID: chainID))
    } catch is CancellationError {
      return .failure(.unavailable)
    } catch let error as TokenSearchError {
      return .failure(error)
    } catch {
      return .failure(.unavailable)
    }
  }

  private static func isTracked(context: BalanceContext, chainID: String, address: String) -> Bool {
    context.tokens.contains { $0.chainID == chainID && $0.address == address.lowercased() }
  }

  public func add(imported: TokenImport, context: BalanceContext) throws {
    try withCurrentContext(context) {
      guard imported.account == context.account,
        context.networks.contains(where: { $0.id == imported.token.chainID }),
        imported.balance.endpoint == context.endpoint(chainID: imported.token.chainID)
      else { throw TokenError.configurationChanged }
      try tokens.add(imported: imported, expectedRevision: context.tokenRevision)
    }
  }

  func begin(context: BalanceContext) throws -> UUID {
    try withCurrentContext(context) {
      try tokens.beginRefresh(account: context.account, revision: context.tokenRevision)
    }
  }

  func commit(context: BalanceContext, refreshID: UUID, result: NetworkBalanceResult) throws {
    try withCurrentContext(context) {
      let entries = Dictionary(
        uniqueKeysWithValues: result.tokens.compactMap { read in
          (try? read.result.get()).map { (read.tokenID, $0) }
        })
      try tokens.saveBalances(
        account: context.account, revision: context.tokenRevision, refreshID: refreshID,
        entries: entries)
    }
  }

  func saveNative(context: BalanceContext, refreshID: UUID, balance: String) throws {
    try withCurrentContext(context) {
      try tokens.withRefresh(
        account: context.account, revision: context.tokenRevision, refreshID: refreshID
      ) {
        try nativeCache.save(
          balance: balance, account: context.account, registryRevision: context.registryRevision)
      }
    }
  }

  // Lock order: registry → networks → RPC overrides → tokens → native cache.
  // No lock spans an await or RPC.
  private func withCurrentContext<T>(_ context: BalanceContext, body: () throws -> T) throws -> T {
    try registry.withLockedReady { registry in
      guard registry.revision == context.registryRevision,
        Self.contains(account: context.account, registry: registry)
      else {
        throw TokenError.configurationChanged
      }
      return try networks.withLockedNetworks { networks in
        try overrides.withLockedOverrides { overrides in
          guard networks == context.networks, overrides == context.overrides,
            try tokens.load().revision == context.tokenRevision
          else { throw TokenError.configurationChanged }
          return try body()
        }
      }
    }
  }

  private static func contains(account: String, registry: WalletRegistry) -> Bool {
    registry.groups.contains { group in
      group.lifecycle == .active
        && group.accounts.contains {
          $0.lifecycle == .active && $0.address.lowercased() == account
        }
    }
  }

  private struct Job: Sendable {
    let chainID: String
    let native: Bool
    let tokens: [WalletToken]
  }

  func fetch(
    context: BalanceContext, receive: @escaping @Sendable (NetworkBalanceResult) async -> Void
  ) async {
    var jobs: [Job] = []
    for network in context.networks {
      var remaining = context.tokens.filter { $0.chainID == network.id }[...]
      var native = network.includeInBalance
      while native || !remaining.isEmpty {
        let chunk = Array(remaining.prefix(native ? 49 : 50))
        jobs.append(Job(chainID: network.id, native: native, tokens: chunk))
        remaining = remaining.dropFirst(chunk.count)
        native = false
      }
    }
    await withTaskGroup(of: NetworkBalanceResult.self) { group in
      var iterator = jobs.makeIterator()
      for _ in 0..<4 {
        if let job = iterator.next() { group.addTask { await fetch(job: job, context: context) } }
      }
      for await result in group {
        guard !Task.isCancelled else {
          group.cancelAll()
          return
        }
        await receive(result)
        if let job = iterator.next() { group.addTask { await fetch(job: job, context: context) } }
      }
    }
  }

  private func fetch(job: Job, context: BalanceContext) async -> NetworkBalanceResult {
    let endpoint = context.endpoint(chainID: job.chainID)
    do {
      var reads: [RPCRead] = []
      if job.native {
        reads.append(
          RPCRead(
            method: "eth_getBalance", params: .array([.string(context.account), .string("latest")]))
        )
      }
      reads += try job.tokens.map {
        try ERC20Reader.balanceRead(address: $0.address, account: context.account)
      }
      let responses = try await client.readBatch(url: endpoint, reads: reads)
      var native: NativeNetworkBalance?
      if job.native {
        var wei: [UInt8]?
        if case .result(.string(let quantity)) = responses[0], quantity.hasPrefix("0x"),
          let parsed = Hex.quantityData(hex: quantity), parsed.count <= 32
        {
          wei = parsed
        }
        native = NativeNetworkBalance(chainID: job.chainID, wei: wei)
      }
      let updatedAt = Date()
      let tokenResults = job.tokens.enumerated().map { index, token in
        let result: Result<TokenBalanceEntry, TokenError>
        do {
          result = .success(
            TokenBalanceEntry(
              raw: try ERC20Reader.balance(response: responses[index + (job.native ? 1 : 0)]),
              updatedAt: updatedAt, endpoint: endpoint))
        } catch {
          result = .failure(error as? TokenError ?? .invalidBalance)
        }
        return TokenBalanceRead(tokenID: token.id, result: result)
      }
      return NetworkBalanceResult(native: native, tokens: tokenResults)
    } catch {
      let failure: TokenError =
        (error as? RPCClientError) == .invalidResponse ? .invalidResponse : .transport
      return NetworkBalanceResult(
        native: job.native ? NativeNetworkBalance(chainID: job.chainID, wei: nil) : nil,
        tokens: job.tokens.map { TokenBalanceRead(tokenID: $0.id, result: .failure(failure)) })
    }
  }
}
