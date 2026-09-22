import Foundation

/// The canonical onchain fields for one wallet-owned send.
///
/// A native-currency send calls the recipient directly and carries the amount in `value`. An ERC-20
/// send calls `transfer(address,uint256)` on the token contract, so the contract is the transaction
/// target and the recipient travels inside the calldata. Keeping this mapping in the core (rather
/// than at the call site) prevents sending transfer calldata to the recipient address, which is a
/// no-op that still costs gas.
public struct SendTransfer: Sendable, Equatable {
  public let to: String
  public let value: String
  public let data: String

  private init(to: String, value: String, data: String) {
    self.to = to
    self.value = value
    self.data = data
  }

  /// Native currency: the recipient is the target, the amount travels in `value`, and calldata is
  /// empty.
  public static func native(recipient: String, rawAmount: [UInt8]) throws -> SendTransfer {
    guard let quantity = Hex.quantity(rawAmount) else { throw TokenTransferError.amountTooLarge }
    return SendTransfer(to: try normalizeRecipient(recipient), value: quantity, data: "0x")
  }

  /// ERC-20: the token contract is the target, `value` is zero, and the recipient is encoded in the
  /// `transfer` calldata.
  public static func erc20(
    token: String, recipient: String, rawAmount: [UInt8]
  ) throws -> SendTransfer {
    guard let contract = try? WalletToken.normalizeAddress(token) else {
      throw TokenTransferError.invalidRecipient
    }
    let data = try TokenTransfer.transferCalldata(to: recipient, rawAmount: rawAmount)
    return SendTransfer(to: contract, value: "0x0", data: data)
  }

  private static func normalizeRecipient(_ recipient: String) throws -> String {
    guard let address = try? WalletToken.normalizeAddress(recipient) else {
      throw TokenTransferError.invalidRecipient
    }
    return address
  }
}
