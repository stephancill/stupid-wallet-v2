import Foundation
import Testing

@testable import StupidWalletCore

struct PortfolioTests {
  private func holding(
    chain: String, network: String, symbol: String, value: String?, address: String? = "0xtoken",
    change: String? = nil
  ) -> PortfolioHolding {
    PortfolioHolding(
      chainID: chain, networkName: network, symbol: symbol, address: address, iconURL: nil,
      raw: [UInt8](repeating: 0, count: 32), decimals: 18, priceUSD: nil, valueUSD: value,
      change24h: change)
  }

  @Test("holdings multiply the balance by the price exactly")
  func value() throws {
    // 1.5 ETH at 2622.6440903517046 USD.
    let wei = try #require(Hex.quantityData(hex: "0x14d1120d7b160000"))
    #expect(
      PortfolioHolding.value(raw: wei, decimals: 18, price: "2622.6440903517046")
        == "3933.9661355275569")
    // 1.234567 USDC at 0.9997420860108598 USD.
    let units = try #require(Hex.quantityData(hex: "0x12d687"))
    #expect(
      PortfolioHolding.value(raw: units, decimals: 6, price: "0.9997420860108598")
        == "1.2342485879001691507066")
    #expect(PortfolioHolding.value(raw: units, decimals: 6, price: "not-a-price") == nil)
  }

  @Test("holding balance previews are independent of price and keep tiny and zero amounts visible")
  func balanceDisplay() throws {
    let units = try #require(Hex.quantityData(hex: "0x12d687"))
    let token = PortfolioHolding(
      chainID: "1", networkName: "Ethereum", symbol: "USDC", address: "0xtoken", iconURL: nil,
      raw: units, decimals: 6, priceUSD: nil, valueUSD: nil)
    #expect(token.balanceDisplay == "1.23457")
    let tiny = PortfolioHolding(
      chainID: "8453", networkName: "Base", symbol: "ETH", address: nil, iconURL: nil,
      raw: [1], decimals: 18, priceUSD: nil, valueUSD: nil)
    #expect(tiny.balanceDisplay == "0.000000000000000001")
    let zero = PortfolioHolding(
      chainID: "1", networkName: "Ethereum", symbol: "USDC", address: "0xtoken", iconURL: nil,
      raw: [0], decimals: 6, priceUSD: nil, valueUSD: "0")
    #expect(zero.balanceDisplay == "0")
  }

  @Test("group balance sums exact token quantities before rounding across differing decimals")
  func groupedBalanceDisplay() throws {
    let first = PortfolioHolding(
      chainID: "1", networkName: "Ethereum", symbol: "USDC", address: "0xtoken",
      iconURL: nil, raw: try #require(Hex.quantityData(hex: "0x75bcbf2")), decimals: 8,
      priceUSD: nil, valueUSD: nil)
    let second = PortfolioHolding(
      chainID: "8453", networkName: "Base", symbol: "USDC", address: "0xtoken",
      iconURL: nil, raw: [40], decimals: 9, priceUSD: nil, valueUSD: nil)
    let group = try #require(PortfolioGroup.groups(from: [first, second]).first)
    #expect(first.balanceDisplay == "1.23456")
    #expect(group.balanceDisplay == "1.23457")
    #expect(group.networkLabel == "2 networks")
    #expect(group.valueDisplay == nil)

    let tiny = PortfolioHolding(
      chainID: "1", networkName: "Ethereum", symbol: "ETH", address: nil, iconURL: nil,
      raw: [1], decimals: 18, priceUSD: nil, valueUSD: nil)
    let tinyGroup = try #require(
      PortfolioGroup.groups(from: [
        tiny,
        PortfolioHolding(
          chainID: "8453", networkName: "Base", symbol: "ETH", address: nil, iconURL: nil,
          raw: [1], decimals: 18, priceUSD: nil, valueUSD: nil
        ),
      ]).first)
    #expect(tinyGroup.balanceDisplay == "0.000000000000000002")
  }

  @Test("holdings group by symbol, ordered by value with unpriced last")
  func grouping() {
    let groups = PortfolioGroup.groups(from: [
      holding(chain: "1", network: "Ethereum", symbol: "ETH", value: "8000", address: nil),
      holding(chain: "8453", network: "Base", symbol: "ETH", value: "3000", address: nil),
      holding(chain: "1", network: "Ethereum", symbol: "USDC", value: "4345.6789"),
      holding(chain: "1", network: "Ethereum", symbol: "PEPE", value: nil),
    ])

    #expect(groups.map(\.symbol) == ["ETH", "USDC", "PEPE"])
    #expect(groups[0].holdings.map(\.chainID) == ["1", "8453"])
    #expect(groups[0].isGrouped)
    #expect(groups[0].valueUSD == "11000")
    #expect(groups[0].valueDisplay == "$11,000.00")
    #expect(groups[0].networkLabel == "2 networks")
    #expect(!groups[1].isGrouped)
    #expect(groups[1].networkLabel == "Ethereum")
    #expect(groups[1].valueDisplay == "$4,345.68")
    #expect(groups[2].valueDisplay == nil)
    #expect(PortfolioGroup.total(of: groups) == "15345.6789")
    #expect(PortfolioGroup.total(of: groups).flatMap(DecimalValue.usd) == "$15,345.68")
    #expect(PortfolioGroup.total(of: []) == nil)
  }

  @Test("same symbol is grouped case-insensitively and keeps a display symbol")
  func groupingIsCaseInsensitive() {
    let groups = PortfolioGroup.groups(from: [
      holding(chain: "1", network: "Ethereum", symbol: "usdc", value: "5"),
      holding(chain: "8453", network: "Base", symbol: "USDC", value: "7"),
    ])
    #expect(groups.count == 1)
    #expect(groups[0].holdings.count == 2)
    #expect(groups[0].symbol == "USDC")  // the higher-value holding's spelling wins
    #expect(groups[0].valueUSD == "12")
  }

  @Test("a group's change is the value-weighted change of its priced holdings")
  func groupChange() {
    let groups = PortfolioGroup.groups(from: [
      holding(
        chain: "1", network: "Ethereum", symbol: "ETH", value: "100", address: nil, change: "-20"),
      holding(
        chain: "8453", network: "Base", symbol: "ETH", value: "100", address: nil, change: "0"),
      holding(chain: "1", network: "Ethereum", symbol: "USDC", value: "50", change: "25"),
    ])
    #expect(groups.map(\.symbol) == ["ETH", "USDC"])
    #expect(groups[0].isGrouped)
    #expect(groups[0].valueUSD == "200")
    // 100 at -20% (baseline 125) and 100 flat (baseline 100): 200/225 - 1.
    #expect(groups[0].change24h == "-11.11")
    #expect(groups[0].changeDisplay == "-11.11%")
    #expect(groups[1].change24h == "25")
    #expect(groups[1].changeDisplay == "+25.00%")
  }

  @Test("a priced holding without a change is left out of the portfolio change")
  func partialChange() {
    let groups = PortfolioGroup.groups(from: [
      holding(
        chain: "1", network: "Ethereum", symbol: "ETH", value: "50", address: nil, change: "25"),
      holding(chain: "1", network: "Ethereum", symbol: "USDC", value: "100"),
    ])
    let change = PortfolioGroup.totalChange(of: groups)
    #expect(change?.percent == "25")
    #expect(change?.amountUSD == "10")
    #expect(change?.display == "+$10.00 (+25.00%)")
    #expect(groups.first(where: { $0.symbol == "ETH" })?.change24h == "25")
    #expect(groups.first(where: { $0.symbol == "USDC" })?.change24h == nil)
  }

  @Test("total change aggregates groups with the same baseline")
  func totalChange() {
    // 200 at +100% (baseline 100) and 100 flat (baseline 100): 300/200 - 1 = +50%, +$100.
    let groups = PortfolioGroup.groups(from: [
      holding(
        chain: "1", network: "Ethereum", symbol: "ETH", value: "200", address: nil, change: "100"),
      holding(chain: "1", network: "Ethereum", symbol: "USDC", value: "100", change: "0"),
    ])
    #expect(PortfolioGroup.totalChange(of: groups)?.percent == "50")
    #expect(PortfolioGroup.totalChange(of: groups)?.amountUSD == "100")
    #expect(PortfolioGroup.totalChange(of: []) == nil)
  }
}
