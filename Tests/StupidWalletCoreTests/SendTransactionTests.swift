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
