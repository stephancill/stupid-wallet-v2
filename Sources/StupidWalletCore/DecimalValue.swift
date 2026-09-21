import Foundation

/// Exact arithmetic on non-negative decimal strings, used for USD display values.
///
/// Values are plain decimal strings (for example `2629.256297515841`). Every operation is exact
/// integer digit arithmetic; no floating point is involved. Display values are rounded to four
/// significant figures.
public enum DecimalValue {
  /// Significant figures used for USD display.
  public static let displaySignificantDigits = 4

  /// Numeric comparison of two decimal strings. Unparsable input compares equal.
  public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    guard let left = parse(lhs), let right = parse(rhs) else { return .orderedSame }
    if left.integer.count != right.integer.count {
      return left.integer.count < right.integer.count ? .orderedAscending : .orderedDescending
    }
    if left.integer != right.integer {
      return left.integer < right.integer ? .orderedAscending : .orderedDescending
    }
    let scale = max(left.fraction.count, right.fraction.count)
    let leftFraction = pad(left.fraction, to: scale)
    let rightFraction = pad(right.fraction, to: scale)
    if leftFraction == rightFraction { return .orderedSame }
    return leftFraction < rightFraction ? .orderedAscending : .orderedDescending
  }

  /// Whether the value is exactly zero.
  public static func isZero(_ value: String) -> Bool {
    guard let parsed = parse(value) else { return true }
    return parsed.integer == "0" && parsed.fraction.isEmpty
  }

  /// Exact sum. Returns nil when no input is parsable.
  public static func sum(_ values: [String]) -> String? {
    let parsed = values.compactMap(parse)
    guard !parsed.isEmpty else { return nil }
    let scale = parsed.map(\.fraction.count).max() ?? 0
    var total = "0"
    for value in parsed {
      total = addDigits(total, value.integer + pad(value.fraction, to: scale))
    }
    return render(digits: total, scale: scale)
  }

  /// Exact product. Returns nil when either input is unparsable.
  public static func product(_ lhs: String, _ rhs: String) -> String? {
    guard let left = parse(lhs), let right = parse(rhs) else { return nil }
    let digits = multiplyDigits(left.integer + left.fraction, right.integer + right.fraction)
    return render(digits: digits, scale: left.fraction.count + right.fraction.count)
  }

  /// Truncates (never rounds) to a number of fraction digits.
  public static func truncating(_ value: String, fractionDigits: Int) -> String? {
    guard let parsed = parse(value) else { return nil }
    return render(
      integer: parsed.integer, fraction: String(parsed.fraction.prefix(max(0, fractionDigits))))
  }

  /// Rounds half-up to a number of significant digits.
  public static func significant(_ value: String, digits: Int) -> String? {
    guard digits > 0, let parsed = parse(value) else { return nil }
    let digitString = Array(parsed.integer + parsed.fraction)
    guard let firstNonZero = digitString.firstIndex(where: { $0 != "0" }) else { return "0" }
    guard digitString.count - firstNonZero > digits else {
      return render(integer: parsed.integer, fraction: parsed.fraction)
    }
    var kept = String(digitString[firstNonZero..<(firstNonZero + digits)])
    let droppedCount = digitString.count - (firstNonZero + digits)
    if digitString[firstNonZero + digits] >= "5" { kept = addDigits(kept, "1") }
    return render(digits: kept, scale: parsed.fraction.count - droppedCount)
  }

  /// Four-significant-figure USD display with grouping separators, or nil when unparsable.
  public static func usd(_ value: String) -> String? {
    guard let parsed = parse(value) else { return nil }
    if parsed.integer == "0", parsed.fraction.isEmpty { return "$0.00" }
    guard let rounded = significant(value, digits: displaySignificantDigits),
      let parts = parse(rounded)
    else { return nil }
    let fraction = parts.fraction.isEmpty ? "" : ".\(parts.fraction)"
    return "$\(grouped(parts.integer))\(fraction)"
  }

  // MARK: - Parsing and rendering

  struct Parts {
    var integer: String  // no leading zeros, "0" when empty
    var fraction: String  // no trailing zeros, may be empty
  }

  static func parse(_ value: String) -> Parts? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count <= 2 else { return nil }
    let whole = String(pieces[0])
    let fraction = pieces.count == 2 ? String(pieces[1]) : ""
    guard !whole.isEmpty || !fraction.isEmpty,
      whole.allSatisfy(\.isNumber), fraction.allSatisfy(\.isNumber)
    else { return nil }
    let integer = whole.drop { $0 == "0" }
    var trimmedFraction = fraction[...]
    while trimmedFraction.last == "0" { trimmedFraction = trimmedFraction.dropLast() }
    return Parts(
      integer: integer.isEmpty ? "0" : String(integer), fraction: String(trimmedFraction))
  }

  private static func render(integer: String, fraction: String) -> String {
    let whole = String(integer.drop { $0 == "0" })
    var digits = Array(fraction)
    while digits.last == "0" { digits.removeLast() }
    let wholeText = whole.isEmpty ? "0" : whole
    return digits.isEmpty ? wholeText : "\(wholeText).\(String(digits))"
  }

  /// Splits a digit string into a decimal value with `scale` fraction digits.
  private static func render(digits: String, scale: Int) -> String {
    guard scale > 0 else {
      return render(integer: digits + String(repeating: "0", count: max(0, -scale)), fraction: "")
    }
    let padded =
      digits.count > scale
      ? digits : String(repeating: "0", count: scale + 1 - digits.count) + digits
    return render(integer: String(padded.dropLast(scale)), fraction: String(padded.suffix(scale)))
  }

  private static func pad(_ fraction: String, to length: Int) -> String {
    fraction.count >= length
      ? fraction : fraction + String(repeating: "0", count: length - fraction.count)
  }

  private static func grouped(_ integer: String) -> String {
    var result = ""
    for (offset, digit) in integer.reversed().enumerated() {
      if offset > 0, offset % 3 == 0 { result.append(",") }
      result.append(digit)
    }
    return String(result.reversed())
  }

  // MARK: - Digit arithmetic

  /// Adds two digit strings without separators.
  static func addDigits(_ lhs: String, _ rhs: String) -> String {
    let left = Array(lhs.utf8.reversed())
    let right = Array(rhs.utf8.reversed())
    var result: [UInt8] = []
    var carry: UInt8 = 0
    for index in 0..<max(left.count, right.count) {
      let leftDigit = index < left.count ? left[index] - 48 : 0
      let rightDigit = index < right.count ? right[index] - 48 : 0
      let total = leftDigit + rightDigit + carry
      result.append(total % 10 + 48)
      carry = total / 10
    }
    if carry > 0 { result.append(carry + 48) }
    return String(decoding: result.reversed(), as: UTF8.self)
  }

  /// Schoolbook multiplication of two digit strings without separators.
  static func multiplyDigits(_ lhs: String, _ rhs: String) -> String {
    let left = lhs.compactMap { $0.wholeNumberValue }
    let right = rhs.compactMap { $0.wholeNumberValue }
    guard !left.isEmpty, !right.isEmpty else { return "0" }
    var product = [Int](repeating: 0, count: left.count + right.count)
    for (leftIndex, leftDigit) in left.reversed().enumerated() {
      for (rightIndex, rightDigit) in right.reversed().enumerated() {
        product[leftIndex + rightIndex] += leftDigit * rightDigit
      }
    }
    for index in 0..<(product.count - 1) {
      product[index + 1] += product[index] / 10
      product[index] %= 10
    }
    while product.count > 1, product.last == 0 { product.removeLast() }
    return product.reversed().map(String.init).joined()
  }
}
