import Foundation
import Testing

@testable import StupidWalletCore

/// Wallet-owned (app-initiated) sends. These bypass the dapp pending-request queue but must still
/// validate, resolve fees, sign, broadcast, and record activity through the one transaction pipeline.
@Suite(.serialized)
struct SendTransactionTests {
  private func service(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data))
    -> WalletService
  {
    SendRPCURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SendRPCURLProtocol.self]
    let client = RPCClient(session: URLSession(configuration: configuration))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SendTransactionTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return WalletService(
      store: PendingRequestStore(directory: directory),
      signing: SendTestSigner(),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: ChainStore(directory: directory),
      networkStore: NetworkStore(
        directory: directory, legacySuiteName: "SendTransactionTests.Networks"),
      activityStore: ActivityStore(
        databaseURL: directory.appendingPathComponent("Activity.sqlite")),
      resolver: RPCResolver(overrides: ["1": URL(string: "https://rpc.example")!]),
      rpcClient: client)
  }

  private func broadcastHandler(_ request: URLRequest) -> (HTTPURLResponse, Data) {
    let object = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
    switch object.nestedString(at: ["method"]) {
    case "eth_getTransactionCount": return sendRPCResponse(result: "0x7")
    case "eth_estimateGas": return sendRPCResponse(result: "0x5208")
    case "eth_gasPrice": return sendRPCResponse(result: "0x3b9aca00")
    case "eth_sendRawTransaction":
      guard case .object(let body) = object, case .array(let params)? = body["params"],
        case .string(let raw)? = params.first, let bytes = Hex.data(raw)
      else { return sendRPCResponse(error: "invalid raw transaction") }
      return sendRPCResponse(result: "0x" + Hex.encode(Keccak.keccak256(bytes)))
    default: return sendRPCResponse(error: "unexpected method")
    }
  }

  @Test("a wallet-owned native send resolves fees, broadcasts, and records activity")
  func nativeSend() async throws {
    let service = service(handler: broadcastHandler)
    let hash = try await service.sendTransaction(
      account: service.account, chainID: "1",
      to: "0x000000000000000000000000000000000000dead", value: "0xde0b6b3a7640000")
    #expect(Hex.data(hash)?.count == 32)

    let activity = try await service.activities()
    #expect(activity.count == 1)
    #expect(activity.first?.kind == .transaction)
    #expect(activity.first?.method == "eth_sendTransaction")
    #expect(activity.first?.origin == WalletService.walletOriginatedOrigin)
    #expect(activity.first?.status == .submitted)
    #expect(activity.first?.nonce == "0x7")
    #expect(activity.first?.transactionTo == "0x000000000000000000000000000000000000dead")
    // A wallet-owned send is not a dapp request and must not enter the approval queue.
    #expect(try await service.store.pending().isEmpty)
    #expect(try await service.list().isEmpty)
  }

  @Test("an ERC-20 send records the transfer calldata and token destination")
  func erc20Send() async throws {
    let token = "0x00000000000000000000000000000000000000aa"
    let recipient = "0x00000000000000000000000000000000000000bb"
    let service = service(handler: broadcastHandler)
    _ = try await service.sendTransaction(
      account: service.account, chainID: "1", to: token, value: "0x0",
      data: try TokenTransfer.transferCalldata(to: recipient, rawAmount: [0x01]))

    let activity = try await service.activities()
    #expect(activity.first?.transactionTo == token)
    #expect(
      activity.first?.transactionData
        == (try TokenTransfer.transferCalldata(to: recipient, rawAmount: [0x01])))
  }

  @Test("an invalid recipient is rejected before any RPC or persistence")
  func rejectsInvalidRecipient() async throws {
    let service = service { _ in sendRPCResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.invalidParams) {
      try await service.sendTransaction(
        account: service.account, chainID: "1", to: "not-an-address", value: "0x1")
    }
    #expect(try await service.activities().isEmpty)
    #expect(try await service.store.pending().isEmpty)
  }

  @Test("an account without a protected key cannot send")
  func rejectsMissingKey() async throws {
    let service = service { _ in sendRPCResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.notReady) {
      try await service.sendTransaction(
        account: "0x0000000000000000000000000000000000000002", chainID: "1",
        to: "0x000000000000000000000000000000000000dead")
    }
    #expect(try await service.activities().isEmpty)
  }

  @Test("a structured broadcast error surfaces and records no activity")
  func broadcastError() async throws {
    let service = service { request in
      let object = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
      switch object.nestedString(at: ["method"]) {
      case "eth_getTransactionCount": return sendRPCResponse(result: "0x0")
      case "eth_estimateGas": return sendRPCResponse(result: "0x5208")
      case "eth_gasPrice": return sendRPCResponse(result: "0x3b9aca00")
      default: return sendRPCResponse(error: "insufficient funds", code: -32000)
      }
    }
    await #expect(
      throws: WalletError.rpc(
        .object(["code": .number(-32000), "message": .string("insufficient funds")]))
    ) {
      try await service.sendTransaction(
        account: service.account, chainID: "1",
        to: "0x000000000000000000000000000000000000dead", value: "0x1")
    }
    #expect(try await service.activities().isEmpty)
  }

  @Test(
    "native 100% reserves the total estimated fee and uses the smaller pending or displayed balance"
  )
  func nativeMaximum() async throws {
    for (pending, cap, expected) in [
      (2_000_000, 1_000_000, 916_000), (1_000_000, 2_000_000, 916_000),
    ] {
      let trace = SendMaximumTrace()
      let maximum = maximumClient { request in
        let body = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
        trace.record(body: body)
        switch body.nestedString(at: ["method"]) {
        case "eth_chainId": return sendRPCResponse(result: "0x1")
        case "eth_getBalance": return sendRPCResponse(result: "0x" + String(pending, radix: 16))
        case "eth_gasPrice": return sendRPCResponse(result: "0x2")
        case "eth_getCode": return sendRPCResponse(result: "0x")
        case "eth_estimateGas": return sendRPCResponse(result: "0x5208")
        default: return sendRPCResponse(error: "Unexpected RPC")
        }
      }
      let amount = try await maximum.amount(
        account: SendTestSigner().account, chainID: "1",
        to: "0x000000000000000000000000000000000000dead",
        balanceCap: TokenTransfer.bytes(fromDecimalDigits: String(cap)))
      #expect(ABI.decimal(from: amount) == String(expected))
      #expect(
        trace.methods == [
          "eth_chainId", "eth_getBalance", "eth_gasPrice", "eth_getCode", "eth_estimateGas",
          "eth_estimateGas",
        ])
      #expect(trace.estimatedValues == ["0x1", Hex.quantity(amount)])
    }
  }

  @Test("native 100% includes OP Stack data and operator fees and verifies oracle ABI")
  func nativeMaximumOPFees() async throws {
    let maximum = maximumClient { request in
      let body = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
      switch body.nestedString(at: ["method"]) {
      case "eth_chainId": return sendRPCResponse(result: "0x2105")
      case "eth_getBalance": return sendRPCResponse(result: "0xf4240")
      case "eth_gasPrice": return sendRPCResponse(result: "0x2")
      case "eth_getCode": return sendRPCResponse(result: "0x6000")
      case "eth_estimateGas": return sendRPCResponse(result: "0x5208")
      case "eth_call":
        guard case .object(let object) = body, case .array(let params)? = object["params"],
          case .object(let call)? = params.first, let data = call["data"]?.stringValue
        else { return sendRPCResponse(error: "Missing oracle calldata") }
        #expect(call["to"] == .string(NativeSendMaximum.gasPriceOracle))
        let isL1 = data.hasSuffix(String(repeating: "0", count: 60) + "0200")
        // Independent viem 2.55.19 calldata vectors.
        #expect(
          data
            == (isL1
              ? "0xf1c7a58b" + String(repeating: "0", count: 60) + "0200"
              : "0x275aedd2" + String(repeating: "0", count: 60) + "5208"))
        return sendRPCResponse(
          result: "0x" + String(repeating: "0", count: 61) + (isL1 ? "3e8" : "7d0"))
      default: return sendRPCResponse(error: "Unexpected RPC")
      }
    }
    let amount = try await maximum.amount(
      account: SendTestSigner().account, chainID: "8453",
      to: "0x000000000000000000000000000000000000dead",
      balanceCap: TokenTransfer.bytes(fromDecimalDigits: "1000000"))
    #expect(ABI.decimal(from: amount) == "910000")
  }

  @Test("native maximum refines value-dependent gas without increasing a previous candidate")
  func nativeMaximumRefinement() async throws {
    let trace = SendMaximumTrace()
    let maximum = maximumClient { request in
      let body = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
      trace.record(body: body)
      switch body.nestedString(at: ["method"]) {
      case "eth_chainId": return sendRPCResponse(result: "0x1")
      case "eth_getBalance": return sendRPCResponse(result: "0x186a0")
      case "eth_gasPrice": return sendRPCResponse(result: "0x1")
      case "eth_getCode": return sendRPCResponse(result: "0x")
      case "eth_estimateGas":
        return sendRPCResponse(
          result: ["0x5208", "0x7530", "0x4e20"][trace.estimatedValues.count - 1])
      default: return sendRPCResponse(error: "Unexpected RPC")
      }
    }
    let amount = try await maximum.amount(
      account: SendTestSigner().account, chainID: "1",
      to: "0x000000000000000000000000000000000000dead",
      balanceCap: TokenTransfer.bytes(fromDecimalDigits: "100000"))
    #expect(ABI.decimal(from: amount) == "40000")
    #expect(trace.estimatedValues == ["0x1", "0xe290", "0x9c40"])
  }

  @Test("native maximum rejects the wrong network and unaffordable fees")
  func nativeMaximumFailures() async throws {
    let wrongChain = maximumClient { _ in sendRPCResponse(result: "0x2") }
    await #expect(throws: NativeSendMaximumError.wrongChain) {
      try await wrongChain.amount(
        account: SendTestSigner().account, chainID: "1",
        to: "0x000000000000000000000000000000000000dead",
        balanceCap: [100])
    }
    let maximum = maximumClient { request in
      let body = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
      switch body.nestedString(at: ["method"]) {
      case "eth_chainId": return sendRPCResponse(result: "0x1")
      case "eth_getBalance": return sendRPCResponse(result: "0x64")
      case "eth_gasPrice": return sendRPCResponse(result: "0x1")
      case "eth_getCode": return sendRPCResponse(result: "0x")
      case "eth_estimateGas": return sendRPCResponse(result: "0x5208")
      default: return sendRPCResponse(error: "Unexpected RPC")
      }
    }
    await #expect(throws: NativeSendMaximumError.insufficientBalance) {
      try await maximum.amount(
        account: SendTestSigner().account, chainID: "1",
        to: "0x000000000000000000000000000000000000dead",
        balanceCap: [100])
    }
  }

  @Test("native maximum never hides a failed OP fee oracle")
  func nativeMaximumOracleFailure() async throws {
    let maximum = maximumClient { request in
      let body = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
      switch body.nestedString(at: ["method"]) {
      case "eth_chainId": return sendRPCResponse(result: "0x1")
      case "eth_getBalance": return sendRPCResponse(result: "0xf4240")
      case "eth_gasPrice": return sendRPCResponse(result: "0x1")
      case "eth_getCode": return sendRPCResponse(result: "0x6000")
      default: return sendRPCResponse(result: "0x")
      }
    }
    await #expect(throws: NativeSendMaximumError.invalidResponse) {
      try await maximum.amount(
        account: SendTestSigner().account, chainID: "1",
        to: "0x000000000000000000000000000000000000dead",
        balanceCap: TokenTransfer.bytes(fromDecimalDigits: "1000000"))
    }
  }

  private func maximumClient(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data))
    -> NativeSendMaximum
  {
    SendRPCURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SendRPCURLProtocol.self]
    return NativeSendMaximum(
      resolver: RPCResolver(overrides: [
        "1": URL(string: "https://rpc.example")!, "8453": URL(string: "https://rpc.example")!,
      ]),
      client: RPCClient(session: URLSession(configuration: configuration)))
  }

  @Test("native maximum bounds refinement and rejects cancellation before RPC")
  func nativeMaximumBounds() async throws {
    let trace = SendMaximumTrace()
    let maximum = maximumClient { request in
      let body = try! JSONDecoder().decode(JSONValue.self, from: sendRequestBody(request))
      trace.record(body: body)
      switch body.nestedString(at: ["method"]) {
      case "eth_chainId": return sendRPCResponse(result: "0x1")
      case "eth_getBalance": return sendRPCResponse(result: "0xf4240")
      case "eth_gasPrice": return sendRPCResponse(result: "0x1")
      case "eth_getCode": return sendRPCResponse(result: "0x")
      case "eth_estimateGas":
        return sendRPCResponse(
          result: "0x" + String(21_000 * trace.estimatedValues.count, radix: 16))
      default: return sendRPCResponse(error: "Unexpected RPC")
      }
    }
    await #expect(throws: NativeSendMaximumError.unstableEstimate) {
      try await maximum.amount(
        account: SendTestSigner().account, chainID: "1",
        to: "0x000000000000000000000000000000000000dead",
        balanceCap: TokenTransfer.bytes(fromDecimalDigits: "1000000"))
    }
    #expect(trace.estimatedValues.count == 4)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await maximum.amount(
        account: SendTestSigner().account, chainID: "1",
        to: "0x000000000000000000000000000000000000dead",
        balanceCap: [100])
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(trace.methods.count == 8)
  }
}

private final class SendMaximumTrace: @unchecked Sendable {
  private let lock = NSLock()
  private var bodies: [JSONValue] = []
  func record(body: JSONValue) { lock.withLock { bodies.append(body) } }
  var methods: [String] { lock.withLock { bodies.compactMap { $0.nestedString(at: ["method"]) } } }
  var estimatedValues: [String?] {
    lock.withLock {
      bodies.filter { $0.nestedString(at: ["method"]) == "eth_estimateGas" }.map {
        guard case .object(let object) = $0, case .array(let params)? = object["params"],
          case .object(let call)? = params.first
        else { return nil }
        return call["value"]?.stringValue
      }
    }
  }
}

private final class SendRPCURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let handler = Self.handler else { return }
    let (response, data) = handler(request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private func sendRequestBody(_ request: URLRequest) -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count > 0 else { break }
    data.append(buffer, count: count)
  }
  return data
}

private struct SendTestSigner: Signing {
  let account: String
  private let keypair: EthereumKeypair

  init() {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 2
    keypair = try! EthereumKeypair.from(secret: secret)
    account = keypair.address
  }

  func hasKey() -> Bool { true }
  func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    try EthereumSigner.sign(digest: digest, keypair: keypair)
  }
}

private func sendRPCResponse(result: String) -> (HTTPURLResponse, Data) {
  sendRPCResponse(result: .string(result))
}

private func sendRPCResponse(result: JSONValue) -> (HTTPURLResponse, Data) {
  (
    httpResponse(),
    try! JSONEncoder().encode(
      JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .number(1), "result": result,
      ]))
  )
}

private func sendRPCResponse(error: String, code: Int = -32603) -> (HTTPURLResponse, Data) {
  (
    httpResponse(),
    try! JSONEncoder().encode(
      JSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": .number(1),
        "error": .object(["code": .number(Double(code)), "message": .string(error)]),
      ]))
  )
}
