import Foundation

/// One tracked holding: a token balance or a chain's native currency, with its USD value when a
/// price is known.
public struct PortfolioHolding: Sendable, Equatable, Identifiable {
  public let chainID: String
  public let networkName: String
  public let symbol: String
  public let address: String?  // nil for the native currency
  public let iconURL: URL?
  public let raw: [UInt8]
  public let decimals: UInt8
  public let priceUSD: String?
  public let valueUSD: String?
  /// Signed 24-hour price change in percent, e.g. `4.25` or `-0.01`, when the catalog reports one.
  public let change24h: String?

  public var id: String { "\(chainID):\(address ?? "native")" }
  public var isNative: Bool { address == nil }
  public var valueDisplay: String? { valueUSD.flatMap(DecimalValue.usd) }
  public var changeDisplay: String? { change24h.flatMap { DecimalValue.signedPercent($0) } }

  public init(
    chainID: String, networkName: String, symbol: String, address: String?, iconURL: URL?,
    raw: [UInt8], decimals: UInt8, priceUSD: String?, valueUSD: String?, change24h: String? = nil
  ) {
    self.chainID = chainID
    self.networkName = networkName
    self.symbol = symbol
    self.address = address
    self.iconURL = iconURL
    self.raw = raw
    self.decimals = decimals
    self.priceUSD = priceUSD
    self.valueUSD = valueUSD
    self.change24h = change24h
  }

  /// The exact USD value of a balance at a price, or nil when either is unusable.
  public static func value(raw: [UInt8], decimals: UInt8, price: String) -> String? {
    DecimalValue.product(
      ClearSigningFormatter.scaledDecimal(raw: raw, decimals: Int(decimals)), price)
  }
}

/// A portfolio-level 24-hour change: the signed USD amount and the signed percent.
public struct PortfolioChange: Sendable, Equatable {
  /// Signed USD change, e.g. `1234.5`, `-12.34`, or `0`.
  public let amountUSD: String
  /// Signed percent change, e.g. `4.25`, `-0.01`, or `0`.
  public let percent: String

  public var amountDisplay: String? { DecimalValue.signedUSD(amountUSD) }
  public var percentDisplay: String? { DecimalValue.signedPercent(percent) }
  /// Combined display such as `+$1,234 (+4.25%)`, or nil when either part is unusable.
  public var display: String? {
    guard let amount = amountDisplay, let percent = percentDisplay else { return nil }
    return "\(amount) (\(percent))"
  }

  public init(amountUSD: String, percent: String) {
    self.amountUSD = amountUSD
    self.percent = percent
  }
}

/// Holdings sharing one symbol across networks, highest value first.
public struct PortfolioGroup: Sendable, Equatable, Identifiable {
  public let symbol: String
  public let holdings: [PortfolioHolding]
  public let valueUSD: String?
  /// Value-weighted 24-hour change in percent for the priced holdings, when at least one reports it.
  public let change24h: String?

  public var id: String { symbol }
  public var isGrouped: Bool { holdings.count > 1 }
  public var valueDisplay: String? { valueUSD.flatMap(DecimalValue.usd) }
  public var changeDisplay: String? { change24h.flatMap { DecimalValue.signedPercent($0) } }
  public var iconURL: URL? { holdings.compactMap(\.iconURL).first }
  public var networkLabel: String {
    holdings.count == 1 ? (holdings.first?.networkName ?? "") : "\(holdings.count) networks"
  }

  /// Groups holdings by symbol, ordering groups and their members by USD value with unpriced
  /// holdings last.
  public static func groups(from holdings: [PortfolioHolding]) -> [PortfolioGroup] {
    let grouped = Dictionary(grouping: holdings) { $0.symbol.uppercased() }
    return
      grouped
      .map { _, members -> PortfolioGroup in
        let ordered = members.sorted { lhs, rhs in
          if let order = valueOrder(lhs.valueUSD, rhs.valueUSD) { return order }
          return lhs.chainID < rhs.chainID
        }
        return PortfolioGroup(
          symbol: ordered.first?.symbol ?? "",
          holdings: ordered,
          valueUSD: DecimalValue.sum(ordered.compactMap(\.valueUSD)),
          change24h: change24h(of: ordered))
      }
      .sorted { lhs, rhs in
        if let order = valueOrder(lhs.valueUSD, rhs.valueUSD) { return order }
        return lhs.symbol < rhs.symbol
      }
  }

  /// Total USD value across groups, or nil when nothing is priced.
  public static func total(of groups: [PortfolioGroup]) -> String? {
    DecimalValue.sum(groups.compactMap(\.valueUSD))
  }

  /// 24-hour change across the priced holdings that report one, as a signed USD amount and percent,
  /// or nil when none do.
  ///
  /// The baseline is each contributing holding's value discounted by its own change, so the result
  /// is the true portfolio change rather than an average of percentages. A priced holding that has no
  /// change (the catalog withholds `h24` for any non-`ok` status) is left out of both sides; when none
  /// report a change, no change line is shown.
  public static func totalChange(of groups: [PortfolioGroup]) -> PortfolioChange? {
    guard let totals = totals(of: groups.flatMap(\.holdings)),
      let amount = DecimalValue.signedSubtract(totals.current, totals.baseline),
      let percent = DecimalValue.percentageChange(
        current: totals.current, previous: totals.baseline)
    else { return nil }
    return PortfolioChange(amountUSD: amount, percent: percent)
  }

  /// The value-weighted 24-hour percent change over the holdings that report both a value and a
  /// change, or nil when none do.
  static func change24h(of holdings: [PortfolioHolding]) -> String? {
    guard let totals = totals(of: holdings) else { return nil }
    return DecimalValue.percentageChange(current: totals.current, previous: totals.baseline)
  }

  /// The summed current value and summed day-old baseline for the holdings that report both a value
  /// and a change, or nil when none do.
  private static func totals(of holdings: [PortfolioHolding])
    -> (current: String, baseline: String)?
  {
    var current: [String] = []
    var baseline: [String] = []
    for holding in holdings {
      guard let value = holding.valueUSD, let change = holding.change24h,
        let past = pastValue(value: value, changePercent: change)
      else { continue }
      current.append(value)
      baseline.append(past)
    }
    guard let currentTotal = DecimalValue.sum(current),
      let baselineTotal = DecimalValue.sum(baseline)
    else { return nil }
    return (currentTotal, baselineTotal)
  }

  /// A holding's value discounted by its 24-hour percent change, i.e. its value one day ago under
  /// the assumption that the balance is unchanged. Returns nil when the divisor is unusable.
  private static func pastValue(value: String, changePercent: String) -> String? {
    let trimmed = changePercent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rate = DecimalValue.signed(trimmed) else { return nil }
    let isNegative = rate.hasPrefix("-")
    let magnitude = isNegative ? String(rate.dropFirst()) : rate
    guard let fraction = DecimalValue.multiplyingByPowerOfTen(magnitude, -2) else { return nil }
    let divisor: String
    if isNegative {
      guard let difference = DecimalValue.subtract("1", fraction) else { return nil }
      divisor = difference
    } else {
      guard let total = DecimalValue.sum(["1", fraction]) else { return nil }
      divisor = total
    }
    guard !DecimalValue.isZero(divisor) else { return nil }
    return DecimalValue.divide(value, by: divisor, fractionDigits: 12)
  }

  /// True when the left value should sort before the right one.
  private static func valueOrder(_ lhs: String?, _ rhs: String?) -> Bool? {
    switch (lhs, rhs) {
    case (let left?, let right?):
      guard left != right else { return nil }
      return DecimalValue.compare(left, right) == .orderedDescending
    case (nil, .some):
      return false
    case (.some, nil):
      return true
    case (nil, nil):
      return nil
    }
  }
}
