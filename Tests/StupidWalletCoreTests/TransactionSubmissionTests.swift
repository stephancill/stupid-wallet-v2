import Foundation
import Testing

@testable import StupidWalletCore

@Suite(.serialized)
struct TransactionSubmissionTests {
  private func service(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data))
    -> WalletService
  {
    TransactionURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TransactionURLProtocol.self]
    let client = RPCClient(session: URLSession(configuration: configuration))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TransactionSubmissionTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return WalletService(
      store: PendingRequestStore(directory: directory),
      signing: TransactionSigner(),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: ChainStore(directory: directory),
      resolver: RPCResolver(overrides: ["1": URL(string: "https://rpc.example")!]),
      rpcClient: client)
  }

  @Test("missing legacy fields are prepared, signed, broadcast, and resolve to the tx hash")
  func preparesAndBroadcasts() async throws {
    let service = service { request in
      let object = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      let method = object.nestedString(at: ["method"])!
      let result: String
      switch method {
      case "eth_getTransactionCount": result = "0x7"
      case "eth_estimateGas": result = "0x5208"
      case "eth_gasPrice": result = "0x3b9aca00"
      case "eth_sendRawTransaction":
        guard case .object(let body) = object,
          case .array(let params)? = body["params"],
          case .string(let raw)? = params.first,
          let bytes = Hex.data(raw), raw.hasPrefix("0x"), raw.count > 132
        else { return rpcResponse(error: "invalid raw transaction") }
        result = "0x" + Hex.encode(Keccak.keccak256(bytes))
      default: return rpcResponse(error: "unexpected method \(method)")
      }
      return rpcResponse(result: result)
    }

    let id = try await service.prepare(
      method: "eth_sendTransaction",
      params: .array([
        .object([
          "to": .string("0x0000000000000000000000000000000000000001"),
          "value": .string("0x0"),
        ])
      ]),
      origin: "https://dapp.example", chainId: "1")

    let record = try await service.store.record(id)
    guard case .array(let params) = record?.params, case .object(let transaction)? = params.first
    else {
      Issue.record("expected prepared transaction")
      return
    }
    #expect(transaction["nonce"] == .string("0x7"))
    #expect(transaction["gas"] == .string("0x5208"))
    #expect(transaction["gasPrice"] == .string("0x3b9aca00"))
    #expect(transaction["chainId"] == .string("0x1"))
    let summary = try await service.summarize(request: id)
    #expect(summary?.rows.contains { $0.label == "Nonce" && $0.value == "0x7" } == true)
    #expect(summary?.rows.contains { $0.label == "Gas limit" && $0.value == "0x5208" } == true)
    #expect(
      summary?.rows.contains { $0.label == "Gas price" && $0.value == "0x3b9aca00" }
        == true)

    let result = try await service.approve(request: id)
    #expect(result.stringValue.flatMap(Hex.data)?.count == 32)
    #expect(await service.status(for: id)?.status == "consumed")
  }

  @Test("a structured broadcast error is terminal and preserved for polling")
  func broadcastErrorPreserved() async throws {
    let service = service { request in
      let object = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      let method = object.nestedString(at: ["method"])!
      if method == "eth_sendRawTransaction" {
        return rpcResponse(error: "insufficient funds", code: -32000)
      }
      return rpcResponse(error: "unexpected method \(method)")
    }
    let id = try await service.prepare(
      method: "eth_sendTransaction",
      params: .array([
        .object([
          "to": .string("0x0000000000000000000000000000000000000001"),
          "value": .string("0x0"),
          "nonce": .string("0x0"),
          "gas": .string("0x5208"),
          "gasPrice": .string("0x3b9aca00"),
        ])
      ]),
      origin: "https://dapp.example", chainId: "1")

    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(-32000),
          "message": .string("insufficient funds"),
        ]))
    ) {
      try await service.approve(request: id)
    }
    let status = await service.status(for: id)
    #expect(status?.status == "failed")
    #expect(status?.error?.nestedString(at: ["message"]) == "insufficient funds")
  }

  @Test("missing EIP-1559 fees are prepared without allowing max fee below priority fee")
  func preparesDynamicFees() async throws {
    let service = service { request in
      let object = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      switch object.nestedString(at: ["method"]) {
      case "eth_maxPriorityFeePerGas": return rpcResponse(result: "0x77359400")
      case "eth_gasPrice": return rpcResponse(result: "0x3b9aca00")
      default: return rpcResponse(error: "unexpected method")
      }
    }
    let id = try await service.prepare(
      method: "eth_sendTransaction",
      params: .array([
        .object([
          "type": .string("0x2"),
          "to": .string("0x0000000000000000000000000000000000000001"),
          "nonce": .string("0x0"),
          "gas": .string("0x5208"),
        ])
      ]),
      origin: "https://dapp.example", chainId: "1")

    guard case .array(let params) = try await service.store.record(id)?.params,
      case .object(let transaction)? = params.first
    else {
      Issue.record("expected prepared transaction")
      return
    }
    #expect(transaction["maxPriorityFeePerGas"] == .string("0x77359400"))
    #expect(transaction["maxFeePerGas"] == .string("0x77359400"))
  }

  @Test("malformed canonical transaction is rejected before persistence")
  func rejectsMalformedBeforePersistence() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "eth_sendTransaction",
        params: .array([
          .object([
            "to": .string("not-an-address"),
            "nonce": .string("0x0"),
            "gas": .string("0x5208"),
            "gasPrice": .string("0x3b9aca00"),
          ])
        ]),
        origin: "https://dapp.example", chainId: "1")
    }
    #expect(try await service.list().isEmpty)
  }

  @Test("non-empty access lists are rejected instead of silently discarded")
  func rejectsAccessList() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "eth_sendTransaction",
        params: .array([
          .object([
            "type": .string("0x2"),
            "to": .string("0x0000000000000000000000000000000000000001"),
            "nonce": .string("0x0"),
            "gas": .string("0x5208"),
            "maxPriorityFeePerGas": .string("0x1"),
            "maxFeePerGas": .string("0x2"),
            "accessList": .array([.object([:])]),
          ])
        ]),
        origin: "https://dapp.example", chainId: "1")
    }
  }

  @Test("supplied max fee cannot be lower than the priority fee")
  func rejectsInvalidDynamicFees() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "eth_sendTransaction",
        params: .array([
          .object([
            "type": .string("0x2"),
            "to": .string("0x0000000000000000000000000000000000000001"),
            "nonce": .string("0x0"),
            "gas": .string("0x5208"),
            "maxPriorityFeePerGas": .string("0x2"),
            "maxFeePerGas": .string("0x1"),
          ])
        ]),
        origin: "https://dapp.example", chainId: "1")
    }
  }

  @Test("unsupported transaction extensions are rejected instead of omitted from signing")
  func rejectsUnsupportedFields() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "eth_sendTransaction",
        params: .array([
          .object([
            "type": .string("0x2"),
            "to": .string("0x0000000000000000000000000000000000000001"),
            "nonce": .string("0x0"),
            "gas": .string("0x5208"),
            "maxPriorityFeePerGas": .string("0x1"),
            "maxFeePerGas": .string("0x2"),
            "authorizationList": .array([]),
          ])
        ]),
        origin: "https://dapp.example", chainId: "1")
    }
  }

  @Test("conflicting transaction aliases are rejected")
  func rejectsConflictingAliases() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "eth_sendTransaction",
        params: .array([
          .object([
            "to": .string("0x0000000000000000000000000000000000000001"),
            "data": .string("0x01"),
            "input": .string("0x02"),
            "nonce": .string("0x0"),
            "gas": .string("0x5208"),
            "gasPrice": .string("0x1"),
          ])
        ]),
        origin: "https://dapp.example", chainId: "1")
    }
  }

  @Test("a malformed destination cannot become an implicit contract creation")
  func rejectsMalformedDestination() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "eth_sendTransaction",
        params: .array([
          .object([
            "to": .number(1),
            "nonce": .string("0x0"),
            "gas": .string("0x5208"),
            "gasPrice": .string("0x1"),
          ])
        ]),
        origin: "https://dapp.example", chainId: "1")
    }
  }

  @Test("a mismatched node transaction hash is terminal")
  func rejectsMismatchedHash() async throws {
    let service = service { request in
      let object = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      guard object.nestedString(at: ["method"]) == "eth_sendRawTransaction" else {
        return rpcResponse(error: "unexpected method")
      }
      return rpcResponse(result: "0x" + String(repeating: "ab", count: 32))
    }
    let id = try await prepareCompleteLegacy(service)
    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(-32603),
          "message": .string("RPC returned a mismatched transaction hash"),
        ]))
    ) {
      try await service.approve(request: id)
    }
    #expect(await service.status(for: id)?.status == "failed")
  }

  @Test("a malformed persisted send becomes terminal instead of remaining pending")
  func oldMalformedSendFailsTerminally() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    let id = UUID()
    let params = JSONValue.array([
      .object(["to": .string("0x0000000000000000000000000000000000000001")])
    ])
    try await service.store.insert(
      WalletPendingRequest(
        id: id, kind: .send, method: "eth_sendTransaction",
        origin: "https://dapp.example", chainId: "1", account: service.account,
        params: params, payloadDigest: CanonicalRequest.digest(of: params, keyedBy: id)))

    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(-32602),
          "message": .string("Invalid persisted request parameters"),
        ]))
    ) {
      try await service.approve(request: id)
    }
    #expect(await service.status(for: id)?.status == "failed")
  }

  @Test("a complete old send with unsupported semantics becomes terminal")
  func oldUnsupportedSendFailsTerminally() async throws {
    let service = service { _ in rpcResponse(error: "RPC must not be called") }
    let id = UUID()
    let params = JSONValue.array([
      .object([
        "from": .string(service.account),
        "to": .string("0x0000000000000000000000000000000000000001"),
        "value": .string("0x0"),
        "data": .string("0x"),
        "nonce": .string("0x0"),
        "gas": .string("0x5208"),
        "gasPrice": .string("0x1"),
        "chainId": .string("0x1"),
        "authorizationList": .array([]),
      ])
    ])
    try await service.store.insert(
      WalletPendingRequest(
        id: id, kind: .send, method: "eth_sendTransaction",
        origin: "https://dapp.example", chainId: "1", account: service.account,
        params: params, payloadDigest: CanonicalRequest.digest(of: params, keyedBy: id)))

    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(-32602),
          "message": .string("Invalid persisted request parameters"),
        ]))
    ) {
      try await service.approve(request: id)
    }
    #expect(await service.status(for: id)?.status == "failed")
  }

  @Test("request claims are atomic across store instances")
  func atomicClaim() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TransactionClaimTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = PendingRequestStore(directory: directory)
    let second = PendingRequestStore(directory: directory)
    let id = UUID()
    let firstClaim = first.claim(id)
    guard let firstClaim else {
      Issue.record("expected first claim")
      return
    }
    #expect(second.claim(id) == nil)
    first.releaseClaim(firstClaim)
    let secondClaim = second.claim(id)
    guard let secondClaim else {
      Issue.record("expected second claim after release")
      return
    }
    second.releaseClaim(secondClaim)
  }

  private func prepareCompleteLegacy(_ service: WalletService) async throws -> UUID {
    try await service.prepare(
      method: "eth_sendTransaction",
      params: .array([
        .object([
          "to": .string("0x0000000000000000000000000000000000000001"),
          "value": .string("0x0"),
          "nonce": .string("0x0"),
          "gas": .string("0x5208"),
          "gasPrice": .string("0x3b9aca00"),
        ])
      ]),
      origin: "https://dapp.example", chainId: "1")
  }
}

private final class TransactionURLProtocol: URLProtocol {
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

private func requestBody(_ request: URLRequest) -> Data {
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

private struct TransactionSigner: Signing {
  let account: String
  private let keypair: EthereumKeypair

  init() {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 1
    keypair = try! EthereumKeypair.from(secret: secret)
    account = keypair.address
  }

  func hasKey() -> Bool { true }
  func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    try EthereumSigner.sign(digest: digest, keypair: keypair)
  }
}

private func rpcResponse(result: String) -> (HTTPURLResponse, Data) {
  (
    httpResponse(),
    try! JSONEncoder().encode(
      JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .number(1), "result": .string(result),
      ]))
  )
}

private func rpcResponse(error: String, code: Int = -32603) -> (HTTPURLResponse, Data) {
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
