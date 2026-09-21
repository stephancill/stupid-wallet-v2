import Foundation

/// Paired editing state. Only a user edit converts USD back into a token amount; price refreshes
/// update the USD display without changing the quantity that will be sent.
public struct SendAmountInput: Sendable, Equatable {
  public enum Unit: Sendable, Hashable { case token, usd }

  public private(set) var token = ""
  public private(set) var usd = ""

  public init() {}

  public mutating func edit(
    value: String, unit: Unit, decimals: UInt8, priceUSD: String?, decimalSeparator: String = "."
  ) {
    switch unit {
    case .token:
      token = value
      refreshUSD(decimals: decimals, priceUSD: priceUSD, decimalSeparator: decimalSeparator)
    case .usd:
      usd = value
      token = ""
      guard let price = Self.price(priceUSD),
        let dollars = Self.decimal(value: value, separator: decimalSeparator),
        let amount = DecimalValue.divide(dollars, by: price, fractionDigits: Int(decimals)),
        let raw = TokenTransfer.rawUnits(fromDecimal: amount, decimals: decimals), raw.count <= 32
      else { return }
      token = amount.replacingOccurrences(of: ".", with: decimalSeparator)
    }
  }

  public mutating func refreshUSD(
    decimals: UInt8, priceUSD: String?, decimalSeparator: String = "."
  ) {
    usd = ""
    guard let price = Self.price(priceUSD),
      let raw = rawUnits(decimals: decimals, decimalSeparator: decimalSeparator),
      let value = PortfolioHolding.value(raw: raw, decimals: decimals, price: price),
      let display = DecimalValue.usd(value)
    else { return }
    // Currency formatting is display-only; it never feeds back into the token amount automatically.
    usd = String(display.dropFirst()).replacingOccurrences(of: ",", with: "")
      .replacingOccurrences(of: ".", with: decimalSeparator)
  }

  public func rawUnits(decimals: UInt8, decimalSeparator: String = ".") -> [UInt8]? {
    guard let amount = Self.decimal(value: token, separator: decimalSeparator),
      let raw = TokenTransfer.rawUnits(fromDecimal: amount, decimals: decimals), raw.count <= 32
    else { return nil }
    return raw
  }

  public static func canConvert(priceUSD: String?) -> Bool { price(priceUSD) != nil }

  private static func price(_ value: String?) -> String? {
    guard let value, let price = decimal(value: value, separator: "."), !DecimalValue.isZero(price)
    else { return nil }
    return price
  }

  private static func decimal(value: String, separator: String) -> String? {
    guard value.utf8.count <= 512 else { return nil }
    let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: separator, with: ".")
    guard canonical.utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) }),
      DecimalValue.parse(canonical) != nil
    else { return nil }
    return canonical
  }
}
