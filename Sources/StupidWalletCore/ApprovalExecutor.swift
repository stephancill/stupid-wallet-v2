import Foundation

public enum ApprovalError: Error, Sendable {
  case badParams
  case notSignable(String)
  case unsupportedKind
}

/// Pure, testable computation of the signable digest and JSON-RPC result for a wallet
/// approval kind. No key material and no side effects. This is the single native owner
/// of "what exactly gets signed and what is returned" so the popup's params can never be
/// interpreted as the signing input.
public enum RequestExecutor {
  /// The 32-byte digest the account key must sign for a request kind.
  public static func signableDigest(for request: WalletPendingRequest) throws -> [UInt8] {
    switch request.kind {
    case .message:
      return MessageHash.eip191(message: try selfMessage(request.params))
    case .typedData:
      return try EIP712.prefixedHash(of: request.params)
    case .send:
      return try transactionDigest(request)
    case .connect:
      return MessageHash.eip191(message: Data("Stupid Wallet: connect \(request.account)".utf8))
    case .chain:
      return MessageHash.eip191(message: Data("Stupid Wallet: chain \(request.chainId)".utf8))
    case .denied, .passthrough:
      throw ApprovalError.notSignable(request.method)
    }
  }

  /// The method-appropriate JSON-RPC result paired with an already-produced signature.
  public static func resultValue(
    signature: [UInt8], for request: WalletPendingRequest
  ) throws -> JSONValue {
    switch request.kind {
    case .message, .typedData:
      return .string("0x" + Hex.encode(signature))
    case .connect:
      // eth_requestAccounts / wallet_connect resolve to the account list.
      return .array([.string(request.account)])
    case .chain:
      return .bool(true)
    case .send:
      // The signed raw transaction bytes are returned for broadcast.
      return .string("0x" + Hex.encode(signature))
    case .denied, .passthrough:
      throw ApprovalError.notSignable(request.method)
    }
  }

  // MARK: message

  /// params = [address, messageHex].
  private static func selfMessage(_ params: JSONValue) throws -> Data {
    guard case .array(let array) = params, array.count >= 2,
      case .string(let hex) = array[1],
      let bytes = Hex.data(hex)
    else { throw ApprovalError.badParams }
    return Data(bytes)
  }

  // MARK: transaction

  /// eth_sendTransaction params = [ { ... } ]. Returns the canonical 32-byte signing
  /// digest (legacy or EIP-1559) for the transaction, mixing the request ID in so the
  /// digest is bound to the pending record.
  private static func transactionDigest(_ request: WalletPendingRequest) throws -> [UInt8] {
    guard case .array(let items) = request.params,
      case .object(let tx) = items.first
    else { throw ApprovalError.badParams }

    func h(_ key: String) -> String { tx[key]?.stringValue ?? "" }
    let chainID = tx["chainId"]?.intValue ?? 1
    let payload: [UInt8]
    if tx["type"]?.stringValue == "0x2" || (!h("maxFeePerGas").isEmpty) {
      let tx = EIP1559Transaction(
        chainId: chainID,
        nonce: h("nonce"),
        maxPriorityFeePerGas: h("maxPriorityFeePerGas"),
        maxFeePerGas: h("maxFeePerGas"),
        gasLimit: h("gas"),
        to: h("to").isEmpty ? nil : h("to"),
        value: h("value"),
        data: h("data")
      )
      payload = try tx.signingPayload()
    } else {
      let tx = LegacyTransaction(
        nonce: h("nonce"),
        gasPrice: h("gasPrice"),
        gasLimit: h("gas"),
        to: h("to").isEmpty ? nil : h("to"),
        value: h("value"),
        data: h("data"),
        chainId: chainID
      )
      payload = try tx.signingPayload()
    }
    return Keccak.keccak256(payload)
  }
}

extension JSONValue {
  var intValue: Int? {
    guard case .string(let s) = self else { return nil }
    return Int(s.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? Int(s)
  }
}
