import Foundation

/// Exact arithmetic on non-negative decimal strings, used for USD display values.
///
/// Values are plain decimal strings (for example `2629.256297515841`). Every operation is exact
/// integer digit arithmetic; no floating point is involved. Division truncates toward zero to a
/// requested number of fraction digits. Display values are rounded to at most two decimal places.
public enum DecimalValue {
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

  /// Full USD display with grouping separators, rounded half-up to at most two decimal places, or
  /// nil when unparsable. Examples: `$12.34`, `$1,234.57`, `$34,400,000`, `$0`.
  public static func usd(_ value: String) -> String? {
    guard parse(value) != nil,
      // Round to cents half-up: add half a cent to the value scaled by 100, truncate, then rescale.
      let scaled = multiplyingByPowerOfTen(value, 2),
      let shifted = sum([scaled, "0.5"]),
      let cents = truncating(shifted, fractionDigits: 0),
      let dollars = multiplyingByPowerOfTen(cents, -2),
      let parts = parse(dollars)
    else { return nil }
    let fraction = parts.fraction.isEmpty ? "" : ".\(parts.fraction)"
    return "$\(grouped(parts.integer))\(fraction)"
  }

  /// Exact difference of two non-negative decimal strings, or nil when the result would be
  /// negative or either input is unparsable.
  public static func subtract(_ lhs: String, _ rhs: String) -> String? {
    guard let left = parse(lhs), let right = parse(rhs) else { return nil }
    let scale = max(left.fraction.count, right.fraction.count)
    let leftDigits = left.integer + pad(left.fraction, to: scale)
    let rightDigits = right.integer + pad(right.fraction, to: scale)
    guard let difference = subtractDigits(leftDigits, rightDigits) else { return nil }
    return render(digits: difference, scale: scale)
  }

  /// Exact long division of non-negative decimal strings, truncated toward zero to
  /// `fractionDigits` decimals. Returns nil when either input is unparsable or the divisor is zero.
  public static func divide(_ lhs: String, by rhs: String, fractionDigits: Int) -> String? {
    guard fractionDigits >= 0, let left = parse(lhs), let right = parse(rhs) else { return nil }
    let divisorDigits = right.integer + right.fraction
    guard divisorDigits.contains(where: { $0 != "0" }) else { return nil }
    let numerator =
      left.integer + left.fraction
      + String(repeating: "0", count: right.fraction.count + fractionDigits)
    let denominator = divisorDigits + String(repeating: "0", count: left.fraction.count)
    guard let quotient = divideDigits(numerator, by: denominator) else { return nil }
    return render(digits: quotient, scale: fractionDigits)
  }

  /// Exact signed percentage change from `previous` to `current`, truncated to `fractionDigits`
  /// decimals. Returns a leading `-` for a decrease, or nil when the baseline is zero or unparsable.
  public static func percentageChange(
    current: String, previous: String, fractionDigits: Int = 2
  ) -> String? {
    guard fractionDigits >= 0, let baseline = parse(previous), parse(current) != nil,
      !(baseline.integer == "0" && baseline.fraction.isEmpty)
    else { return nil }
    let comparison = compare(current, previous)
    if comparison == .orderedSame { return "0" }
    let magnitude =
      comparison == .orderedAscending
      ? subtract(previous, current) : subtract(current, previous)
    guard let magnitude, let scaled = multiplyingByPowerOfTen(magnitude, 2),
      let percent = divide(scaled, by: previous, fractionDigits: fractionDigits)
    else { return nil }
    guard !isZero(percent) else { return "0" }
    return comparison == .orderedAscending ? "-\(percent)" : percent
  }

  /// Canonical signed decimal string, accepting an optional leading `-`. Unlike `parse`, this
  /// preserves a negative sign for percent-change values.
  public static func signed(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let negative = trimmed.hasPrefix("-")
    let magnitude = negative ? String(trimmed.dropFirst()) : trimmed
    guard let parsed = parse(magnitude) else { return nil }
    let rendered = render(integer: parsed.integer, fraction: parsed.fraction)
    guard negative, !(parsed.integer == "0" && parsed.fraction.isEmpty) else { return rendered }
    return "-\(rendered)"
  }

  /// Exact signed difference of two non-negative decimal strings, prefixed with `-` when the result
  /// is negative. Returns nil when either input is unparsable.
  public static func signedSubtract(_ lhs: String, _ rhs: String) -> String? {
    guard parse(lhs) != nil, parse(rhs) != nil else { return nil }
    let comparison = compare(lhs, rhs)
    if comparison == .orderedSame { return "0" }
    let magnitude = comparison == .orderedAscending ? subtract(rhs, lhs) : subtract(lhs, rhs)
    guard let magnitude else { return nil }
    return comparison == .orderedAscending ? "-\(magnitude)" : magnitude
  }

  /// Signed USD display such as `+$1,234`, `-$12.34`, or `$0.00`.
  public static func signedUSD(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let negative = trimmed.hasPrefix("-")
    let magnitude = negative ? String(trimmed.dropFirst()) : trimmed
    guard let display = usd(magnitude) else { return nil }
    guard !isZero(magnitude) else { return display }
    return negative ? "-\(display)" : "+\(display)"
  }

  /// Signed percent display such as `+4.25%`, `-0.01%`, or `0.00%`.
  public static func signedPercent(_ value: String, fractionDigits: Int = 2) -> String? {
    guard fractionDigits >= 0 else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let negative = trimmed.hasPrefix("-")
    let magnitude = negative ? String(trimmed.dropFirst()) : trimmed
    guard let parsed = parse(magnitude) else { return nil }
    let isZeroValue = parsed.integer == "0" && parsed.fraction.isEmpty
    let sign = isZeroValue ? "" : (negative ? "-" : "+")
    return "\(sign)\(grouped(parsed.integer)).\(pad(parsed.fraction, to: fractionDigits))%"
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

  /// Multiplies a non-negative decimal string by a power of ten, shifting the decimal point.
  static func multiplyingByPowerOfTen(_ value: String, _ power: Int) -> String? {
    guard let parsed = parse(value) else { return nil }
    if power == 0 { return render(integer: parsed.integer, fraction: parsed.fraction) }
    if power > 0 {
      let fraction = parsed.fraction
      if fraction.count <= power {
        return render(
          integer: parsed.integer + fraction
            + String(repeating: "0", count: power - fraction.count),
          fraction: "")
      }
      let split = fraction.index(fraction.startIndex, offsetBy: power)
      return render(
        integer: parsed.integer + fraction[..<split], fraction: String(fraction[split...]))
    }
    let shift = -power
    if parsed.integer.count <= shift {
      let padded = String(repeating: "0", count: shift - parsed.integer.count) + parsed.integer
      let split = padded.index(padded.endIndex, offsetBy: -shift)
      return render(
        integer: String(padded[..<split]), fraction: String(padded[split...]) + parsed.fraction)
    }
    let split = parsed.integer.index(parsed.integer.endIndex, offsetBy: -shift)
    return render(
      integer: String(parsed.integer[..<split]),
      fraction: String(parsed.integer[split...]) + parsed.fraction)
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

  /// Removes leading zeros from a bare digit string, yielding `0` when nothing remains.
  static func stripLeadingZeros(_ digits: String) -> String {
    let trimmed = digits.drop { $0 == "0" }
    return trimmed.isEmpty ? "0" : String(trimmed)
  }

  /// Numeric comparison of two bare non-negative digit strings.
  static func compareDigits(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = stripLeadingZeros(lhs)
    let right = stripLeadingZeros(rhs)
    if left.count != right.count {
      return left.count < right.count ? .orderedAscending : .orderedDescending
    }
    if left == right { return .orderedSame }
    return left < right ? .orderedAscending : .orderedDescending
  }

  /// Subtracts two bare digit strings, or nil when the result would be negative.
  static func subtractDigits(_ lhs: String, _ rhs: String) -> String? {
    guard compareDigits(lhs, rhs) != .orderedAscending else { return nil }
    let left = Array(stripLeadingZeros(lhs).utf8.reversed())
    let right = Array(stripLeadingZeros(rhs).utf8.reversed())
    var result: [UInt8] = []
    var borrow = 0
    for index in 0..<left.count {
      var digit =
        Int(left[index]) - 48 - (index < right.count ? Int(right[index]) - 48 : 0) - borrow
      if digit < 0 {
        digit += 10
        borrow = 1
      } else {
        borrow = 0
      }
      result.append(UInt8(digit) + 48)
    }
    return stripLeadingZeros(String(decoding: result.reversed(), as: UTF8.self))
  }

  /// Schoolbook integer division of two bare non-negative digit strings, truncated toward zero.
  static func divideDigits(_ numerator: String, by denominator: String) -> String? {
    let divisor = stripLeadingZeros(denominator)
    guard divisor != "0" else { return nil }
    var quotient = ""
    var remainder = "0"
    for digit in numerator {
      remainder = stripLeadingZeros((remainder == "0" ? "" : remainder) + String(digit))
      var count = 0
      while compareDigits(remainder, divisor) != .orderedAscending {
        guard let next = subtractDigits(remainder, divisor) else { return nil }
        remainder = next
        count += 1
      }
      quotient.append(String(count))
    }
    return stripLeadingZeros(quotient)
  }

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
