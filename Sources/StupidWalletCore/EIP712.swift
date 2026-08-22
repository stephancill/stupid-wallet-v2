import Foundation

/// EIP-712 typed-data hashing: keccak256(0x1901 ‖ domainSeparator ‖ structHash(message)).
/// Supports primitives, fixed/atomic arrays, dynamic bytes/string, and nested structs so
/// the typed-data approval binds to canonical byte hashing.
public enum EIP712 {
  public static func prefixedHash(of params: JSONValue) throws -> [UInt8] {
    guard case .object(let root) = params,
      case .object(let types)? = root["types"],
      case .string(let primaryType)? = root["primaryType"],
      let domain = root["domain"],
      let message = root["message"]
    else { throw ApprovalError.badParams }

    let domainHash = try structHash(type: "EIP712Domain", value: domain, types: types)
    let messageHash = try structHash(type: primaryType, value: message, types: types)
    return Keccak.keccak256([0x19, 0x01] + domainHash + messageHash)
  }

  // MARK: struct hashing

  /// keccak256(keccak256(encodeType(type)) ‖ encodeData(type, value)).
  static func structHash(
    type: String, value: JSONValue, types: [String: JSONValue]
  ) throws -> [UInt8] {
    let typeHash = Keccak.keccak256(Array(try encodeType(type: type, types: types).utf8))
    let data = try encodeData(type: type, value: value, types: types)
    return Keccak.keccak256(typeHash + data)
  }

  static func fields(for type: String, types: [String: JSONValue]) throws -> [(
    name: String, type: String
  )] {
    guard case .array(let entries)? = types[type] else { return [] }
    return try entries.map { entry in
      guard case .object(let o) = entry,
        case .string(let name)? = o["name"],
        case .string(let t)? = o["type"]
      else { throw ApprovalError.badParams }
      return (name, t)
    }
  }

  /// encodeType: "PrimaryType(field1 type1,...)" followed by referenced structs in
  /// alphabetical order, recursively. EIP-712Domain is always referenced by a domain but
  /// is excluded from the sorted dependency tail.
  static func encodeType(type: String, types: [String: JSONValue]) throws -> String {
    let reference = try
      (references(of: type, types: types).filter { $0 != "EIP712Domain" && $0 != type }).sorted()
    var s = try defineType(type, types)
    for ref in reference { s += try defineType(ref, types) }
    return s
  }

  private static func defineType(
    _ type: String, _ types: [String: JSONValue]
  ) throws -> String {
    let fs = try fields(for: type, types: types)
    let inner = fs.map { "\($0.type) \($0.name)" }.joined(separator: ",")
    return "\(type)(\(inner))"
  }

  /// All struct types transitively referenced by `type`, excluding primitives and
  /// EIP-712Domain.
  static func references(of type: String, types: [String: JSONValue]) throws -> Set<String> {
    var discovered: Set<String> = []
    var queue = [type]
    while let current = queue.first {
      queue.removeFirst()
      for (_, ftype) in try fields(for: current, types: types) {
        let base = Self.base(of: ftype)
        guard !Self.isAtomic(base), types[base] != nil else { continue }
        if discovered.insert(base).inserted { queue.append(base) }
      }
    }
    return discovered
  }

  /// encodeData(type, value): concatenation of per-field encodings.
  static func encodeData(
    type: String, value: JSONValue, types: [String: JSONValue]
  ) throws -> [UInt8] {
    var out: [UInt8] = []
    for (name, ftype) in try fields(for: type, types: types) {
      let fieldValue = scalarValue(name, in: value)
      out.append(contentsOf: try encodeField(ftype, fieldValue, types: types))
    }
    return out
  }

  private static func scalarValue(_ name: String, in value: JSONValue) -> JSONValue {
    guard case .object(let o) = value, let member = o[name] else { return .null }
    return member
  }

  static func isAtomic(_ fieldType: String) -> Bool {
    let base = self.base(of: fieldType)
    switch base {
    case "address", "bool", "bytes", "string": return true
    case _ where base.hasPrefix("uint") || base.hasPrefix("int"): return true
    case "bytes1", "bytes2", "bytes4", "bytes8", "bytes16", "bytes32": return true
    default: return false
    }
  }

  /// element type for `foo[]`/`foo[N]`; identity otherwise.
  private static func base(of fieldType: String) -> String {
    if let open = fieldType.firstIndex(of: "[") { return String(fieldType[..<open]) }
    return fieldType
  }

  private static func isArray(_ fieldType: String) -> Bool {
    fieldType.hasSuffix("]")
  }

  // MARK: field encoding

  private static func encodeField(
    _ fieldType: String, _ value: JSONValue, types: [String: JSONValue]
  ) throws -> [UInt8] {
    let base = self.base(of: fieldType)
    // Fixed-size or dynamic array: hash each element then keccak of the concatenation.
    if isArray(fieldType) {
      guard case .array(let items) = value else { throw ApprovalError.badParams }
      var concatenated: [UInt8] = []
      for item in items {
        concatenated.append(contentsOf: try encodeField(base, item, types: types))
      }
      return Keccak.keccak256(concatenated)
    }

    switch base {
    case "address":
      guard case .string(let s) = value, let bytes = Hex.data(s), bytes.count == 20 else {
        throw ApprovalError.badParams
      }
      return [UInt8](repeating: 0, count: 12) + bytes
    case "bool":
      guard case .bool(let b) = value else { throw ApprovalError.badParams }
      return uint256(b ? 1 : 0)
    case "bytes":
      guard case .string(let s) = value, let bytes = Hex.data(s) else {
        throw ApprovalError.badParams
      }
      return Keccak.keccak256(bytes)
    case "string":
      guard case .string(let s) = value else { throw ApprovalError.badParams }
      return Keccak.keccak256(Array(s.utf8))
    case _ where base.hasPrefix("bytes"):
      guard case .string(let s) = value, let bytes = Hex.data(s) else {
        throw ApprovalError.badParams
      }
      let tail = base.dropFirst("bytes".count)
      guard let size = Int(tail) ?? Int(tail), size == bytes.count else {
        throw ApprovalError.badParams
      }
      return bytes
    case _ where base.hasPrefix("uint") || base.hasPrefix("int"):
      let bits = Int(base.dropFirst(4)) ?? 256
      guard bits >= 8, bits <= 256, bits.isMultiple(of: 8) else { throw ApprovalError.badParams }
      let integer = try integerValue(value)
      return uint256(integer)
    default:
      // Nested struct: hash the nested struct.
      return try structHash(type: base, value: value, types: types)
    }
  }

  private static func integerValue(_ value: JSONValue) throws -> Int {
    switch value {
    case .string(let s):
      if s.hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) {
        return v
      }
      if let v = Int(s) { return v }
      throw ApprovalError.badParams
    case .number(let n) where n.rounded() == n:
      return Int(n)
    default:
      throw ApprovalError.badParams
    }
  }

  private static func uint256(_ value: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    var v = UInt64(bitPattern: Int64(value))
    for index in stride(from: 31, through: 0, by: -1) where v > 0 {
      out[index] = UInt8(v & 0xFF)
      v >>= 8
    }
    return out
  }
}
