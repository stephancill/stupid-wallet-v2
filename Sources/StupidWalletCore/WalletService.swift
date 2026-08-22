import Foundation

public enum WalletError: Error, Sendable {
  case invalidParams
  case unsupported
  case notFound
  case alreadyConsumed
  case expired
  case authCancelled
}

/// A demo account. `address` is a public, fixed value; a real implementation
/// derives the address from the secp256k1 public key and signs through keychain.
public struct WalletAccount: Sendable {
  public let address: String
  public init(address: String = "0xD8d6F226E874eE8257Ac2600f4C2B0A0A8d9c1d0") {
    self.address = address
  }
}

public enum SignerError: Error, Sendable {
  case encodingFailed
}

/// Mock signing. This prototype returns a deterministic, clearly-labeled
/// signature so the UI can be exercised. It does NOT use key material.
public enum Signer {
  public static func mockPersonalSign(account: String, message: String) -> String {
    let prefix = "\u{19}Ethereum Signed Message:\n\(message.count)"
    let material = Array("\(prefix)\n\(message)\n\(account)".utf8)
    var digest = [UInt8](repeating: 0, count: 32)
    for (index, byte) in material.enumerated() {
      digest[index % 32] ^= byte
    }
    var signature = Data()
    signature.append(contentsOf: digest)
    signature.append(contentsOf: Array(repeating: 0x5A, count: 32).reversed())
    signature.append(0x1B)  // v = 27
    return "0x" + signature.map { String(format: "%02x", UInt8($0)) }.joined()
  }
}

public enum PersonalSignSummary {
  /// params[1] is the hex-encoded message; decode UTF-8 for display if possible.
  public static func message(from params: JSONValue) -> String {
    guard case .array(let array) = params, array.count >= 2 else { return "Unavailable" }
    guard case .string(let hex) = array[1] else {
      if case .string(let str) = array[1] { return str }
      return "Unavailable"
    }
    let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    guard let bytes = Data(hexString: cleaned) else { return hex }
    return String(data: bytes, encoding: .utf8) ?? hex
  }
}

extension Data {
  init?(hexString: String) {
    let cleaned = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
    guard cleaned.count.isMultiple(of: 2), cleaned.allSatisfy({ $0.isHexDigit }) else {
      return nil
    }
    var data = Data()
    data.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
      let next = cleaned.index(index, offsetBy: 2)
      guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    self = data
  }
}

/// Orchestrates wallet-owned RPC handling and the approval lifecycle.
public actor WalletService {
  public nonisolated let store: PendingRequestStore
  public nonisolated let account: WalletAccount

  public init(store: PendingRequestStore? = nil, account: WalletAccount = WalletAccount()) {
    self.account = account
    self.store = store ?? PendingRequestStore()
  }

  public struct Summary: Sendable {
    public let id: String
    public let method: String
    public let origin: String
    public let chainId: String
    public let account: String
    public let message: String?
  }

  public struct ApprovalStatus: Sendable {
    public let status: String
    public let result: JSONValue?
  }

  /// Creates a canonical pending record for a signing request.
  public func prepare(
    method: String, params: JSONValue, origin: String, chainId: String = "1"
  ) async throws -> UUID {
    let request = WalletPendingRequest(
      method: method,
      origin: Origin.normalize(origin),
      chainId: chainId,
      account: account.address,
      params: params
    )
    try await store.insert(request)
    return request.id
  }

  /// Display-safe summary for a pending request.
  public func summary(for request: UUID) async throws -> Summary {
    guard let record = try await store.record(request) else { throw WalletError.notFound }
    let message =
      record.method.lowercased() == "personal_sign"
      ? message(from: record.params) : nil
    return Summary(
      id: record.id.uuidString,
      method: record.method,
      origin: record.origin,
      chainId: record.chainId,
      account: record.account,
      message: message
    )
  }

  private func message(from params: JSONValue) -> String {
    PersonalSignSummary.message(from: params)
  }

  /// All pending approvals from the native store, newest first.
  public func list() async throws -> [Summary] {
    let records = try await store.pending()
    return records.map { record in
      Summary(
        id: record.id.uuidString,
        method: record.method,
        origin: record.origin,
        chainId: record.chainId,
        account: record.account,
        message: record.method.lowercased() == "personal_sign"
          ? message(from: record.params) : nil
      )
    }
  }

  /// Plainest-possible persisted lookup so a suspending service worker and a polling
  /// page can converge without a live callback. Returns nil when the record is gone.
  public func status(for id: UUID) async -> ApprovalStatus? {
    guard let record = try? await store.record(id) else { return nil }
    return ApprovalStatus(status: record.status.rawValue, result: record.result)
  }

  /// Approves a pending request: verifies it is pending, authenticates the user,
  /// then atomically consumes it and returns a mock signing result.
  public func approve(request: UUID) async throws -> JSONValue {
    guard var record = try await store.record(request) else { throw WalletError.notFound }
    guard record.status == .pending else { throw WalletError.alreadyConsumed }

    try await LocalAuthenticator.authenticate(reason: "Stupid Wallet is signing a message")

    let signature = Signer.mockPersonalSign(
      account: record.account, message: message(from: record.params))
    record.status = .consumed
    record.result = .string(signature)
    try await store.insert(record)
    return .string(signature)
  }

  /// Approves and returns the persisted record (used by handlers that log activity).
  public func consume(request: UUID) async throws -> WalletPendingRequest {
    guard let record = try await store.record(request) else { throw WalletError.notFound }
    guard record.status == .pending else { throw WalletError.alreadyConsumed }
    var consumed = record
    consumed.status = .consumed
    try await store.insert(consumed)
    return consumed
  }

  public func reject(request: UUID) async throws {
    guard let record = try await store.record(request) else { throw WalletError.notFound }
    guard record.status == .pending else { throw WalletError.alreadyConsumed }
    var rejected = record
    rejected.status = .rejected
    try await store.insert(rejected)
  }
}
