import Foundation

public enum NativeSendMaximumError: Error, Sendable, Equatable, LocalizedError {
  case invalidInput
  case wrongChain
  case invalidResponse
  case insufficientBalance
  case unstableEstimate
  case rpc(JSONValue)

  public var errorDescription: String? {
    switch self {
    case .invalidInput: "Select an asset and recipient before calculating Max."
    case .wrongChain: "The RPC returned the wrong network. Check its settings."
    case .invalidResponse: "The network returned an invalid fee estimate. Try again."
    case .insufficientBalance: "The available balance is too low to reserve the network fee."
    case .unstableEstimate:
      "The network fee could not be estimated reliably. Enter an amount instead."
    case .rpc: "The network fee could not be estimated. Try again."
    }
  }
}

/// Read-only native-send amount preview. The displayed amount stays fixed during actual submission.
public struct NativeSendMaximum: Sendable {
  private let resolver: RPCResolver
  private let client: RPCClient
  static let gasPriceOracle = "0x420000000000000000000000000000000000000f"

  public init(resolver: RPCResolver, client: RPCClient = RPCClient()) {
    self.resolver = resolver
    self.client = client
  }

  public func amount(account: String, chainID: String, to: String, balanceCap: [UInt8]) async throws
    -> [UInt8]
  {
    guard ChainStore.normalize(chainID) == chainID,
      let account = try? WalletToken.normalizeAddress(account),
      let to = try? WalletToken.normalizeAddress(to),
      let recipient = Hex.data(to), recipient.contains(where: { $0 != 0 }),
      !balanceCap.isEmpty, balanceCap.count <= 32
    else { throw NativeSendMaximumError.invalidInput }
    let endpoint = resolver.resolve(chainID: chainID)
    let chain = try await call(endpoint: endpoint, method: "eth_chainId", params: .array([]))
    guard case .string(let chainHex) = chain, ChainStore.normalize(chainHex) == chainID else {
      throw NativeSendMaximumError.wrongChain
    }
    let pending = try await quantity(
      endpoint: endpoint, method: "eth_getBalance",
      params: .array([.string(account), .string("pending")]))
    let balance = NativeBalanceService.isGreater(pending, than: balanceCap) ? balanceCap : pending
    let balanceDecimal = ABI.decimal(from: balance)
    guard !DecimalValue.isZero(balanceDecimal) else {
      throw NativeSendMaximumError.insufficientBalance
    }
    let price = try await quantity(endpoint: endpoint, method: "eth_gasPrice", params: .array([]))
    let oracle = try await call(
      endpoint: endpoint, method: "eth_getCode",
      params: .array([.string(Self.gasPriceOracle), .string("latest")]))
    guard case .string(let code) = oracle, code.hasPrefix("0x"), let codeBytes = Hex.data(code)
    else {
      throw NativeSendMaximumError.invalidResponse
    }
    // A 512-byte bound covers an empty-data legacy transfer with full-width quantities/signature.
    let l1Fee =
      codeBytes.isEmpty
      ? "0"
      : try await oracleFee(
        endpoint: endpoint, signature: "getL1FeeUpperBound(uint256)", argument: [2, 0])
    var candidate: [UInt8] = [1]
    var reserved = "0"
    for _ in 0..<4 {
      guard let value = Hex.quantity(candidate) else {
        throw NativeSendMaximumError.invalidResponse
      }
      let gas = try await quantity(
        endpoint: endpoint, method: "eth_estimateGas",
        params: .array([
          .object([
            "from": .string(account), "to": .string(to), "value": .string(value),
            "data": .string("0x"),
          ])
        ]))
      guard gas.contains(where: { $0 != 0 }) else { throw NativeSendMaximumError.invalidResponse }
      let operatorFee =
        codeBytes.isEmpty
        ? "0"
        : try await oracleFee(
          endpoint: endpoint, signature: "getOperatorFee(uint256)", argument: gas)
      guard let execution = DecimalValue.product(ABI.decimal(from: gas), ABI.decimal(from: price)),
        let total = DecimalValue.sum([execution, l1Fee, operatorFee]),
        // Reserve twice the estimated total fee to allow for changes before signing.
        let reserve = DecimalValue.product(total, "2")
      else { throw NativeSendMaximumError.invalidResponse }
      if DecimalValue.compare(reserve, reserved) != .orderedDescending, reserved != "0" {
        return candidate
      }
      reserved = reserve
      guard let spendable = DecimalValue.subtract(balanceDecimal, reserved),
        !DecimalValue.isZero(spendable)
      else { throw NativeSendMaximumError.insufficientBalance }
      let next = TokenTransfer.bytes(fromDecimalDigits: spendable)
      if next == candidate { return candidate }
      candidate = next
    }
    throw NativeSendMaximumError.unstableEstimate
  }

  private func oracleFee(endpoint: URL, signature: String, argument: [UInt8]) async throws -> String
  {
    guard argument.count <= 32 else { throw NativeSendMaximumError.invalidResponse }
    let data =
      Array(Keccak.keccak256(Array(signature.utf8)).prefix(4))
      + [UInt8](repeating: 0, count: 32 - argument.count) + argument
    let result = try await call(
      endpoint: endpoint, method: "eth_call",
      params: .array([
        .object(["to": .string(Self.gasPriceOracle), "data": .string("0x" + Hex.encode(data))]),
        .string("latest"),
      ]))
    guard case .string(let hex) = result, hex.hasPrefix("0x"), let bytes = Hex.data(hex),
      bytes.count == 32
    else { throw NativeSendMaximumError.invalidResponse }
    return ABI.decimal(from: bytes)
  }

  private func quantity(endpoint: URL, method: String, params: JSONValue) async throws -> [UInt8] {
    let result = try await call(endpoint: endpoint, method: method, params: params)
    guard case .string(let hex) = result, let bytes = Hex.quantityData(hex: hex) else {
      throw NativeSendMaximumError.invalidResponse
    }
    return bytes
  }

  private func call(endpoint: URL, method: String, params: JSONValue) async throws -> JSONValue {
    try Task.checkCancellation()
    let response = try await client.call(url: endpoint, method: method, params: params)
    try Task.checkCancellation()
    switch response {
    case .result(let result): return result
    case .error(let error): throw NativeSendMaximumError.rpc(error)
    }
  }
}
