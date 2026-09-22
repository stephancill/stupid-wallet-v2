import Foundation
import Testing

@testable import StupidWalletCore

struct SendTransferTests {
  private let recipient = "0x00000000000000000000000000000000000000bb"
  private let token = "0x00000000000000000000000000000000000000aa"

  @Test("a native send targets the recipient with the amount in value and no calldata")
  func nativeTargetsRecipient() throws {
    let transfer = try SendTransfer.native(recipient: recipient, rawAmount: [0x0f, 0x42, 0x40])
    #expect(transfer.to == recipient)
    #expect(transfer.value == "0xf4240")
    #expect(transfer.data == "0x")
  }

  @Test("an ERC-20 send targets the token contract and encodes the recipient in calldata")
  func erc20TargetsTokenContract() throws {
    let transfer = try SendTransfer.erc20(
      token: token, recipient: recipient, rawAmount: [0x0f, 0x42, 0x40])
    // Regression: the transaction target must be the token contract, never the recipient. Sending
    // transfer calldata to the recipient is a no-op that still costs gas.
    #expect(transfer.to == token)
    #expect(transfer.to != recipient)
    #expect(transfer.value == "0x0")
    #expect(
      transfer.data
        == (try TokenTransfer.transferCalldata(to: recipient, rawAmount: [0x0f, 0x42, 0x40])))
  }

  @Test("an ERC-20 send normalizes the token contract address")
  func erc20NormalizesToken() throws {
    let checksummed = "0x00000000000000000000000000000000000000AA"
    let transfer = try SendTransfer.erc20(
      token: checksummed, recipient: recipient, rawAmount: [1])
    #expect(transfer.to == token)
  }

  @Test("an invalid recipient is rejected")
  func rejectsInvalidRecipient() {
    #expect(throws: TokenTransferError.invalidRecipient) {
      _ = try SendTransfer.native(recipient: "0x1234", rawAmount: [1])
    }
    #expect(throws: TokenTransferError.invalidRecipient) {
      _ = try SendTransfer.erc20(token: token, recipient: "not-an-address", rawAmount: [1])
    }
  }

  @Test("an invalid token contract is rejected")
  func rejectsInvalidToken() {
    #expect(throws: TokenTransferError.invalidRecipient) {
      _ = try SendTransfer.erc20(token: "0xdeadbeef", recipient: recipient, rawAmount: [1])
    }
  }

  @Test("a native amount that overflows a 256-bit word is rejected")
  func rejectsOversizedNativeAmount() {
    #expect(throws: TokenTransferError.amountTooLarge) {
      _ = try SendTransfer.native(recipient: recipient, rawAmount: [UInt8](repeating: 1, count: 33))
    }
  }
}
