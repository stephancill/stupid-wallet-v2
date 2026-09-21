import Foundation
import Testing

@testable import StupidWalletCore

@Suite(.serialized)
struct TokenTransferTests {
  @Test("transfer calldata uses the standard selector with a padded address and amount")
  func transferCalldata() throws {
    #expect(TokenTransfer.transferSelector == "0xa9059cbb")
    let recipient = "0x00000000000000000000000000000000000000Bb"
    let calldata = try TokenTransfer.transferCalldata(to: recipient, rawAmount: [0x01])
    #expect(calldata.hasPrefix("0xa9059cbb"))
    #expect(calldata.count == 10 + 64 + 64)
    #expect(
      calldata
        == "0xa9059cbb"
        + String(repeating: "0", count: 24) + "00000000000000000000000000000000000000bb"
        + String(repeating: "0", count: 62) + "01")
  }

  @Test("transfer calldata rejects a malformed recipient and an oversized amount")
  func transferCalldataRejections() {
    #expect(throws: TokenTransferError.invalidRecipient) {
      _ = try TokenTransfer.transferCalldata(to: "0x1234", rawAmount: [1])
    }
    #expect(throws: TokenTransferError.amountTooLarge) {
      _ = try TokenTransfer.transferCalldata(
        to: "0x0000000000000000000000000000000000000001",
        rawAmount: [UInt8](repeating: 1, count: 33))
    }
  }

  @Test("display amounts convert to raw base units without floating point")
  func rawUnits() {
    #expect(TokenTransfer.rawUnits(fromDecimal: "1.5", decimals: 6) == [0x16, 0xe3, 0x60])
    #expect(TokenTransfer.rawUnits(fromDecimal: "0.000001", decimals: 6) == [1])
    // 10^18 wei = 0x0DE0B6B3A7640000.
    #expect(
      TokenTransfer.rawUnits(fromDecimal: "1", decimals: 18) == [
        0x0d, 0xe0, 0xb6, 0xb3, 0xa7, 0x64, 0x00, 0x00,
      ])
    #expect(TokenTransfer.rawUnits(fromDecimal: "0", decimals: 6) == [0])
    // More precision than the asset supports fails loudly rather than truncating.
    #expect(TokenTransfer.rawUnits(fromDecimal: "1.0000001", decimals: 6) == nil)
    #expect(TokenTransfer.rawUnits(fromDecimal: "abc", decimals: 6) == nil)
    #expect(TokenTransfer.rawUnits(fromDecimal: "", decimals: 6) == nil)
    #expect(TokenTransfer.rawUnits(fromDecimal: "-1", decimals: 6) == nil)
  }

  @Test("quantities are canonical minimal hex")
  func quantities() {
    #expect(Hex.quantity([0]) == "0x0")
    #expect(Hex.quantity([0x00, 0x01]) == "0x1")
    #expect(Hex.quantity([0x01, 0x00]) == "0x100")
    #expect(Hex.quantity([0xff, 0xff]) == "0xffff")
    #expect(Hex.quantity([UInt8](repeating: 1, count: 33)) == nil)
  }
}
