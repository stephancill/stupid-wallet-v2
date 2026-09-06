import Foundation

/// A named component of a Solidity function parameter/return (ABI) list. Names are used
/// for ERC-7730 path resolution; the type drives decoding and selector computation.
public struct ABIArgument: Equatable, Sendable {
  public let name: String
  public let type: ABIType

  public init(name: String, type: ABIType) {
    self.name = name
    self.type = type
  }
}

/// A Solidity (ABI/calldata) type. Enumeration values only; the `tuple` case carries named
/// members, which is how paths like `order.amount` are addressed.
public indirect enum ABIType: Equatable, Sendable {
  case uint(Int)  // bits; 256 is canonical but widths are preserved
  case int(Int)
  case address
  case bool
  case fixedBytes(Int)  // bytesN
  case bytes
  case string
  case array(ABIType)  // dynamic T[]
  case fixedArray(ABIType, Int)  // T[N]
  case tuple([ABIArgument])

  /// Whether this type is dynamically encoded (its ABI slot holds an offset word).
  public var isDynamic: Bool {
    switch self {
    case .uint, .int, .address, .bool, .fixedBytes: return false
    case .bytes, .string, .array: return true
    case .fixedArray(let element, _): return element.isDynamic
    case .tuple(let components): return components.contains { $0.type.isDynamic }
    }
  }

  /// Encoded width in bytes when the type is static. Only called for static types.
  var staticSize: Int {
    switch self {
    case .uint, .int, .address, .bool, .fixedBytes: return 32
    case .bytes, .string, .array:
      assertionFailure("staticSize() called on a dynamic type")
      return 0
    case .fixedArray(let element, let count): return count * element.staticSize
    case .tuple(let components): return components.reduce(0) { $0 + $1.type.staticSize }
    }
  }

  /// Canonical type name used to build a type-only signature for selector hashing.
  var canonicalName: String {
    switch self {
    case .uint(let bits): return "uint\(bits)"
    case .int(let bits): return "int\(bits)"
    case .address: return "address"
    case .bool: return "bool"
    case .fixedBytes(let n): return "bytes\(n)"
    case .bytes: return "bytes"
    case .string: return "string"
    case .array(let element): return element.canonicalName + "[]"
    case .fixedArray(let element, let count): return element.canonicalName + "[\(count)]"
    case .tuple(let components):
      return "(" + components.map { $0.type.canonicalName }.joined(separator: ",") + ")"
    }
  }
}

/// A decoded calldata argument value. Integer words keep their raw 32-byte big-endian bytes so
/// amounts can be scaled/formatted without any BigInt dependency; tuples decode to ordered fields.
public enum ABIValue: Equatable, Sendable {
  case uint256([UInt8])
  case int([UInt8])
  case address(String)  // lowercase 0x + 40
  case bool(Bool)
  case bytes([UInt8])
  case string(String)
  case array([ABIValue])
  case object([String: ABIValue])

  public var isObject: Bool {
    if case .object = self { return true }
    return false
  }

  /// 0x-prefixed hex rendering (integers render their trimmed value, not the padded word).
  public var hexDisplay: String {
    switch self {
    case .uint256(let bytes): return "0x" + Hex.encode(Array(ABI.trimLeadingZeros(bytes)))
    case .int(let bytes): return "0x" + Hex.encode(Array(ABI.trimLeadingZeros(bytes)))
    case .address(let address): return address
    case .bool(let value): return value ? "true" : "false"
    case .bytes(let bytes): return "0x" + Hex.encode(bytes)
    case .string(let value): return value
    case .array: return ""
    case .object: return ""
    }
  }

  /// Decimal rendering of an unsigned integer word (empty for non-integers).
  public var decimalString: String {
    switch self {
    case .uint256(let bytes): return ABI.decimal(from: bytes)
    case .int(let bytes): return ABI.decimal(from: bytes)
    default: return ""
    }
  }

  /// Human-friendly plain text used for generic display and interpolation.
  public var displayString: String {
    switch self {
    case .string(let value): return value
    case .bool(let value): return value ? "Yes" : "No"
    case .address, .uint256, .int, .bytes: return hexDisplay
    case .array(let values): return values.map(\.displayString).joined(separator: ", ")
    case .object(let fields):
      return fields.sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value.displayString)" }.joined(separator: "\n")
    }
  }
}

/// Error type for signature parsing / calldata decoding failures.
public enum ABIError: Error, Sendable, Equatable {
  case invalidSignature
  case invalid
}

/// Parses human-readable Solidity function signatures such as
/// `transfer(address to,uint256 value)` or
/// `submitOrder((address token,uint256 amount) order,bytes32 salt)`, computes selectors, and
/// decodes calldata.
public enum ABI {
  /// Parses a human-readable function signature into its name and typed parameters. Names may
  /// be absent (type-only `transfer(address,uint256)`) or spaced after the type.
  public static func parse(signature: String) throws -> (name: String, arguments: [ABIArgument]) {
    var scanner = SignatureScanner(signature)
    guard let name = scanner.readIdentifier() else { throw ABIError.invalidSignature }
    guard scanner.consumeIf("(") else { throw ABIError.invalidSignature }
    let arguments = try scanner.parseParamList(untilClose: true)
    return (name, arguments)
  }

  /// The 4-byte function selector for a parsed function's type-only signature.
  public static func selector(name: String, arguments: [ABIArgument]) -> String {
    let types = arguments.map { $0.type.canonicalName }.joined(separator: ",")
    let digest = Keccak.keccak256(Array("\(name)(\(types))".utf8))
    return "0x" + Hex.encode(Array(digest.prefix(4)))
  }

  /// Decodes calldata (optionally including its leading selector) against `arguments`.
  /// Returns nil on malformed data so callers can fall back to raw calldata.
  public static func decode(
    arguments: [ABIArgument], calldataHex: String
  ) -> [String: ABIValue]? {
    guard let raw = Hex.data(calldataHex) else { return nil }
    let data = raw.count >= 4 ? Array(raw.dropFirst(4)) : Array(raw)
    return decode(arguments: arguments, data: data)
  }

  /// Decodes a raw argument byte region (selector already stripped) against `arguments`.
  public static func decode(arguments: [ABIArgument], data: [UInt8]) -> [String: ABIValue]? {
    guard !arguments.isEmpty else { return [:] }
    var result: [String: ABIValue] = [:]
    var head: Int = 0
    for argument in arguments {
      if argument.type.isDynamic {
        guard let content = relativeOffset(data, slot: head, base: 0),
          let value = decodeTail(argument.type, data: data, base: content)
        else { return nil }
        result[argument.name] = value
        head += 32
      } else {
        guard let value = decodeTail(argument.type, data: data, base: head) else { return nil }
        result[argument.name] = value
        head += argument.type.staticSize
      }
    }
    return result
  }

  // MARK: - Value decoding

  /// Decodes a value whose *content* begins at `base` in `data` (i.e. dynamic types here are
  /// already past their offset slot — this is the tail decode).
  private static func decodeTail(_ type: ABIType, data: [UInt8], base: Int) -> ABIValue? {
    switch type {
    case .uint:
      guard let value = word(data, base) else { return nil }
      return .uint256(value)
    case .int:
      guard let value = word(data, base) else { return nil }
      return .int(value)
    case .address:
      guard data.count >= base + 32 else { return nil }
      return .address("0x" + Hex.encode(Array(data[(base + 12)..<(base + 32)])))
    case .bool:
      guard data.count >= base + 32 else { return nil }
      return .bool(data[base + 31] != 0)
    case .fixedBytes(let count):
      guard count <= 32, data.count >= base + 32 else { return nil }
      return .bytes(Array(data[base..<(base + count)]))
    case .bytes:
      guard base + 32 <= data.count else { return nil }
      let length = Int(readWord(data, at: base))
      guard length >= 0, base + 32 + length <= data.count else { return nil }
      return .bytes(Array(data[(base + 32)..<(base + 32 + length)]))
    case .string:
      guard base + 32 <= data.count else { return nil }
      let length = Int(readWord(data, at: base))
      guard length >= 0, base + 32 + length <= data.count else { return nil }
      let bytes = Data(data[(base + 32)..<(base + 32 + length)])
      return .string(String(data: bytes, encoding: .utf8) ?? "")
    case .array(let element):
      return .array(decodeArrayTail(element, data: data, base: base) ?? [])
    case .fixedArray(let element, let count):
      return .array(decodeFixedArrayTail(element, count: count, data: data, base: base) ?? [])
    case .tuple(let components):
      return decodeTupleTail(components, data: data, base: base)
    }
  }

  private static func decodeTupleTail(
    _ components: [ABIArgument], data: [UInt8], base: Int
  ) -> ABIValue? {
    var object: [String: ABIValue] = [:]
    var head = base
    for component in components {
      if component.type.isDynamic {
        // The slot holds an offset relative to this tuple's start.
        guard let content = relativeOffset(data, slot: head, base: base),
          let value = decodeTail(component.type, data: data, base: content)
        else { return nil }
        object[component.name] = value
        head += 32
      } else {
        guard let value = decodeTail(component.type, data: data, base: head) else { return nil }
        object[component.name] = value
        head += component.type.staticSize
      }
    }
    return .object(object)
  }

  private static func decodeArrayTail(
    _ elementType: ABIType, data: [UInt8], base: Int
  ) -> [ABIValue]? {
    guard base + 32 <= data.count else { return nil }
    let count = Int(readWord(data, at: base))
    if count == 0 { return [] }
    guard count >= 0 else { return nil }
    var values: [ABIValue] = []
    if elementType.isDynamic {
      guard base + 32 + count * 32 <= data.count else { return nil }
      for index in 0..<count {
        // Each slot holds an offset relative to this array's start (the length word base).
        guard let content = relativeOffset(data, slot: base + 32 + index * 32, base: base),
          let value = decodeTail(elementType, data: data, base: content)
        else { return nil }
        values.append(value)
      }
    } else {
      for index in 0..<count {
        let slot = base + 32 + index * elementType.staticSize
        guard let value = decodeTail(elementType, data: data, base: slot) else { return nil }
        values.append(value)
      }
    }
    return values
  }

  private static func decodeFixedArrayTail(
    _ elementType: ABIType, count: Int, data: [UInt8], base: Int
  ) -> [ABIValue]? {
    var values: [ABIValue] = []
    for index in 0..<count {
      let slot = base + index * elementType.staticSize
      guard let value = decodeTail(elementType, data: data, base: slot) else { return nil }
      values.append(value)
    }
    return values
  }

  private static func word(_ data: [UInt8], _ base: Int) -> [UInt8]? {
    guard base >= 0, base + 32 <= data.count else { return nil }
    return Array(data[base..<(base + 32)])
  }

  /// Resolves a dynamic slot at `slot` whose integer value is an offset measured from `base`.
  private static func relativeOffset(_ data: [UInt8], slot: Int, base: Int) -> Int? {
    guard slot >= 0, slot + 32 <= data.count else { return nil }
    let raw = readWord(data, at: slot)
    guard raw <= UInt64(Int.max) else { return nil }
    let resolved = base + Int(raw)
    guard resolved >= 0, resolved <= data.count else { return nil }
    return resolved
  }

  private static func readWord(_ data: [UInt8], at base: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in data[base..<(base + min(32, data.count - base))] {
      value = (value << 8) | UInt64(byte)
    }
    return value
  }

  // MARK: - Helpers

  static func trimLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
    var out = Array(bytes.drop(while: { $0 == 0 }))
    if out.isEmpty { out = [0] }
    return out
  }

  /// Big-endian word -> unsigned decimal string.
  static func decimal(from bytes: [UInt8]) -> String {
    var digits = [0]
    for byte in bytes {
      var carry = Int(byte)
      for index in digits.indices {
        let value = digits[index] * 256 + carry
        digits[index] = value % 10
        carry = value / 10
      }
      while carry > 0 {
        digits.append(carry % 10)
        carry /= 10
      }
    }
    var out = digits.reversed().map(String.init).joined()
    while out.count > 1, out.first == "0" { out.removeFirst() }
    return out
  }
}

/// Parses human-readable Solidity type signatures (`function name(address to,uint256 value)`).
private struct SignatureScanner {
  let chars: [Character]
  var index = 0

  init(_ text: String) {
    self.chars = Array(text)
  }

  var isAtEnd: Bool { index >= chars.count }

  mutating func skipWhitespace() {
    while let char = peek(), char == " " || char == "\t" || char == "\n" { index += 1 }
  }

  private func isIdentifierChar(_ char: Character) -> Bool {
    char.isLetter || char.isNumber || char == "_"
  }

  mutating func readIdentifier() -> String? {
    skipWhitespace()
    var out = ""
    while let char = peek(), isIdentifierChar(char) {
      out.append(char)
      index += 1
    }
    return out.isEmpty ? nil : out
  }

  mutating func consumeIf(_ character: Character) -> Bool {
    skipWhitespace()
    guard peek() == character else { return false }
    index += 1
    return true
  }

  private func peek() -> Character? {
    index < chars.count ? chars[index] : nil
  }

  /// Parses a comma-separated parameter list until `)`, consuming that `)` when `untilClose`.
  mutating func parseParamList(untilClose: Bool) throws -> [ABIArgument] {
    var result: [ABIArgument] = []
    skipWhitespace()
    while !isAtEnd {
      if peek() == ")" { break }
      result.append(try parseParam())
      skipWhitespace()
      if peek() == "," {
        index += 1
        continue
      }
      break
    }
    skipWhitespace()
    if untilClose {
      guard peek() == ")" else { throw ABIError.invalidSignature }
      index += 1
    }
    return result
  }

  /// Parses one parameter: an elementary type or a parenthesised tuple, then array suffixes,
  /// then an optional name.
  mutating func parseParam() throws -> ABIArgument {
    skipWhitespace()
    var type: ABIType
    if peek() == "(" {
      type = try parseTupleType()
    } else if let name = readIdentifier(),
      (try? ABIType.base(name)) != nil
    {
      type = try ABIType.base(name)
    } else {
      throw ABIError.invalidSignature
    }

    while peek() == "[" {
      index += 1
      var count = ""
      while let char = peek(), char != "]" {
        count.append(char)
        index += 1
      }
      guard peek() == "]" else { throw ABIError.invalidSignature }
      index += 1
      if count.isEmpty {
        type = .array(type)
      } else if let n = Int(count), n > 0 {
        type = .fixedArray(type, n)
      } else {
        throw ABIError.invalidSignature
      }
    }

    skipWhitespace()
    let name = readParameterName()
    return ABIArgument(name: name, type: type)
  }

  mutating func parseTupleType() throws -> ABIType {
    skipWhitespace()
    guard peek() == "(" else { throw ABIError.invalidSignature }
    index += 1
    let components = try parseParamList(untilClose: true)
    return .tuple(components)
  }

  /// Reads an optional parameter name.
  mutating func readParameterName() -> String {
    skipWhitespace()
    guard let char = peek(), isIdentifierChar(char) else { return "" }
    return readIdentifier() ?? ""
  }
}

extension ABIType {
  /// Constructs an elementary type from its identifier (`uint256`, `address`, `bytes32`, ...).
  static func base(_ identifier: String) throws -> ABIType {
    switch identifier {
    case "address": return .address
    case "bool": return .bool
    case "bytes": return .bytes
    case "string": return .string
    default:
      if identifier.hasPrefix("uint") {
        let bits = Int(identifier.dropFirst(4)) ?? 256
        guard bits >= 8, bits <= 256, bits % 8 == 0 else { throw ABIError.invalidSignature }
        return .uint(bits)
      }
      if identifier.hasPrefix("int") {
        let bits = Int(identifier.dropFirst(3)) ?? 256
        guard bits >= 8, bits <= 256, bits % 8 == 0 else { throw ABIError.invalidSignature }
        return .int(bits)
      }
      if identifier.hasPrefix("bytes") {
        guard let n = Int(identifier.dropFirst(5)), (1...32).contains(n) else {
          throw ABIError.invalidSignature
        }
        return .fixedBytes(n)
      }
      throw ABIError.invalidSignature
    }
  }
}
