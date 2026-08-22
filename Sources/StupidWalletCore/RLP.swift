import Foundation

/// Recursive Length Prefix encoding (the Ethereum byte serializer).
public enum RLP {
  public enum Item: Sendable {
    case string([UInt8])
    case list([Item])
  }

  public static func encode(_ item: Item) -> [UInt8] {
    switch item {
    case .string(let bytes):
      return encodeString(bytes)
    case .list(let items):
      let payload = items.flatMap(encode)
      return encodeWithLength(payload, is: 0xC0)
    }
  }

  /// Encodes a 0x-prefixed hex quantity (integer) per the canonical RLP rule: strip
  /// leading zero bytes, empty becomes a single 0x00, high bit sets the 0x80 prefix.
  public static func encodeQuantity(hex: String) -> [UInt8]? {
    guard var bytes = Hex.data(hex) else { return nil }
    while bytes.first == 0 { bytes.removeFirst() }
    if bytes.isEmpty { return [0x00] }
    return encodeString(bytes)
  }

  private static func encodeString(_ raw: [UInt8]) -> [UInt8] {
    guard !raw.isEmpty else { return [0x80] }
    guard raw.count == 1, raw[0] < 0x80 else {
      return encodeWithLength(raw, is: 0x80)
    }
    return raw
  }

  /// Encodes `payload` with a length prefix. `is` is 0x80 for a string, 0xC0 for a list.
  private static func encodeWithLength(_ payload: [UInt8], is marker: UInt8) -> [UInt8] {
    if payload.count < 56 {
      return [marker + UInt8(payload.count)] + payload
    }
    let lengthOfLength = minimalBytesLength(payload.count)
    let lenBytes = bigEndianBytesOf(payload.count, count: lengthOfLength)
    let offset = marker + 55 + UInt8(lengthOfLength)
    return [offset] + lenBytes + payload
  }

  private static func minimalBytesLength(_ value: Int) -> Int {
    var v = value
    var count = 1
    while v >= 256 {
      v >>= 8
      count += 1
    }
    return count
  }

  private static func bigEndianBytesOf(_ value: Int, count: Int) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: count)
    var v = value
    var i = count - 1
    while i >= 0 {
      result[i] = UInt8(v & 0xFF)
      v >>= 8
      i -= 1
    }
    return result
  }
}
