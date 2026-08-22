import Foundation

/// Canonical Ethereum transaction encodings for signing and raw transaction submission.
public enum EncodingError: Error { case badQuantity, badTo, badField }

/// Legacy (pre-1559) transaction with EIP-155 replay protection.
public struct LegacyTransaction: Sendable {
  public let nonce: String
  public let gasPrice: String
  public let gasLimit: String
  public let to: String?
  public let value: String
  public let data: String
  public let chainId: Int

  public init(
    nonce: String, gasPrice: String, gasLimit: String, to: String?, value: String,
    data: String, chainId: Int = 1
  ) {
    self.nonce = nonce
    self.gasPrice = gasPrice
    self.gasLimit = gasLimit
    self.to = to
    self.value = value
    self.data = data
    self.chainId = chainId
  }

  /// Signing payload = RLP(nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0).
  public func signingPayload() throws -> [UInt8] {
    let fields = try rlpFields()
    return RLP.encode(.list(fields))
  }

  /// Signed EIP-155 transaction = RLP(nonce, gasPrice, gasLimit, to, value, data, v, r, s).
  public func signedPayload(signature: [UInt8]) throws -> [UInt8] {
    let parts = try SignatureParts(signature)
    var fields = Array(try rlpFields().prefix(6))
    fields.append(contentsOf: [
      .string(Self.chainIDBytes(chainId * 2 + 35 + parts.yParity)),
      .string(parts.r),
      .string(parts.s),
    ])
    return RLP.encode(.list(fields))
  }

  private func rlpFields() throws -> [RLP.Item] {
    guard
      let nonceBytes = Hex.quantityData(hex: nonce),
      let gasPriceBytes = Hex.quantityData(hex: gasPrice),
      let gasLimitBytes = Hex.quantityData(hex: gasLimit),
      let valueBytes = Hex.quantityData(hex: value),
      let dataBytes = Hex.data(data)
    else { throw EncodingError.badQuantity }

    var fields: [RLP.Item] = [
      .string(RLP.trimQuantity(nonceBytes)),
      .string(RLP.trimQuantity(gasPriceBytes)),
      .string(RLP.trimQuantity(gasLimitBytes)),
    ]
    if let to {
      guard let toBytes = Hex.data(to), toBytes.count == 20 else { throw EncodingError.badTo }
      fields.append(.string(toBytes))
    } else {
      fields.append(.string([]))  // empty -> contract creation
    }
    fields.append(contentsOf: [
      .string(RLP.trimQuantity(valueBytes)),
      .string(dataBytes),
      .string(Self.chainIDBytes(chainId)),
      .string([]),
      .string([]),
    ])
    return fields
  }

  private static func chainIDBytes(_ chainId: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    var v = chainId
    repeat {
      bytes.insert(UInt8(v & 0xFF), at: 0)
      v >>= 8
    } while v > 0
    return bytes
  }
}

/// Minimal EIP-1559 fee-market transaction (type 0x02), access list left empty.
public struct EIP1559Transaction: Sendable {
  public let chainId: Int
  public let nonce: String
  public let maxPriorityFeePerGas: String
  public let maxFeePerGas: String
  public let gasLimit: String
  public let to: String?
  public let value: String
  public let data: String

  public init(
    chainId: Int = 1, nonce: String, maxPriorityFeePerGas: String, maxFeePerGas: String,
    gasLimit: String, to: String?, value: String, data: String
  ) {
    self.chainId = chainId
    self.nonce = nonce
    self.maxPriorityFeePerGas = maxPriorityFeePerGas
    self.maxFeePerGas = maxFeePerGas
    self.gasLimit = gasLimit
    self.to = to
    self.value = value
    self.data = data
  }

  /// Signing payload = 0x02 ‖ RLP(chainId, nonce, maxPri, maxFee, gasLimit, to, value,
  /// data, []).
  public func signingPayload() throws -> [UInt8] {
    let rlp = try transactionFields()
    return [0x02] + RLP.encode(.list(rlp))
  }

  /// Signed type-2 transaction = 0x02 ‖ RLP(unsigned fields, yParity, r, s).
  public func signedPayload(signature: [UInt8]) throws -> [UInt8] {
    let parts = try SignatureParts(signature)
    var fields = try transactionFields()
    fields.append(contentsOf: [
      .string(parts.yParity == 0 ? [] : [UInt8(parts.yParity)]),
      .string(parts.r),
      .string(parts.s),
    ])
    return [0x02] + RLP.encode(.list(fields))
  }

  private func transactionFields() throws -> [RLP.Item] {
    guard
      let nonceBytes = Hex.quantityData(hex: nonce),
      let priBytes = Hex.quantityData(hex: maxPriorityFeePerGas),
      let feeBytes = Hex.quantityData(hex: maxFeePerGas),
      let limitBytes = Hex.quantityData(hex: gasLimit),
      let valueBytes = Hex.quantityData(hex: value),
      let dataBytes = Hex.data(data)
    else { throw EncodingError.badField }

    var fields: [RLP.Item] = [
      .string(chainIDBytes),
      .string(RLP.trimQuantity(nonceBytes)),
      .string(RLP.trimQuantity(priBytes)),
      .string(RLP.trimQuantity(feeBytes)),
      .string(RLP.trimQuantity(limitBytes)),
    ]
    if let to {
      guard let toBytes = Hex.data(to), toBytes.count == 20 else { throw EncodingError.badTo }
      fields.append(.string(toBytes))
    } else {
      fields.append(.string([]))
    }
    fields.append(contentsOf: [
      .string(RLP.trimQuantity(valueBytes)),
      .string(dataBytes),
      .list([]),  // empty access list
    ])
    return fields
  }

  private var chainIDBytes: [UInt8] {
    var bytes: [UInt8] = []
    var v = chainId
    repeat {
      bytes.insert(UInt8(v & 0xFF), at: 0)
      v >>= 8
    } while v > 0
    return bytes
  }
}

private struct SignatureParts {
  let r: [UInt8]
  let s: [UInt8]
  let yParity: Int

  init(_ signature: [UInt8]) throws {
    guard signature.count == 65, signature[64] == 27 || signature[64] == 28 else {
      throw EncodingError.badField
    }
    r = RLP.trimQuantity(Array(signature[0..<32]))
    s = RLP.trimQuantity(Array(signature[32..<64]))
    yParity = Int(signature[64] - 27)
  }
}

extension RLP {
  /// Normalizes an integer byte array to minimal big-endian form. Canonical zero is an
  /// empty byte string (RLP 0x80), not a 0x00 byte.
  static func trimQuantity(_ bytes: [UInt8]) -> [UInt8] {
    var bytes = bytes
    while bytes.first == 0 { bytes.removeFirst() }
    return bytes
  }
}
