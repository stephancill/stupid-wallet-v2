import Foundation

public enum AuthorizationState: Equatable, Sendable {
  case notAuthorized
  case authorized(delegate: String)
  case malformed(code: String)
  case unavailable(error: AuthorizationRPCFailure)

  public var delegate: String? {
    guard case .authorized(let delegate) = self else { return nil }
    return delegate
  }
}

public enum AuthorizationRPCFailure: Equatable, Sendable {
  case node(JSONValue)
  case transport
  case invalidResponse(String)
}

public struct AuthorizationStatus: Identifiable, Equatable, Sendable {
  public let network: WalletNetwork
  public let state: AuthorizationState

  public var id: String { network.id }

  public init(network: WalletNetwork, state: AuthorizationState) {
    self.network = network
    self.state = state
  }
}

public enum AuthorizationOperationError: Error, Equatable, Sendable {
  case unsupportedChain
  case missingImplementation
  case alreadyEnabled
  case notAuthorized
  case replacementConfirmationRequired(delegate: String)
  case unsafeAccountCode(code: String)
  case nonceOverflow
  case signerMismatch
  case rpc(AuthorizationRPCFailure)
}

public enum AuthorizationReceiptStatus: Equatable, Sendable {
  case pending
  case confirmed(blockNumber: String?)
  case reverted(blockNumber: String?)
}

/// Wallet-owned EIP-7702 authorization management. This service has no dapp-facing request
/// surface and can only delegate to the reviewed EIP-5792 implementation or revoke to zero.
public struct AuthorizationService: Sendable {
  public static let zeroAddress = "0x0000000000000000000000000000000000000000"

  public let account: String
  private let signing: any Signing
  private let networkStore: NetworkStore
  private let resolver: RPCResolver
  private let rpcClient: RPCClient
  private let simple7702AccountRuntimeHash: String

  public init(
    account: String,
    signing: any Signing,
    networkStore: NetworkStore = NetworkStore(),
    resolver: RPCResolver = .persisted(),
    rpcClient: RPCClient = RPCClient(),
    simple7702AccountRuntimeHash: String = EIP5792.simple7702AccountRuntimeHash
  ) {
    self.account = account
    self.signing = signing
    self.networkStore = networkStore
    self.resolver = resolver
    self.rpcClient = rpcClient
    self.simple7702AccountRuntimeHash = simple7702AccountRuntimeHash
  }

  public func statuses() async -> [AuthorizationStatus] {
    let networks = supportedNetworks()
    var statuses: [AuthorizationStatus] = []
    statuses.reserveCapacity(networks.count)
    for network in networks {
      let state: AuthorizationState
      do {
        state = try await authorizationState(chainID: network.id)
      } catch let error as AuthorizationOperationError {
        if case .rpc(let failure) = error {
          state = .unavailable(error: failure)
        } else {
          state = .unavailable(error: .invalidResponse("Authorization status unavailable"))
        }
      } catch {
        state = .unavailable(error: .transport)
      }
      statuses.append(AuthorizationStatus(network: network, state: state))
    }
    return statuses
  }

  /// Enables the fixed Simple7702Account implementation. A foreign canonical delegation can
  /// only be replaced after the caller has shown a distinct replacement confirmation.
  @discardableResult
  public func enable(
    chainID: String, replacingForeignAuthorization: Bool = false
  ) async throws -> String {
    try requireSupported(chainID)

    let implementationCode = try await rpcData(
      method: "eth_getCode",
      params: .array([.string(EIP5792.simple7702Account), .string("latest")]),
      chainID: chainID)
    guard
      EIP5792.isVerifiedImplementation(
        implementationCode, expectedRuntimeHash: simple7702AccountRuntimeHash)
    else {
      throw AuthorizationOperationError.missingImplementation
    }

    switch try await authorizationState(chainID: chainID) {
    case .notAuthorized:
      break
    case .authorized(let delegate)
    where delegate.caseInsensitiveCompare(EIP5792.simple7702Account) == .orderedSame:
      throw AuthorizationOperationError.alreadyEnabled
    case .authorized(let delegate):
      guard replacingForeignAuthorization else {
        throw AuthorizationOperationError.replacementConfirmationRequired(delegate: delegate)
      }
    case .malformed(let code):
      throw AuthorizationOperationError.unsafeAccountCode(code: code)
    case .unavailable(let error):
      throw AuthorizationOperationError.rpc(error)
    }

    return try await signAndSubmit(chainID: chainID, delegate: EIP5792.simple7702Account)
  }

  /// Revokes a canonical delegation. Other account code is never overwritten as though it were
  /// an ordinary authorization.
  @discardableResult
  public func revoke(chainID: String) async throws -> String {
    try requireSupported(chainID)
    switch try await authorizationState(chainID: chainID) {
    case .authorized:
      break
    case .notAuthorized:
      throw AuthorizationOperationError.notAuthorized
    case .malformed(let code):
      throw AuthorizationOperationError.unsafeAccountCode(code: code)
    case .unavailable(let error):
      throw AuthorizationOperationError.rpc(error)
    }
    return try await signAndSubmit(chainID: chainID, delegate: Self.zeroAddress)
  }

  /// A bounded refresh boundary for callers that want to distinguish submitted from mined without
  /// blocking authorization submission indefinitely.
  public func receiptStatus(
    transactionHash: String, chainID: String
  ) async throws -> AuthorizationReceiptStatus {
    try requireSupported(chainID)
    let response = try await call(
      method: "eth_getTransactionReceipt", params: .array([.string(transactionHash)]),
      chainID: chainID)
    switch response {
    case .result(.null): return .pending
    case .result(.object(let receipt)):
      let block = receipt["blockNumber"]?.stringValue
      switch receipt["status"]?.stringValue?.lowercased() {
      case "0x1": return .confirmed(blockNumber: block)
      case "0x0": return .reverted(blockNumber: block)
      default:
        throw AuthorizationOperationError.rpc(
          .invalidResponse("Invalid transaction receipt status"))
      }
    case .result:
      throw AuthorizationOperationError.rpc(.invalidResponse("Invalid transaction receipt"))
    case .error(let error):
      throw AuthorizationOperationError.rpc(.node(error))
    }
  }

  private func signAndSubmit(chainID: String, delegate: String) async throws -> String {
    guard signing.account.caseInsensitiveCompare(account) == .orderedSame else {
      throw AuthorizationOperationError.signerMismatch
    }
    guard let chainQuantity = ChainStore.hexChainID(chainID) else {
      throw AuthorizationOperationError.unsupportedChain
    }

    // These values are deliberately fetched together immediately before signing. The estimate is
    // only a base self-transaction estimate; explicit authorization overhead is added below.
    let nonce = try await rpcQuantity(
      method: "eth_getTransactionCount",
      params: .array([.string(account), .string("pending")]), chainID: chainID)
    let estimate = try await rpcQuantity(
      method: "eth_estimateGas",
      params: .array([
        .object([
          "from": .string(account), "to": .string(account), "value": .string("0x0"),
          "data": .string("0x"),
        ])
      ]), chainID: chainID)
    let priorityFee = try await rpcQuantity(
      method: "eth_maxPriorityFeePerGas", params: .array([]), chainID: chainID)
    let gasPrice = try await rpcQuantity(
      method: "eth_gasPrice", params: .array([]), chainID: chainID)

    guard let outerNonce = EIP5792.uint64Quantity(nonce), outerNonce < UInt64.max else {
      throw AuthorizationOperationError.nonceOverflow
    }
    guard let gasLimit = Self.authorizationGasLimit(estimate) else {
      throw AuthorizationOperationError.rpc(.invalidResponse("Invalid gas estimate"))
    }
    let maxFee = try Self.maximumQuantity(gasPrice, priorityFee)
    let authorization = try EIP7702Authorization(
      chainID: chainQuantity, delegate: delegate, nonce: outerNonce + 1)

    let authorizationSignature = try signing.signDigest(authorization.digest())
    guard signing.verify(digest: authorization.digest(), signature: authorizationSignature) else {
      throw AuthorizationOperationError.signerMismatch
    }
    let transaction = try EIP7702Transaction(
      chainID: chainQuantity, nonce: nonce, maxPriorityFeePerGas: priorityFee,
      maxFeePerGas: maxFee, gasLimit: gasLimit, destination: account, value: "0x0", data: "0x",
      authorizationList: [try authorization.signed(signature: authorizationSignature)])
    let transactionDigest = Keccak.keccak256(transaction.signingPayload())
    let transactionSignature = try signing.signDigest(transactionDigest)
    guard signing.verify(digest: transactionDigest, signature: transactionSignature) else {
      throw AuthorizationOperationError.signerMismatch
    }
    let rawTransaction = try transaction.signedPayload(signature: transactionSignature)

    let response = try await call(
      method: "eth_sendRawTransaction",
      params: .array([.string("0x" + Hex.encode(rawTransaction))]), chainID: chainID)
    switch response {
    case .result(.string(let hash)) where Hex.data(hash)?.count == 32:
      let expected = "0x" + Hex.encode(Keccak.keccak256(rawTransaction))
      guard hash.caseInsensitiveCompare(expected) == .orderedSame else {
        throw AuthorizationOperationError.rpc(
          .invalidResponse("RPC returned a mismatched transaction hash"))
      }
      return expected
    case .result:
      throw AuthorizationOperationError.rpc(
        .invalidResponse("Invalid eth_sendRawTransaction result"))
    case .error(let error):
      throw AuthorizationOperationError.rpc(.node(error))
    }
  }

  private func authorizationState(chainID: String) async throws -> AuthorizationState {
    let code = try await rpcData(
      method: "eth_getCode", params: .array([.string(account), .string("latest")]),
      chainID: chainID)
    if code.isEmpty { return .notAuthorized }
    if let designator = EIP7702DelegationDesignator(code: code) {
      return .authorized(delegate: "0x" + Hex.encode(designator.delegate))
    }
    return .malformed(code: "0x" + Hex.encode(code))
  }

  private func supportedNetworks() -> [WalletNetwork] {
    ((try? networkStore.all()) ?? []).filter { EIP5792.verifiedChains.contains($0.id) }
  }

  private func requireSupported(_ chainID: String) throws {
    guard supportedNetworks().contains(where: { $0.id == chainID }) else {
      throw AuthorizationOperationError.unsupportedChain
    }
  }

  private func rpcData(method: String, params: JSONValue, chainID: String) async throws -> [UInt8] {
    let response = try await call(method: method, params: params, chainID: chainID)
    switch response {
    case .result(.string(let value)):
      guard value.hasPrefix("0x"), let data = Hex.data(value) else {
        throw AuthorizationOperationError.rpc(.invalidResponse("Invalid data from \(method)"))
      }
      return data
    case .result:
      throw AuthorizationOperationError.rpc(.invalidResponse("Invalid data from \(method)"))
    case .error(let error):
      throw AuthorizationOperationError.rpc(.node(error))
    }
  }

  private func rpcQuantity(method: String, params: JSONValue, chainID: String) async throws
    -> String
  {
    let response = try await call(method: method, params: params, chainID: chainID)
    switch response {
    case .result(.string(let value)) where EIP5792.isCanonicalQuantity(value): return value
    case .result:
      throw AuthorizationOperationError.rpc(.invalidResponse("Invalid quantity from \(method)"))
    case .error(let error):
      throw AuthorizationOperationError.rpc(.node(error))
    }
  }

  private func call(method: String, params: JSONValue, chainID: String) async throws -> RPCResponse
  {
    do {
      return try await rpcClient.call(
        url: resolver.resolve(chainID: chainID), method: method, params: params)
    } catch {
      throw AuthorizationOperationError.rpc(.transport)
    }
  }

  private static func authorizationGasLimit(_ estimate: String) -> String? {
    guard let value = EIP5792.uint64Quantity(estimate) else { return nil }
    let safety = max(value / 5, 1_500)
    let overhead: UInt64 = 66_000
    guard value <= UInt64.max - safety, value + safety <= UInt64.max - overhead else { return nil }
    return "0x" + String(max(value + safety, 21_000) + overhead, radix: 16)
  }

  private static func maximumQuantity(_ lhs: String, _ rhs: String) throws -> String {
    guard let left = Hex.quantityData(hex: lhs), let right = Hex.quantityData(hex: rhs) else {
      throw AuthorizationOperationError.rpc(.invalidResponse("Invalid fee quantity"))
    }
    if left.count != right.count { return left.count > right.count ? lhs : rhs }
    return left.lexicographicallyPrecedes(right) ? rhs : lhs
  }
}
