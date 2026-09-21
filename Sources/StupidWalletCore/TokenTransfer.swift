import Foundation

public enum TokenTransferError: Error, Sendable, Equatable {
  case invalidAmount
  case amountTooLarge
  case invalidRecipient
}

/// Builds the standard ERC-20 `transfer(address,uint256)` call and converts a display amount into
/// raw base units. Amounts are decimal-string arithmetic; no floating point is involved.
public enum TokenTransfer {
  /// Selector for `transfer(address,uint256)`.
  public static let transferSelector: String = ABI.selector(
    name: "transfer",
    arguments: [
      ABIArgument(name: "to", type: .address),
      ABIArgument(name: "amount", type: .uint(256)),
    ])

  /// Raw base units for a non-negative decimal amount at `decimals`. Rejects malformed input and an
  /// amount with more precision than the asset supports rather than silently truncating it.
  public static func rawUnits(fromDecimal decimal: String, decimals: UInt8) -> [UInt8]? {
    guard let scaled = DecimalValue.multiplyingByPowerOfTen(decimal, Int(decimals)),
      let parts = DecimalValue.parse(scaled),
      parts.fraction.isEmpty
    else { return nil }
    return bytes(fromDecimalDigits: parts.integer)
  }

  /// ERC-20 `transfer` calldata for a recipient and raw amount.
  public static func transferCalldata(to recipient: String, rawAmount: [UInt8]) throws -> String {
    guard let address = try? WalletToken.normalizeAddress(recipient) else {
      throw TokenTransferError.invalidRecipient
    }
    guard rawAmount.count <= 32 else { throw TokenTransferError.amountTooLarge }
    var amountWord = [UInt8](repeating: 0, count: 32)
    let offset = 32 - rawAmount.count
    for (index, byte) in rawAmount.enumerated() { amountWord[offset + index] = byte }
    let addressWord = String(repeating: "0", count: 24) + address.dropFirst(2)
    return transferSelector + addressWord + Hex.encode(amountWord)
  }

  /// Converts a big-endian decimal digit string into a minimal big-endian byte array.
  static func bytes(fromDecimalDigits digits: String) -> [UInt8] {
    var bytes: [UInt8] = [0]
    for character in digits {
      guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { continue }
      var carry = digit
      for index in bytes.indices {
        let value = Int(bytes[index]) * 10 + carry
        bytes[index] = UInt8(value & 0xff)
        carry = value >> 8
      }
      while carry > 0 {
        bytes.append(UInt8(carry & 0xff))
        carry >>= 8
      }
    }
    return Array(bytes.reversed())
  }
}
