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
    case .siwe: return "Sign in with Ethereum"
    case .message: return "Sign message"
    case .typedData: return "Sign typed data"
    case .send: return "Send transaction"
    case .batch: return "Send calls"
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
    case .siwe:
      rows.append(("Account", request.account))
      guard case .object(let params) = request.params else { break }
      for (key, label) in [
        ("domain", "Domain"), ("scheme", "Scheme"), ("uri", "URI"),
        ("version", "Version"), ("chainId", "Chain"), ("nonce", "Nonce"),
        ("issuedAt", "Issued At"),
        ("expirationTime", "Expiration Time"), ("notBefore", "Not Before"),
        ("requestId", "Request ID"), ("statement", "Statement"),
      ] {
        if let value = params[key]?.stringValue { rows.append((label, value)) }
      }
      if case .array(let resources)? = params["resources"] {
        rows.append(("Resources", resources.compactMap(\.stringValue).joined(separator: "\n")))
      }
      if let message = params["message"]?.stringValue { rows.append(("Message", message)) }
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
          rows.append(("Data", data))
        }
      }
    case .batch:
      rows.append(("Account", request.account))
      rows.append(("Chain", request.chainId))
      rows.append(("Origin", request.origin))
      if case .object(let params) = request.params, case .array(let calls)? = params["calls"] {
        rows.append(("Calls", String(calls.count)))
        for (index, value) in calls.enumerated() {
          guard case .object(let call) = value else { continue }
          let target = call["to"]?.stringValue ?? "Unavailable"
          let amount = call["value"]?.stringValue ?? "0x0"
          let data = call["data"]?.stringValue ?? "0x"
          rows.append(("Call \(index + 1) Target", target))
          rows.append(("Call \(index + 1) Value", amount))
          rows.append(("Call \(index + 1) Data", data))
        }
      }
    case .chain:
      if let id = Self.addedChainID(request.params) { rows.append(("Chain ID", id)) }
      if let name = Self.addedChainName(request.params) { rows.append(("Name", name)) }
      if let url = Self.addedChainRPCURL(request.params) {
        rows.append(("Fallback RPC URL", url))
      }
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

  private static func addedChainRPCURL(_ params: JSONValue) -> String? {
    guard let object = firstObjectAny(params), case .array(let urls)? = object["rpcUrls"] else {
      return nil
    }
    return urls.first?.stringValue
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

}

/// Orchestrates wallet-owned RPC handling and the canonical approval lifecycle.
/// Signing is injected behind `Signing` so hermetic tests use a deterministic stub and
/// production uses `KeychainSigner` backed by the shared keychain.
public actor WalletService {
  public nonisolated let store: PendingRequestStore
  public nonisolated let signing: any Signing
  public nonisolated let accountResolver: any AccountResolving
  nonisolated let enforcesConnectedAccountPolicy: Bool
  public nonisolated let connectedSites: ConnectedSitesStore
  public nonisolated let chainStore: ChainStore
  public nonisolated let networkStore: NetworkStore
  public nonisolated let activityStore: ActivityStore
  nonisolated let resolver: RPCResolver
  nonisolated let rpcClient: RPCClient
  nonisolated let rpcOverrideStore: RPCOverrideStore
  nonisolated let deploymentStore: Simple7702AccountDeploymentStore
  nonisolated let submissionLock: TransactionSubmissionLock
  nonisolated let simple7702AccountRuntimeHash: String
  /// Optional registry authority. When set, request handling fails closed until the
  /// registry validates as `.complete` and retained pending legacy-binding records are
  /// terminalized instead of signed. `nil` keeps hermetic single-account behavior.
  nonisolated let registryStore: WalletRegistryStore?
  nonisolated let groupLifecycle: WalletGroupLifecycleCoordinator

  public init(
    store: PendingRequestStore? = nil,
    signing: any Signing,
    connectedSites: ConnectedSitesStore? = nil,
    chainStore: ChainStore = ChainStore(),
    networkStore: NetworkStore = NetworkStore(),
    activityStore: ActivityStore = ActivityStore(),
    resolver: RPCResolver = RPCResolver(),
    rpcClient: RPCClient = RPCClient(),
    rpcOverrideStore: RPCOverrideStore = RPCOverrideStore(),
    deploymentStore: Simple7702AccountDeploymentStore = Simple7702AccountDeploymentStore(),
    submissionLock: TransactionSubmissionLock? = nil,
    simple7702AccountRuntimeHash: String = EIP5792.simple7702AccountRuntimeHash,
    registryStore: WalletRegistryStore? = nil,
    accountResolver: (any AccountResolving)? = nil
  ) {
    self.signing = signing
    self.accountResolver = accountResolver ?? InjectedAccountResolver(signing: signing)
    self.enforcesConnectedAccountPolicy = accountResolver != nil
    let resolvedStore = store ?? PendingRequestStore()
    self.store = resolvedStore
    self.connectedSites = connectedSites ?? ConnectedSitesStore()
    self.chainStore = chainStore
    self.networkStore = networkStore
    self.activityStore = activityStore
    self.resolver = resolver
    self.rpcClient = rpcClient
    self.rpcOverrideStore = rpcOverrideStore
    self.deploymentStore = deploymentStore
    self.submissionLock =
      submissionLock ?? TransactionSubmissionLock(directory: resolvedStore.directory)
    self.simple7702AccountRuntimeHash = simple7702AccountRuntimeHash
    self.registryStore = registryStore
    self.groupLifecycle = WalletGroupLifecycleCoordinator(
      directory: resolvedStore.directory.deletingLastPathComponent())
  }

  /// Hermetic-test initializer that also isolates the connection-grant store.
  public init(
    store: PendingRequestStore?,
    signing: any Signing,
    grantsSuite: String
  ) {
    self.signing = signing
    self.accountResolver = InjectedAccountResolver(signing: signing)
    self.enforcesConnectedAccountPolicy = false
    self.store = store ?? PendingRequestStore()
    let chainDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ChainStore-\(grantsSuite)")
    try? FileManager.default.createDirectory(
      at: chainDirectory, withIntermediateDirectories: true)
    _ = try? ConnectionStateStore(directory: chainDirectory, suiteName: grantsSuite)
      .getOrCreate(ConnectionState(revision: 0))
    self.connectedSites = ConnectedSitesStore(suiteName: grantsSuite, directory: chainDirectory)
    self.chainStore = ChainStore(directory: chainDirectory)
    self.networkStore = NetworkStore(
      directory: chainDirectory, legacySuiteName: grantsSuite)
    self.activityStore = ActivityStore(
      databaseURL: chainDirectory.appendingPathComponent("Activity.sqlite"))
    self.resolver = RPCResolver()
    self.rpcClient = RPCClient()
    self.rpcOverrideStore = RPCOverrideStore(directory: chainDirectory)
    self.deploymentStore = Simple7702AccountDeploymentStore(directory: chainDirectory)
    self.submissionLock = TransactionSubmissionLock(directory: chainDirectory)
    self.simple7702AccountRuntimeHash = EIP5792.simple7702AccountRuntimeHash
    self.registryStore = nil
    self.groupLifecycle = WalletGroupLifecycleCoordinator(directory: chainDirectory)
  }

  // MARK: Connection grants

  /// Whether this origin already has a connection grant to the active account.
  public nonisolated func isConnected(origin: String, profileID: String? = nil) async throws -> Bool
  {
    try await connectedSites.visibleAccount(origin: origin, profileID: profileID) != nil
  }

  /// Atomically resolves the account array visible to one provider origin/profile.
  public nonisolated func visibleAccounts(origin: String, profileID: String? = nil) async throws
    -> [String]
  {
    guard
      let account = try await connectedSites.visibleAccount(origin: origin, profileID: profileID),
      let signer = try? accountResolver.signer(address: account), signer.hasKey()
    else { return [] }
    return [signer.account]
  }

  /// Persisted connection grants for the current account.
  public func connectedSitesList() async throws -> [ConnectedSite] {
    try await connectedSites.grants(account: signing.account)
  }

  /// Grants a connection and binds it to the active account. Idempotent.
  public func connect(origin: String, profileID: String? = nil) async throws {
    try await connectedSites.connect(
      site: ConnectedSite(
        domain: Origin.downHost(of: origin),
        address: signing.account,
        origin: origin,
        profileID: profileID)
    )
  }

  /// Revokes a connection. Idempotent.
  public func disconnect(origin: String, profileID: String? = nil) async throws {
    guard
      let account = try await connectedSites.visibleAccount(origin: origin, profileID: profileID)
    else { return }
    try await connectedSites.disconnect(
      account: account, origin: origin, profileID: profileID)
  }

  public nonisolated var account: String { signing.account }

  /// Fail-closed adoption barrier. When a registry authority is supplied, request
  /// handling is refused while the registry is `.migrating` (mapped to notReady) or
  /// corrupt. An absent registry also fails closed; only no registryStore uses ordinary behavior.
  private func ensureRegistryReady() throws {
    guard let registryStore else { return }
    do {
      guard try registryStore.loadReady() != nil else { throw WalletError.notReady }
    } catch {
      throw WalletError.notReady
    }
  }

  private nonisolated func connectedSigner(
    origin: String, profileID: String?, exactOnly: Bool = false
  ) async throws -> any Signing {
    guard
      let account = try await connectedSites.visibleAccount(
        origin: origin, profileID: profileID, exactOnly: exactOnly)
    else { throw WalletError.unauthorized }
    guard let signer = try? accountResolver.signer(address: account), signer.hasKey() else {
      throw WalletError.notReady
    }
    return signer
  }

  private static func validateStandardAccountParameter(
    method: String, params: JSONValue, account: String
  ) throws {
    let method = method.lowercased()
    let supplied: String?
    switch method {
    case "personal_sign":
      guard case .array(let values) = params, values.count == 2,
        values[0].stringValue != nil, let address = values[1].stringValue
      else { throw WalletError.invalidParams }
      supplied = address
    case "eth_signtypeddata_v4":
      guard case .array(let values) = params, values.count == 2,
        let address = values[0].stringValue, values[1].stringValue != nil
      else { throw WalletError.invalidParams }
      supplied = address
    default:
      return
    }
    guard supplied?.caseInsensitiveCompare(account) == .orderedSame else {
      throw WalletError.invalidParams
    }
  }

  private static func requestComesBefore(_ lhs: WalletPendingRequest, _ rhs: WalletPendingRequest)
    -> Bool
  {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
  }

  public struct ActiveChainState: Sendable {
    public let chainID: String
    public let recoveredSwitch: Bool
  }

  public func activeChainState() async throws -> ActiveChainState {
    try ensureRegistryReady()
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
    _ = try await connectedSigner(origin: origin, profileID: profileID)
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
    public let accountLabel: String?
    public let title: String
    public let rows: [(label: String, value: String)]
    public let queued: Bool
    public let revision: UInt64
  }

  public struct AvailableAccount: Sendable, Equatable {
    public let address: String
    public let derivationIndex: UInt32?
  }

  public struct AvailableAccountGroup: Sendable, Equatable {
    public let id: UUID
    public let kind: WalletGroupKind
    public let accounts: [AvailableAccount]
  }

  /// Public registered accounts whose exact protected source is currently available.
  public func availableAccountGroups() throws -> [AvailableAccountGroup] {
    guard let registryStore, let registry = try registryStore.loadReady() else {
      throw WalletError.notReady
    }
    return registry.groups.compactMap { group in
      guard group.lifecycle == .active else { return nil }
      let accounts = group.accounts.compactMap { account -> AvailableAccount? in
        guard account.lifecycle == .active else { return nil }
        guard let signer = try? accountResolver.signer(address: account.address), signer.hasKey()
        else { return nil }
        return AvailableAccount(address: account.address, derivationIndex: account.derivationIndex)
      }
      guard !accounts.isEmpty else { return nil }
      return AvailableAccountGroup(id: group.id, kind: group.kind, accounts: accounts)
    }
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
    profileID: String? = nil,
    requestKey: String? = nil
  ) async throws -> UUID {
    try ensureRegistryReady()
    let chainId = try await activeChainID()
    var kind = RequestKind.kind(for: method)
    guard MethodPolicy.requiresApproval(method) else { throw WalletError.methodNotApproved }
    let methodName = method.lowercased()
    let isSIWE = methodName == "wallet_connect" && Self.hasSIWECapability(params)
    if methodName == "wallet_connect", !isSIWE, Self.hasCapabilities(params) {
      throw WalletError.invalidParams
    }
    let requestSigner: any Signing
    if enforcesConnectedAccountPolicy, kind == .connect, !isSIWE {
      requestSigner = try proposedConnectionSigner()
    } else if !enforcesConnectedAccountPolicy || (kind == .connect && !isSIWE) {
      guard signing.hasKey() else { throw WalletError.notReady }
      requestSigner = signing
    } else {
      requestSigner = try await connectedSigner(
        origin: origin, profileID: profileID, exactOnly: kind == .batch)
    }
    let account = requestSigner.account
    if enforcesConnectedAccountPolicy {
      try Self.validateStandardAccountParameter(method: method, params: params, account: account)
    }

    let canonicalParams: JSONValue
    var recordChainID = chainId
    if isSIWE {
      let prepared = try SIWE.prepare(params: params, account: account, origin: origin)
      kind = .siwe
      canonicalParams = prepared.params
      recordChainID = prepared.chainID
    } else if kind == .batch {
      guard (try? networkStore.network(chainID: chainId)) != nil else {
        throw Self.walletError(.unsupportedChain)
      }
      do {
        canonicalParams = try EIP5792.prepare(
          params: params, account: account, activeChainID: chainId
        ).params
      } catch let error as EIP5792Error {
        throw Self.walletError(error)
      }
      if case .object(let object) = canonicalParams,
        let requestedID = object["id"]?.stringValue
      {
        let duplicateActivity =
          (try? await activityStore.callBundle(
            id: requestedID, origin: origin, profileID: profileID, account: account)) != nil
        guard !duplicateActivity else {
          throw Self.walletError(.duplicateID)
        }
      }
    } else if kind == .send {
      canonicalParams = try canonicalizeTransaction(
        params: params, account: account, chainID: chainId)
    } else {
      canonicalParams = params
    }
    if kind == .chain, Self.requestedChainID(canonicalParams) == nil {
      throw WalletError.invalidParams
    }
    let normalizedOrigin = Origin.normalize(origin)
    let intentDigest = CanonicalRequest.intentDigestV2(
      method: method, origin: normalizedOrigin, chainId: recordChainID,
      profileID: profileID, params: kind == .siwe ? params : canonicalParams)
    let id = UUID()
    let createdAt = Date()
    let expiresAt = createdAt.addingTimeInterval(600)
    let payloadDigest = CanonicalRequest.bindingDigestV2(
      requestID: id,
      kind: kind,
      method: method,
      origin: normalizedOrigin,
      profileID: profileID,
      chainId: recordChainID,
      account: account,
      params: canonicalParams,
      createdAt: createdAt,
      expiresAt: expiresAt)
    let record = WalletPendingRequest(
      id: id,
      kind: kind,
      method: method,
      origin: normalizedOrigin,
      profileID: profileID,
      chainId: recordChainID,
      account: account,
      params: canonicalParams,
      payloadDigest: payloadDigest,
      intentDigest: intentDigest,
      requestKey: requestKey,
      bindingVersion: 2,
      revision: 0,
      createdAt: createdAt,
      expiresAt: expiresAt
    )
    if kind == .send {
      do {
        try Self.validateTransactionIntent(
          record.params, account: record.account, chainID: record.chainId)
      } catch {
        throw WalletError.invalidParams
      }
    }
    let callBundleID: String?
    if kind == .batch, case .object(let params) = canonicalParams {
      callBundleID = params["id"]?.stringValue
    } else {
      callBundleID = nil
    }
    do {
      return
        (try await store.insertIfAbsent(record, rejectingCallBundleID: callBundleID)) ?? record.id
    } catch PendingRequestStoreError.duplicateCallBundleID {
      throw Self.walletError(.duplicateID)
    } catch PendingRequestStoreError.conflictingRequestKey {
      throw WalletError.invalidParams
    }
  }

  private func proposedConnectionSigner() throws -> any Signing {
    guard let registryStore else { throw WalletError.notReady }
    let account = try registryStore.withLockedReady { registry in
      try connectedSites.connectionStore.withLockedState { state in
        try state.validate(against: registry)
        return state.defaultAccount ?? registry.homeSelectedAddress
          ?? registry.groups
          .filter { $0.lifecycle == .active }
          .flatMap(\.accounts)
          .first(where: { $0.lifecycle == .active })?.address
      }
    }
    guard let account, let signer = try? accountResolver.signer(address: account), signer.hasKey()
    else { throw WalletError.notReady }
    return signer
  }

  /// Display-safe canonical summary for one pending request.
  public func summarize(request: UUID, profileID: String? = nil) async throws -> Summary? {
    _ = try ensureRegistryReady()
    guard let record = try await store.record(request) else { return nil }
    guard record.profileID == profileID else { return nil }
    guard record.bindingVersion == 2 else { return nil }
    return await makeSummary(record)
  }

  /// Summaries for all pending records, oldest first (queue order) with the active head.
  public func list(profileID: String? = nil) async throws -> [Summary] {
    _ = try ensureRegistryReady()
    let pending =
      (try await store.pending()).filter { $0.profileID == profileID }.sorted(
        by: Self.requestComesBefore)
    var summaries: [Summary] = []
    for record in pending where record.bindingVersion == 2 {
      summaries.append(await makeSummary(record))
    }
    return summaries
  }

  private func makeSummary(_ record: WalletPendingRequest) async -> Summary {
    var active = false
    if let queue = try? await store.pending().sorted(by: Self.requestComesBefore) {
      active = queue.first?.id == record.id
    }
    var rows = ApprovalSummary.rows(for: record).map { row in
      switch row.0 {
      case "Chain": return (row.0, chainDisplayName(record.chainId))
      case "Domain Chain": return (row.0, chainDisplayName(row.1))
      case "Chain ID": return (row.0, ChainStore.normalize(row.1) ?? row.1)
      case "Value": return (row.0, Self.displayValue(row.1, chainID: record.chainId))
      case let label where label.hasPrefix("Call ") && label.hasSuffix(" Value"):
        return (row.0, Self.displayValue(row.1, chainID: record.chainId))
      default: return row
      }
    }
    if record.kind == .batch, let value = Self.batchValue(record.params, chainID: record.chainId) {
      let chainIndex = rows.firstIndex { $0.0 == "Chain" }.map { rows.index(after: $0) }
      rows.insert(("Value", value), at: chainIndex ?? rows.endIndex)
    }
    if record.kind == .send || record.kind == .batch {
      rows.append(("Network Fee", await estimatedNetworkFee(for: record)))
    }
    return Summary(
      id: record.id.uuidString,
      kind: record.kind.rawValue,
      method: record.method,
      origin: record.origin,
      chainId: record.chainId,
      account: record.account,
      accountLabel: accountLabel(for: record.account),
      title: ApprovalSummary.title(for: record),
      rows: rows,
      queued: !active,
      revision: record.revision
    )
  }

  /// The current editable display label for an account, or nil when the registry
  /// does not resolve it. Labels are non-authoritative review metadata and never
  /// enter canonical request identity.
  private func accountLabel(for address: String) -> String? {
    guard let registryStore, let registry = try? registryStore.loadReady() else { return nil }
    return registry.groups.lazy.flatMap(\.accounts).first {
      $0.address.caseInsensitiveCompare(address) == .orderedSame
    }?.label
  }

  /// Rebinds only the globally active plain-connect request to an existing available account.
  public func rebindConnect(
    request: UUID,
    account: String,
    reviewedRevision: UInt64,
    profileID: String? = nil
  ) throws {
    try ensureRegistryReady()
    guard let registryStore, let initialRegistry = try registryStore.loadReady(),
      let selectedGroup = initialRegistry.groups.first(where: { group in
        group.lifecycle == .active
          && group.accounts.contains {
            $0.lifecycle == .active
              && $0.address.caseInsensitiveCompare(account) == .orderedSame
          }
      }),
      let selectedAccount = selectedGroup.accounts.first(where: {
        $0.lifecycle == .active && $0.address.caseInsensitiveCompare(account) == .orderedSame
      })
    else { throw WalletError.bindingMismatch }

    try groupLifecycle.withClaim(groupID: selectedGroup.id) {
      guard let claim = store.claim(request) else { throw WalletError.alreadyConsumed }
      defer { store.releaseClaim(claim) }
      guard var record = try rawRecord(request) else { throw WalletError.notFound }
      if try reconcileConnectCommit(request: request, record: record) != nil {
        throw WalletError.alreadyConsumed
      }
      guard record.kind == .connect, Self.isPlainConnect(record), record.bindingVersion == 2,
        record.profileID == profileID, record.status == .pending, !record.isExpired,
        record.revision == reviewedRevision, record.revision < UInt64.max
      else { throw WalletError.bindingMismatch }
      let queue = try rawPendingQueue()
      guard queue.first?.id == record.id else { throw WalletError.queued }
      guard
        try registryStore.withLockedReady({ registry in
          registry.groups.contains { group in
            group.id == selectedGroup.id && group.lifecycle == .active
              && group.accounts.contains {
                $0.lifecycle == .active && $0.address == selectedAccount.address
              }
          }
        }),
        let signer = try? accountResolver.signer(address: selectedAccount.address), signer.hasKey()
      else { throw WalletError.bindingMismatch }

      record = WalletPendingRequest(
        id: record.id, kind: record.kind, method: record.method, origin: record.origin,
        profileID: record.profileID, chainId: record.chainId, account: selectedAccount.address,
        params: record.params,
        payloadDigest: CanonicalRequest.bindingDigestV2(
          requestID: record.id, kind: record.kind, method: record.method, origin: record.origin,
          profileID: record.profileID, chainId: record.chainId, account: selectedAccount.address,
          params: record.params, createdAt: record.createdAt, expiresAt: record.expiresAt),
        intentDigest: record.intentDigest, requestKey: record.requestKey,
        bindingVersion: record.bindingVersion, revision: record.revision + 1,
        resolvedParams: record.resolvedParams, createdAt: record.createdAt,
        expiresAt: record.expiresAt, status: record.status, result: record.result,
        error: record.error)
      try store.persistForLifecycleCleanup(record)
    }
  }

  private func estimatedNetworkFee(for record: WalletPendingRequest) async -> String {
    if record.kind == .batch {
      guard let calldata = try? EIP5792.executeBatchCalldata(record.params) else {
        return "Unable to estimate"
      }
      do {
        let implementationCode: [UInt8]
        if let verifiedCode = try await verifiedImplementationCode(chainID: record.chainId) {
          implementationCode = verifiedCode
        } else if simple7702AccountRuntimeHash.caseInsensitiveCompare(
          EIP5792.simple7702AccountRuntimeHash) == .orderedSame,
          let reviewedCode = Simple7702AccountDeployment.runtimeCode
        {
          implementationCode = reviewedCode
        } else {
          return "Unable to estimate"
        }
        let code = try await rpcData(
          method: "eth_getCode", params: .array([.string(record.account), .string("latest")]),
          chainID: record.chainId)
        let needsAuthorization: Bool
        if code.isEmpty {
          needsAuthorization = true
        } else if Self.isCanonicalDelegation(code) {
          needsAuthorization = false
        } else {
          return "Unable to estimate"
        }
        var estimateParams: [JSONValue] = [
          .object([
            "from": .string(record.account), "to": .string(record.account),
            "value": .string("0x0"), "data": .string(calldata),
          ])
        ]
        var accountOverride: [String: JSONValue] = [
          "balance": .string("0x" + String(repeating: "f", count: 64))
        ]
        if needsAuthorization {
          accountOverride["code"] = .string("0x" + Hex.encode(implementationCode))
        }
        estimateParams.append(.string("latest"))
        estimateParams.append(.object([record.account: .object(accountOverride)]))
        let estimate = try await rpcQuantity(
          method: "eth_estimateGas", params: .array(estimateParams), chainID: record.chainId)
        guard let gas = Self.safeBatchGas(estimate, needsAuthorization: needsAuthorization),
          let gasBytes = Hex.quantityData(hex: gas)
        else { return "Unable to estimate" }
        let fee = try await rpcQuantity(
          method: "eth_gasPrice", params: .array([]), chainID: record.chainId)
        guard let feeBytes = Hex.quantityData(hex: fee) else { return "Unable to estimate" }
        let amount = NativeBalanceService.formatEther(bytes: Self.multiply(gasBytes, feeBytes))
        return "~\(amount) \(Self.nativeCurrencySymbol(chainID: record.chainId))"
      } catch {
        return "Unable to estimate"
      }
    }
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

  private static func displayValue(_ quantity: String, chainID: String) -> String {
    guard let bytes = Hex.quantityData(hex: quantity) else { return quantity }
    let amount = NativeBalanceService.formatEther(bytes: bytes)
      .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    return "\(amount) \(nativeCurrencySymbol(chainID: chainID))"
  }

  private static func batchValue(_ params: JSONValue, chainID: String) -> String? {
    guard case .object(let object) = params, case .array(let calls) = object["calls"] else {
      return nil
    }
    var total: [UInt8] = [0]
    for value in calls {
      guard case .object(let call) = value,
        let quantity = call["value"]?.stringValue,
        let bytes = Hex.quantityData(hex: quantity)
      else { return nil }
      total = NativeBalanceService.add(total, bytes)
    }
    let amount = NativeBalanceService.formatEther(bytes: total)
      .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    return "\(amount) \(nativeCurrencySymbol(chainID: chainID))"
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

  private nonisolated func rawRecord(_ id: UUID) throws -> WalletPendingRequest? {
    try store.retainedRecordsForClaimedTransition().first { $0.id == id }
  }

  private nonisolated func rawPendingQueue() throws -> [WalletPendingRequest] {
    try store.retainedRecordsForClaimedTransition()
      .filter { $0.status == .pending && !$0.isExpired }
      .sorted(by: Self.requestComesBefore)
  }

  private nonisolated func transitionAccount(
    request: UUID, record: WalletPendingRequest?
  ) throws -> String? {
    if let account = try connectMarkerAccount(request: request) { return account }
    return record?.account
  }

  private nonisolated func connectMarkerAccount(request: UUID) throws -> String? {
    do {
      return try connectedSites.connectionStore.withLockedState { state in
        state.connectCommits.first { $0.requestID == request }?.account
      }
    } catch ConnectionStateError.missing {
      return nil
    }
  }

  private nonisolated func withGroupClaim<T>(
    account: String?, operation: () throws -> T
  ) throws -> T {
    guard let registryStore else { return try operation() }
    guard let account, let registry = try registryStore.loadReady(),
      let group = registry.groups.first(where: { group in
        group.lifecycle == .active
          && group.accounts.contains {
            $0.lifecycle == .active
              && $0.address.caseInsensitiveCompare(account) == .orderedSame
          }
      })
    else { throw WalletError.bindingMismatch }
    return try groupLifecycle.withClaim(groupID: group.id, operation: operation)
  }

  private nonisolated func reconcileConnectCommit(
    request: UUID, record: WalletPendingRequest?
  ) throws -> (record: WalletPendingRequest, result: JSONValue)? {
    let connectionStore = connectedSites.connectionStore
    let marker: ConnectCommit?
    do {
      marker = try connectionStore.withLockedState { state in
        state.connectCommits.first { $0.requestID == request }
      }
    } catch ConnectionStateError.missing {
      return nil
    }
    guard let marker else { return nil }
    guard var record, record.kind == .connect, Self.isPlainConnect(record),
      record.bindingVersion == 2, record.id == marker.requestID,
      record.revision == marker.requestRevision, record.origin == marker.origin,
      record.profileID == marker.profileID, record.account == marker.account,
      record.payloadDigest == marker.bindingDigest,
      CanonicalRequest.bindingDigestV2(
        requestID: record.id, kind: record.kind, method: record.method, origin: record.origin,
        profileID: record.profileID, chainId: record.chainId, account: record.account,
        params: record.params, createdAt: record.createdAt, expiresAt: record.expiresAt)
        == record.payloadDigest,
      record.status == .pending || (record.status == .consumed && record.result == marker.result)
    else { throw WalletError.bindingMismatch }

    if record.status == .pending {
      record.status = .consumed
      record.result = marker.result
      try store.persistForLifecycleCleanup(record)
    }
    guard let consumed = try rawRecord(request), consumed.status == .consumed,
      consumed.result == marker.result
    else { throw WalletError.bindingMismatch }
    _ = try connectionStore.mutate { state in
      guard let current = state.connectCommits.first(where: { $0.requestID == request }),
        current == marker
      else { throw WalletError.bindingMismatch }
      state.connectCommits.removeAll { $0.requestID == request }
    }
    return (consumed, marker.result)
  }

  private func approvePlainConnect(
    request: UUID, profileID: String?, reviewedRevision: UInt64
  ) throws -> JSONValue {
    let initial = try rawRecord(request)
    let account = try transitionAccount(request: request, record: initial)
    return try withGroupClaim(account: account) {
      guard let claim = store.claim(request) else { throw WalletError.alreadyConsumed }
      defer { store.releaseClaim(claim) }
      let raw = try rawRecord(request)
      if let recovered = try reconcileConnectCommit(request: request, record: raw) {
        guard recovered.record.profileID == profileID else { throw WalletError.bindingMismatch }
        return recovered.result
      }
      guard var record = raw else { throw WalletError.notFound }
      guard record.kind == .connect, Self.isPlainConnect(record), record.bindingVersion == 2,
        record.profileID == profileID, record.revision == reviewedRevision
      else { throw WalletError.bindingMismatch }
      guard record.status == .pending else { throw WalletError.alreadyConsumed }
      if record.isExpired {
        record.status = .expired
        try store.persistForLifecycleCleanup(record)
        throw WalletError.expired
      }
      guard try rawPendingQueue().first?.id == record.id else { throw WalletError.queued }
      guard Self.kindMatches(record),
        CanonicalRequest.bindingDigestV2(
          requestID: record.id, kind: record.kind, method: record.method, origin: record.origin,
          profileID: record.profileID, chainId: record.chainId, account: record.account,
          params: record.params, createdAt: record.createdAt, expiresAt: record.expiresAt)
          == record.payloadDigest,
        let signer = try? accountResolver.signer(address: record.account), signer.hasKey()
      else { throw WalletError.bindingMismatch }

      let result: JSONValue = .array([.string(record.account)])
      let commitConnection: (WalletRegistry?) throws -> Void = { registry in
        _ = try self.connectedSites.connectionStore.mutate { state in
          if let registry { try state.validate(against: registry) }
          guard !state.connectCommits.contains(where: { $0.requestID == record.id }) else {
            throw WalletError.bindingMismatch
          }
          let grant = ConnectionGrant(
            account: record.account, origin: record.origin,
            legacyDomain: Origin.downHost(of: record.origin), profileID: record.profileID,
            connectedAt: Date(), precision: .exact)
          state.grants.removeAll { $0.id == grant.id }
          state.grants.append(grant)
          state.activeConnections.removeAll {
            $0.origin == record.origin && $0.profileID == record.profileID
          }
          state.activeConnections.append(
            ActiveConnection(
              origin: record.origin, profileID: record.profileID, account: record.account))
          state.defaultAccount = record.account
          state.connectCommits.append(
            ConnectCommit(
              requestID: record.id, requestRevision: record.revision,
              connectionRevision: state.revision + 1, origin: record.origin,
              profileID: record.profileID, account: record.account,
              bindingDigest: record.payloadDigest, result: result, committedAt: Date()))
        }
      }
      if let registryStore {
        try registryStore.withLockedReady { registry in
          guard
            registry.groups.contains(where: { group in
              group.lifecycle == .active
                && group.accounts.contains {
                  $0.lifecycle == .active && $0.address == record.account
                }
            })
          else { throw WalletError.bindingMismatch }
          try commitConnection(registry)
        }
      } else {
        try commitConnection(nil)
      }

      record.status = .consumed
      record.result = result
      try store.persistForLifecycleCleanup(record)
      guard let recovered = try reconcileConnectCommit(request: request, record: record) else {
        throw WalletError.bindingMismatch
      }
      return recovered.result
    }
  }

  private static func isPlainConnect(_ record: WalletPendingRequest) -> Bool {
    record.kind == .connect
      && (record.method.lowercased() == "eth_requestaccounts"
        || record.method.lowercased() == "wallet_connect")
  }

  /// Persisted status so a suspending service worker and a polling page converge.
  public func status(for id: UUID, profileID: String? = nil) async -> RequestStatus? {
    guard (try? ensureRegistryReady()) != nil else { return nil }
    do {
      let initial = try rawRecord(id)
      let markerAccount = try connectMarkerAccount(request: id)
      if let initial, initial.status != .pending, markerAccount == nil {
        guard initial.profileID == profileID, initial.bindingVersion == 2 else { return nil }
        return RequestStatus(
          status: initial.status.rawValue, result: initial.result, error: initial.error)
      }
      let account = markerAccount ?? initial?.account
      guard initial != nil || account != nil else { return nil }
      return try withGroupClaim(account: account) {
        guard let claim = store.claim(id) else {
          // Approval and rejection hold the one-time claim while they authenticate and
          // persist their terminal result. A concurrent provider poll must keep waiting;
          // treating this short-lived contention as a missing request loses the result.
          guard let initial, initial.profileID == profileID, initial.bindingVersion == 2 else {
            return nil
          }
          return RequestStatus(
            status: initial.status.rawValue, result: initial.result, error: initial.error)
        }
        defer { store.releaseClaim(claim) }
        let raw = try rawRecord(id)
        if let recovered = try reconcileConnectCommit(request: id, record: raw) {
          guard recovered.record.profileID == profileID else { return nil }
          return RequestStatus(status: "consumed", result: recovered.result, error: nil)
        }
        guard var record = raw, record.profileID == profileID, record.bindingVersion == 2 else {
          return nil
        }
        if record.status == .pending && record.isExpired {
          record.status = .expired
          try store.persistForLifecycleCleanup(record)
        }
        return RequestStatus(
          status: record.status.rawValue, result: record.result, error: record.error)
      }
    } catch {
      return RequestStatus(
        status: "failed", result: nil,
        error: .object([
          "code": .number(-32603),
          "message": .string("Conflicting committed connection state"),
        ]))
    }
  }

  /// Approve the active head: verify binding, queue eligibility, expiry, recomputed
  /// digest, authenticate, then sign with the real account key and consume the record.
  public func approve(
    request: UUID, profileID: String? = nil, reviewedRevision: UInt64 = 0
  ) async throws -> JSONValue {
    _ = try ensureRegistryReady()
    let initial = try rawRecord(request)
    if initial == nil,
      try transitionAccount(request: request, record: nil) != nil
    {
      throw WalletError.bindingMismatch
    }
    guard let initial else { throw WalletError.notFound }
    if initial.kind == .connect, registryStore != nil {
      return try approvePlainConnect(
        request: request, profileID: profileID, reviewedRevision: reviewedRevision)
    }
    guard let claim = store.claim(request) else { throw WalletError.alreadyConsumed }
    defer { store.releaseClaim(claim) }

    guard try reconcileConnectCommit(request: request, record: initial) == nil else {
      throw WalletError.bindingMismatch
    }
    guard var record = try await store.record(request) else { throw WalletError.notFound }
    guard record.profileID == profileID else { throw WalletError.bindingMismatch }
    guard record.bindingVersion == 2 else { throw WalletError.bindingMismatch }
    guard record.revision == reviewedRevision else { throw WalletError.bindingMismatch }
    // store.record() normalizes an expired pending record to `.expired`.
    if record.status == .expired { throw WalletError.expired }
    guard record.status == .pending else { throw WalletError.alreadyConsumed }
    guard !record.isExpired else {
      record.status = .expired
      try await store.insert(record)
      throw WalletError.expired
    }
    // Queue policy: only the oldest pending request may be approved.
    let queue = (try await store.pending()).sorted(by: Self.requestComesBefore)
    guard queue.first?.id == record.id else { throw WalletError.queued }
    let activeChainID = try await activeChainID()
    guard record.kind == .siwe || record.chainId == activeChainID else {
      let rpcError = JSONValue.object([
        "code": .number(4901),
        "message": .string("Active chain changed before approval"),
      ])
      record.status = .failed
      record.error = rpcError
      try await store.insert(record)
      throw WalletError.rpc(rpcError)
    }
    let requestSigner: any Signing
    if record.kind == .connect || !enforcesConnectedAccountPolicy {
      do {
        requestSigner = try accountResolver.signer(address: record.account)
      } catch {
        throw WalletError.bindingMismatch
      }
      guard requestSigner.hasKey() else { throw WalletError.notReady }
    } else {
      do {
        requestSigner = try await connectedSigner(
          origin: record.origin, profileID: profileID, exactOnly: record.kind == .batch)
      } catch {
        let rpcError = JSONValue.object([
          "code": .number(4100),
          "message": .string("Connected account changed before approval"),
        ])
        record.status = .failed
        record.error = rpcError
        try await store.insert(record)
        throw WalletError.rpc(rpcError)
      }
      guard requestSigner.account.caseInsensitiveCompare(record.account) == .orderedSame else {
        let rpcError = JSONValue.object([
          "code": .number(4100),
          "message": .string("Connected account changed before approval"),
        ])
        record.status = .failed
        record.error = rpcError
        try await store.insert(record)
        throw WalletError.rpc(rpcError)
      }
    }
    guard Self.kindMatches(record) else {
      throw WalletError.bindingMismatch
    }
    // Recompute the account-inclusive digest over the reloaded canonical record.
    let digestNow = CanonicalRequest.bindingDigestV2(
      requestID: record.id,
      kind: record.kind,
      method: record.method,
      origin: record.origin,
      profileID: record.profileID,
      chainId: record.chainId,
      account: record.account,
      params: record.params,
      createdAt: record.createdAt,
      expiresAt: record.expiresAt)
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
    var submissionClaim: TransactionSubmissionClaim?
    if record.kind == .send || record.kind == .batch {
      guard let claim = submissionLock.claim(account: record.account, chainID: record.chainId)
      else {
        throw WalletError.queued
      }
      submissionClaim = claim
    }
    defer { submissionClaim?.release() }
    if requiresSignature {
      if record.kind == .batch {
        do {
          let result = try await approveBatch(record: &record, signing: requestSigner)
          record.status = .consumed
          record.result = result
          try await store.insert(record)
          return result
        } catch WalletError.rpc(let error) {
          record.status = .failed
          record.error = error
          try? await store.insert(record)
          throw WalletError.rpc(error)
        }
      }
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
        signature = try requestSigner.signDigest(signable)
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
      do {
        try await configureRPCForAddedNetwork(chainID: target, params: record.params)
      } catch {
        let rpcError: JSONValue
        if case WalletError.rpc(let value) = error {
          rpcError = value
        } else {
          rpcError = .object([
            "code": .number(-32603), "message": .string("The network could not be configured"),
          ])
        }
        record.status = .failed
        record.error = rpcError
        try? await store.insert(record)
        throw WalletError.rpc(rpcError)
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
    if record.kind == .connect || record.kind == .siwe {
      try await connectedSites.connect(
        site: ConnectedSite(
          domain: Origin.downHost(of: record.origin),
          address: record.account,
          origin: record.origin,
          profileID: record.profileID)
      )
    }
    return result
  }

  private static func hasSIWECapability(_ params: JSONValue) -> Bool {
    guard case .array(let values) = params, case .object(let request)? = values.first,
      case .object(let capabilities)? = request["capabilities"]
    else { return false }
    return capabilities["signInWithEthereum"] != nil
  }

  private static func hasCapabilities(_ params: JSONValue) -> Bool {
    guard case .array(let values) = params, case .object(let request)? = values.first,
      case .object(let capabilities)? = request["capabilities"]
    else { return false }
    return !capabilities.isEmpty
  }

  private static func kindMatches(_ record: WalletPendingRequest) -> Bool {
    if record.kind == .siwe {
      return record.method.lowercased() == "wallet_connect"
        && SIWE.validatePersisted(
          params: record.params, account: record.account, origin: record.origin,
          chainID: record.chainId)
    }
    if record.kind == .batch {
      return record.method.lowercased() == "wallet_sendcalls"
        && EIP5792.validatePersisted(
          params: record.params, account: record.account, chainID: record.chainId)
    }
    return RequestKind.kind(for: record.method) == record.kind
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

  private func configureRPCForAddedNetwork(chainID: String, params: JSONValue) async throws {
    let defaultResult = await RPCOverrideValidator.validate(
      url: RPCResolver.defaultURL(forChainID: chainID), expectedChainID: chainID,
      client: rpcClient)
    if case .success = defaultResult { return }

    let existingOverrides: [String: URL]
    do {
      existingOverrides = try rpcOverrideStore.all()
    } catch {
      throw WalletError.notReady
    }
    guard existingOverrides[chainID] == nil else { return }
    guard let fallbackURL = Self.firstRequestedRPCURL(params) else {
      throw Self.addNetworkRPCError("A valid fallback RPC URL is required for this network")
    }

    switch await RPCOverrideValidator.validate(
      url: fallbackURL, expectedChainID: chainID, client: rpcClient)
    {
    case .success:
      do {
        try rpcOverrideStore.set(fallbackURL, forChainID: chainID)
      } catch {
        throw WalletError.notReady
      }
    case .failure(.chainMismatch):
      throw Self.addNetworkRPCError("The fallback RPC URL serves a different network")
    case .failure(.insecure):
      throw Self.addNetworkRPCError("The fallback RPC URL must use HTTPS or loopback HTTP")
    case .failure(.invalidURL):
      throw Self.addNetworkRPCError("The fallback RPC URL is invalid")
    case .failure(.unreachable):
      throw Self.addNetworkRPCError("The fallback RPC URL could not be reached")
    }
  }

  private static func firstRequestedRPCURL(_ params: JSONValue) -> URL? {
    let object: [String: JSONValue]?
    if case .array(let values) = params, case .object(let value)? = values.first {
      object = value
    } else if case .object(let value) = params {
      object = value
    } else {
      object = nil
    }
    guard case .array(let urls)? = object?["rpcUrls"],
      let value = urls.first?.stringValue
    else { return nil }
    return URL(string: value)
  }

  private static func addNetworkRPCError(_ message: String) -> WalletError {
    .rpc(.object(["code": .number(4900), "message": .string(message)]))
  }

  private func canonicalizeTransaction(params: JSONValue, account: String, chainID: String) throws
    -> JSONValue
  {
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
      from.caseInsensitiveCompare(account) != .orderedSame
    {
      throw WalletError.invalidParams
    }
    transaction["from"] = .string(account)
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
    try Self.validateTransactionIntent(intent, account: account, chainID: chainID)
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

  private func approveBatch(record: inout WalletPendingRequest, signing: any Signing) async throws
    -> JSONValue
  {
    guard
      EIP5792.validatePersisted(
        params: record.params, account: record.account, chainID: record.chainId),
      case .object(let batch) = record.params,
      let version = batch["version"]?.stringValue
    else { throw WalletError.invalidParams }
    let calldata = try EIP5792.executeBatchCalldata(record.params)
    let implementationCode = try await ensureBatchImplementation(
      chainID: record.chainId, signing: signing)
    let accountCode = try await rpcData(
      method: "eth_getCode", params: .array([.string(record.account), .string("latest")]),
      chainID: record.chainId)
    let needsAuthorization: Bool
    if accountCode.isEmpty {
      needsAuthorization = true
    } else if Self.isCanonicalDelegation(accountCode) {
      needsAuthorization = false
    } else {
      throw WalletError.rpc(
        .object([
          "code": .number(5700),
          "message": .string(
            "Account code cannot be replaced by wallet_sendCalls; review it in Authorizations"),
        ]))
    }
    let nonce = try await rpcQuantity(
      method: "eth_getTransactionCount",
      params: .array([.string(record.account), .string("pending")]), chainID: record.chainId)
    let estimateTransaction: [String: JSONValue] = [
      "from": .string(record.account), "to": .string(record.account),
      "value": .string("0x0"), "data": .string(calldata),
    ]
    var estimateParams: [JSONValue] = [.object(estimateTransaction)]
    if needsAuthorization {
      // Simulate the reviewed runtime at the account without disclosing a reusable signed
      // authorization to the RPC before the outer transaction is ready to broadcast.
      estimateParams.append(.string("latest"))
      estimateParams.append(
        .object([
          record.account: .object([
            "code": .string("0x" + Hex.encode(implementationCode))
          ])
        ]))
    }
    let estimate = try await rpcQuantity(
      method: "eth_estimateGas", params: .array(estimateParams), chainID: record.chainId)
    guard let gas = Self.safeBatchGas(estimate, needsAuthorization: needsAuthorization) else {
      throw WalletError.invalidParams
    }
    let priorityFee = try await rpcQuantity(
      method: "eth_maxPriorityFeePerGas", params: .array([]), chainID: record.chainId)
    let gasPrice = try await rpcQuantity(
      method: "eth_gasPrice", params: .array([]), chainID: record.chainId)
    let maxFee = try Self.maximumQuantity(gasPrice, priorityFee)
    guard let chainQuantity = ChainStore.hexChainID(record.chainId) else {
      throw WalletError.invalidParams
    }

    let raw: [UInt8]
    let type: String
    if needsAuthorization {
      guard let authorizationNonce = EIP5792.adding(1, to: nonce),
        let authorizationNonceValue = EIP5792.uint64Quantity(authorizationNonce)
      else { throw WalletError.invalidParams }
      let authorization = try EIP7702Authorization(
        chainID: chainQuantity, delegate: EIP5792.simple7702Account,
        nonce: authorizationNonceValue)
      let authorizationSignature: [UInt8]
      do {
        authorizationSignature = try signing.signDigest(authorization.digest())
      } catch {
        throw WalletError.authCancelled
      }
      guard signing.verify(digest: authorization.digest(), signature: authorizationSignature) else {
        throw WalletError.bindingMismatch
      }
      let transaction = try EIP7702Transaction(
        chainID: chainQuantity, nonce: nonce, maxPriorityFeePerGas: priorityFee,
        maxFeePerGas: maxFee, gasLimit: gas, destination: record.account, value: "0x0",
        data: calldata,
        authorizationList: [try authorization.signed(signature: authorizationSignature)])
      let digest = Keccak.keccak256(transaction.signingPayload())
      let signature: [UInt8]
      do {
        signature = try signing.signDigest(digest)
      } catch {
        throw WalletError.authCancelled
      }
      guard signing.verify(digest: digest, signature: signature) else {
        throw WalletError.bindingMismatch
      }
      raw = try transaction.signedPayload(signature: signature)
      type = "0x4"
    } else {
      guard let chainID = Int(record.chainId) else { throw WalletError.invalidParams }
      let transaction = EIP1559Transaction(
        chainId: chainID, nonce: nonce, maxPriorityFeePerGas: priorityFee,
        maxFeePerGas: maxFee, gasLimit: gas, to: record.account, value: "0x0", data: calldata)
      let digest = Keccak.keccak256(try transaction.signingPayload())
      let signature: [UInt8]
      do {
        signature = try signing.signDigest(digest)
      } catch {
        throw WalletError.authCancelled
      }
      guard signing.verify(digest: digest, signature: signature) else {
        throw WalletError.bindingMismatch
      }
      raw = try transaction.signedPayload(signature: signature)
      type = "0x2"
    }

    record.resolvedParams = .array([
      .object([
        "from": .string(record.account), "to": .string(record.account),
        "chainId": .string(chainQuantity), "nonce": .string(nonce), "gas": .string(gas),
        "maxPriorityFeePerGas": .string(priorityFee), "maxFeePerGas": .string(maxFee),
        "value": .string("0x0"), "data": .string(calldata), "type": .string(type),
      ])
    ])
    let requestedID = batch["id"]?.stringValue
    let hash =
      try await broadcast(
        rawTransaction: raw, record: &record, callBundleID: requestedID
      ).stringValue ?? ""
    if version == "2.0.0" {
      return .object([
        "id": .string(requestedID ?? hash),
        "capabilities": .object(["atomic": .bool(true)]),
      ])
    }
    return .string(hash)
  }

  private func ensureBatchImplementation(chainID: String, signing: any Signing) async throws
    -> [UInt8]
  {
    if shouldCacheDeployment(chainID: chainID),
      let cached = deploymentStore.verifiedCode(
        chainID: chainID, runtimeHash: simple7702AccountRuntimeHash,
        rpcURL: resolver.resolve(chainID: chainID))
    {
      return cached
    }
    let currentCode = try await rpcData(
      method: "eth_getCode",
      params: .array([.string(EIP5792.simple7702Account), .string("latest")]),
      chainID: chainID)
    if EIP5792.isVerifiedImplementation(
      currentCode, expectedRuntimeHash: simple7702AccountRuntimeHash)
    {
      if shouldCacheDeployment(chainID: chainID) {
        try? deploymentStore.recordVerified(
          chainID: chainID, code: currentCode, rpcURL: resolver.resolve(chainID: chainID))
      }
      return currentCode
    }
    guard currentCode.isEmpty else {
      throw WalletError.rpc(
        .object([
          "code": .number(5710),
          "message": .string("Simple7702Account has unrecognized code on this chain"),
        ]))
    }

    let authorizations = AuthorizationService(
      account: signing.account, signing: signing, networkStore: networkStore,
      resolver: resolver, rpcClient: rpcClient,
      deploymentStore: deploymentStore,
      simple7702AccountRuntimeHash: simple7702AccountRuntimeHash)
    let transactionHash: String
    do {
      transactionHash = try await authorizations.deployImplementationWhileClaimed(chainID: chainID)
    } catch let error as AuthorizationOperationError {
      throw Self.batchDeploymentError(error)
    } catch let error as Simple7702AccountDeploymentError {
      throw Self.batchDeploymentError(error)
    } catch {
      throw WalletError.authCancelled
    }

    for _ in 0..<30 {
      let receiptStatus: AuthorizationReceiptStatus
      do {
        receiptStatus = try await authorizations.receiptStatus(
          transactionHash: transactionHash, chainID: chainID)
      } catch let error as AuthorizationOperationError {
        throw Self.batchDeploymentError(error)
      }
      switch receiptStatus {
      case .pending:
        try await Task.sleep(for: .seconds(2))
      case .reverted:
        throw WalletError.rpc(
          .object([
            "code": .number(5710),
            "message": .string("Simple7702Account deployment reverted"),
          ]))
      case .confirmed:
        let deployedCode = try await rpcData(
          method: "eth_getCode",
          params: .array([.string(EIP5792.simple7702Account), .string("latest")]),
          chainID: chainID)
        guard
          EIP5792.isVerifiedImplementation(
            deployedCode, expectedRuntimeHash: simple7702AccountRuntimeHash)
        else {
          throw WalletError.rpc(
            .object([
              "code": .number(5710),
              "message": .string("Deployed Simple7702Account runtime did not match"),
            ]))
        }
        if shouldCacheDeployment(chainID: chainID) {
          try? deploymentStore.recordVerified(
            chainID: chainID, code: deployedCode, rpcURL: resolver.resolve(chainID: chainID))
        }
        return deployedCode
      }
    }
    throw WalletError.rpc(
      .object([
        "code": .number(5710),
        "message": .string("Simple7702Account deployment confirmation timed out"),
      ]))
  }

  private static func batchDeploymentError(_ error: Error) -> WalletError {
    let message: String
    switch error {
    case Simple7702AccountDeploymentError.missingCanonicalFactory:
      message = "Canonical CREATE2 factory is not deployed on this chain"
    case Simple7702AccountDeploymentError.unsafeCanonicalFactory:
      message = "Canonical CREATE2 factory has unrecognized code on this chain"
    case Simple7702AccountDeploymentError.unsafeImplementation:
      message = "Simple7702Account has unrecognized code on this chain"
    case Simple7702AccountDeploymentError.invalidPrimitive:
      message = "Simple7702Account deployment primitive is invalid"
    case Simple7702AccountDeploymentError.alreadyDeployed:
      message = "Simple7702Account deployment changed while preparing the batch"
    case AuthorizationOperationError.rpc(.node(let value)):
      return .rpc(value)
    case AuthorizationOperationError.rpc(.transport):
      return .rpc(transportError)
    case AuthorizationOperationError.rpc(.invalidResponse(let detail)):
      message = detail
    default:
      message = "Simple7702Account could not be deployed on this chain"
    }
    return .rpc(.object(["code": .number(5710), "message": .string(message)]))
  }

  private func verifiedImplementationCode(chainID: String) async throws -> [UInt8]? {
    if shouldCacheDeployment(chainID: chainID),
      let cached = deploymentStore.verifiedCode(
        chainID: chainID, runtimeHash: simple7702AccountRuntimeHash,
        rpcURL: resolver.resolve(chainID: chainID))
    {
      return cached
    }
    let code = try await rpcData(
      method: "eth_getCode",
      params: .array([.string(EIP5792.simple7702Account), .string("latest")]),
      chainID: chainID)
    if code.isEmpty { return nil }
    guard
      EIP5792.isVerifiedImplementation(
        code, expectedRuntimeHash: simple7702AccountRuntimeHash)
    else {
      throw WalletError.rpc(
        .object([
          "code": .number(5710),
          "message": .string("Simple7702Account has unrecognized code on this chain"),
        ]))
    }
    if shouldCacheDeployment(chainID: chainID) {
      try? deploymentStore.recordVerified(
        chainID: chainID, code: code, rpcURL: resolver.resolve(chainID: chainID))
    }
    return code
  }

  private func shouldCacheDeployment(chainID: String) -> Bool {
    guard let host = resolver.resolve(chainID: chainID).host?.lowercased() else { return false }
    return host != "localhost" && host != "127.0.0.1" && host != "::1"
  }

  public func getCapabilities(
    params: JSONValue, origin: String, profileID: String? = nil
  ) async throws -> JSONValue {
    let signing = try await connectedSigner(origin: origin, profileID: profileID, exactOnly: true)
    guard case .array(let values) = params, values.count == 1 || values.count == 2,
      let requestedAccount = values.first?.stringValue,
      requestedAccount.caseInsensitiveCompare(signing.account) == .orderedSame
    else { throw WalletError.invalidParams }

    let configured = Set((try? networkStore.all().map(\.id)) ?? [])
    let requestedChains: [String]
    if values.count == 2 {
      guard case .array(let chains) = values[1] else { throw WalletError.invalidParams }
      requestedChains = try chains.map { value in
        guard let quantity = value.stringValue, EIP5792.isCanonicalQuantity(quantity),
          let decimal = ChainStore.normalize(quantity)
        else { throw WalletError.invalidParams }
        return decimal
      }
    } else {
      requestedChains = configured.sorted()
    }

    var result: [String: JSONValue] = [:]
    for chainID in requestedChains where configured.contains(chainID) {
      guard let chainQuantity = ChainStore.hexChainID(chainID) else { continue }
      do {
        guard try await supportsAtomicBatch(chainID: chainID) else { continue }
        result[chainQuantity] = .object([
          "atomic": .object(["status": .string("supported"), "supported": .bool(true)])
        ])
      } catch {
        // Omit unknown support. RPC failures must never become a positive capability claim.
      }
    }
    return .object(result)
  }

  private func supportsAtomicBatch(chainID: String) async throws -> Bool {
    if try await verifiedImplementationCode(chainID: chainID) != nil { return true }
    guard Simple7702AccountDeployment.isValid() else { return false }
    let factoryCode = try await rpcData(
      method: "eth_getCode",
      params: .array([.string(Simple7702AccountDeployment.factory), .string("latest")]),
      chainID: chainID)
    guard !factoryCode.isEmpty else { return false }
    return ("0x" + Hex.encode(Keccak.keccak256(factoryCode))).caseInsensitiveCompare(
      Simple7702AccountDeployment.factoryRuntimeHash) == .orderedSame
  }

  public func getCallsStatus(
    params: JSONValue, origin: String, profileID: String? = nil
  ) async throws -> JSONValue {
    let signing = try await connectedSigner(origin: origin, profileID: profileID, exactOnly: true)
    guard case .array(let values) = params, values.count == 1,
      let id = values[0].stringValue, EIP5792.isValidID(id)
    else { throw WalletError.invalidParams }
    guard
      let activity = try await activityStore.callBundle(
        id: id, origin: origin, profileID: profileID, account: signing.account),
      let hash = activity.transactionHash,
      let chainQuantity = ChainStore.hexChainID(activity.chainID)
    else {
      throw WalletError.rpc(
        .object(["code": .number(5730), "message": .string("Unknown bundle id")]))
    }

    let response: RPCResponse
    do {
      response = try await rpcClient.call(
        url: resolver.resolve(chainID: activity.chainID), method: "eth_getTransactionReceipt",
        params: .array([.string(hash)]))
    } catch {
      throw WalletError.rpc(Self.transportError)
    }
    switch response {
    case .error(let error): throw WalletError.rpc(error)
    case .result(.null):
      let status: Int = [.dropped, .replaced].contains(activity.status) ? 400 : 100
      return Self.callsStatus(id: id, chainID: chainQuantity, status: status)
    case .result(.object(let receipt)):
      guard let receiptStatus = receipt["status"]?.stringValue,
        ["0x0", "0x1"].contains(receiptStatus),
        let blockHash = receipt["blockHash"]?.stringValue,
        let blockNumber = receipt["blockNumber"]?.stringValue,
        let gasUsed = receipt["gasUsed"]?.stringValue,
        case .array(let logs)? = receipt["logs"]
      else {
        throw WalletError.rpc(
          .object([
            "code": .number(-32603), "message": .string("Invalid transaction receipt"),
          ]))
      }
      let filteredLogs: [JSONValue] = try logs.map { value in
        guard case .object(let log) = value, let address = log["address"],
          let data = log["data"], let topics = log["topics"]
        else { throw WalletError.invalidParams }
        return .object(["address": address, "data": data, "topics": topics])
      }
      var result = Self.callsStatus(
        id: id, chainID: chainQuantity, status: receiptStatus == "0x1" ? 200 : 500)
      guard case .object(var object) = result else { return result }
      object["receipts"] = .array([
        .object([
          "logs": .array(filteredLogs), "status": .string(receiptStatus),
          "blockHash": .string(blockHash), "blockNumber": .string(blockNumber),
          "gasUsed": .string(gasUsed), "transactionHash": .string(hash),
        ])
      ])
      result = .object(object)
      return result
    case .result:
      throw WalletError.rpc(
        .object(["code": .number(-32603), "message": .string("Invalid transaction receipt")]))
    }
  }

  private static func callsStatus(
    id: String, chainID: String, status: Int
  ) -> JSONValue {
    .object([
      "version": .string("2.0.0"), "id": .string(id), "chainId": .string(chainID),
      "status": .number(Double(status)), "atomic": .bool(true),
    ])
  }

  private static func walletError(_ error: EIP5792Error) -> WalletError {
    let code: Int
    let message: String
    switch error {
    case .invalidParams: return .invalidParams
    case .unsupportedCapability(let capability):
      code = 5700
      message = "Unsupported non-optional capability: \(capability)"
    case .unsupportedChain:
      code = 5710
      message = "Unsupported chain id"
    case .duplicateID:
      code = 5720
      message = "Duplicate ID"
    case .bundleTooLarge:
      code = 5740
      message = "Bundle too large"
    }
    return .rpc(.object(["code": .number(Double(code)), "message": .string(message)]))
  }

  private static func isCanonicalDelegation(_ code: [UInt8]) -> Bool {
    guard let designator = EIP7702DelegationDesignator(code: code),
      let expected = Hex.data(EIP5792.simple7702Account)
    else { return false }
    return designator.delegate == expected
  }

  private static func safeBatchGas(_ estimate: String, needsAuthorization: Bool) -> String? {
    guard let value = EIP5792.uint64Quantity(estimate) else { return nil }
    let margin = max(value / 2, 1_500)
    guard value <= UInt64.max - margin else { return nil }
    var safe = max(value + margin, 21_000)
    if needsAuthorization {
      guard safe <= UInt64.max - 66_000 else { return nil }
      safe += 66_000
    }
    return "0x" + String(safe, radix: 16)
  }

  private func rpcData(method: String, params: JSONValue, chainID: String) async throws -> [UInt8] {
    let response: RPCResponse
    do {
      response = try await rpcClient.call(
        url: resolver.resolve(chainID: chainID), method: method, params: params)
    } catch {
      throw WalletError.rpc(Self.transportError)
    }
    switch response {
    case .result(.string(let value)):
      guard value.hasPrefix("0x"), let data = Hex.data(value) else {
        throw WalletError.rpc(
          .object(["code": .number(-32603), "message": .string("Invalid data from \(method)")]))
      }
      return data
    case .result:
      throw WalletError.rpc(
        .object(["code": .number(-32603), "message": .string("Invalid data from \(method)")]))
    case .error(let error): throw WalletError.rpc(error)
    }
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
    rawTransaction: [UInt8], record: inout WalletPendingRequest, callBundleID: String? = nil
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
          request: record, hash: expectedHash, nonce: nonce,
          callBundleID: record.kind == .batch ? (callBundleID ?? expectedHash) : nil)
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

  public func activities(account: String, limit: Int = 100) async throws -> [ActivityRecord] {
    try await activityStore.activities(account: account, limit: limit)
  }

  public func activities(for site: ConnectedSite, limit: Int = 100) async throws
    -> [ActivityRecord]
  {
    try await activityStore.activities(for: site, limit: limit)
  }

  public func activities(
    for site: ConnectedSite, account: String, limit: Int = 100
  ) async throws -> [ActivityRecord] {
    try await activityStore.activities(for: site, account: account, limit: limit)
  }

  /// Refreshes unresolved transactions through the same resolver used for preparation and
  /// broadcast. A missing receipt is not treated as failure while the node still knows the
  /// transaction or while propagation is within the grace period.
  public func refreshTransactionActivity(
    account: String? = nil, now: Date = Date(), missingGracePeriod: TimeInterval = 60
  ) async {
    let unresolved: [ActivityRecord]?
    if let account {
      unresolved = try? await activityStore.unresolvedTransactions(account: account)
    } else {
      unresolved = try? await activityStore.unresolvedTransactions()
    }
    guard let unresolved else { return }
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

  public func reject(
    request: UUID, profileID: String? = nil, reviewedRevision: UInt64 = 0
  ) async throws {
    _ = try ensureRegistryReady()
    let initial = try rawRecord(request)
    let account = try transitionAccount(request: request, record: initial)
    guard initial != nil || account != nil else { throw WalletError.notFound }
    try withGroupClaim(account: account) {
      guard let claim = store.claim(request) else { throw WalletError.alreadyConsumed }
      defer { store.releaseClaim(claim) }
      let raw = try rawRecord(request)
      if try reconcileConnectCommit(request: request, record: raw) != nil {
        throw WalletError.alreadyConsumed
      }
      guard var record = raw else { throw WalletError.notFound }
      guard record.profileID == profileID, record.bindingVersion == 2,
        record.revision == reviewedRevision
      else { throw WalletError.bindingMismatch }
      guard record.status == .pending else { throw WalletError.alreadyConsumed }
      if record.isExpired {
        record.status = .expired
        try store.persistForLifecycleCleanup(record)
        throw WalletError.expired
      }
      record.status = .rejected
      try store.persistForLifecycleCleanup(record)
    }
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
