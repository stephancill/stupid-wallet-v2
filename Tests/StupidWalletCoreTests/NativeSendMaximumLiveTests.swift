import Foundation
import Testing

@testable import StupidWalletCore

struct NativeSendMaximumLiveTests {
  @Test(
    "native maximum previews reserve fees on Ethereum, Base, Optimism and Arbitrum",
    .enabled(if: ProcessInfo.processInfo.environment["SEND_MAXIMUM_LIVE_TESTS"] == "1"),
    arguments: ["1", "8453", "10", "42161"])
  func publicReadOnlyPreview(chainID: String) async throws {
    // Public burn address, read-only simulation; no signing or broadcast.
    let account = "0x000000000000000000000000000000000000dead"
    let recipient = "0x2222222222222222222222222222222222222222"
    let cap = try #require(TokenTransfer.rawUnits(fromDecimal: "0.01", decimals: 18))
    let resolver = RPCResolver()
    let amount = try await NativeSendMaximum(resolver: resolver).amount(
      account: account, chainID: chainID, to: recipient, balanceCap: cap)
    #expect(amount.contains { $0 != 0 })
    #expect(NativeBalanceService.isGreater(cap, than: amount))
    let value = try #require(Hex.quantity(amount))
    let simulated = try await RPCClient().call(
      url: resolver.resolve(chainID: chainID), method: "eth_estimateGas",
      params: .array([
        .object(["from": .string(account), "to": .string(recipient), "value": .string(value)])
      ]))
    guard case .result(.string(let gas)) = simulated else {
      Issue.record("The node refused the fee-reserved value")
      return
    }
    #expect(Hex.quantityData(hex: gas)?.contains { $0 != 0 } == true)
  }
}
