public enum EIP7702Error: Error, Equatable, Sendable {
  case invalidQuantity(String)
  case invalidDelegate
  case invalidDestination
  case invalidData
  case invalidSignature
  case emptyAuthorizationList
}

/// The unsigned fields covered by an EIP-7702 authorization signature.
public struct EIP7702Authorization: Equatable, Sendable {
  /// Minimal big-endian chain ID bytes. An empty value represents chain ID zero.
  public let chainID: [UInt8]
  public let delegate: [UInt8]
  public let nonce: UInt64

  public init(chainID: String, delegate: String, nonce: UInt64) throws {
    self.chainID = try EIP7702Encoding.quantity(chainID, field: "chainID", allowZero: true)
    guard let delegate = EIP7702Encoding.data(delegate), delegate.count == 20 else {
      throw EIP7702Error.invalidDelegate
    }
    self.delegate = delegate
    self.nonce = nonce
  }

  /// `keccak256(0x05 || RLP([chain_id, address, nonce]))`.
  public func digest() -> [UInt8] {
    Keccak.keccak256([0x05] + RLP.encode(unsignedRLP))
  }

  /// Converts the core signer's `r || s || (27/28)` output to an EIP-7702 tuple.
  public func signed(signature: [UInt8]) throws -> EIP7702SignedAuthorization {
    guard signature.count == 65, signature[64] == 27 || signature[64] == 28 else {
      throw EIP7702Error.invalidSignature
    }
    return EIP7702SignedAuthorization(
      authorization: self,
      yParity: signature[64] - 27,
      r: EIP7702Encoding.trimQuantity(Array(signature[0..<32])),
      s: EIP7702Encoding.trimQuantity(Array(signature[32..<64]))
    )
  }

  fileprivate var unsignedRLP: RLP.Item {
    .list([
      .string(chainID),
      .string(delegate),
      .string(EIP7702Encoding.uint64Bytes(nonce)),
    ])
  }
}

/// A complete `[chain_id, address, nonce, y_parity, r, s]` authorization tuple.
public struct EIP7702SignedAuthorization: Equatable, Sendable {
  public let authorization: EIP7702Authorization
  public let yParity: UInt8
  /// Minimal big-endian scalar bytes.
  public let r: [UInt8]
  /// Minimal big-endian scalar bytes.
  public let s: [UInt8]

  public var chainID: [UInt8] { authorization.chainID }
  public var delegate: [UInt8] { authorization.delegate }
  public var nonce: UInt64 { authorization.nonce }

  fileprivate var rlp: RLP.Item {
    .list([
      .string(authorization.chainID),
      .string(authorization.delegate),
      .string(EIP7702Encoding.uint64Bytes(authorization.nonce)),
      .string(yParity == 0 ? [] : [yParity]),
      .string(r),
      .string(s),
    ])
  }

  fileprivate init(
    authorization: EIP7702Authorization,
    yParity: UInt8,
    r: [UInt8],
    s: [UInt8]
  ) {
    self.authorization = authorization
    self.yParity = yParity
    self.r = r
    self.s = s
  }
}

/// Exact parser for the 23-byte `0xef0100 || delegate` code designator.
public struct EIP7702DelegationDesignator: Equatable, Sendable {
  public static let prefix: [UInt8] = [0xef, 0x01, 0x00]

  public let delegate: [UInt8]

  public init?(code: [UInt8]) {
    guard code.count == 23, code.starts(with: Self.prefix) else { return nil }
    delegate = Array(code.dropFirst(Self.prefix.count))
  }

  public init?(hex: String) {
    guard let code = EIP7702Encoding.data(hex) else { return nil }
    self.init(code: code)
  }

  public var code: [UInt8] { Self.prefix + delegate }
}

/// EIP-7702 set-code transaction (EIP-2718 type `0x04`). Access lists are intentionally empty.
public struct EIP7702Transaction: Equatable, Sendable {
  public let chainID: [UInt8]
  public let nonce: [UInt8]
  public let maxPriorityFeePerGas: [UInt8]
  public let maxFeePerGas: [UInt8]
  public let gasLimit: [UInt8]
  public let destination: [UInt8]
  public let value: [UInt8]
  public let data: [UInt8]
  public let authorizationList: [EIP7702SignedAuthorization]

  public init(
    chainID: String,
    nonce: String,
    maxPriorityFeePerGas: String,
    maxFeePerGas: String,
    gasLimit: String,
    destination: String?,
    value: String,
    data: String,
    authorizationList: [EIP7702SignedAuthorization]
  ) throws {
    self.chainID = try EIP7702Encoding.quantity(chainID, field: "chainID", allowZero: false)
    self.nonce = try EIP7702Encoding.quantity(nonce, field: "nonce", allowZero: true)
    self.maxPriorityFeePerGas = try EIP7702Encoding.quantity(
      maxPriorityFeePerGas, field: "maxPriorityFeePerGas", allowZero: true)
    self.maxFeePerGas = try EIP7702Encoding.quantity(
      maxFeePerGas, field: "maxFeePerGas", allowZero: true)
    self.gasLimit = try EIP7702Encoding.quantity(gasLimit, field: "gasLimit", allowZero: true)
    self.value = try EIP7702Encoding.quantity(value, field: "value", allowZero: true)

    guard let destination, let destinationBytes = EIP7702Encoding.data(destination),
      destinationBytes.count == 20
    else {
      throw EIP7702Error.invalidDestination
    }
    guard let dataBytes = EIP7702Encoding.data(data) else {
      throw EIP7702Error.invalidData
    }
    guard !authorizationList.isEmpty else {
      throw EIP7702Error.emptyAuthorizationList
    }

    self.destination = destinationBytes
    self.data = dataBytes
    self.authorizationList = authorizationList
  }

  /// `0x04 || RLP([chain_id, nonce, fees, gas, destination, value, data, [], auths])`.
  public func signingPayload() -> [UInt8] {
    [0x04] + RLP.encode(.list(unsignedFields))
  }

  /// `0x04 || RLP([unsigned fields, y_parity, r, s])`.
  public func signedPayload(signature: [UInt8]) throws -> [UInt8] {
    guard signature.count == 65, signature[64] == 27 || signature[64] == 28 else {
      throw EIP7702Error.invalidSignature
    }
    let yParity = signature[64] - 27
    return [0x04]
      + RLP.encode(
        .list(
          unsignedFields + [
            .string(yParity == 0 ? [] : [yParity]),
            .string(EIP7702Encoding.trimQuantity(Array(signature[0..<32]))),
            .string(EIP7702Encoding.trimQuantity(Array(signature[32..<64]))),
          ]))
  }

  private var unsignedFields: [RLP.Item] {
    [
      .string(chainID),
      .string(nonce),
      .string(maxPriorityFeePerGas),
      .string(maxFeePerGas),
      .string(gasLimit),
      .string(destination),
      .string(value),
      .string(data),
      .list([]),
      .list(authorizationList.map(\.rlp)),
    ]
  }
}

private enum EIP7702Encoding {
  /// Parses an EIP-1474 canonical quantity without narrowing through a host integer.
  static func quantity(_ hex: String, field: String, allowZero: Bool) throws -> [UInt8] {
    guard hex.hasPrefix("0x") else { throw EIP7702Error.invalidQuantity(field) }
    let digits = hex.dropFirst(2)
    guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit), digits.count <= 64 else {
      throw EIP7702Error.invalidQuantity(field)
    }
    guard digits == "0" || digits.first != "0" else {
      throw EIP7702Error.invalidQuantity(field)
    }
    if digits == "0" {
      guard allowZero else { throw EIP7702Error.invalidQuantity(field) }
      return []
    }
    guard let bytes = Hex.quantityData(hex: hex), bytes.count <= 32 else {
      throw EIP7702Error.invalidQuantity(field)
    }
    return bytes
  }

  static func data(_ hex: String) -> [UInt8]? {
    guard hex.hasPrefix("0x") else { return nil }
    return Hex.data(hex)
  }

  static func uint64Bytes(_ value: UInt64) -> [UInt8] {
    guard value != 0 else { return [] }
    var value = value
    var bytes: [UInt8] = []
    while value > 0 {
      bytes.insert(UInt8(value & 0xff), at: 0)
      value >>= 8
    }
    return bytes
  }

  static func trimQuantity(_ bytes: [UInt8]) -> [UInt8] {
    Array(bytes.drop(while: { $0 == 0 }))
  }
}
