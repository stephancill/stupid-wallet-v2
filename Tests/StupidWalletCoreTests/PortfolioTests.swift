import Foundation
import Testing

@testable import StupidWalletCore

struct PortfolioTests {
  private func holding(
    chain: String, network: String, symbol: String, value: String?, address: String? = "0xtoken"
  ) -> PortfolioHolding {
    PortfolioHolding(
      chainID: chain, networkName: network, symbol: symbol, address: address, iconURL: nil,
      raw: [UInt8](repeating: 0, count: 32), decimals: 18, priceUSD: nil, valueUSD: value)
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
    #expect(groups[0].valueDisplay == "$11,000")
    #expect(groups[0].networkLabel == "2 networks")
    #expect(!groups[1].isGrouped)
    #expect(groups[1].networkLabel == "Ethereum")
    #expect(groups[1].valueDisplay == "$4,346")
    #expect(groups[2].valueDisplay == nil)
    #expect(PortfolioGroup.total(of: groups) == "15345.6789")
    #expect(PortfolioGroup.total(of: groups).flatMap(DecimalValue.usd) == "$15,350")
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
}
