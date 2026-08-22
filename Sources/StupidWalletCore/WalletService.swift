import Foundation

public enum WalletError: Error, Sendable {
  case invalidParams
  case unsupported
  case notFound
  case alreadyConsumed
  case expired
  case authCancelled
  case transport
  case notReady
  case bindingMismatch
  case queued
  case methodNotApproved
}

/// Renders the human-readable canonical summary for a request kind. Display-only; the
/// signing input is the persisted `params` + `payloadDigest`, never this text.
public enum ApprovalSummary {
  public static func title(for request: WalletPendingRequest) -> String {
    switch request.kind {
    case .connect: return "Connect site"
    case .message: return "Sign message"
    case .typedData: return "Sign typed data"
    case .send: return "Send transaction"
    case .chain:
      return request.method.lowercased() == "wallet_switchethereumchain"
        ? "Switch network" : "Add network"
    case .denied: return "Blocked method"
    case .passthrough: return request.method
    }
  }

  public static func rows(for request: WalletPendingRequest) -> [(String, String)] {
    var rows: [(String, String)] = []
    switch request.kind {
    case .connect:
      rows.append(("Account", request.account))
      rows.append(("Origin", request.origin))
    case .message:
      rows.append(("From", request.origin))
      rows.append(("Account", request.account))
      rows.append(("Chain", request.chainId))
      rows.append(("Message", Self.messageDisplay(request.params)))
    case .typedData:
      rows.append(("From", request.origin))
      rows.append(("Account", request.account))
      rows.append(("Domain", Self.typedDomain(request.params)))
      if let contract = Self.typedVerifyingContract(request.params) {
        rows.append(("Contract", contract))
      }
      rows.append(("Chain", request.chainId))
    case .send:
      rows.append(("From", request.origin))
      rows.append(("Account", request.account))
      rows.append(("Chain", request.chainId))
      if let tx = Self.firstObject(request.params) {
        if let to = tx["to"]?.stringValue, !to.isEmpty { rows.append(("To", to)) }
        if let value = tx["value"]?.stringValue, value != "0x0", !value.isEmpty {
          rows.append(("Value", value))
        }
        if let data = tx["data"]?.stringValue, !data.isEmpty, data != "0x" {
          rows.append(("Data", Self.dataDigest(data)))
        }
      }
    case .chain:
      if let id = Self.addedChainID(request.params) { rows.append(("Chain ID", id)) }
      if let name = Self.addedChainName(request.params) { rows.append(("Name", name)) }
      rows.append(("From", request.origin))
    case .denied:
      rows.append(("Method", request.method))
      rows.append(("Note", "This method is blocked for safety."))
    case .passthrough:
      rows.append(("Method", request.method))
    }
    return rows
  }

  private static func firstObject(_ params: JSONValue) -> [String: JSONValue]? {
    if case .object(let o) = params { return o }
    guard case .array(let a) = params, case .object(let o)? = a.first else { return nil }
    return o
  }

  private static func messageDisplay(_ params: JSONValue) -> String {
    guard case .array(let a) = params, a.count >= 2,
      case .string(let hex) = a[1]
    else { return "Unavailable" }
    let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    guard let bytes = Hex.data(cleaned) else { return hex }
    return String(data: Data(bytes), encoding: .utf8) ?? hex
  }

  private static func typedDomain(_ params: JSONValue) -> String {
    guard case .object(let o) = params, let domain = o["domain"] else { return "Unavailable" }
    if case .object(let d) = domain, let name = d["name"]?.stringValue { return name }
    return "Unavailable"
  }

  private static func typedVerifyingContract(_ params: JSONValue) -> String? {
    guard case .object(let o) = params, let domain = o["domain"] else { return nil }
    if case .object(let d) = domain, let c = d["verifyingContract"]?.stringValue, !c.isEmpty {
      return c
    }
    return nil
  }

  private static func addedChainID(_ params: JSONValue) -> String? {
    guard case .object(let o) = params else { return nil }
    return o["addedChainID"]?.stringValue ?? o["chainID"]?.stringValue
  }
  private static func addedChainName(_ params: JSONValue) -> String? {
    guard case .object(let o) = params else { return nil }
    return o["chainName"]?.stringValue
  }

  private static func dataDigest(_ data: String) -> String {
    let cleaned = data.hasPrefix("0x") ? String(data.dropFirst(2)) : data
    guard let bytes = Hex.data(cleaned), !bytes.isEmpty else { return "0x" }
    let hash = Hex.encode(Keccak.keccak256(bytes))
    return "0x" + String(hash.prefix(10)) + "…"
  }
}

/// Orchestrates wallet-owned RPC handling and the canonical approval lifecycle.
/// Signing is injected behind `Signing` so hermetic tests use a deterministic stub and
/// production uses `KeychainSigner` backed by the shared keychain.
public actor WalletService {
  public nonisolated let store: PendingRequestStore
  public nonisolated let signing: any Signing
  nonisolated let resolver: RPCResolver
  nonisolated let rpcClient: RPCClient

  public init(
    store: PendingRequestStore? = nil,
    signing: any Signing,
    resolver: RPCResolver = RPCResolver(),
    rpcClient: RPCClient = RPCClient()
  ) {
    self.signing = signing
    self.store = store ?? PendingRequestStore()
    self.resolver = resolver
    self.rpcClient = rpcClient
  }

  public nonisolated var account: String { signing.account }

  public struct Summary: Sendable {
    public let id: String
    public let kind: String
    public let method: String
    public let origin: String
    public let chainId: String
    public let account: String
    public let title: String
    public let rows: [(label: String, value: String)]
    public let queued: Bool
  }

  public struct RequestStatus: Sendable {
    public let status: String
    public let result: JSONValue?
  }

  /// Creates a canonical pending record with a derived payload digest. Requests whose
  /// policy kind is not approval-worthy are rejected up front.
  public func prepare(
    method: String, params: JSONValue, origin: String, chainId: String = "1"
  ) async throws -> UUID {
    let kind = RequestKind.kind(for: method)
    guard kind.requiresApproval else { throw WalletError.methodNotApproved }
    guard signing.hasKey() else { throw WalletError.notReady }

    let id = UUID()
    let record = WalletPendingRequest(
      id: id,
      kind: kind,
      method: method,
      origin: Origin.normalize(origin),
      chainId: chainId,
      account: signing.account,
      params: params,
      payloadDigest: CanonicalRequest.digest(of: params, keyedBy: id)
    )
    try await store.insert(record)
    return id
  }

  /// Display-safe canonical summary for one pending request.
  public func summarize(request: UUID) async throws -> Summary? {
    guard let record = try await store.record(request) else { return nil }
    return await makeSummary(record)
  }

  /// Summaries for all pending records, oldest first (queue order) with the active head.
  public func list() async throws -> [Summary] {
    let records = try await store.pending().sorted { $0.createdAt < $1.createdAt }
    var summaries: [Summary] = []
    for record in records { summaries.append(await makeSummary(record)) }
    return summaries
  }

  private func makeSummary(_ record: WalletPendingRequest) async -> Summary {
    var active = false
    if let queue = try? await store.pending().sorted(by: { $0.createdAt < $1.createdAt }) {
      active = queue.first?.id == record.id
    }
    return Summary(
      id: record.id.uuidString,
      kind: record.kind.rawValue,
      method: record.method,
      origin: record.origin,
      chainId: record.chainId,
      account: record.account,
      title: ApprovalSummary.title(for: record),
      rows: ApprovalSummary.rows(for: record),
      queued: !active
    )
  }

  /// Persisted status so a suspending service worker and a polling page converge.
  public func status(for id: UUID) async -> RequestStatus? {
    guard let record = try? await store.record(id) else { return nil }
    return RequestStatus(status: record.status.rawValue, result: record.result)
  }

  /// Approve the active head: verify binding, queue eligibility, expiry, recomputed
  /// digest, authenticate, then sign with the real account key and consume the record.
  public func approve(request: UUID) async throws -> JSONValue {
    guard var record = try await store.record(request) else { throw WalletError.notFound }
    // store.record() normalizes an expired pending record to `.expired`.
    if record.status == .expired { throw WalletError.expired }
    guard record.status == .pending else { throw WalletError.alreadyConsumed }
    guard !record.isExpired else {
      record.status = .expired
      try await store.insert(record)
      throw WalletError.expired
    }
    // Queue policy: only the oldest pending request may be approved.
    let queue = (try await store.pending()).sorted { $0.createdAt < $1.createdAt }
    guard queue.first?.id == record.id else { throw WalletError.queued }
    guard RequestKind.kind(for: record.method) == record.kind else {
      throw WalletError.bindingMismatch
    }
    // Recompute the digest over the reloaded, canonical params; must equal the binding.
    let digestNow = CanonicalRequest.digest(of: record.params, keyedBy: record.id)
    guard digestNow == record.payloadDigest else { throw WalletError.bindingMismatch }

    // Consent-only approvals (connect / chain) return without touching the key.
    // Only signature-producing kinds (message / typed-data / send) require device-owner
    // authentication, which `.userPresence` keychain access presents itself.
    let requiresSignature: Bool
    switch record.kind {
    case .connect, .chain: requiresSignature = false
    default: requiresSignature = true
    }

    let result: JSONValue
    if requiresSignature {
      let signable = try RequestExecutor.signableDigest(for: record)
      let signature: [UInt8]
      do {
        signature = try signing.signDigest(signable)
      } catch {
        throw WalletError.authCancelled
      }
      result = try RequestExecutor.resultValue(signature: signature, for: record)
    } else {
      result = try RequestExecutor.resultValue(signature: [], for: record)
    }
    record.status = .consumed
    record.result = result
    try await store.insert(record)
    return result
  }

  public func reject(request: UUID) async throws {
    guard let record = try await store.record(request) else { throw WalletError.notFound }
    guard record.status == .pending else { throw WalletError.alreadyConsumed }
    var rejected = record
    rejected.status = .rejected
    try await store.insert(rejected)
  }

  /// Node-answered JSON-RPC result or preserved node error, through the one resolver.
  public enum RPCOutcome: Sendable {
    case result(JSONValue)
    case nodeError(JSONValue)
  }

  public func passthrough(method: String, params: JSONValue, chainID: String) async -> RPCOutcome {
    let url = resolver.resolve(chainID: chainID)
    do {
      let response = try await rpcClient.call(url: url, method: method, params: params)
      switch response {
      case .result(let value): return .result(value)
      case .error(let error): return .nodeError(error)
      }
    } catch {
      return .nodeError(
        .object([
          "code": .number(-32000),
          "message": .string("RPC transport failure"),
        ]))
    }
  }
}
