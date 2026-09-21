import Testing

@testable import StupidWalletCore

struct SendAmountInputTests {
  @Test("token editing retains full precision while USD rounds for display without grouping")
  func tokenToUSD() {
    var input = SendAmountInput()
    input.edit(value: "1.234567", unit: .token, decimals: 6, priceUSD: "0.9997420860108598")
    #expect(input.token == "1.234567")
    #expect(input.usd == "1.23")
    #expect(input.rawUnits(decimals: 6) == TokenTransfer.bytes(fromDecimalDigits: "1234567"))
    input.edit(value: "1.", unit: .token, decimals: 18, priceUSD: "2622.6440903517046")
    #expect(input.token == "1.")
    #expect(input.usd == "2622.64")
    input.edit(value: "0.000000000000000001", unit: .token, decimals: 18, priceUSD: "3000")
    #expect(input.usd == "0.00")
    #expect(input.rawUnits(decimals: 18) == [1])
  }

  @Test("USD editing floors to token base units and preserves the entered text")
  func usdToToken() {
    var input = SendAmountInput()
    input.edit(value: "100.00", unit: .usd, decimals: 18, priceUSD: "3000")
    #expect(input.token == "0.033333333333333333")
    #expect(input.usd == "100.00")
    #expect(
      input.rawUnits(decimals: 18) == TokenTransfer.bytes(fromDecimalDigits: "33333333333333333"))
    input.edit(value: "1.", unit: .usd, decimals: 6, priceUSD: "3")
    #expect(input.usd == "1.")
    #expect(input.token == "0.333333")
    input.edit(value: "0.50", unit: .usd, decimals: 0, priceUSD: "3")
    #expect(input.token == "0")
    #expect(input.rawUnits(decimals: 0) == [0])
    input.edit(value: "0.50", unit: .usd, decimals: 6, priceUSD: "0.0000005")
    #expect(input.token == "1000000")
  }

  @Test("price changes update dollars without changing a USD-derived or Max token quantity")
  func priceRefresh() {
    var input = SendAmountInput()
    input.edit(value: "100.00", unit: .usd, decimals: 18, priceUSD: "3000")
    let raw = input.rawUnits(decimals: 18)
    input.refreshUSD(decimals: 18, priceUSD: "2500")
    #expect(input.rawUnits(decimals: 18) == raw)
    #expect(input.usd == "83.33")
    input.refreshUSD(decimals: 18, priceUSD: nil)
    #expect(input.rawUnits(decimals: 18) == raw)
    #expect(input.usd.isEmpty)
    input.refreshUSD(decimals: 18, priceUSD: "3000")
    #expect(input.usd == "100.00")

    let maximum = [UInt8](repeating: 0xff, count: 32)
    let amount = ClearSigningFormatter.scaledDecimal(raw: maximum, decimals: 18)
    input.edit(value: amount, unit: .token, decimals: 18, priceUSD: "0.5")
    input.refreshUSD(decimals: 18, priceUSD: "0.6")
    #expect(input.token == amount)
    #expect(input.rawUnits(decimals: 18) == maximum)
  }

  @Test("clearing either input clears its counterpart, including partial or malformed edits")
  func clearingAndInvalidInput() {
    for invalid in [
      "", ".", "-1", "1e3", "1.2.3", "$1", "1,000", "NaN", "²", "١",
      String(repeating: "1", count: 513),
    ] {
      var input = SendAmountInput()
      input.edit(value: "10", unit: .token, decimals: 18, priceUSD: "2")
      input.edit(value: invalid, unit: .usd, decimals: 18, priceUSD: "2")
      #expect(input.usd == invalid)
      #expect(input.token.isEmpty)
      #expect(input.rawUnits(decimals: 18) == nil)

      input.edit(value: "10", unit: .usd, decimals: 18, priceUSD: "2")
      input.edit(value: invalid, unit: .token, decimals: 18, priceUSD: "2")
      #expect(input.token == invalid)
      #expect(input.usd.isEmpty)
      #expect(input.rawUnits(decimals: 18) == nil)
    }
  }

  @Test("missing, zero, or invalid prices cannot create a token amount from USD")
  func unavailablePrice() {
    for price: String? in [nil, "0", "0.000", "-2", "bad", "١", "1e3"] {
      #expect(!SendAmountInput.canConvert(priceUSD: price))
      var input = SendAmountInput()
      input.edit(value: "1", unit: .token, decimals: 6, priceUSD: price)
      #expect(input.usd.isEmpty)
      #expect(input.rawUnits(decimals: 6) != nil)
      input.edit(value: "10", unit: .usd, decimals: 6, priceUSD: price)
      #expect(input.token.isEmpty)
      #expect(input.rawUnits(decimals: 6) == nil)
    }
    #expect(SendAmountInput.canConvert(priceUSD: "0.000001"))
  }

  @Test("both inputs support a locale decimal separator and pasted dot decimals")
  func localeSeparator() {
    var input = SendAmountInput()
    input.edit(value: "1,5", unit: .token, decimals: 6, priceUSD: "2.5", decimalSeparator: ",")
    #expect(input.usd == "3,75")
    #expect(
      input.rawUnits(decimals: 6, decimalSeparator: ",")
        == TokenTransfer.bytes(fromDecimalDigits: "1500000"))
    input.edit(value: "10,25", unit: .usd, decimals: 6, priceUSD: "2", decimalSeparator: ",")
    #expect(input.token == "5,125")
    #expect(input.usd == "10,25")
    input.edit(value: "1.5", unit: .token, decimals: 6, priceUSD: "2.5", decimalSeparator: ",")
    #expect(input.usd == "3,75")
  }

  @Test("unsupported token precision and uint256 overflow never leave a sendable stale amount")
  func bounds() {
    var input = SendAmountInput()
    input.edit(value: "1.0000001", unit: .token, decimals: 6, priceUSD: "1")
    #expect(input.usd.isEmpty)
    #expect(input.rawUnits(decimals: 6) == nil)
    let overflow = "115792089237316195423570985008687907853269984665640564039457584007913129639936"
    for unit in [SendAmountInput.Unit.token, .usd] {
      input.edit(value: "1", unit: .token, decimals: 0, priceUSD: "1")
      input.edit(value: overflow, unit: unit, decimals: 0, priceUSD: "1")
      #expect(input.rawUnits(decimals: 0) == nil)
    }
  }
}
