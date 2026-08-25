import Foundation
import Testing

@testable import StupidWalletCore

@Suite(.serialized)
struct AuthorizationServiceTests {
  @Test("status distinguishes empty, canonical, and malformed code without unsupported RPCs")
  func statusClassification() async {
    let target = String(EIP5792.simple7702Account.dropFirst(2)).lowercased()
    let rpc = AuthorizationRPCStub(results: [
      "1": ["eth_getCode": [.string("0x")]],
      "8453": ["eth_getCode": [.string("0xef0100\(target)")]],
      "42161": ["eth_getCode": [.string("0x60016000")]],
      "10": ["eth_getCode": [.string("0x")]],
    ])
    let service = makeService(rpc: rpc)

    let statuses = await service.statuses()

    #expect(statuses.map(\.network.id) == ["1", "8453", "42161", "10"])
    #expect(statuses[0].state == .notAuthorized)
    #expect(
      statuses[1].state
        == .authorized(delegate: "0x\(target)"))
    #expect(statuses[2].state == .malformed(code: "0x60016000"))
    #expect(rpc.chains == ["1", "8453", "42161", "10"])
  }

  @Test("status preserves a foreign delegate and structured node errors")
  func foreignAndUnavailableStatus() async {
    let foreign = String(repeating: "11", count: 20)
    let nodeError = JSONValue.object([
      "code": .number(-32000), "message": .string("rate limited"),
      "data": .object(["retry": .bool(true)]),
    ])
    let rpc = AuthorizationRPCStub(results: [
      "1": ["eth_getCode": [.string("0xef0100\(foreign)")]],
      "8453": ["eth_getCode": [.error(nodeError)]],
      "42161": ["eth_getCode": [.string("0x")]],
      "10": ["eth_getCode": [.string("0x")]],
    ])

    let statuses = await makeService(rpc: rpc).statuses()

    #expect(statuses[0].state == .authorized(delegate: "0x\(foreign)"))
    #expect(statuses[1].state == .unavailable(error: .node(nodeError)))
  }

  @Test("enable uses the exact v1 RPC sequence, two verified signatures, and type-4 hash")
  func enableSequence() async throws {
    let rpc = operationRPC(accountCode: "0x")
    let signer = RecordingAuthorizationSigner()
    let service = makeService(rpc: rpc, signing: signer)

    let hash = try await service.enable(chainID: "1")

    #expect(
      rpc.methods == [
        "eth_getCode", "eth_getCode", "eth_getTransactionCount", "eth_estimateGas",
        "eth_maxPriorityFeePerGas", "eth_gasPrice", "eth_sendRawTransaction",
      ])
    #expect(rpc.params[0] == .array([.string(EIP5792.simple7702Account), .string("latest")]))
    #expect(rpc.params[1] == .array([.string(signer.account), .string("latest")]))
    #expect(rpc.rawTransaction?.first == 0x04)
    #expect(hash == rpc.rawTransaction.map { "0x" + Hex.encode(Keccak.keccak256($0)) })
    #expect(signer.digests.count == 2)
    let expectedAuthorization = try EIP7702Authorization(
      chainID: "0x1", delegate: EIP5792.simple7702Account, nonce: 8)
    #expect(signer.digests.first == expectedAuthorization.digest())
  }

  @Test("revoke uses zero-address chain-bound authorization and exact RPC sequence")
  func revokeSequence() async throws {
    let foreign = String(repeating: "22", count: 20)
    let rpc = operationRPC(accountCode: "0xef0100\(foreign)", includeImplementation: false)
    let signer = RecordingAuthorizationSigner()

    let hash = try await makeService(rpc: rpc, signing: signer).revoke(chainID: "1")

    #expect(
      rpc.methods == [
        "eth_getCode", "eth_getTransactionCount", "eth_estimateGas",
        "eth_maxPriorityFeePerGas", "eth_gasPrice", "eth_sendRawTransaction",
      ])
    let expectedAuthorization = try EIP7702Authorization(
      chainID: "0x1", delegate: AuthorizationService.zeroAddress, nonce: 8)
    #expect(signer.digests.first == expectedAuthorization.digest())
    #expect(rpc.rawTransaction?.first == 0x04)
    #expect(hash == rpc.rawTransaction.map { "0x" + Hex.encode(Keccak.keccak256($0)) })
  }

  @Test("foreign delegation needs explicit replacement and malformed code is never overwritten")
  func replacementSafety() async {
    let foreign = "0x" + String(repeating: "33", count: 20)
    let foreignRPC = operationRPC(accountCode: "0xef0100\(foreign.dropFirst(2))")
    await #expect(
      throws: AuthorizationOperationError.replacementConfirmationRequired(delegate: foreign)
    ) {
      try await makeService(rpc: foreignRPC).enable(chainID: "1")
    }
    #expect(foreignRPC.methods == ["eth_getCode", "eth_getCode"])

    let malformedRPC = operationRPC(accountCode: "0x6000")
    await #expect(throws: AuthorizationOperationError.unsafeAccountCode(code: "0x6000")) {
      try await makeService(rpc: malformedRPC).enable(
        chainID: "1", replacingForeignAuthorization: true)
    }
    #expect(malformedRPC.methods == ["eth_getCode", "eth_getCode"])
  }

  @Test("enable rejects missing or invalid implementation code before account or signing calls")
  func implementationRequired() async {
    for implementation in ["0x", "invalid"] {
      let rpc = AuthorizationRPCStub(results: [
        "1": ["eth_getCode": [.string(implementation)]]
      ])
      if implementation == "0x" {
        await #expect(throws: AuthorizationOperationError.missingImplementation) {
          try await makeService(rpc: rpc).enable(chainID: "1")
        }
      } else {
        await #expect(
          throws: AuthorizationOperationError.rpc(
            .invalidResponse("Invalid data from eth_getCode"))
        ) {
          try await makeService(rpc: rpc).enable(chainID: "1")
        }
      }
      #expect(rpc.methods == ["eth_getCode"])
    }
  }

  @Test("node errors, signer mismatch, and nonce overflow stop before broadcast")
  func terminalFailures() async {
    let nodeError = JSONValue.object([
      "code": .number(-32000), "message": .string("temporarily unavailable"),
    ])
    let nodeRPC = AuthorizationRPCStub(results: [
      "1": ["eth_getCode": [.error(nodeError)]]
    ])
    await #expect(
      throws: AuthorizationOperationError.rpc(.node(nodeError))
    ) {
      try await makeService(rpc: nodeRPC).revoke(chainID: "1")
    }

    let mismatchRPC = operationRPC(accountCode: "0x")
    let mismatchedSigner = RecordingAuthorizationSigner(signWithDifferentKey: true)
    await #expect(throws: AuthorizationOperationError.signerMismatch) {
      try await makeService(rpc: mismatchRPC, signing: mismatchedSigner).enable(chainID: "1")
    }
    #expect(!mismatchRPC.methods.contains("eth_sendRawTransaction"))

    let overflowRPC = operationRPC(
      accountCode: "0x", nonce: "0xffffffffffffffff")
    let overflowSigner = RecordingAuthorizationSigner()
    await #expect(throws: AuthorizationOperationError.nonceOverflow) {
      try await makeService(rpc: overflowRPC, signing: overflowSigner).enable(chainID: "1")
    }
    #expect(overflowSigner.digests.isEmpty)
    #expect(!overflowRPC.methods.contains("eth_sendRawTransaction"))
  }

  @Test("a mismatched node hash is rejected after type-4 serialization")
  func mismatchedHash() async {
    let rpc = operationRPC(
      accountCode: "0x", broadcast: .string("0x" + String(repeating: "ab", count: 32)))
    await #expect(
      throws: AuthorizationOperationError.rpc(
        .invalidResponse("RPC returned a mismatched transaction hash"))
    ) {
      try await makeService(rpc: rpc).enable(chainID: "1")
    }
    #expect(rpc.rawTransaction?.first == 0x04)
    #expect(rpc.methods.last == "eth_sendRawTransaction")
  }

  @Test("unsupported or unconfigured chains make no RPC calls")
  func unsupportedChains() async {
    let rpc = AuthorizationRPCStub(results: [:])
    await #expect(throws: AuthorizationOperationError.unsupportedChain) {
      try await makeService(rpc: rpc).enable(chainID: "31337")
    }
    await #expect(throws: AuthorizationOperationError.unsupportedChain) {
      try await makeService(rpc: rpc).revoke(chainID: "137")
    }
    #expect(rpc.methods.isEmpty)
  }

  @Test("receipt boundary reports pending, success, and revert")
  func receiptStatus() async throws {
    let hash = "0x" + String(repeating: "ab", count: 32)
    let rpc = AuthorizationRPCStub(results: [
      "1": [
        "eth_getTransactionReceipt": [
          .null,
          .object(["status": .string("0x1"), "blockNumber": .string("0x10")]),
          .object(["status": .string("0x0"), "blockNumber": .string("0x11")]),
        ]
      ]
    ])
    let service = makeService(rpc: rpc)
    #expect(try await service.receiptStatus(transactionHash: hash, chainID: "1") == .pending)
    #expect(
      try await service.receiptStatus(transactionHash: hash, chainID: "1")
        == .confirmed(blockNumber: "0x10"))
    #expect(
      try await service.receiptStatus(transactionHash: hash, chainID: "1")
        == .reverted(blockNumber: "0x11"))
  }

  @Test("reviewed deployment primitive has the exact transaction calldata and CREATE2 target")
  func deploymentPrimitive() throws {
    let creationCode = try #require(Hex.data(Simple7702AccountDeployment.creationCode))
    let calldata = try #require(Hex.data(Simple7702AccountDeployment.calldata))
    #expect(creationCode.count == 3_665)
    #expect(calldata.count == 3_697)
    #expect(Array(calldata.prefix(32)) == [UInt8](repeating: 0, count: 32))
    #expect(Array(calldata.dropFirst(32)) == creationCode)
    #expect(
      "0x" + Hex.encode(Keccak.keccak256(calldata))
        == "0x414122fad5a970579482e95a967d40376305e3e120dad055e75f0821360b679e")
    #expect(Simple7702AccountDeployment.isValid())
  }

  @Test("verified implementation status is cached while missing and unsafe results are not")
  func customChainImplementationStatus() async throws {
    let chainID = "31337"
    let rpc = AuthorizationRPCStub(results: [
      chainID: ["eth_getCode": [.string("0x6000")]]
    ])
    let service = makeService(rpc: rpc, customChainID: chainID)

    #expect(try await service.implementationState(chainID: chainID) == .verified)
    #expect(try await service.implementationState(chainID: chainID) == .verified)
    #expect(rpc.chains == [chainID])

    let missingRPC = AuthorizationRPCStub(results: [
      chainID: ["eth_getCode": [.string("0x"), .string("0x")]]
    ])
    let missing = makeService(rpc: missingRPC, customChainID: chainID)
    #expect(try await missing.implementationState(chainID: chainID) == .missing)
    #expect(try await missing.implementationState(chainID: chainID) == .missing)
    #expect(missingRPC.chains == [chainID, chainID])

    let unsafeRPC = AuthorizationRPCStub(results: [
      chainID: ["eth_getCode": [.string("0x6001")]]
    ])
    #expect(
      try await makeService(rpc: unsafeRPC, customChainID: chainID)
        .implementationState(chainID: chainID) == .unsafe(code: "0x6001"))
  }

  @Test("loopback implementation status bypasses the persistent cache")
  func loopbackImplementationStatus() async throws {
    let chainID = "31337"
    let rpc = AuthorizationRPCStub(results: [
      chainID: ["eth_getCode": [.string("0x6000"), .string("0x")]]
    ])
    let service = makeService(
      rpc: rpc, customChainID: chainID,
      customRPCURL: URL(string: "http://127.0.0.1:8545/31337")!)

    #expect(try await service.implementationState(chainID: chainID) == .verified)
    #expect(try await service.implementationState(chainID: chainID) == .missing)
    #expect(rpc.chains == [chainID, chainID])
  }

  @Test("custom configured chain reports missing and deploys the exact reviewed transaction")
  func customChainDeployment() async throws {
    let chainID = "31337"
    let factoryCode =
      "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
    #expect(
      "0x" + Hex.encode(Keccak.keccak256(try #require(Hex.data(factoryCode))))
        == Simple7702AccountDeployment.factoryRuntimeHash)
    let rpc = AuthorizationRPCStub(results: [
      chainID: [
        "eth_getCode": [.string("0x"), .string("0x"), .string(factoryCode)],
        "eth_getTransactionCount": [.string("0x7")],
        "eth_estimateGas": [.string("0x100000")],
        "eth_maxPriorityFeePerGas": [.string("0x3b9aca00")],
        "eth_gasPrice": [.string("0x77359400")],
        "eth_sendRawTransaction": [.rawTransactionHash],
      ]
    ])
    let signer = RecordingAuthorizationSigner()
    let service = makeService(rpc: rpc, signing: signer, customChainID: chainID)

    #expect(try await service.implementationState(chainID: chainID) == .missing)
    let hash = try await service.deployImplementation(chainID: chainID)

    #expect(
      rpc.methods == [
        "eth_getCode", "eth_getCode", "eth_getCode", "eth_getTransactionCount",
        "eth_estimateGas", "eth_maxPriorityFeePerGas", "eth_gasPrice",
        "eth_sendRawTransaction",
      ])
    #expect(
      rpc.params[2]
        == .array([.string(Simple7702AccountDeployment.factory), .string("latest")]))
    #expect(
      rpc.params[4]
        == .array([
          .object([
            "from": .string(signer.account), "to": .string(Simple7702AccountDeployment.factory),
            "value": .string("0x0"), "data": .string(Simple7702AccountDeployment.calldata),
          ])
        ]))
    #expect(rpc.rawTransaction?.first == 0x02)
    #expect(hash == rpc.rawTransaction.map { "0x" + Hex.encode(Keccak.keccak256($0)) })
    #expect(signer.digests.count == 1)

    let expected = EIP1559Transaction(
      chainId: 31_337, nonce: "0x7", maxPriorityFeePerGas: "0x3b9aca00",
      maxFeePerGas: "0x77359400", gasLimit: "0x133333",
      to: Simple7702AccountDeployment.factory, value: "0x0",
      data: Simple7702AccountDeployment.calldata)
    let expectedDigest = Keccak.keccak256(try expected.signingPayload())
    let expectedRaw = try expected.signedPayload(signature: signer.signature(for: expectedDigest))
    #expect(signer.digests == [expectedDigest])
    #expect(rpc.rawTransaction == expectedRaw)
  }

  @Test("deployment refuses wrong implementation and missing or wrong canonical factory")
  func deploymentRefusals() async {
    let chainID = "31337"
    let wrongImplementation = AuthorizationRPCStub(results: [
      chainID: ["eth_getCode": [.string("0x6001")]]
    ])
    await #expect(throws: Simple7702AccountDeploymentError.unsafeImplementation(code: "0x6001")) {
      try await makeService(rpc: wrongImplementation, customChainID: chainID)
        .deployImplementation(chainID: chainID)
    }
    #expect(wrongImplementation.methods == ["eth_getCode"])

    let missingFactory = AuthorizationRPCStub(results: [
      chainID: ["eth_getCode": [.string("0x"), .string("0x")]]
    ])
    await #expect(throws: Simple7702AccountDeploymentError.missingCanonicalFactory) {
      try await makeService(rpc: missingFactory, customChainID: chainID)
        .deployImplementation(chainID: chainID)
    }
    #expect(missingFactory.methods == ["eth_getCode", "eth_getCode"])

    let wrongFactory = AuthorizationRPCStub(results: [
      chainID: ["eth_getCode": [.string("0x"), .string("0x6002")]]
    ])
    await #expect(
      throws: Simple7702AccountDeploymentError.unsafeCanonicalFactory(code: "0x6002")
    ) {
      try await makeService(rpc: wrongFactory, customChainID: chainID)
        .deployImplementation(chainID: chainID)
    }
    #expect(wrongFactory.methods == ["eth_getCode", "eth_getCode"])
  }

  private func makeService(
    rpc: AuthorizationRPCStub,
    signing: RecordingAuthorizationSigner = RecordingAuthorizationSigner(),
    customChainID: String? = nil,
    customRPCURL: URL? = nil
  ) -> AuthorizationService {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AuthorizationServiceTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let networkStore = NetworkStore(
      directory: directory, legacySuiteName: "AuthorizationServiceTests.\(UUID().uuidString)")
    if let customChainID {
      try? networkStore.add(name: "Custom", chainID: customChainID)
    }
    var overrides = [
      "1": URL(string: "https://rpc.example/1")!,
      "8453": URL(string: "https://rpc.example/8453")!,
      "42161": URL(string: "https://rpc.example/42161")!,
    ]
    if let customChainID {
      overrides[customChainID] =
        customRPCURL ?? URL(string: "https://rpc.example/\(customChainID)")!
    }
    return AuthorizationService(
      account: signing.account, signing: signing,
      networkStore: networkStore, resolver: RPCResolver(overrides: overrides),
      rpcClient: RPCClient(session: rpc.session),
      deploymentStore: Simple7702AccountDeploymentStore(directory: directory),
      submissionLock: TransactionSubmissionLock(directory: directory),
      simple7702AccountRuntimeHash: "0x" + Hex.encode(Keccak.keccak256([0x60, 0x00])))
  }

  private func operationRPC(
    accountCode: String, nonce: String = "0x7", includeImplementation: Bool = true,
    broadcast: AuthorizationRPCStub.Answer = .rawTransactionHash
  ) -> AuthorizationRPCStub {
    var code: [AuthorizationRPCStub.Answer] = []
    if includeImplementation { code.append(.string("0x6000")) }
    code.append(.string(accountCode))
    return AuthorizationRPCStub(results: [
      "1": [
        "eth_getCode": code,
        "eth_getTransactionCount": [.string(nonce)],
        "eth_estimateGas": [.string("0x5208")],
        "eth_maxPriorityFeePerGas": [.string("0x3b9aca00")],
        "eth_gasPrice": [.string("0x77359400")],
        "eth_sendRawTransaction": [broadcast],
      ]
    ])
  }
}

private final class AuthorizationRPCStub: @unchecked Sendable {
  enum Answer: Sendable {
    case string(String)
    case value(JSONValue)
    case error(JSONValue)
    case rawTransactionHash

    static var null: Self { .value(.null) }
    static func object(_ value: [String: JSONValue]) -> Self { .value(.object(value)) }
  }

  private let lock = NSLock()
  private var results: [String: [String: [Answer]]]
  private(set) var methods: [String] = []
  private(set) var chains: [String] = []
  private(set) var params: [JSONValue] = []
  private(set) var rawTransaction: [UInt8]?
  let session: URLSession

  init(results: [String: [String: [Answer]]]) {
    self.results = results
    let configuration = URLSessionConfiguration.ephemeral
    let protocolClass = AuthorizationURLProtocol.self
    configuration.protocolClasses = [protocolClass]
    session = URLSession(configuration: configuration)
    protocolClass.handler = { [weak self] request in
      guard let self else { fatalError("authorization RPC stub released") }
      return self.response(request)
    }
  }

  private func response(_ request: URLRequest) -> (HTTPURLResponse, Data) {
    lock.withLock {
      let body = authorizationRequestBody(request)
      let value = try! JSONDecoder().decode(JSONValue.self, from: body)
      let method = value.nestedString(at: ["method"])!
      let chain = request.url!.lastPathComponent
      guard case .object(let object) = value, let requestParams = object["params"] else {
        fatalError("invalid RPC request")
      }
      methods.append(method)
      chains.append(chain)
      params.append(requestParams)
      guard var answers = results[chain]?[method], !answers.isEmpty else {
        fatalError("unexpected RPC call \(method) on \(chain)")
      }
      let answer = answers.removeFirst()
      results[chain]![method] = answers
      if method == "eth_sendRawTransaction" {
        guard case .array(let values) = requestParams, let raw = values.first?.stringValue,
          let bytes = Hex.data(raw)
        else { fatalError("missing raw transaction") }
        rawTransaction = bytes
      }
      let response: JSONValue
      switch answer {
      case .string(let string):
        response = .object(["jsonrpc": .string("2.0"), "id": .number(1), "result": .string(string)])
      case .value(let value):
        response = .object(["jsonrpc": .string("2.0"), "id": .number(1), "result": value])
      case .error(let error):
        response = .object(["jsonrpc": .string("2.0"), "id": .number(1), "error": error])
      case .rawTransactionHash:
        guard let bytes = rawTransaction else { fatalError("missing raw transaction") }
        response = .object([
          "jsonrpc": .string("2.0"), "id": .number(1),
          "result": .string("0x" + Hex.encode(Keccak.keccak256(bytes))),
        ])
      }
      return (httpResponse(), try! JSONEncoder().encode(response))
    }
  }
}

private func authorizationRequestBody(_ request: URLRequest) -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count > 0 else { break }
    data.append(buffer, count: count)
  }
  return data
}

private final class AuthorizationURLProtocol: URLProtocol {
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

private final class RecordingAuthorizationSigner: Signing, @unchecked Sendable {
  let account: String
  private let keypair: EthereumKeypair
  private let signingKeypair: EthereumKeypair
  private let lock = NSLock()
  private(set) var digests: [[UInt8]] = []

  init(signWithDifferentKey: Bool = false) {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 1
    keypair = try! EthereumKeypair.from(secret: secret)
    account = keypair.address
    secret[31] = signWithDifferentKey ? 2 : 1
    signingKeypair = try! EthereumKeypair.from(secret: secret)
  }

  func hasKey() -> Bool { true }
  func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    lock.withLock { digests.append(digest) }
    return try EthereumSigner.sign(digest: digest, keypair: signingKeypair)
  }

  func signature(for digest: [UInt8]) throws -> [UInt8] {
    try EthereumSigner.sign(digest: digest, keypair: signingKeypair)
  }
}
