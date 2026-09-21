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

  public var id: String { "\(chainID):\(address ?? "native")" }
  public var isNative: Bool { address == nil }
  public var valueDisplay: String? { valueUSD.flatMap(DecimalValue.usd) }

  public init(
    chainID: String, networkName: String, symbol: String, address: String?, iconURL: URL?,
    raw: [UInt8], decimals: UInt8, priceUSD: String?, valueUSD: String?
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
  }

  /// The exact USD value of a balance at a price, or nil when either is unusable.
  public static func value(raw: [UInt8], decimals: UInt8, price: String) -> String? {
    DecimalValue.product(
      ClearSigningFormatter.scaledDecimal(raw: raw, decimals: Int(decimals)), price)
  }
}

/// Holdings sharing one symbol across networks, highest value first.
public struct PortfolioGroup: Sendable, Equatable, Identifiable {
  public let symbol: String
  public let holdings: [PortfolioHolding]
  public let valueUSD: String?

  public var id: String { symbol }
  public var isGrouped: Bool { holdings.count > 1 }
  public var valueDisplay: String? { valueUSD.flatMap(DecimalValue.usd) }
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
          valueUSD: DecimalValue.sum(ordered.compactMap(\.valueUSD)))
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
