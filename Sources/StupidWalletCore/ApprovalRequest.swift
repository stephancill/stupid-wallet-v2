import Foundation

/// The canonical, approval-worthy class of an EIP-1193 request. The full JSON-RPC method
/// string is preserved on the pending record; this is the curated review-surface kind.
public enum RequestKind: String, Sendable, Codable {
  /// eth_requestAccounts / wallet_connect — which account is being shared.
  case connect
  /// wallet_connect with signInWithEthereum — an origin-bound EIP-4361 signature.
  case siwe
  /// personal_sign — a human-readable message.
  case message
  /// eth_signTypedData_v4 — an EIP-712 payload.
  case typedData
  /// eth_sendTransaction — a transaction to send.
  case send
  /// wallet_sendCalls — an atomic EIP-5792 call batch.
  case batch
  /// A network-state change. Add-chain requests use the approval queue; new switch requests
  /// are authorized and applied immediately, while old persisted switch records remain readable.
  case chain
  /// eth_sign / unsafe variants — deliberately denied.
  case denied
  /// Everything else routed to the RPC endpoint (no approval).
  case passthrough

  /// Maps a JSON-RPC method to its review kind without mutating state.
  public static func kind(for method: String) -> RequestKind {
    switch MethodPolicy.classify(method) {
    case .connect: return .connect
    case .chain: return .chain
    case .denied: return .denied
    case .send: return .send
    case .calls:
      return method.lowercased() == "wallet_sendcalls" ? .batch : .passthrough
    case .sign:
      switch method.lowercased() {
      case "eth_signtypeddata_v4": return .typedData
      default: return .message
      }
    case .passthrough: return .passthrough
    }
  }

}

/// Canonical, immutable binding pieces a pending approval records and that the native
/// signer re-verifies at approval time. The popup supplies only the request ID.
public struct ApprovalBinding: Sendable, Codable, Equatable {
  public let requestID: UUID
  public let kind: RequestKind
  public let method: String
  public let origin: String
  public let chainId: String
  public let account: String
  /// keccak-256 of the canonical encoding (`canonicalDigestPayload`) at prepare time.
  public let payloadDigest: String
  public let createdAt: Date
  public let expiresAt: Date

  public init(
    requestID: UUID = UUID(),
    kind: RequestKind,
    method: String,
    origin: String,
    chainId: String,
    account: String,
    payloadDigest: String,
    createdAt: Date = Date(),
    expiresAt: Date = Date().addingTimeInterval(600)
  ) {
    self.requestID = requestID
    self.kind = kind
    self.method = method
    self.origin = origin
    self.chainId = chainId
    self.account = account
    self.payloadDigest = payloadDigest
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }

  public var isExpired: Bool { Date() > expiresAt }
}

/// Deterministic canonical bytes for a request, used only to detect mutation between
/// prepare and approve. Key order is normalized so semantically identical objects hash
/// identically regardless of ordering.
public enum CanonicalRequest {
  /// keccak-256 of the request ID mixed with the canonical params encoding. The ID is
  /// mixed in so a digest is meaningful only for its own pending record; a payload
  /// replayed onto a different request ID yields a different digest.
  public static func digest(
    of params: JSONValue,
    keyedBy requestID: UUID
  ) -> String {
    var input = requestID.uuidString.utf8.map { $0 }
    input.append(contentsOf: canonicalization(params))
    return Hex.encode(Keccak.keccak256(input))
  }

  /// A stable digest of a request intent (normalized method, origin, chain, profile, and
  /// canonical params) that does not depend on any specific pending-record ID. Combined
  /// with the provider-session request key, it lets `prepare` converge transport retries
  /// without collapsing separate requests that happen to carry identical params.
  public static func intentDigest(
    method: String, origin: String, chainId: String, profileID: String?, params: JSONValue
  ) -> String {
    var input = Array("intent\u{1e}".utf8)
    input.append(contentsOf: method.lowercased().utf8)
    input.append(0x1f)
    input.append(contentsOf: origin.utf8)
    input.append(0x1f)
    input.append(contentsOf: chainId.utf8)
    input.append(0x1f)
    input.append(contentsOf: (profileID ?? "").utf8)
    input.append(0x1f)
    input.append(contentsOf: canonicalization(params))
    return Hex.encode(Keccak.keccak256(input))
  }

  /// JSON encoding with object keys sorted in canonical order, so byte-level equality is
  /// a reliable tamper check. `.sortedKeys` on a heterogeneous object is stable.
  public static func canonicalData(_ value: JSONValue) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: canonicalizable(value),
      options: [.sortedKeys, .fragmentsAllowed]
    )
  }

  public static func canonicalization(_ value: JSONValue) -> [UInt8] {
    (try? canonicalData(value)).flatMap { [UInt8]($0) } ?? []
  }

  private static func canonicalizable(_ value: JSONValue) -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let bool): return bool
    case .number(let number): return number
    case .string(let string): return string
    case .array(let array): return array.map(canonicalizable)
    case .object(let object):
      return object.mapValues(canonicalizable)
    }
  }
}
