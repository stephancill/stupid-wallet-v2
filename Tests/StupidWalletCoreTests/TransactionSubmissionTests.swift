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
      networkStore: NetworkStore(
        directory: directory, legacySuiteName: "TransactionSubmissionTests.Networks"),
      activityStore: ActivityStore(
        databaseURL: directory.appendingPathComponent("Activity.sqlite")),
      resolver: RPCResolver(overrides: ["1": URL(string: "https://rpc.example")!]),
      rpcClient: client)
  }

  @Test("missing legacy fields are resolved only when approved and broadcast")
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
    #expect(transaction["nonce"] == nil)
    #expect(transaction["gas"] == nil)
    #expect(transaction["gasPrice"] == nil)
    #expect(transaction["chainId"] == .string("0x1"))
    let summary = try await service.summarize(request: id)
    #expect(
      summary?.rows.contains { $0.label == "Network Fee" && $0.value == "~0.000021 ETH" }
        == true)
    #expect(summary?.rows.contains { $0.label == "Chain" && $0.value == "Ethereum" } == true)
    #expect(summary?.rows.contains { $0.label == "Nonce" } == false)
    #expect(summary?.rows.contains { $0.label == "Gas limit" } == false)
    #expect(summary?.rows.contains { $0.label == "Gas price" } == false)

    let result = try await service.approve(request: id)
    #expect(result.stringValue.flatMap(Hex.data)?.count == 32)
    #expect(await service.status(for: id)?.status == "consumed")
    let activity = try await service.activities()
    #expect(activity.count == 1)
    #expect(activity.first?.requestID == id)
    #expect(activity.first?.status == .submitted)
    #expect(activity.first?.nonce == "0x7")
    let terminalRecord = try await service.store.record(id)
    #expect(terminalRecord?.params == record?.params)
    #expect(terminalRecord?.payloadDigest == record?.payloadDigest)
    guard case .array(let resolvedParams) = terminalRecord?.resolvedParams,
      case .object(let resolvedTransaction)? = resolvedParams.first
    else {
      Issue.record("expected resolved transaction")
      return
    }
    #expect(resolvedTransaction["nonce"] == .string("0x7"))
    #expect(resolvedTransaction["gas"] == .string("0x5208"))
    #expect(resolvedTransaction["gasPrice"] == .string("0x3b9aca00"))
  }

  @Test("simulation previews net native and ERC-20 changes without changing the request")
  func simulatedAssetChanges() async throws {
    let account = TransactionSigner().account
    let token = "0x1111111111111111111111111111111111111111"
    let counterparty = "0x2222222222222222222222222222222222222222"
    let transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    @Sendable func topic(_ address: String) -> JSONValue {
      .string("0x" + String(repeating: "0", count: 24) + address.dropFirst(2).lowercased())
    }
    @Sendable func log(_ emitter: String, _ from: String, _ to: String, _ amount: UInt64)
      -> JSONValue
    {
      .object([
        "address": .string(emitter),
        "topics": .array([.string(transfer), topic(from), topic(to)]),
        "data": .string("0x" + String(format: "%064llx", amount)),
      ])
    }
    let service = service { request in
      let body = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      switch body.nestedString(at: ["method"]) {
      case "eth_estimateGas": return rpcResponse(result: "0x5208")
      case "eth_gasPrice": return rpcResponse(result: "0x3b9aca00")
      case "eth_simulateV1":
        guard case .object(let envelope) = body,
          case .array(let parameters)? = envelope["params"],
          case .object(let simulation)? = parameters.first,
          simulation["traceTransfers"] == .bool(true),
          parameters.last == .string("latest"),
          case .array(let blocks)? = simulation["blockStateCalls"],
          case .object(let block)? = blocks.first,
          case .array(let calls)? = block["calls"],
          case .object(let call)? = calls.first,
          call["from"] == .string(account), call["to"] == .string(counterparty)
        else { return rpcResponse(error: "bad simulation request") }
        return rpcResponse(
          result: .array([
            .object([
              "calls": .array([
                .object([
                  "status": .string("0x1"),
                  "logs": .array([
                    log(
                      "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", account, counterparty,
                      1_000_000_000_000_000_000),
                    log(token, counterparty, account, 2_000_000),
                    log(token, account, counterparty, 500_000),
                    // ERC-721 Transfer has four topics; it is not a fungible change.
                    .object([
                      "address": .string(token),
                      "topics": .array([
                        .string(transfer), topic(counterparty), topic(account), .string("0x1"),
                      ]),
                      "data": .string("0x"),
                    ]),
                  ]),
                ])
              ])
            ])
          ]))
      case "eth_call":
        let selector: String?
        if case .object(let envelope) = body,
          case .array(let params)? = envelope["params"],
          case .object(let request)? = params.first
        {
          selector = request["data"]?.stringValue
        } else {
          selector = nil
        }
        if selector == "0x313ce567" {
          return rpcResponse(result: "0x" + String(repeating: "0", count: 63) + "6")
        }
        if selector == "0x95d89b41" {
          return rpcResponse(
            result: "0x" + String(repeating: "0", count: 62) + "20"
              + String(repeating: "0", count: 63) + "4" + "55534443"
              + String(repeating: "0", count: 56))
        }
        return rpcResponse(error: "unknown metadata")
      default: return rpcResponse(error: "unexpected method")
      }
    }
    let id = try await service.prepare(
      method: "eth_sendTransaction",
      params: .array([
        .object(["to": .string(counterparty), "value": .string("0xde0b6b3a7640000")])
      ]),
      origin: "https://dapp.example")
    let before = try #require(await service.store.record(id))
    let summary = try #require(await service.summarize(request: id))
    #expect(summary.rows.contains { $0.label == "Asset Change 1" && $0.value == "−1 ETH" })
    #expect(summary.rows.contains { $0.label == "Asset Change 2" && $0.value == "+1.5 USDC" })
    #expect(try await service.store.record(id)?.params == before.params)
    #expect(try await service.store.record(id)?.payloadDigest == before.payloadDigest)
  }

  @Test("simulation rejection and unsupported RPC remain visible")
  func simulationFailures() async throws {
    for (response, message) in [
      (
        rpcResponse(
          result: .array([.object(["calls": .array([.object(["status": .string("0x0")])])])])),
        "Transaction reverted in simulation"
      ),
      (
        rpcResponse(error: "method not found", code: -32601),
        "Unsupported by selected RPC"
      ),
      (
        rpcResponse(
          result: .array([
            .object([
              "calls": .array([
                .object([
                  "status": .string("0x1"), "logs": .array([]),
                ])
              ])
            ])
          ])),
        "No net fungible asset changes detected"
      ),
    ] {
      let service = service { request in
        let body = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
        return body.nestedString(at: ["method"]) == "eth_simulateV1"
          ? response : rpcResponse(result: "0x5208")
      }
      let id = try await service.prepare(
        method: "eth_sendTransaction",
        params: .array([.object(["to": .string("0x2222222222222222222222222222222222222222")])]),
        origin: "https://dapp.example")
      let summary = try #require(await service.summarize(request: id))
      #expect(summary.rows.contains { $0.label == "Simulation" && $0.value == message })
    }
  }

  @Test("oversized token metadata is ignored instead of crashing review")
  func oversizedSimulationTokenSymbol() async {
    TransactionURLProtocol.handler = { request in
      let body = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      if case .object(let envelope) = body,
        case .array(let params)? = envelope["params"],
        case .object(let call)? = params.first,
        call["data"] == .string("0x313ce567")
      {
        return rpcResponse(result: "0x" + String(repeating: "0", count: 63) + "6")
      }
      return rpcResponse(
        result: "0x" + String(repeating: "0", count: 64)
          + String(repeating: "f", count: 64))
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TransactionURLProtocol.self]
    let metadata = await RPCTokenResolver(
      client: RPCClient(session: URLSession(configuration: configuration)),
      resolver: RPCResolver(overrides: ["1": URL(string: "https://rpc.example")!])
    )
    .tokenMetadata(chainID: "1", tokenAddress: "0x1111111111111111111111111111111111111111")
    #expect(metadata?.symbol == nil)
    #expect(metadata?.decimals == 6)
  }

  @Test("quick successive approvals resolve consecutive pending nonces")
  func resolvesNonceAtEachApproval() async throws {
    let state = TransactionRPCState()
    let service = service { request in
      let object = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      let method = object.nestedString(at: ["method"])!
      switch method {
      case "eth_getTransactionCount": return rpcResponse(result: state.pendingNonce)
      case "eth_estimateGas": return rpcResponse(result: "0x5208")
      case "eth_gasPrice": return rpcResponse(result: "0x3b9aca00")
      case "eth_sendRawTransaction":
        guard case .object(let body) = object,
          case .array(let params)? = body["params"],
          case .string(let raw)? = params.first,
          let bytes = Hex.data(raw)
        else { return rpcResponse(error: "invalid raw transaction") }
        state.didBroadcast()
        return rpcResponse(result: "0x" + Hex.encode(Keccak.keccak256(bytes)))
      default: return rpcResponse(error: "unexpected method \(method)")
      }
    }
    let params = JSONValue.array([
      .object([
        "to": .string("0x0000000000000000000000000000000000000001"),
        "value": .string("0x0"),
      ])
    ])
    let first = try await service.prepare(
      method: "eth_sendTransaction", params: params, origin: "https://dapp.example")
    let second = try await service.prepare(
      method: "eth_sendTransaction", params: params, origin: "https://dapp.example")

    #expect(state.nonceRequestCount == 0)
    _ = try await service.approve(request: first)
    _ = try await service.approve(request: second)

    #expect(state.nonceRequestCount == 2)
    let activities = try await service.activities()
    #expect(Set(activities.compactMap(\.nonce)) == Set(["0x0", "0x1"]))
  }

  @Test("receipt polling confirms a submitted transaction")
  func confirmsReceipt() async throws {
    let service = service { request in
      let object = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
      switch object.nestedString(at: ["method"]) {
      case "eth_sendRawTransaction":
        guard case .object(let body) = object,
          case .array(let params)? = body["params"],
          case .string(let raw)? = params.first,
          let bytes = Hex.data(raw)
        else { return rpcResponse(error: "invalid raw transaction") }
        return rpcResponse(result: "0x" + Hex.encode(Keccak.keccak256(bytes)))
      case "eth_getTransactionReceipt":
        return rpcResponse(
          result: .object([
            "status": .string("0x1"), "blockNumber": .string("0x123"),
          ]))
      default: return rpcResponse(error: "unexpected method")
      }
    }
    let id = try await prepareCompleteLegacy(service)
    _ = try await service.approve(request: id)
    await service.refreshTransactionActivity()
    let activity = try await service.activities()
    #expect(activity.first?.status == .confirmed)
    #expect(activity.first?.blockNumber == "0x123")
  }

  @Test("missing transactions become dropped or replaced only after the grace period")
  func classifiesMissingTransactions() async throws {
    for (latestNonce, expected) in [("0x0", ActivityStatus.dropped), ("0x1", .replaced)] {
      let service = service { request in
        let object = try! JSONDecoder().decode(JSONValue.self, from: requestBody(request))
        switch object.nestedString(at: ["method"]) {
        case "eth_sendRawTransaction":
          guard case .object(let body) = object,
            case .array(let params)? = body["params"],
            case .string(let raw)? = params.first,
            let bytes = Hex.data(raw)
          else { return rpcResponse(error: "invalid raw transaction") }
          return rpcResponse(result: "0x" + Hex.encode(Keccak.keccak256(bytes)))
        case "eth_getTransactionReceipt", "eth_getTransactionByHash":
          return rpcResponse(result: .null)
        case "eth_getTransactionCount": return rpcResponse(result: latestNonce)
        default: return rpcResponse(error: "unexpected method")
        }
      }
      let id = try await prepareCompleteLegacy(service)
      _ = try await service.approve(request: id)
      await service.refreshTransactionActivity(
        now: Date().addingTimeInterval(120), missingGracePeriod: 60)
      #expect(try await service.activities().first?.status == expected)
    }
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
      case "eth_sendRawTransaction":
        guard case .object(let body) = object,
          case .array(let params)? = body["params"],
          case .string(let raw)? = params.first,
          let bytes = Hex.data(raw)
        else { return rpcResponse(error: "invalid raw transaction") }
        return rpcResponse(result: "0x" + Hex.encode(Keccak.keccak256(bytes)))
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

    _ = try await service.approve(request: id)
    guard case .array(let params) = try await service.store.record(id)?.resolvedParams,
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

  @Test("an unsupported old malformed send fails binding without mutation")
  func oldMalformedSendFailsBinding() async throws {
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

    await #expect(throws: WalletError.bindingMismatch) {
      try await service.approve(request: id)
    }
    #expect(await service.status(for: id) == nil)
    #expect(try await service.store.record(id)?.status == .pending)
  }

  @Test("an unsupported complete old send fails binding without mutation")
  func oldUnsupportedSendFailsBinding() async throws {
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

    await #expect(throws: WalletError.bindingMismatch) {
      try await service.approve(request: id)
    }
    #expect(await service.status(for: id) == nil)
    #expect(try await service.store.record(id)?.status == .pending)
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

private final class TransactionRPCState: @unchecked Sendable {
  private let lock = NSLock()
  private var broadcasts = 0
  private var nonceRequests = 0

  var pendingNonce: String {
    lock.withLock {
      nonceRequests += 1
      return "0x" + String(broadcasts, radix: 16)
    }
  }

  var nonceRequestCount: Int { lock.withLock { nonceRequests } }

  func didBroadcast() { lock.withLock { broadcasts += 1 } }
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
  rpcResponse(result: .string(result))
}

private func rpcResponse(result: JSONValue) -> (HTTPURLResponse, Data) {
  (
    httpResponse(),
    try! JSONEncoder().encode(
      JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .number(1), "result": result,
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
