import Foundation

public enum WalletError: Error, Sendable, Equatable {
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
  case rpc(JSONValue)
  case unauthorized
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
      if let primaryType = Self.typedPrimaryType(request.params) {
        rows.append(("Primary Type", primaryType))
      }
      rows.append(("Domain", Self.typedDomain(request.params)))
      if let version = Self.typedDomainField("version", request.params) {
        rows.append(("Version", version))
      }
      if let domainChain = Self.typedDomainField("chainId", request.params) {
        rows.append(("Domain Chain", domainChain))
      }
      if let contract = Self.typedVerifyingContract(request.params) {
        rows.append(("Contract", contract))
      }
      rows.append(("Chain", request.chainId))
      rows.append(contentsOf: Self.typedMessageRows(request.params))
    case .send:
      rows.append(("From", request.origin))
      rows.append(("Account", request.account))
      rows.append(("Chain", request.chainId))
      if let tx = Self.firstObject(request.params) {
        if let to = tx["to"]?.stringValue, !to.isEmpty {
          rows.append(("To", to))
        } else {
          rows.append(("To", "Contract creation"))
        }
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
      case .string(let hex) = a[0]
    else { return "Unavailable" }
    let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    guard let bytes = Hex.data(cleaned) else { return hex }
    return String(data: Data(bytes), encoding: .utf8) ?? hex
  }

  private static func typedDomain(_ params: JSONValue) -> String {
    guard let object = typedObject(params),
      let domain = object["domain"]
    else { return "Unavailable" }
    if case .object(let d) = domain, let name = d["name"]?.stringValue { return name }
    return "Unavailable"
  }

  private static func typedPrimaryType(_ params: JSONValue) -> String? {
    typedObject(params)?["primaryType"]?.stringValue
  }

  private static func typedDomainField(_ field: String, _ params: JSONValue) -> String? {
    guard let object = typedObject(params), case .object(let domain)? = object["domain"],
      let value = domain[field]
    else { return nil }
    return jsonDisplay(value)
  }

  private static func typedMessageRows(_ params: JSONValue) -> [(String, String)] {
    guard let object = typedObject(params), case .object(let message)? = object["message"] else {
      return []
    }

    var names: [String] = []
    if let primaryType = object["primaryType"]?.stringValue,
      case .object(let types)? = object["types"],
      case .array(let fields)? = types[primaryType]
    {
      names = fields.compactMap { field in
        guard case .object(let definition) = field else { return nil }
        return definition["name"]?.stringValue
      }
    }
    if names.isEmpty { names = message.keys.sorted() }

    return names.compactMap { name in
      guard let value = message[name], let display = jsonDisplay(value) else { return nil }
      return ("Message / \(name)", display)
    }
  }

  private static func jsonDisplay(_ value: JSONValue) -> String? {
    if case .string(let string) = value { return string }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func typedVerifyingContract(_ params: JSONValue) -> String? {
    guard let object = typedObject(params),
      let domain = object["domain"]
    else { return nil }
    if case .object(let d) = domain, let c = d["verifyingContract"]?.stringValue, !c.isEmpty {
      return c
    }
    return nil
  }

  /// Unwraps standard `[address, jsonString]` params or accepts a bare object.
  private static func typedObject(_ params: JSONValue) -> [String: JSONValue]? {
    switch params {
    case .object(let object):
      return object
    case .array(let array) where array.count >= 2:
      guard case .string(let json) = array[1],
        let data = json.data(using: .utf8),
        case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
      else { return nil }
      return object
    default:
      return nil
    }
  }

  private static func addedChainID(_ params: JSONValue) -> String? {
    let object = firstObjectAny(params)
    guard let object else { return nil }
    return object["addedChainID"]?.stringValue ?? object["chainID"]?.stringValue
      ?? object["chainId"]?.stringValue
  }
  private static func addedChainName(_ params: JSONValue) -> String? {
    let object = firstObjectAny(params)
    guard let object else { return nil }
    return object["chainName"]?.stringValue
  }

  /// First object in either a bare object or a single-element array, matching both the
  /// canonical record form and standard EIP-1193 `[object]` params.
  private static func firstObjectAny(_ params: JSONValue) -> [String: JSONValue]? {
    if case .object(let object) = params { return object }
    guard case .array(let array) = params, case .object(let object)? = array.first else {
      return nil
    }
    return object
  }

  private static func dataDigest(_ data: String) -> String {
    let cleaned = data.hasPrefix("0x") ? String(data.dropFirst(2)) : data
    guard let bytes = Hex.data(cleaned), !bytes.isEmpty else { return "0x" }
    let hash = Hex.encode(Keccak.keccak256(bytes))
    return "keccak256 0x\(hash) (\(bytes.count) bytes)"
  }
}

/// Orchestrates wallet-owned RPC handling and the canonical approval lifecycle.
/// Signing is injected behind `Signing` so hermetic tests use a deterministic stub and
/// production uses `KeychainSigner` backed by the shared keychain.
public actor WalletService {
  public nonisolated let store: PendingRequestStore
  public nonisolated let signing: any Signing
  public nonisolated let connectedSites: ConnectedSitesStore
  public nonisolated let chainStore: ChainStore
  public nonisolated let networkStore: NetworkStore
  public nonisolated let activityStore: ActivityStore
  nonisolated let resolver: RPCResolver
  nonisolated let rpcClient: RPCClient

  public init(
    store: PendingRequestStore? = nil,
    signing: any Signing,
    connectedSites: ConnectedSitesStore? = nil,
    chainStore: ChainStore = ChainStore(),
    networkStore: NetworkStore = NetworkStore(),
    activityStore: ActivityStore = ActivityStore(),
    resolver: RPCResolver = RPCResolver(),
    rpcClient: RPCClient = RPCClient()
  ) {
    self.signing = signing
    self.store = store ?? PendingRequestStore()
    self.connectedSites = connectedSites ?? ConnectedSitesStore()
    self.chainStore = chainStore
    self.networkStore = networkStore
    self.activityStore = activityStore
    self.resolver = resolver
    self.rpcClient = rpcClient
  }

  /// Hermetic-test initializer that also isolates the connection-grant store.
  public init(
    store: PendingRequestStore?,
    signing: any Signing,
    grantsSuite: String
  ) {
    self.signing = signing
    self.store = store ?? PendingRequestStore()
    self.connectedSites = ConnectedSitesStore(suiteName: grantsSuite)
    let chainDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ChainStore-\(grantsSuite)")
    try? FileManager.default.createDirectory(
      at: chainDirectory, withIntermediateDirectories: true)
    self.chainStore = ChainStore(directory: chainDirectory)
    self.networkStore = NetworkStore(
      directory: chainDirectory, legacySuiteName: grantsSuite)
    self.activityStore = ActivityStore(
      databaseURL: chainDirectory.appendingPathComponent("Activity.sqlite"))
    self.resolver = RPCResolver()
    self.rpcClient = RPCClient()
  }

  // MARK: Connection grants

  /// Whether this origin already has a connection grant to the active account.
  public nonisolated func isConnected(origin: String, profileID: String? = nil) async -> Bool {
    await connectedSites.isConnected(
      origin: origin, address: signing.account, profileID: profileID)
  }

  /// All persisted connection grants.
  public func connectedSitesList() async -> [ConnectedSite] {
    await connectedSites.all()
  }

  /// Grants a connection and binds it to the active account. Idempotent.
  public func connect(origin: String, profileID: String? = nil) async {
    await connectedSites.connect(
      site: ConnectedSite(
        domain: Origin.downHost(of: origin),
        address: signing.account,
        origin: origin,
        profileID: profileID)
    )
  }

  /// Revokes a connection. Idempotent.
  public func disconnect(origin: String, profileID: String? = nil) async {
    await connectedSites.disconnect(origin: origin, profileID: profileID)
  }

  public nonisolated var account: String { signing.account }
  public struct ActiveChainState: Sendable {
    public let chainID: String
    public let recoveredSwitch: Bool
  }

  public func activeChainState() async throws -> ActiveChainState {
    guard let claim = chainStore.claimSwitch(wait: true) else { throw ChainStoreError.unavailable }
    defer { chainStore.releaseSwitch(claim) }
    var recovered = false
    if try chainStore.pendingSwitch() != nil {
      if let currentJournal = try chainStore.pendingSwitch() {
        let consumed = try await store.record(currentJournal.requestID)?.status == .consumed
        try chainStore.recoverSwitch(currentJournal, consumed: consumed)
        recovered = true
      }
    }
    return ActiveChainState(
      chainID: try chainStore.currentChainID(), recoveredSwitch: recovered)
  }

  public func activeChainID() async throws -> String {
    try await activeChainState().chainID
  }

  /// Applies an authorized dapp's standard wallet_switchEthereumChain request immediately.
  /// This is wallet-owned state, not an RPC passthrough, but it requires neither a popup
  /// approval record nor keychain authentication.
  public func switchChain(
    params: JSONValue,
    origin: String,
    profileID: String? = nil
  ) async throws -> JSONValue {
    guard signing.hasKey() else { throw WalletError.notReady }
    guard
      await connectedSites.isConnected(
        origin: origin, address: signing.account, profileID: profileID)
    else { throw WalletError.unauthorized }
    guard let target = Self.requestedChainID(params) else { throw WalletError.invalidParams }
    guard let claim = chainStore.claimSwitch() else { throw WalletError.queued }
    defer { chainStore.releaseSwitch(claim) }

    if let journal = try chainStore.pendingSwitch() {
      let consumed = try await store.record(journal.requestID)?.status == .consumed
      try chainStore.recoverSwitch(journal, consumed: consumed)
    }
    try networkStore.record(chainID: target)
    try chainStore.setChainID(target)
    return .null
  }

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
    public let error: JSONValue?
  }

  /// Creates a canonical pending record with a derived payload digest. Requests whose
  /// policy kind is not approval-worthy are rejected up front.
  public func prepare(
    method: String,
    params: JSONValue,
    origin: String,
    chainId _: String = "1",
    profileID: String? = nil
  ) async throws -> UUID {
    let chainId = try await activeChainID()
    let kind = RequestKind.kind(for: method)
    guard MethodPolicy.requiresApproval(method) else { throw WalletError.methodNotApproved }
    guard signing.hasKey() else { throw WalletError.notReady }
    if kind == .chain,
      !(await connectedSites.isConnected(
        origin: origin, address: signing.account, profileID: profileID))
    {
      throw WalletError.unauthorized
    }

    let canonicalParams: JSONValue
    if kind == .send {
      canonicalParams = try canonicalizeTransaction(params: params, chainID: chainId)
    } else {
      canonicalParams = params
    }
    if kind == .chain, Self.requestedChainID(canonicalParams) == nil {
      throw WalletError.invalidParams
    }
    let id = UUID()
    let record = WalletPendingRequest(
      id: id,
      kind: kind,
      method: method,
      origin: Origin.normalize(origin),
      profileID: profileID,
      chainId: chainId,
      account: signing.account,
      params: canonicalParams,
      payloadDigest: CanonicalRequest.digest(of: canonicalParams, keyedBy: id)
    )
    if kind == .send {
      do {
        try Self.validateTransactionIntent(
          record.params, account: record.account, chainID: record.chainId)
      } catch {
        throw WalletError.invalidParams
      }
    }
    try await store.insert(record)
    return id
  }

  /// Display-safe canonical summary for one pending request.
  public func summarize(request: UUID, profileID: String? = nil) async throws -> Summary? {
    guard let record = try await store.record(request) else { return nil }
    guard record.profileID == profileID else { return nil }
    return await makeSummary(record)
  }

  /// Summaries for all pending records, oldest first (queue order) with the active head.
  public func list(profileID: String? = nil) async throws -> [Summary] {
    let records = try await store.pending().filter { $0.profileID == profileID }.sorted {
      $0.createdAt < $1.createdAt
    }
    var summaries: [Summary] = []
    for record in records { summaries.append(await makeSummary(record)) }
    return summaries
  }

  private func makeSummary(_ record: WalletPendingRequest) async -> Summary {
    var active = false
    if let queue = try? await store.pending().sorted(by: { $0.createdAt < $1.createdAt }) {
      active = queue.first?.id == record.id
    }
    var rows = ApprovalSummary.rows(for: record).map { row in
      switch row.0 {
      case "Chain": return (row.0, chainDisplayName(record.chainId))
      case "Domain Chain": return (row.0, chainDisplayName(row.1))
      default: return row
      }
    }
    if record.kind == .send {
      rows.append(("Network Fee", await estimatedNetworkFee(for: record)))
    }
    return Summary(
      id: record.id.uuidString,
      kind: record.kind.rawValue,
      method: record.method,
      origin: record.origin,
      chainId: record.chainId,
      account: record.account,
      title: ApprovalSummary.title(for: record),
      rows: rows,
      queued: !active
    )
  }

  private func estimatedNetworkFee(for record: WalletPendingRequest) async -> String {
    guard case .array(let items) = record.params, items.count == 1,
      case .object(let transaction) = items[0]
    else { return "Unable to estimate" }

    do {
      let gas: String
      if let suppliedGas = transaction["gas"]?.stringValue {
        gas = suppliedGas
      } else {
        gas = try await rpcQuantity(
          method: "eth_estimateGas", params: .array([.object(transaction)]),
          chainID: record.chainId)
      }

      let feePerGas: String
      if transaction["type"]?.stringValue == "0x2" {
        if let maxFee = transaction["maxFeePerGas"]?.stringValue {
          feePerGas = maxFee
        } else {
          let gasPrice = try await rpcQuantity(
            method: "eth_gasPrice", params: .array([]), chainID: record.chainId)
          let priorityFee: String
          if let suppliedPriorityFee = transaction["maxPriorityFeePerGas"]?.stringValue {
            priorityFee = suppliedPriorityFee
          } else {
            priorityFee = try await rpcQuantity(
              method: "eth_maxPriorityFeePerGas", params: .array([]), chainID: record.chainId)
          }
          feePerGas = try Self.maximumQuantity(gasPrice, priorityFee)
        }
      } else if let suppliedGasPrice = transaction["gasPrice"]?.stringValue {
        feePerGas = suppliedGasPrice
      } else {
        feePerGas = try await rpcQuantity(
          method: "eth_gasPrice", params: .array([]), chainID: record.chainId)
      }

      guard let gasBytes = Hex.quantityData(hex: gas),
        let feeBytes = Hex.quantityData(hex: feePerGas)
      else { return "Unable to estimate" }
      let amount = NativeBalanceService.formatEther(bytes: Self.multiply(gasBytes, feeBytes))
      return "~\(amount) \(Self.nativeCurrencySymbol(chainID: record.chainId))"
    } catch {
      return "Unable to estimate"
    }
  }

  private static func multiply(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    guard lhs.contains(where: { $0 != 0 }), rhs.contains(where: { $0 != 0 }) else { return [0] }
    let left = Array(lhs.reversed())
    let right = Array(rhs.reversed())
    var words = [UInt64](repeating: 0, count: left.count + right.count + 1)
    for (leftIndex, leftByte) in left.enumerated() {
      for (rightIndex, rightByte) in right.enumerated() {
        words[leftIndex + rightIndex] += UInt64(leftByte) * UInt64(rightByte)
      }
    }
    for index in 0..<(words.count - 1) {
      words[index + 1] += words[index] >> 8
      words[index] &= 0xff
    }
    while words.count > 1, words.last == 0 { words.removeLast() }
    return words.reversed().map(UInt8.init)
  }

  private static func nativeCurrencySymbol(chainID: String) -> String {
    switch chainID {
    case "1", "10", "8453", "42161": return "ETH"
    case "56": return "BNB"
    case "100": return "xDAI"
    case "137": return "MATIC"
    case "42220": return "CELO"
    case "43114": return "AVAX"
    default: return "native"
    }
  }

  private func chainDisplayName(_ chainID: String) -> String {
    guard let normalized = ChainStore.normalize(chainID) else { return "Chain \(chainID)" }
    if let network = try? networkStore.network(chainID: normalized) { return network.name }
    return "Chain \(normalized)"
  }

  /// Persisted status so a suspending service worker and a polling page converge.
  public func status(for id: UUID, profileID: String? = nil) async -> RequestStatus? {
    guard let record = try? await store.record(id), record.profileID == profileID else {
      return nil
    }
    return RequestStatus(
      status: record.status.rawValue, result: record.result, error: record.error)
  }

  /// Approve the active head: verify binding, queue eligibility, expiry, recomputed
  /// digest, authenticate, then sign with the real account key and consume the record.
  public func approve(request: UUID, profileID: String? = nil) async throws -> JSONValue {
    guard try await store.record(request) != nil else { throw WalletError.notFound }
    guard let claim = store.claim(request) else { throw WalletError.alreadyConsumed }
    defer { store.releaseClaim(claim) }

    guard var record = try await store.record(request) else { throw WalletError.notFound }
    guard record.profileID == profileID else { throw WalletError.bindingMismatch }
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
    let activeChainID = try await activeChainID()
    guard record.chainId == activeChainID else {
      let rpcError = JSONValue.object([
        "code": .number(4901),
        "message": .string("Active chain changed before approval"),
      ])
      record.status = .failed
      record.error = rpcError
      try await store.insert(record)
      throw WalletError.rpc(rpcError)
    }
    guard signing.account.caseInsensitiveCompare(record.account) == .orderedSame else {
      throw WalletError.bindingMismatch
    }
    if record.kind == .chain,
      !(await connectedSites.isConnected(
        origin: record.origin, address: record.account, profileID: profileID))
    {
      let rpcError = JSONValue.object([
        "code": .number(4100),
        "message": .string("Origin disconnected before approval"),
      ])
      record.status = .failed
      record.error = rpcError
      try await store.insert(record)
      throw WalletError.rpc(rpcError)
    }
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
      let signable: [UInt8]
      do {
        if record.kind == .send {
          try Self.validateTransactionIntent(
            record.params, account: record.account, chainID: record.chainId)
          record = try await resolveTransaction(record)
          try Self.validatePreparedTransaction(
            record.resolvedParams ?? record.params, account: record.account,
            chainID: record.chainId)
        }
        signable = try RequestExecutor.signableDigest(for: record)
      } catch let error as WalletError {
        if case .rpc = error { throw error }
        let rpcError = JSONValue.object([
          "code": .number(-32602),
          "message": .string("Invalid persisted request parameters"),
        ])
        record.status = .failed
        record.error = rpcError
        try await store.insert(record)
        throw WalletError.rpc(rpcError)
      } catch {
        let rpcError = JSONValue.object([
          "code": .number(-32602),
          "message": .string("Invalid persisted request parameters"),
        ])
        record.status = .failed
        record.error = rpcError
        try await store.insert(record)
        throw WalletError.rpc(rpcError)
      }
      let signature: [UInt8]
      do {
        signature = try signing.signDigest(signable)
      } catch {
        throw WalletError.authCancelled
      }
      if record.kind == .send {
        let raw = try RequestExecutor.signedTransaction(signature: signature, for: record)
        result = try await broadcast(rawTransaction: raw, record: &record)
      } else {
        result = try RequestExecutor.resultValue(signature: signature, for: record)
        try? await activityStore.recordSignature(request: record, signature: signature)
      }
    } else {
      result = try RequestExecutor.resultValue(signature: [], for: record)
    }
    let previousChainID = activeChainID
    var switchJournal: ChainStore.SwitchJournal?
    var chainSwitchClaim: Int32?
    defer {
      if let chainSwitchClaim { chainStore.releaseSwitch(chainSwitchClaim) }
    }
    if record.kind == .chain,
      record.method.lowercased() == "wallet_switchethereumchain"
    {
      guard let switchClaim = chainStore.claimSwitch() else { throw WalletError.queued }
      chainSwitchClaim = switchClaim
      guard let target = Self.requestedChainID(record.params) else {
        throw WalletError.invalidParams
      }
      try chainStore.beginSwitch(
        requestID: record.id, previousChainID: previousChainID, targetChainID: target)
      let journal = try chainStore.pendingSwitch()
      guard let journal else { throw ChainStoreError.unavailable }
      do {
        try chainStore.setChainID(target)
      } catch {
        try? chainStore.recoverSwitch(journal, consumed: false)
        throw error
      }
      switchJournal = journal
    }
    if record.kind == .chain,
      record.method.lowercased() == "wallet_addethereumchain"
    {
      guard let target = Self.requestedChainID(record.params) else {
        throw WalletError.invalidParams
      }
      try networkStore.record(
        chainID: target, suggestedName: Self.requestedChainName(record.params))
    }
    record.status = .consumed
    record.result = result
    do {
      try await store.insert(record)
    } catch {
      if let switchJournal {
        do {
          try chainStore.recoverSwitch(switchJournal, consumed: false)
        } catch {
          throw WalletError.notReady
        }
      }
      throw error
    }
    if switchJournal != nil { try? chainStore.finishSwitch() }
    // A successful connect/chain-approval content grant establishes the durable
    // connection so a subsequent eth_requestAccounts from the same origin short-circuits.
    if record.kind == .connect {
      await connectedSites.connect(
        site: ConnectedSite(
          domain: Origin.downHost(of: record.origin),
          address: record.account,
          origin: record.origin,
          profileID: record.profileID)
      )
    }
    return result
  }

  private static func requestedChainID(_ params: JSONValue) -> String? {
    let object: [String: JSONValue]?
    if case .array(let values) = params, case .object(let value)? = values.first {
      object = value
    } else if case .object(let value) = params {
      object = value
    } else {
      object = nil
    }
    guard let raw = object?["chainId"]?.stringValue else { return nil }
    return ChainStore.normalize(raw)
  }

  private static func requestedChainName(_ params: JSONValue) -> String? {
    let object: [String: JSONValue]?
    if case .array(let values) = params, case .object(let value)? = values.first {
      object = value
    } else if case .object(let value) = params {
      object = value
    } else {
      object = nil
    }
    return object?["chainName"]?.stringValue
  }

  private func canonicalizeTransaction(params: JSONValue, chainID: String) throws -> JSONValue {
    guard case .array(let items) = params, items.count == 1,
      case .object(var transaction) = items[0]
    else { throw WalletError.invalidParams }

    let supportedFields: Set<String> = [
      "from", "to", "value", "data", "input", "gas", "gasLimit", "gasPrice", "nonce",
      "chainId", "type", "maxFeePerGas", "maxPriorityFeePerGas", "accessList",
    ]
    guard transaction.keys.allSatisfy(supportedFields.contains) else {
      throw WalletError.invalidParams
    }

    if let from = transaction["from"]?.stringValue,
      from.caseInsensitiveCompare(signing.account) != .orderedSame
    {
      throw WalletError.invalidParams
    }
    transaction["from"] = .string(signing.account)
    transaction["value"] = transaction["value"] ?? .string("0x0")
    if let data = transaction["data"], let input = transaction["input"], data != input {
      throw WalletError.invalidParams
    }
    transaction["data"] = transaction["data"] ?? transaction["input"] ?? .string("0x")
    transaction.removeValue(forKey: "input")

    let chainQuantity = try Self.chainQuantity(chainID)
    if let supplied = transaction["chainId"]?.stringValue,
      try Self.chainQuantity(supplied) != chainQuantity
    {
      throw WalletError.invalidParams
    }
    transaction["chainId"] = .string(chainQuantity)

    if transaction["gas"] == nil {
      if let gasLimit = transaction.removeValue(forKey: "gasLimit") {
        transaction["gas"] = gasLimit
      }
    } else if let gasLimit = transaction["gasLimit"] {
      guard transaction["gas"] == gasLimit else { throw WalletError.invalidParams }
      transaction.removeValue(forKey: "gasLimit")
    }

    let type = transaction["type"]?.stringValue?.lowercased()
    let dynamic =
      type == "0x2" || transaction["maxFeePerGas"] != nil
      || transaction["maxPriorityFeePerGas"] != nil
    if dynamic {
      guard transaction["gasPrice"] == nil, type == nil || type == "0x2" else {
        throw WalletError.invalidParams
      }
      if let accessList = transaction["accessList"] {
        guard accessList == .array([]) else { throw WalletError.invalidParams }
      }
      transaction["type"] = .string("0x2")
    } else {
      guard type == nil || type == "0x0" else { throw WalletError.invalidParams }
      guard transaction["accessList"] == nil else { throw WalletError.invalidParams }
      transaction.removeValue(forKey: "type")
    }
    let intent = JSONValue.array([.object(transaction)])
    try Self.validateTransactionIntent(intent, account: signing.account, chainID: chainID)
    return intent
  }

  private func resolveTransaction(_ record: WalletPendingRequest) async throws
    -> WalletPendingRequest
  {
    guard case .array(let items) = record.params, items.count == 1,
      case .object(var transaction) = items[0]
    else { throw WalletError.invalidParams }

    if transaction["nonce"] == nil {
      transaction["nonce"] = .string(
        try await rpcQuantity(
          method: "eth_getTransactionCount",
          params: .array([.string(record.account), .string("pending")]),
          chainID: record.chainId))
    }
    if transaction["gas"] == nil {
      transaction["gas"] = .string(
        try await rpcQuantity(
          method: "eth_estimateGas", params: .array([.object(transaction)]),
          chainID: record.chainId))
    }
    if transaction["type"]?.stringValue == "0x2" {
      if transaction["maxPriorityFeePerGas"] == nil {
        transaction["maxPriorityFeePerGas"] = .string(
          try await rpcQuantity(
            method: "eth_maxPriorityFeePerGas", params: .array([]), chainID: record.chainId))
      }
      if transaction["maxFeePerGas"] == nil {
        let gasPrice = try await rpcQuantity(
          method: "eth_gasPrice", params: .array([]), chainID: record.chainId)
        let priorityFee = transaction["maxPriorityFeePerGas"]?.stringValue ?? "0x0"
        transaction["maxFeePerGas"] = .string(
          try Self.maximumQuantity(gasPrice, priorityFee))
      }
    } else if transaction["gasPrice"] == nil {
      transaction["gasPrice"] = .string(
        try await rpcQuantity(method: "eth_gasPrice", params: .array([]), chainID: record.chainId))
    }

    var resolved = record
    resolved.resolvedParams = .array([.object(transaction)])
    return resolved
  }

  private func rpcQuantity(method: String, params: JSONValue, chainID: String) async throws
    -> String
  {
    let response: RPCResponse
    do {
      response = try await rpcClient.call(
        url: resolver.resolve(chainID: chainID), method: method, params: params)
    } catch {
      throw WalletError.rpc(Self.transportError)
    }
    switch response {
    case .result(.string(let quantity)) where Hex.quantityData(hex: quantity) != nil:
      return quantity
    case .result:
      throw WalletError.rpc(
        .object([
          "code": .number(-32603),
          "message": .string("Invalid quantity returned by \(method)"),
        ]))
    case .error(let error): throw WalletError.rpc(error)
    }
  }

  private func broadcast(
    rawTransaction: [UInt8], record: inout WalletPendingRequest
  ) async throws -> JSONValue {
    let response: RPCResponse
    do {
      response = try await rpcClient.call(
        url: resolver.resolve(chainID: record.chainId),
        method: "eth_sendRawTransaction",
        params: .array([.string("0x" + Hex.encode(rawTransaction))]))
    } catch {
      record.status = .failed
      record.error = Self.transportError
      try await store.insert(record)
      throw WalletError.rpc(Self.transportError)
    }
    switch response {
    case .result(.string(let transactionHash)) where Hex.data(transactionHash)?.count == 32:
      let expectedHash = "0x" + Hex.encode(Keccak.keccak256(rawTransaction))
      guard transactionHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
        let error = JSONValue.object([
          "code": .number(-32603),
          "message": .string("RPC returned a mismatched transaction hash"),
        ])
        record.status = .failed
        record.error = error
        try await store.insert(record)
        throw WalletError.rpc(error)
      }
      if let nonce = Self.transactionObject(record.resolvedParams ?? record.params)?["nonce"]?
        .stringValue
      {
        try? await activityStore.recordTransaction(
          request: record, hash: expectedHash, nonce: nonce)
      }
      return .string(expectedHash)
    case .result:
      let error = JSONValue.object([
        "code": .number(-32603),
        "message": .string("Invalid eth_sendRawTransaction result"),
      ])
      record.status = .failed
      record.error = error
      try await store.insert(record)
      throw WalletError.rpc(error)
    case .error(let error):
      record.status = .failed
      record.error = error
      try await store.insert(record)
      throw WalletError.rpc(error)
    }
  }

  private static let transportError = JSONValue.object([
    "code": .number(-32000),
    "message": .string("RPC transport failure"),
  ])

  public func activities(limit: Int = 100) async throws -> [ActivityRecord] {
    try await activityStore.activities(limit: limit)
  }

  public func activities(for site: ConnectedSite, limit: Int = 100) async throws
    -> [ActivityRecord]
  {
    try await activityStore.activities(for: site, limit: limit)
  }

  /// Refreshes unresolved transactions through the same resolver used for preparation and
  /// broadcast. A missing receipt is not treated as failure while the node still knows the
  /// transaction or while propagation is within the grace period.
  public func refreshTransactionActivity(
    now: Date = Date(), missingGracePeriod: TimeInterval = 60
  ) async {
    guard let unresolved = try? await activityStore.unresolvedTransactions() else { return }
    for activity in unresolved {
      guard let hash = activity.transactionHash else { continue }
      let receipt = await rpcResult(
        method: "eth_getTransactionReceipt", params: .array([.string(hash)]),
        chainID: activity.chainID)
      if case .object(let object)? = receipt,
        let receiptStatus = object["status"]?.stringValue
      {
        let status: ActivityStatus = receiptStatus == "0x1" ? .confirmed : .reverted
        try? await activityStore.updateTransaction(
          hash: hash, status: status, blockNumber: object["blockNumber"]?.stringValue,
          at: now)
        continue
      }
      guard receipt == .null else { continue }

      let transaction = await rpcResult(
        method: "eth_getTransactionByHash", params: .array([.string(hash)]),
        chainID: activity.chainID)
      if case .object? = transaction {
        try? await activityStore.updateTransaction(hash: hash, status: .pending, at: now)
        continue
      }
      guard transaction == .null,
        now.timeIntervalSince(activity.createdAt) >= missingGracePeriod,
        let nonce = activity.nonce
      else { continue }

      let latestNonce = await rpcResult(
        method: "eth_getTransactionCount",
        params: .array([.string(activity.account), .string("latest")]),
        chainID: activity.chainID)?.stringValue
      let status: ActivityStatus
      if let latestNonce, Self.quantity(latestNonce, isGreaterThan: nonce) {
        status = .replaced
      } else {
        status = .dropped
      }
      try? await activityStore.updateTransaction(hash: hash, status: status, at: now)
    }
  }

  private func rpcResult(method: String, params: JSONValue, chainID: String) async -> JSONValue? {
    guard
      let response = try? await rpcClient.call(
        url: resolver.resolve(chainID: chainID), method: method, params: params)
    else { return nil }
    guard case .result(let value) = response else { return nil }
    return value
  }

  private static func transactionObject(_ params: JSONValue) -> [String: JSONValue]? {
    guard case .array(let items) = params, case .object(let object)? = items.first else {
      return nil
    }
    return object
  }

  private static func quantity(_ lhs: String, isGreaterThan rhs: String) -> Bool {
    guard let left = Hex.quantityData(hex: lhs), let right = Hex.quantityData(hex: rhs) else {
      return false
    }
    let normalizedLeft = RLP.trimQuantity(left)
    let normalizedRight = RLP.trimQuantity(right)
    if normalizedLeft.count != normalizedRight.count {
      return normalizedLeft.count > normalizedRight.count
    }
    return normalizedRight.lexicographicallyPrecedes(normalizedLeft)
  }

  private static func chainQuantity(_ raw: String) throws -> String {
    let value: Int?
    if raw.lowercased().hasPrefix("0x") {
      value = Int(raw.dropFirst(2), radix: 16)
    } else {
      value = Int(raw)
    }
    guard let value, value > 0 else { throw WalletError.invalidParams }
    return "0x" + String(value, radix: 16)
  }

  private static func maximumQuantity(_ lhs: String, _ rhs: String) throws -> String {
    guard let left = Hex.quantityData(hex: lhs), let right = Hex.quantityData(hex: rhs) else {
      throw WalletError.invalidParams
    }
    let normalizedLeft = RLP.trimQuantity(left)
    let normalizedRight = RLP.trimQuantity(right)
    if normalizedLeft.count != normalizedRight.count {
      return normalizedLeft.count > normalizedRight.count ? lhs : rhs
    }
    return normalizedLeft.lexicographicallyPrecedes(normalizedRight) ? rhs : lhs
  }

  private static func validatePreparedTransaction(
    _ params: JSONValue, account: String, chainID: String
  ) throws {
    guard case .array(let items) = params, items.count == 1,
      case .object(let transaction) = items[0]
    else { throw WalletError.invalidParams }
    let supportedFields: Set<String> = [
      "from", "to", "value", "data", "gas", "gasPrice", "nonce", "chainId", "type",
      "maxFeePerGas", "maxPriorityFeePerGas", "accessList",
    ]
    guard transaction.keys.allSatisfy(supportedFields.contains),
      transaction["from"]?.stringValue?.caseInsensitiveCompare(account) == .orderedSame,
      let transactionChainID = transaction["chainId"]?.stringValue,
      try chainQuantity(transactionChainID) == chainQuantity(chainID),
      transaction["value"]?.stringValue != nil,
      transaction["data"]?.stringValue != nil,
      transaction["gas"]?.stringValue != nil,
      transaction["nonce"]?.stringValue != nil
    else { throw WalletError.invalidParams }

    if let to = transaction["to"] {
      guard to.stringValue != nil || to == .null else { throw WalletError.invalidParams }
    }
    if let type = transaction["type"] {
      guard type.stringValue != nil else { throw WalletError.invalidParams }
    }

    let type = transaction["type"]?.stringValue?.lowercased()
    let dynamic =
      type == "0x2" || transaction["maxFeePerGas"] != nil
      || transaction["maxPriorityFeePerGas"] != nil
    if dynamic {
      guard type == "0x2", transaction["gasPrice"] == nil,
        transaction["accessList"] == nil || transaction["accessList"] == .array([]),
        let maxFee = transaction["maxFeePerGas"]?.stringValue,
        let priorityFee = transaction["maxPriorityFeePerGas"]?.stringValue,
        try maximumQuantity(maxFee, priorityFee) == maxFee
      else { throw WalletError.invalidParams }
    } else {
      guard type == nil, transaction["accessList"] == nil,
        transaction["gasPrice"]?.stringValue != nil
      else { throw WalletError.invalidParams }
    }
  }

  private static func validateTransactionIntent(
    _ params: JSONValue, account: String, chainID: String
  ) throws {
    guard case .array(let items) = params, items.count == 1,
      case .object(let transaction) = items[0]
    else { throw WalletError.invalidParams }
    let supportedFields: Set<String> = [
      "from", "to", "value", "data", "gas", "gasPrice", "nonce", "chainId", "type",
      "maxFeePerGas", "maxPriorityFeePerGas", "accessList",
    ]
    guard transaction.keys.allSatisfy(supportedFields.contains),
      transaction["from"]?.stringValue?.caseInsensitiveCompare(account) == .orderedSame,
      let transactionChainID = transaction["chainId"]?.stringValue,
      try chainQuantity(transactionChainID) == chainQuantity(chainID),
      let value = transaction["value"]?.stringValue, Hex.quantityData(hex: value) != nil,
      let data = transaction["data"]?.stringValue, Hex.data(data) != nil
    else { throw WalletError.invalidParams }

    if let to = transaction["to"] {
      guard to == .null || to.stringValue.flatMap(Hex.data)?.count == 20 else {
        throw WalletError.invalidParams
      }
    }
    for field in ["gas", "gasPrice", "nonce", "maxFeePerGas", "maxPriorityFeePerGas"] {
      if let value = transaction[field] {
        guard let quantity = value.stringValue, Hex.quantityData(hex: quantity) != nil else {
          throw WalletError.invalidParams
        }
      }
    }

    let type = transaction["type"]?.stringValue?.lowercased()
    let dynamic =
      type == "0x2" || transaction["maxFeePerGas"] != nil
      || transaction["maxPriorityFeePerGas"] != nil
    if dynamic {
      guard type == "0x2", transaction["gasPrice"] == nil,
        transaction["accessList"] == nil || transaction["accessList"] == .array([])
      else { throw WalletError.invalidParams }
      if let maxFee = transaction["maxFeePerGas"]?.stringValue,
        let priorityFee = transaction["maxPriorityFeePerGas"]?.stringValue
      {
        guard try maximumQuantity(maxFee, priorityFee) == maxFee else {
          throw WalletError.invalidParams
        }
      }
    } else {
      guard type == nil, transaction["accessList"] == nil else {
        throw WalletError.invalidParams
      }
    }
  }

  public func reject(request: UUID, profileID: String? = nil) async throws {
    guard try await store.record(request) != nil else { throw WalletError.notFound }
    guard let claim = store.claim(request) else { throw WalletError.alreadyConsumed }
    defer { store.releaseClaim(claim) }
    guard let record = try await store.record(request) else { throw WalletError.notFound }
    guard record.profileID == profileID else { throw WalletError.bindingMismatch }
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
