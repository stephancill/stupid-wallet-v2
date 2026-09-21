import Combine
import Foundation

public struct TokenBalanceRow: Identifiable, Sendable, Equatable {
  public let token: WalletToken
  public let networkName: String
  /// Catalog display icon, resolved asynchronously; never persisted.
  public var iconURL: URL?
  public var entry: TokenBalanceEntry?
  public var isCached = true
  public var isLoading = false
  public var error: String?
  public var id: String { token.id }
}

public struct NativeBalanceRow: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let balance: String?
  public let wei: [UInt8]
}

/// One instance is shared by Home and Settings. Cached rows are published before any network wait.
@MainActor
public final class WalletBalanceModel: ObservableObject {
  @Published public private(set) var account = ""
  @Published public private(set) var nativeTotal: String?
  @Published public private(set) var nativeRows: [NativeBalanceRow] = []
  @Published public private(set) var rows: [TokenBalanceRow] = []
  @Published public private(set) var includedNetworkCount = 0
  @Published public private(set) var portfolioGroups: [PortfolioGroup] = []
  @Published public private(set) var portfolioHoldings: [PortfolioHolding] = []
  @Published public private(set) var portfolioTotalUSD: String?
  @Published public private(set) var portfolioChange: PortfolioChange?
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var error: String?
  public let service: WalletBalanceService

  private var active: (id: UUID, context: BalanceContext, task: Task<Void, Never>)?
  private var nativeResults: [String: NativeNetworkBalance] = [:]
  private var nativeBalances: [String: [UInt8]] = [:]
  private var priceQuotes: [String: PriceQuote] = [:]
  private var iconCache: [String: URL?] = [:]
  private let now: @Sendable () -> Date
  private var priceExpiryTask: Task<Void, Never>?

  public init(
    service: WalletBalanceService = WalletBalanceService(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.service = service
    self.now = now
  }

  deinit { priceExpiryTask?.cancel() }

  /// Full two-decimal USD display of the portfolio total, or nil when nothing is priced.
  public var portfolioTotalDisplay: String? {
    portfolioTotalUSD.flatMap(DecimalValue.usd)
  }

  /// Signed USD amount and percent of the portfolio's 24-hour change, e.g. `+$1,234 (+4.25%)`,
  /// or nil when unavailable.
  public var portfolioChangeDisplay: String? {
    portfolioChange?.display
  }

  public func selectAccount(_ address: String) {
    let normalized = address.lowercased()
    guard account != normalized else { return }
    priceExpiryTask?.cancel()
    priceExpiryTask = nil
    active?.task.cancel()
    active = nil
    account = normalized
    nativeTotal = nil
    nativeRows = []
    nativeResults = [:]
    nativeBalances = [:]
    priceQuotes = [:]
    rows = []
    error = nil
    isRefreshing = false
    includedNetworkCount = 0
    portfolioGroups = []
    portfolioHoldings = []
    portfolioTotalUSD = nil
    portfolioChange = nil
    guard !account.isEmpty else { return }
    do {
      nativeTotal = try service.cachedNative(account: account)
      try hydrate(context: service.context(account: account))
    } catch { self.error = error.localizedDescription }
  }

  public func refresh() async {
    guard !account.isEmpty else { return }
    let context: BalanceContext
    do { context = try service.context(account: account) } catch {
      active?.task.cancel()
      active = nil
      isRefreshing = false
      for index in rows.indices { rows[index].isLoading = false }
      self.error = error.localizedDescription
      if nativeTotal == nil { nativeTotal = "Unavailable" }
      return
    }
    if let active, active.context == context {
      await active.task.value
      return
    }
    active?.task.cancel()
    do {
      try hydrate(context: context)
      let refreshID = try service.begin(context: context)
      error = nil
      isRefreshing = true
      nativeResults = [:]
      for index in rows.indices { rows[index].isLoading = true }
      let task = Task { [weak self, service] in
        await service.fetch(context: context) { [weak self] result in
          await self?.receive(result: result, context: context, refreshID: refreshID)
        }
        await self?.refreshPortfolio(context: context, refreshID: refreshID)
        self?.finish(context: context, refreshID: refreshID)
      }
      active = (refreshID, context, task)
      await task.value
    } catch {
      active = nil
      isRefreshing = false
      self.error = error.localizedDescription
      if nativeTotal == nil { nativeTotal = "Unavailable" }
    }
  }

  public func remove(tokenID: String) async {
    do {
      try service.tokens.remove(tokenID: tokenID)
      active?.task.cancel()
      active = nil
      isRefreshing = false
      rows.removeAll { $0.id == tokenID }
      try hydrate(context: service.context(account: account))
      error = nil
      Task { await refresh() }
    } catch { self.error = error.localizedDescription }
  }

  private func hydrate(context: BalanceContext) throws {
    let snapshot = try service.tokens.load()
    let names = Dictionary(uniqueKeysWithValues: context.networks.map { ($0.id, $0.name) })
    rows = context.tokens.compactMap { token in
      guard let name = names[token.chainID] else { return nil }
      return TokenBalanceRow(
        token: token, networkName: name, iconURL: iconCache[token.id] ?? nil,
        entry: snapshot.balance(account: account, tokenID: token.id))
    }.sorted {
      if $0.token.symbol != $1.token.symbol {
        return $0.token.symbol.localizedStandardCompare($1.token.symbol) == .orderedAscending
      }
      if $0.networkName != $1.networkName {
        return $0.networkName.localizedStandardCompare($1.networkName) == .orderedAscending
      }
      return $0.id < $1.id
    }
    includedNetworkCount = context.networks.filter(\.includeInBalance).count
    let portfolio = snapshot.portfolios[account] ?? PortfolioCacheEntry()
    nativeBalances = portfolio.nativeBalances.mapValues(\.raw)
    let identities = Set(context.tokens.map(\.id) + context.networks.map { "\($0.id):native" })
    priceQuotes = priceQuotes.filter { identities.contains($0.key) }
    for (id, entry) in portfolio.prices where priceQuotes[id] == nil {
      priceQuotes[id] = entry.quote
    }
    publishPortfolio(context: context)
    nativeRows = etherRows(context: context, balances: nativeBalances)
  }

  private func receive(result: NetworkBalanceResult, context: BalanceContext, refreshID: UUID) {
    guard active?.id == refreshID, account == context.account, !Task.isCancelled else { return }
    do {
      try service.commit(context: context, refreshID: refreshID, result: result)
      if let native = result.native {
        nativeResults[native.chainID] = native
        if let wei = native.wei { nativeBalances[native.chainID] = wei }
      }
      for read in result.tokens {
        guard let index = rows.firstIndex(where: { $0.id == read.tokenID }) else { continue }
        rows[index].isLoading = false
        switch read.result {
        case .success(let entry):
          rows[index].entry = entry
          rows[index].isCached = false
          rows[index].error = nil
        case .failure(let error):
          rows[index].isCached = true
          rows[index].error = error.localizedDescription
        }
      }
      publishPortfolio(context: context)
    } catch {
      self.error = error.localizedDescription
      active?.task.cancel()
    }
  }

  /// Refresh stays active through the price request, keeping cached values visible and dimmed.
  private func refreshPortfolio(context: BalanceContext, refreshID: UUID) async {
    guard active?.id == refreshID, account == context.account, !Task.isCancelled else { return }
    var requests = context.networks.filter(\.includeInBalance).compactMap {
      PriceRequest(chainID: $0.id, address: "native")
    }
    requests += rows.compactMap { row in
      guard row.entry?.raw.contains(where: { $0 != 0 }) == true else { return nil }
      return PriceRequest(chainID: row.token.chainID, address: row.token.address)
    }
    let quotes = await service.prices(for: requests)
    guard active?.id == refreshID, account == context.account, !Task.isCancelled else { return }
    do {
      try service.savePrices(context: context, refreshID: refreshID, quotes: quotes)
    } catch {
      self.error = error.localizedDescription
      return
    }
    for (request, quote) in quotes {
      let id = "\(request.chainID):\(request.address)"
      priceQuotes[id] = priceQuotes[id].map { StupidTokensClient.merging(quote, with: $0) } ?? quote
    }
    publishPortfolio(context: context)
    let etherRows = etherRows(context: context, balances: nativeResults.compactMapValues(\.wei))
    updateNativeAggregate(
      context: context, refreshID: refreshID, rows: etherRows,
      bytes: etherRows.reduce([0]) { NativeBalanceService.add($0, $1.wei) })
  }

  /// Rebuild from the selected account's latest balances and retained prices without awaiting HTTP.
  private func publishPortfolio(context: BalanceContext) {
    let date = now()
    priceQuotes = priceQuotes.mapValues { $0.valid(at: date) }
    var holdings: [PortfolioHolding] = []
    for network in context.networks where network.includeInBalance {
      guard let wei = nativeBalances[network.id], wei.contains(where: { $0 != 0 })
      else { continue }
      let quote = priceQuotes["\(network.id):native"]
      let decimals = quote?.decimals ?? 18
      holdings.append(
        PortfolioHolding(
          chainID: network.id, networkName: network.name,
          symbol: quote?.symbol ?? network.name, address: nil,
          iconURL: quote?.imageURL, raw: wei, decimals: decimals, priceUSD: quote?.priceUSD,
          valueUSD: (quote?.priceUSD ?? nil).flatMap {
            PortfolioHolding.value(raw: wei, decimals: decimals, price: $0)
          }, change24h: quote?.change24h))
    }

    for index in rows.indices {
      let row = rows[index]
      let token = row.token
      guard let entry = row.entry, entry.raw.contains(where: { $0 != 0 }) else { continue }
      let quote = priceQuotes[token.id]
      let iconURL = quote?.imageURL ?? row.iconURL ?? iconCache[token.id] ?? nil
      iconCache[token.id] = iconURL
      if rows[index].iconURL != iconURL { rows[index].iconURL = iconURL }
      holdings.append(
        PortfolioHolding(
          chainID: token.chainID, networkName: row.networkName, symbol: token.symbol,
          address: token.address, iconURL: iconURL, raw: entry.raw, decimals: token.decimals,
          priceUSD: quote?.priceUSD,
          valueUSD: (quote?.priceUSD ?? nil).flatMap {
            PortfolioHolding.value(raw: entry.raw, decimals: token.decimals, price: $0)
          }, change24h: quote?.change24h))
    }

    let groups = PortfolioGroup.groups(from: holdings)
    portfolioHoldings = holdings.sorted { lhs, rhs in
      switch (lhs.valueUSD, rhs.valueUSD) {
      case (let left?, let right?):
        if left != right { return DecimalValue.compare(left, right) == .orderedDescending }
      case (nil, .some): return false
      case (.some, nil): return true
      case (nil, nil): break
      }
      return lhs.id < rhs.id
    }
    portfolioGroups = groups
    portfolioTotalUSD = PortfolioGroup.total(of: groups)
    portfolioChange = PortfolioGroup.totalChange(of: groups)
    schedulePriceExpiry(context: context, date: date)
  }

  private func schedulePriceExpiry(context: BalanceContext, date: Date) {
    priceExpiryTask?.cancel()
    priceExpiryTask = nil
    guard
      let expiry = priceQuotes.values.filter({ $0.priceUSD != nil })
        .map({ $0.updatedAt.addingTimeInterval(PriceQuote.maximumCacheAge) }).min()
    else { return }
    priceExpiryTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSince(date)))) } catch {
        return
      }
      guard !Task.isCancelled, let self, self.account == context.account else { return }
      self.publishPortfolio(context: context)
    }
  }

  private func etherRows(context: BalanceContext, balances: [String: [UInt8]]) -> [NativeBalanceRow]
  {
    context.networks.compactMap { network in
      guard network.includeInBalance,
        Self.isEther(symbol: priceQuotes["\(network.id):native"]?.symbol),
        let wei = balances[network.id], wei.contains(where: { $0 != 0 })
      else { return nil }
      return NativeBalanceRow(
        id: network.id, name: network.name,
        balance: NativeBalanceService.formatEther(bytes: wei), wei: wei)
    }.sorted { NativeBalanceService.isGreater($0.wei, than: $1.wei) }
  }

  private func finish(context: BalanceContext, refreshID: UUID) {
    guard active?.id == refreshID, account == context.account else { return }
    active = nil
    isRefreshing = false
    for index in rows.indices { rows[index].isLoading = false }
  }

  /// Publishes the ETH-only native aggregate: the home total and its grouped breakdown.
  ///
  /// A network counts as ETH when its catalog native symbol is ETH, or when the catalog does not
  /// know the currency, so a catalog gap never hides a balance. Known non-ETH currencies (for
  /// example POL) are excluded from both the total and the breakdown.
  private func updateNativeAggregate(
    context: BalanceContext, refreshID: UUID, rows: [NativeBalanceRow], bytes: [UInt8]
  ) {
    // Only native successes decide whether the aggregate can be replaced.
    let successful = nativeResults.values.compactMap(\.wei)
    guard includedNetworkCount == 0 || !successful.isEmpty else {
      if nativeTotal == nil { nativeTotal = "Unavailable" }
      return
    }
    let total = NativeBalanceService.formatEther(bytes: bytes)
    do {
      try service.saveNative(context: context, refreshID: refreshID, balance: total)
    } catch { self.error = error.localizedDescription }
    let sorted = rows.sorted {
      if $0.wei == $1.wei { return $0.name < $1.name }
      return NativeBalanceService.isGreater($0.wei, than: $1.wei)
    }
    nativeTotal = total
    nativeRows = sorted
  }

  private static func isEther(symbol: String?) -> Bool {
    guard let symbol else { return true }
    return symbol.caseInsensitiveCompare("ETH") == .orderedSame
  }
}
