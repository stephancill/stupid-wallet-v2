import Foundation
import Testing

@testable import StupidWalletCore

@Test("display uses four significant figures")
func display() throws {
  #expect(DecimalValue.truncating("1.239", fractionDigits: 2) == "1.23")
  #expect(DecimalValue.truncating("0.009", fractionDigits: 2) == "0")
  #expect(DecimalValue.truncating("5", fractionDigits: 2) == "5")

  #expect(DecimalValue.significant("1234.567", digits: 4) == "1235")
  #expect(DecimalValue.significant("12345.6", digits: 4) == "12350")
  #expect(DecimalValue.significant("1234567", digits: 4) == "1235000")
  #expect(DecimalValue.significant("1.23456", digits: 4) == "1.235")
  #expect(DecimalValue.significant("0.0000012345", digits: 4) == "0.000001235")
  #expect(DecimalValue.significant("9999.9", digits: 4) == "10000")
  #expect(DecimalValue.significant("0.5", digits: 4) == "0.5")
  #expect(DecimalValue.significant("0", digits: 4) == "0")

  #expect(DecimalValue.usd("0") == "$0.00")
  #expect(DecimalValue.usd("0.001") == "$0.001")
  #expect(DecimalValue.usd("0.999") == "$0.999")
  #expect(DecimalValue.usd("1234.567") == "$1,235")
  #expect(DecimalValue.usd("1234567.891") == "$1,235,000")
  #expect(DecimalValue.usd("1000000") == "$1,000,000")
  #expect(DecimalValue.usd("1311.3220451758523") == "$1,311")
  #expect(DecimalValue.usd("1.2342485879001691507066") == "$1.234")
  #expect(DecimalValue.usd("1312.5562937637524691507066") == "$1,313")
  #expect(DecimalValue.usd("0.0000012345") == "$0.000001235")
  #expect(DecimalValue.usd("nope") == nil)
}

struct DecimalValueTests {
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

    #expect(DecimalValue.signedUSD("1234") == "+$1,234")
    #expect(DecimalValue.signedUSD("-12.34") == "-$12.34")
    #expect(DecimalValue.signedUSD("0") == "$0.00")
    #expect(DecimalValue.signedUSD("nope") == nil)
  }
}
