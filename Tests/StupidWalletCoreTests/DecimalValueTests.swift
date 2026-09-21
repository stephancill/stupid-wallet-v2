import Foundation
import Testing

@testable import StupidWalletCore

@Test("display rounds dollars to exactly two decimals")
func display() throws {
  #expect(DecimalValue.truncating("1.239", fractionDigits: 2) == "1.23")
  #expect(DecimalValue.truncating("0.009", fractionDigits: 2) == "0")
  #expect(DecimalValue.truncating("5", fractionDigits: 2) == "5")

  #expect(DecimalValue.usd("0") == "$0.00")
  #expect(DecimalValue.usd("0.001") == "$0.00")
  #expect(DecimalValue.usd("0.005") == "$0.01")
  #expect(DecimalValue.usd("0.999") == "$1.00")
  #expect(DecimalValue.usd("12.34") == "$12.34")
  #expect(DecimalValue.usd("1.2342485879001691507066") == "$1.23")
  #expect(DecimalValue.usd("1234.567") == "$1,234.57")
  #expect(DecimalValue.usd("1311.3220451758523") == "$1,311.32")
  #expect(DecimalValue.usd("1312.5562937637524691507066") == "$1,312.56")
  #expect(DecimalValue.usd("12340") == "$12,340.00")
  #expect(DecimalValue.usd("1234567.891") == "$1,234,567.89")
  #expect(DecimalValue.usd("1000000") == "$1,000,000.00")
  #expect(DecimalValue.usd("12340000") == "$12,340,000.00")
  #expect(DecimalValue.usd("999.95") == "$999.95")
  #expect(DecimalValue.usd("0.0000012345") == "$0.00")
  #expect(DecimalValue.usd("nope") == nil)
  // A tenth keeps its trailing zero, and a whole dollar keeps its cents.
  #expect(DecimalValue.usd("1.3") == "$1.30")
  #expect(DecimalValue.usd("1527.3") == "$1,527.30")
  #expect(DecimalValue.signedUSD("1527.3") == "+$1,527.30")
  #expect(DecimalValue.signedUSD("-0.5") == "-$0.50")
  #expect(DecimalValue.signedUSD("0") == "$0.00")
}

struct DecimalValueTests {
  @Test("significant-digit previews handle tiny values, full-width balances, and rounding carries")
  func significantDigits() {
    #expect(DecimalValue.rounded("12640.510709", significantDigits: 6) == "12640.5")
    #expect(DecimalValue.rounded("1.234565", significantDigits: 6) == "1.23457")
    #expect(DecimalValue.rounded("1234567.89", significantDigits: 6) == "1234570")
    #expect(DecimalValue.rounded("0.00000123456789", significantDigits: 6) == "0.00000123457")
    #expect(
      DecimalValue.rounded("0.000000000000000001", significantDigits: 6) == "0.000000000000000001")
    #expect(DecimalValue.rounded("9.999995", significantDigits: 6) == "10")
    #expect(DecimalValue.rounded("0.009999995", significantDigits: 6) == "0.01")
    #expect(DecimalValue.rounded("999999.5", significantDigits: 6) == "1000000")
    #expect(DecimalValue.rounded("000.5000", significantDigits: 6) == "0.5")
    #expect(DecimalValue.rounded("0", significantDigits: 6) == "0")
    let maximum = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
    #expect(
      DecimalValue.rounded(maximum, significantDigits: 6)
        == "115792" + String(repeating: "0", count: 72))
    #expect(DecimalValue.rounded("nope", significantDigits: 6) == nil)
    #expect(DecimalValue.rounded("1", significantDigits: 0) == nil)
  }

  @Test("values normalize without floating point")
  func parsing() throws {
    #expect(DecimalValue.compare("0", "0.000") == .orderedSame)
    #expect(DecimalValue.compare("00.500", "0.5") == .orderedSame)
    #expect(DecimalValue.compare(".5", "0.5") == .orderedSame)
    #expect(DecimalValue.compare("5.", "5") == .orderedSame)
    #expect(DecimalValue.compare("2", "10") == .orderedAscending)
    #expect(DecimalValue.compare("0.5", "0.45") == .orderedDescending)
    #expect(DecimalValue.compare("1.0000001", "1") == .orderedDescending)
    #expect(DecimalValue.compare("not-a-number", "1") == .orderedSame)
    #expect(DecimalValue.compare("1.2.3", "1") == .orderedSame)
    #expect(DecimalValue.compare("-1", "1") == .orderedSame)
    #expect(DecimalValue.isZero("0.000"))
    #expect(!DecimalValue.isZero("0.0000001"))
  }

  @Test("sums and products match independent exact arithmetic")
  func arithmetic() throws {
    #expect(DecimalValue.sum(["1.5", "2.25"]) == "3.75")
    #expect(DecimalValue.sum(["0.1", "0.2"]) == "0.3")
    #expect(DecimalValue.sum(["0", "0"]) == "0")
    #expect(DecimalValue.sum(["1", "0.000000000000000001"]) == "1.000000000000000001")
    #expect(DecimalValue.sum([]) == nil)
    #expect(DecimalValue.sum(["abc"]) == nil)

    #expect(DecimalValue.product("1.5", "2") == "3")
    #expect(DecimalValue.product("0.000001", "0.000001") == "0.000000000001")
    #expect(
      DecimalValue.product("1.234567", "0.9997420860108598") == "1.2342485879001691507066")
    #expect(DecimalValue.product("0.5", "2622.6440903517046") == "1311.3220451758523")
    let maximum = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
    #expect(
      DecimalValue.product(maximum, "0.5")
        == "57896044618658097711785492504343953926634992332820282019728792003956564819967.5")
    #expect(
      DecimalValue.product(maximum, "2622.6440903517046")
        == "303681438547724537817288088113482804039929689614104029991185207823303696484048839.828911483201"
    )
    #expect(DecimalValue.product("abc", "1") == nil)
    #expect(
      DecimalValue.sum([
        DecimalValue.product("1.234567", "0.9997420860108598")!,
        DecimalValue.product("0.5", "2622.6440903517046")!,
      ]) == "1312.5562937637524691507066")
  }

  @Test("subtraction and division are exact and reject negative or zero divisors")
  func subtractionAndDivision() throws {
    #expect(DecimalValue.subtract("5", "3") == "2")
    #expect(DecimalValue.subtract("1", "0.25") == "0.75")
    #expect(DecimalValue.subtract("3", "5") == nil)
    #expect(DecimalValue.subtract("1", "1") == "0")

    #expect(DecimalValue.divide("10", by: "4", fractionDigits: 2) == "2.5")
    #expect(DecimalValue.divide("1", by: "3", fractionDigits: 4) == "0.3333")
    #expect(DecimalValue.divide("2.5", by: "0.5", fractionDigits: 2) == "5")
    #expect(DecimalValue.divide("40", by: "0.8", fractionDigits: 12) == "50")
    #expect(DecimalValue.divide("1", by: "0", fractionDigits: 2) == nil)
    #expect(DecimalValue.divide("abc", by: "2", fractionDigits: 2) == nil)

    #expect(DecimalValue.multiplyingByPowerOfTen("1.5", 2) == "150")
    #expect(DecimalValue.multiplyingByPowerOfTen("20", -2) == "0.2")
  }

  @Test("percent change is signed, exact, and handles zero baselines")
  func percentChange() throws {
    #expect(DecimalValue.percentageChange(current: "105", previous: "100") == "5")
    #expect(DecimalValue.percentageChange(current: "95", previous: "100") == "-5")
    #expect(DecimalValue.percentageChange(current: "100", previous: "100") == "0")
    #expect(DecimalValue.percentageChange(current: "200", previous: "150") == "33.33")
    #expect(DecimalValue.percentageChange(current: "5", previous: "0") == nil)

    #expect(DecimalValue.signed("-0.500") == "-0.5")
    #expect(DecimalValue.signed("4.2500") == "4.25")
    #expect(DecimalValue.signed("-0") == "0")
    #expect(DecimalValue.signed("nope") == nil)

    #expect(DecimalValue.signedPercent("4.25") == "+4.25%")
    #expect(DecimalValue.signedPercent("-0.5") == "-0.50%")
    #expect(DecimalValue.signedPercent("0") == "0.00%")

    #expect(DecimalValue.signedSubtract("50", "40") == "10")
    #expect(DecimalValue.signedSubtract("40", "50") == "-10")
    #expect(DecimalValue.signedSubtract("5", "5") == "0")
    #expect(DecimalValue.signedSubtract("abc", "1") == nil)

    #expect(DecimalValue.signedUSD("1234") == "+$1,234.00")
    #expect(DecimalValue.signedUSD("-12.34") == "-$12.34")
    #expect(DecimalValue.signedUSD("0") == "$0.00")
    #expect(DecimalValue.signedUSD("nope") == nil)
  }
}
