import Foundation

public enum EIP5792Error: Error, Sendable, Equatable {
  case invalidParams
  case unsupportedCapability(String)
  case unsupportedChain
  case duplicateID
  case bundleTooLarge
}

public enum EIP5792 {
  public static let simple7702Account = "0xe6Cae83BdE06E4c305530e199D7217f42808555B"
  public static let simple7702AccountRuntimeHash =
    "0xcc7b633aef4b2543cb8f37522adf1a401f910f0f6b2430c1eecc11f401ccfcf3"
  public static let verifiedChains: Set<String> = ["1", "8453", "42161"]
  public static let maximumCalls = 32

  public static func isVerifiedImplementation(
    _ code: [UInt8], expectedRuntimeHash: String = simple7702AccountRuntimeHash
  ) -> Bool {
    !code.isEmpty
      && ("0x" + Hex.encode(Keccak.keccak256(code))).caseInsensitiveCompare(expectedRuntimeHash)
        == .orderedSame
  }

  public struct Prepared: Sendable, Equatable {
    public let params: JSONValue
    public let isV2: Bool
    public let requestedID: String?
    public let calldata: String
  }

  public static func prepare(
    params: JSONValue, account: String, activeChainID: String
  ) throws -> Prepared {
    guard case .array(let values) = params, values.count == 1,
      case .object(let supplied) = values[0]
    else { throw EIP5792Error.invalidParams }

    let supportedFields: Set<String> = [
      "version", "account", "from", "chainId", "calls", "atomicRequired", "id",
      "capabilities",
    ]
    guard supplied.keys.allSatisfy(supportedFields.contains) else {
      throw EIP5792Error.invalidParams
    }

    let version: String
    switch supplied["version"] {
    case nil: version = "1.0"
    case .string(let value) where ["1", "1.0", "1.0.0"].contains(value): version = "1.0"
    case .number(let value) where value == 1: version = "1.0"
    case .string("2.0.0"): version = "2.0.0"
    default: throw EIP5792Error.invalidParams
    }
    let isV2 = version == "2.0.0"

    guard !isV2 || supplied["account"] == nil else { throw EIP5792Error.invalidParams }

    for field in ["account", "from"] where supplied[field] != nil {
      guard let suppliedAccount = supplied[field]?.stringValue,
        suppliedAccount.caseInsensitiveCompare(account) == .orderedSame
      else { throw EIP5792Error.invalidParams }
    }
    let chainID: String
    if let suppliedChainID = supplied["chainId"]?.stringValue {
      guard isCanonicalQuantity(suppliedChainID),
        ChainStore.normalize(suppliedChainID) == activeChainID
      else { throw EIP5792Error.invalidParams }
      chainID = suppliedChainID.lowercased()
    } else {
      guard !isV2, let activeQuantity = ChainStore.hexChainID(activeChainID) else {
        throw EIP5792Error.invalidParams
      }
      chainID = activeQuantity
    }
    guard verifiedChains.contains(activeChainID) else { throw EIP5792Error.unsupportedChain }

    let atomicRequired: Bool
    if let value = supplied["atomicRequired"] {
      guard case .bool(let required) = value else { throw EIP5792Error.invalidParams }
      atomicRequired = required
    } else {
      guard !isV2 else { throw EIP5792Error.invalidParams }
      atomicRequired = legacyAtomicRequired(supplied["capabilities"]) ?? true
    }
    try validateCapabilities(supplied["capabilities"])

    let requestedID: String?
    if let id = supplied["id"]?.stringValue {
      guard isValidID(id) else { throw EIP5792Error.invalidParams }
      requestedID = id
    } else if supplied["id"] != nil {
      throw EIP5792Error.invalidParams
    } else {
      requestedID = nil
    }

    guard case .array(let suppliedCalls) = supplied["calls"], !suppliedCalls.isEmpty else {
      throw EIP5792Error.invalidParams
    }
    guard suppliedCalls.count <= maximumCalls else { throw EIP5792Error.bundleTooLarge }

    var calls: [JSONValue] = []
    calls.reserveCapacity(suppliedCalls.count)
    for suppliedCall in suppliedCalls {
      guard case .object(let call) = suppliedCall,
        call.keys.allSatisfy(Set(["to", "value", "data"]).contains),
        let to = call["to"]?.stringValue, Hex.data(to)?.count == 20
      else { throw EIP5792Error.invalidParams }
      let value = call["value"]?.stringValue ?? "0x0"
      let data = call["data"]?.stringValue ?? "0x"
      guard isCanonicalQuantity(value), isCanonicalData(data) else {
        throw EIP5792Error.invalidParams
      }
      calls.append(
        .object([
          "to": .string(to), "value": .string(value.lowercased()),
          "data": .string(data.lowercased()),
        ]))
    }

    var canonical: [String: JSONValue] = [
      "version": .string(version), "from": .string(account), "chainId": .string(chainID),
      "calls": .array(calls), "atomicRequired": .bool(atomicRequired),
    ]
    if let requestedID { canonical["id"] = .string(requestedID) }
    if let capabilities = supplied["capabilities"] { canonical["capabilities"] = capabilities }
    let canonicalParams = JSONValue.object(canonical)
    return Prepared(
      params: canonicalParams, isV2: isV2, requestedID: requestedID,
      calldata: try executeBatchCalldata(canonicalParams))
  }

  public static func validatePersisted(
    params: JSONValue, account: String, chainID: String
  ) -> Bool {
    guard case .object(let object) = params,
      let chainQuantity = object["chainId"]?.stringValue,
      ChainStore.normalize(chainQuantity) == chainID
    else { return false }
    do {
      let prepared = try prepare(
        params: .array([params]), account: account, activeChainID: chainID)
      return prepared.params == params
    } catch {
      return false
    }
  }

  public static func executeBatchCalldata(_ params: JSONValue) throws -> String {
    guard case .object(let object) = params, case .array(let calls) = object["calls"] else {
      throw EIP5792Error.invalidParams
    }
    struct EncodedCall {
      let head: [UInt8]
      let tail: [UInt8]
    }
    let encoded: [EncodedCall] = try calls.map { value in
      guard case .object(let call) = value,
        let to = call["to"]?.stringValue.flatMap(Hex.data), to.count == 20,
        let quantity = call["value"]?.stringValue.flatMap(quantityBytes),
        let data = call["data"]?.stringValue.flatMap(Hex.data)
      else { throw EIP5792Error.invalidParams }
      let head = leftPad(to, to: 32) + leftPad(quantity, to: 32) + word(96)
      let padding = [UInt8](repeating: 0, count: (32 - data.count % 32) % 32)
      return EncodedCall(head: head, tail: word(data.count) + data + padding)
    }

    var array = word(encoded.count)
    var offset = 32 * encoded.count
    for call in encoded {
      array += word(offset)
      offset += call.head.count + call.tail.count
    }
    for call in encoded { array += call.head + call.tail }
    let bytes: [UInt8] = [0x34, 0xfc, 0xd5, 0xbe] + word(32) + array
    return "0x" + Hex.encode(bytes)
  }

  public static func isCanonicalQuantity(_ value: String) -> Bool {
    guard value.hasPrefix("0x") else { return false }
    let digits = value.dropFirst(2)
    return !digits.isEmpty && digits.allSatisfy(\.isHexDigit) && digits.count <= 64
      && (digits == "0" || digits.first != "0")
  }

  public static func isCanonicalData(_ value: String) -> Bool {
    value.hasPrefix("0x") && value.dropFirst(2).count.isMultiple(of: 2)
      && value.dropFirst(2).allSatisfy(\.isHexDigit)
  }

  public static func uint64Quantity(_ value: String) -> UInt64? {
    guard isCanonicalQuantity(value) else { return nil }
    return UInt64(value.dropFirst(2), radix: 16)
  }

  public static func adding(_ amount: UInt64, to quantity: String) -> String? {
    guard let value = uint64Quantity(quantity), value <= UInt64.max - amount else { return nil }
    return "0x" + String(value + amount, radix: 16)
  }

  private static func validateCapabilities(_ value: JSONValue?) throws {
    guard let value else { return }
    guard case .object(let capabilities) = value else { throw EIP5792Error.invalidParams }
    for (name, capability) in capabilities {
      guard case .object(let fields) = capability else { throw EIP5792Error.invalidParams }
      if let optional = fields["optional"], case .bool = optional {
      } else if fields["optional"] != nil {
        throw EIP5792Error.invalidParams
      }
      if name == "atomic" { continue }
      guard fields["optional"] == .bool(true) else {
        throw EIP5792Error.unsupportedCapability(name)
      }
    }
  }

  private static func legacyAtomicRequired(_ value: JSONValue?) -> Bool? {
    guard case .object(let capabilities)? = value,
      case .object(let atomic)? = capabilities["atomic"],
      case .bool(let required)? = atomic["required"]
    else { return nil }
    return required
  }

  public static func isValidID(_ id: String) -> Bool {
    guard id.hasPrefix("0x"), id.count > 2, let bytes = Hex.data(id) else { return false }
    return bytes.count <= 4_096
  }

  private static func quantityBytes(_ value: String) -> [UInt8]? {
    guard isCanonicalQuantity(value) else { return nil }
    return Hex.quantityData(hex: value)
  }

  private static func leftPad(_ bytes: [UInt8], to count: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: max(0, count - bytes.count)) + bytes
  }

  private static func word(_ value: Int) -> [UInt8] {
    var value = UInt64(value)
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in stride(from: 31, through: 24, by: -1) {
      bytes[index] = UInt8(value & 0xff)
      value >>= 8
    }
    return bytes
  }
}
