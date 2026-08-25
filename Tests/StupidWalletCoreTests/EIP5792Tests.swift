import Foundation
import Testing

@testable import StupidWalletCore

struct EIP5792EncodingTests {
  private let account = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"

  @Test("executeBatch calldata matches viem 2.55.19")
  func abiVector() throws {
    let prepared = try EIP5792.prepare(
      params: .array([
        .object([
          "version": .string("2.0.0"), "from": .string(account),
          "chainId": .string("0x1"), "atomicRequired": .bool(true),
          "calls": .array([
            .object([
              "to": .string("0x1111111111111111111111111111111111111111"),
              "value": .string("0x1"), "data": .string("0x1234"),
            ]),
            .object([
              "to": .string("0x2222222222222222222222222222222222222222"),
              "value": .string("0x0"), "data": .string("0x"),
            ]),
          ]),
        ])
      ]), account: account, activeChainID: "1")
    #expect(
      prepared.calldata
        == "0x34fcd5be00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000212340000000000000000000000000000000000000000000000000000000000000000000000000000000000002222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000"
    )
  }

  @Test("shipped v1 defaults and canonical v2 are both accepted")
  func versions() throws {
    let v1 = try EIP5792.prepare(
      params: callsParams(version: nil), account: account, activeChainID: "1")
    #expect(v1.isV2 == false)
    #expect(v1.params.nestedString(at: ["version"]) == "1.0")

    let v2 = try EIP5792.prepare(
      params: callsParams(version: "2.0.0", atomicRequired: true), account: account,
      activeChainID: "1")
    #expect(v2.isV2)
    #expect(v2.params.nestedString(at: ["from"]) == account)
  }

  @Test("strict validation rejects malformed calls and unsupported required capabilities")
  func validation() throws {
    var object = try #require(callsParams(version: "2.0.0", atomicRequired: true).firstObject)
    object["calls"] = .array([])
    #expect(throws: EIP5792Error.invalidParams) {
      try EIP5792.prepare(params: .array([.object(object)]), account: account, activeChainID: "1")
    }
    object = try #require(callsParams(version: "2.0.0", atomicRequired: true).firstObject)
    object["capabilities"] = .object(["paymasterService": .object([:])])
    #expect(throws: EIP5792Error.unsupportedCapability("paymasterService")) {
      try EIP5792.prepare(params: .array([.object(object)]), account: account, activeChainID: "1")
    }
    object["capabilities"] = .object([
      "paymasterService": .object(["optional": .bool(true)])
    ])
    _ = try EIP5792.prepare(
      params: .array([.object(object)]), account: account, activeChainID: "1")
  }

  private func callsParams(version: String?, atomicRequired: Bool? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
      "calls": .array([
        .object([
          "to": .string("0x1111111111111111111111111111111111111111"),
          "value": .string("0x0"), "data": .string("0x"),
        ])
      ])
    ]
    if let version { object["version"] = .string(version) }
    if version != nil { object["chainId"] = .string("0x1") }
    if let atomicRequired { object["atomicRequired"] = .bool(atomicRequired) }
    return .array([.object(object)])
  }
}

@Suite(.serialized)
struct EIP5792ServiceTests {
  @Test("already-delegated v1 sends type 2 and returns the transaction hash")
  func delegatedV1() async throws {
    let state = CallsRPCState(accountCode: delegationCode)
    let (service, _) = makeService(state: state)
    await service.connect(origin: origin, profileID: profile)
    let id = try await service.prepare(
      method: "wallet_sendCalls", params: v1Params(), origin: origin, profileID: profile)
    let summary = try await service.summarize(request: id, profileID: profile)
    #expect(summary?.kind == "batch")
    #expect(summary?.rows.contains { $0.label == "Execution" && $0.value == "Atomic" } == true)
    let result = try await service.approve(request: id, profileID: profile)
    #expect(result.stringValue == state.transactionHash)
    #expect(state.rawTransaction?.first == 0x02)
    #expect(try await service.activities().first?.method == "wallet_sendCalls")
    #expect(try await service.activities().first?.transactionData?.hasPrefix("0x34fcd5be") == true)
  }

  @Test("missing delegation signs chain-bound authorization nonce plus one and sends type 4")
  func automaticDelegationV2() async throws {
    let state = CallsRPCState(accountCode: "0x")
    let (service, signer) = makeService(state: state)
    await service.connect(origin: origin, profileID: profile)
    let id = try await service.prepare(
      method: "wallet_sendCalls", params: v2Params(id: appID), origin: origin,
      profileID: profile)
    let result = try await service.approve(request: id, profileID: profile)
    #expect(result.nestedString(at: ["id"]) == appID)
    #expect(result.nestedBool(at: ["capabilities", "atomic"]) == true)
    #expect(state.rawTransaction?.first == 0x04)
    let expectedAuthorization = try EIP7702Authorization(
      chainID: "0x1", delegate: EIP5792.simple7702Account, nonce: 8)
    #expect(signer.digests.first == expectedAuthorization.digest())
    #expect(state.estimateParams?.value(at: ["0", "authorizationList"]) == nil)
    #expect(
      state.estimateParams?.value(at: ["2", signer.account, "code"])?.stringValue == "0x6001")

    let status = try await service.getCallsStatus(
      params: .array([.string(state.transactionHash)]), origin: origin, profileID: profile)
    #expect(status.nestedNumber(at: ["status"]) == 200)
    #expect(status.nestedString(at: ["id"]) == state.transactionHash)
  }

  @Test("wallet_sendCalls never replaces foreign or malformed account code")
  func rejectsUnsafeAccountCode() async throws {
    for code in [
      "0xef0100" + String(repeating: "11", count: 20),
      "0x6000",
    ] {
      let state = CallsRPCState(accountCode: code)
      let (service, signer) = makeService(state: state)
      await service.connect(origin: origin, profileID: profile)
      let id = try await service.prepare(
        method: "wallet_sendCalls", params: v1Params(), origin: origin, profileID: profile)
      await #expect(
        throws: WalletError.rpc(
          .object([
            "code": .number(5700),
            "message": .string(
              "Account code cannot be replaced by wallet_sendCalls; review it in Authorizations"),
          ]))
      ) {
        try await service.approve(request: id, profileID: profile)
      }
      #expect(signer.digests.isEmpty)
      #expect(!state.methods.contains("eth_sendRawTransaction"))
    }
  }

  @Test("batch mutation is rejected by the canonical binding before RPC")
  func mutation() async throws {
    let state = CallsRPCState(accountCode: delegationCode)
    let (service, _) = makeService(state: state)
    await service.connect(origin: origin, profileID: profile)
    let id = try await service.prepare(
      method: "wallet_sendCalls", params: v1Params(), origin: origin, profileID: profile)
    let original = try #require(await service.store.record(id))
    guard case .object(var params) = original.params, case .array(var calls) = params["calls"],
      case .object(var call) = calls[0]
    else {
      Issue.record("expected canonical batch")
      return
    }
    call["value"] = .string("0x1")
    calls[0] = .object(call)
    params["calls"] = .array(calls)
    try await service.store.insert(
      WalletPendingRequest(
        id: original.id, kind: original.kind, method: original.method, origin: original.origin,
        profileID: original.profileID, chainId: original.chainId, account: original.account,
        params: .object(params), payloadDigest: original.payloadDigest,
        intentDigest: original.intentDigest, requestKey: original.requestKey,
        createdAt: original.createdAt, expiresAt: original.expiresAt))
    await #expect(throws: WalletError.bindingMismatch) {
      try await service.approve(request: id, profileID: profile)
    }
    #expect(state.methods.isEmpty)
  }

  @Test("an app-provided ID remains idempotent only for the same provider request")
  func appIDRetryIdentity() async throws {
    let state = CallsRPCState(accountCode: delegationCode)
    let (service, _) = makeService(state: state)
    await service.connect(origin: origin, profileID: profile)
    let first = try await service.prepare(
      method: "wallet_sendCalls", params: v2Params(id: appID), origin: origin,
      profileID: profile, requestKey: "session:1")
    let retry = try await service.prepare(
      method: "wallet_sendCalls", params: v2Params(id: appID), origin: origin,
      profileID: profile, requestKey: "session:1")
    #expect(retry == first)
    await #expect(
      throws: WalletError.rpc(
        .object(["code": .number(5720), "message": .string("Duplicate ID")]))
    ) {
      try await service.prepare(
        method: "wallet_sendCalls", params: v2Params(id: appID), origin: origin,
        profileID: profile, requestKey: "session:2")
    }
  }

  @Test("capabilities require an exact grant and only claim live verified deployments")
  func capabilities() async throws {
    let state = CallsRPCState(accountCode: delegationCode)
    let (service, _) = makeService(state: state)
    await #expect(throws: WalletError.unauthorized) {
      try await service.getCapabilities(
        params: .array([.string(service.account), .array([.string("0x1")])]),
        origin: origin, profileID: profile)
    }
    await service.connect(origin: origin, profileID: profile)
    let result = try await service.getCapabilities(
      params: .array([.string(service.account), .array([.string("0x1"), .string("0xa")])]),
      origin: origin, profileID: profile)
    #expect(result.nestedString(at: ["0x1", "atomic", "status"]) == "supported")
    #expect(result.nestedBool(at: ["0x1", "atomic", "supported"]) == true)
    #expect(result.value(at: ["0xa"]) == nil)
    #expect(result.value(at: ["0x0"]) == nil)
  }

  @Test("status maps pending, reverted, offchain failure, unknown ID, and node errors")
  func statuses() async throws {
    let state = CallsRPCState(accountCode: delegationCode)
    let (service, _) = makeService(state: state)
    await service.connect(origin: origin, profileID: profile)
    let id = try await service.prepare(
      method: "wallet_sendCalls", params: v1Params(), origin: origin, profileID: profile)
    _ = try await service.approve(request: id, profileID: profile)

    state.receipt = .null
    var status = try await service.getCallsStatus(
      params: .array([.string(state.transactionHash)]), origin: origin, profileID: profile)
    #expect(status.nestedNumber(at: ["status"]) == 100)
    try await service.activityStore.updateTransaction(
      hash: state.transactionHash, status: .dropped)
    status = try await service.getCallsStatus(
      params: .array([.string(state.transactionHash)]), origin: origin, profileID: profile)
    #expect(status.nestedNumber(at: ["status"]) == 400)
    state.receipt = receipt(status: "0x0")
    status = try await service.getCallsStatus(
      params: .array([.string(state.transactionHash)]), origin: origin, profileID: profile)
    #expect(status.nestedNumber(at: ["status"]) == 500)

    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(5730), "message": .string("Unknown bundle id"),
        ]))
    ) {
      try await service.getCallsStatus(
        params: .array([.string("0x" + String(repeating: "11", count: 32))]),
        origin: origin, profileID: profile)
    }
    state.receiptError = .object([
      "code": .number(-32001), "message": .string("receipt unavailable"),
    ])
    await #expect(throws: WalletError.rpc(state.receiptError!)) {
      try await service.getCallsStatus(
        params: .array([.string(state.transactionHash)]), origin: origin, profileID: profile)
    }
  }

  @Test("required unsupported capabilities return EIP-5792 5700")
  func unsupportedCapability() async throws {
    let state = CallsRPCState(accountCode: delegationCode)
    let (service, _) = makeService(state: state)
    await service.connect(origin: origin, profileID: profile)
    var object = try #require(v1Params().firstObject)
    object["capabilities"] = .object(["paymasterService": .object([:])])
    await #expect(
      throws: WalletError.rpc(
        .object([
          "code": .number(5700),
          "message": .string("Unsupported non-optional capability: paymasterService"),
        ]))
    ) {
      try await service.prepare(
        method: "wallet_sendCalls", params: .array([.object(object)]), origin: origin,
        profileID: profile)
    }
  }

  private let origin = "https://dapp.example"
  private let profile = "profile-a"
  private let appID = "0x1234"
  private var delegationCode: String {
    "0xef0100" + EIP5792.simple7702Account.dropFirst(2).lowercased()
  }

  private func v1Params() -> JSONValue {
    .array([
      .object([
        "calls": .array([
          .object([
            "to": .string("0x1111111111111111111111111111111111111111"),
            "value": .string("0x0"), "data": .string("0x1234"),
          ])
        ])
      ])
    ])
  }

  private func v2Params(id: String) -> JSONValue {
    .array([
      .object([
        "version": .string("2.0.0"), "chainId": .string("0x1"),
        "atomicRequired": .bool(true), "id": .string(id),
        "calls": .array([
          .object([
            "to": .string("0x1111111111111111111111111111111111111111"),
            "value": .string("0x0"), "data": .string("0x1234"),
          ])
        ]),
      ])
    ])
  }

  private func makeService(state: CallsRPCState) -> (WalletService, RecordingSigner) {
    let signer = RecordingSigner()
    CallsURLProtocol.handler = { request in state.response(request: request) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CallsURLProtocol.self]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EIP5792Tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (
      WalletService(
        store: PendingRequestStore(directory: directory), signing: signer,
        connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
        chainStore: ChainStore(directory: directory),
        networkStore: NetworkStore(directory: directory, legacySuiteName: UUID().uuidString),
        activityStore: ActivityStore(
          databaseURL: directory.appendingPathComponent("Activity.sqlite")),
        resolver: RPCResolver(overrides: ["1": URL(string: "https://rpc.example")!]),
        rpcClient: RPCClient(session: URLSession(configuration: configuration)),
        simple7702AccountRuntimeHash: "0x" + Hex.encode(Keccak.keccak256([0x60, 0x01]))),
      signer
    )
  }

  private func receipt(status: String) -> JSONValue {
    .object([
      "status": .string(status), "blockHash": .string("0x" + String(repeating: "ab", count: 32)),
      "blockNumber": .string("0x10"), "gasUsed": .string("0x5208"),
      "logs": .array([
        .object([
          "address": .string("0x1111111111111111111111111111111111111111"),
          "data": .string("0x"), "topics": .array([]), "logIndex": .string("0x0"),
        ])
      ]),
    ])
  }
}

private final class CallsRPCState: @unchecked Sendable {
  private let lock = NSLock()
  let accountCode: String
  private(set) var transactionHash = "0x" + String(repeating: "ab", count: 32)
  var receipt: JSONValue = .object([
    "status": .string("0x1"), "blockHash": .string("0x" + String(repeating: "cd", count: 32)),
    "blockNumber": .string("0x10"), "gasUsed": .string("0x5208"), "logs": .array([]),
  ])
  var receiptError: JSONValue?
  private(set) var rawTransaction: [UInt8]?
  private(set) var methods: [String] = []
  private(set) var estimateParams: JSONValue?

  init(accountCode: String) { self.accountCode = accountCode }

  func response(request: URLRequest) -> (HTTPURLResponse, Data) {
    let object = try! JSONDecoder().decode(JSONValue.self, from: callsRequestBody(request))
    let method = object.nestedString(at: ["method"])!
    return lock.withLock {
      methods.append(method)
      switch method {
      case "eth_getCode":
        let address = object.value(at: ["params", "0"])?.stringValue ?? ""
        return callsRPCResponse(
          result: address.caseInsensitiveCompare(EIP5792.simple7702Account) == .orderedSame
            ? .string("0x6001") : .string(accountCode))
      case "eth_getTransactionCount": return callsRPCResponse(result: .string("0x7"))
      case "eth_estimateGas":
        estimateParams = object.value(at: ["params"])
        return callsRPCResponse(result: .string("0x10000"))
      case "eth_maxPriorityFeePerGas": return callsRPCResponse(result: .string("0x1"))
      case "eth_gasPrice": return callsRPCResponse(result: .string("0x2"))
      case "eth_sendRawTransaction":
        rawTransaction = object.value(at: ["params", "0"])?.stringValue.flatMap(Hex.data)
        transactionHash =
          rawTransaction.map { "0x" + Hex.encode(Keccak.keccak256($0)) } ?? transactionHash
        return callsRPCResponse(result: .string(transactionHash))
      case "eth_getTransactionReceipt":
        if let receiptError { return callsRPCResponse(error: receiptError) }
        return callsRPCResponse(result: receipt)
      default: return callsRPCResponse(error: .object(["code": .number(-32603)]))
      }
    }
  }
}

private final class RecordingSignerState: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[UInt8]] = []
  func append(_ digest: [UInt8]) { lock.withLock { values.append(digest) } }
  var digests: [[UInt8]] { lock.withLock { values } }
}

private struct RecordingSigner: Signing {
  let account: String
  private let keypair: EthereumKeypair
  private let state = RecordingSignerState()

  init() {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 1
    keypair = try! EthereumKeypair.from(secret: secret)
    account = keypair.address
  }

  func hasKey() -> Bool { true }
  func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    state.append(digest)
    return try EthereumSigner.sign(digest: digest, keypair: keypair)
  }
  var digests: [[UInt8]] { state.digests }
}

private final class CallsURLProtocol: URLProtocol {
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

private func callsRequestBody(_ request: URLRequest) -> Data {
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

private func callsRPCResponse(result: JSONValue) -> (HTTPURLResponse, Data) {
  (
    httpResponse(),
    try! JSONEncoder().encode(
      JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .number(1), "result": result,
      ]))
  )
}

private func callsRPCResponse(error: JSONValue) -> (HTTPURLResponse, Data) {
  (
    httpResponse(),
    try! JSONEncoder().encode(
      JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .number(1), "error": error,
      ]))
  )
}

extension JSONValue {
  fileprivate var firstObject: [String: JSONValue]? {
    guard case .array(let values) = self, case .object(let object)? = values.first else {
      return nil
    }
    return object
  }

  fileprivate func value(at path: [String]) -> JSONValue? {
    var current = self
    for component in path {
      if case .object(let object) = current, let value = object[component] {
        current = value
      } else if case .array(let array) = current, let index = Int(component),
        array.indices.contains(index)
      {
        current = array[index]
      } else {
        return nil
      }
    }
    return current
  }

  fileprivate func nestedBool(at path: [String]) -> Bool? {
    guard case .bool(let value)? = value(at: path) else { return nil }
    return value
  }

  fileprivate func nestedNumber(at path: [String]) -> Double? {
    guard case .number(let value)? = value(at: path) else { return nil }
    return value
  }
}
