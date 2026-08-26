import Foundation
import Testing

@testable import StupidWalletCore

/// Hermetic Gate 5 tests: canonical approval protocol binding, replay, mutation, expiry,
/// queueing, and reject=4001 without any network or LocalAuthentication involvement.
struct ApprovalTests {
  private static func tmpStore() -> PendingRequestStore {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApprovalTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return PendingRequestStore(directory: dir)
  }

  private static func tmpChainStore() -> ChainStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ApprovalChainTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return ChainStore(directory: directory)
  }

  private static func tmpNetworkStore() -> NetworkStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ApprovalNetworkTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return NetworkStore(directory: directory, legacySuiteName: "ApprovalTests.Networks")
  }

  private func service(
    _ store: PendingRequestStore? = nil, signer: any Signing = StubSigner()
  ) -> WalletService {
    WalletService(
      store: store ?? Self.tmpStore(), signing: signer,
      connectedSites: ConnectedSitesStore(suiteName: "ApprovalTests-\(UUID().uuidString)"),
      chainStore: Self.tmpChainStore(),
      networkStore: Self.tmpNetworkStore())
  }

  private func prepareMessage(
    _ svc: WalletService,
    params: JSONValue = .array([
      .string("0x" + Data("hello".utf8).map { String(format: "%02x", $0) }.joined()),
      .string("0x1234"),
    ])
  ) async throws -> UUID {
    try await svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example")
  }

  @Test("approve of an unchanged message returns a signature and consumes the record")
  func approveAndConsume() async throws {
    let svc = service()
    let id = try await prepareMessage(svc)
    let result = try await svc.approve(request: id)
    #expect(result.stringValue?.hasPrefix("0x") == true)
    let status = await svc.status(for: id)
    #expect(status?.status == "consumed")
    // Duplicate approval is rejected.
    await #expect(throws: WalletError.alreadyConsumed) {
      try await svc.approve(request: id)
    }
  }

  @Test("provider retries converge after terminal completion and changed intent fails")
  func retainedRequestRetryIdentity() async throws {
    let svc = service()
    let params: JSONValue = .array([.string("0x6869"), .string("0x1234")])
    let id = try await svc.prepare(
      method: "personal_sign", params: params, origin: "https://dapp.example",
      requestKey: "provider-request")
    _ = try await svc.approve(request: id)

    #expect(
      try await svc.prepare(
        method: "personal_sign", params: params, origin: "https://dapp.example",
        requestKey: "provider-request") == id)
    await #expect(throws: WalletError.invalidParams) {
      try await svc.prepare(
        method: "personal_sign",
        params: .array([.string("0x68656c6c6f"), .string("0x1234")]),
        origin: "https://dapp.example", requestKey: "provider-request")
    }
  }

  @Test("retained retry scanning does not decode unsupported binding records")
  func retainedRetryIgnoresUnsupportedBindings() async throws {
    let svc = service()
    let unsupported = svc.store.directory.appendingPathComponent("\(UUID().uuidString).json")
    try Data(#"{"bindingVersion":1}"#.utf8).write(to: unsupported)

    let id = try await svc.prepare(
      method: "personal_sign", params: .array([.string("0x6869"), .string("0x1234")]),
      origin: "https://dapp.example", requestKey: "provider-request")
    #expect(try await svc.store.record(id)?.bindingVersion == 2)
  }

  @Test("prepare of a passthrough method is rejected with methodNotApproved")
  func passthroughNotPrepared() async throws {
    let svc = service()
    await #expect(throws: WalletError.methodNotApproved) {
      try await svc.prepare(
        method: "eth_blockNumber", params: .array([]), origin: "https://dapp.example")
    }
  }

  @Test("prepare of a denied method is rejected")
  func deniedNotPrepared() async throws {
    let svc = service()
    await #expect(throws: WalletError.methodNotApproved) {
      try await svc.prepare(
        method: "eth_sign", params: .array([]), origin: "https://dapp.example")
    }
  }

  @Test("mutating the params between prepare and approve is rejected")
  func mutationRejected() async throws {
    let svc = service()
    let id = try await prepareMessage(svc)
    // Rewrite the stored record's params to simulate an attacker mutating the payload.
    let store = svc.store
    let original = try await store.record(id)!
    let mutated = WalletPendingRequest(
      id: original.id,
      kind: original.kind,
      method: original.method,
      origin: original.origin,
      chainId: original.chainId,
      account: original.account,
      params: .array([
        .string("0x" + Data("evil".utf8).map { String(format: "%02x", $0) }.joined()),
        .string("0x1234"),
      ]),
      payloadDigest: original.payloadDigest,
      createdAt: original.createdAt,
      expiresAt: original.expiresAt
    )
    try await store.insert(mutated)
    await #expect(throws: WalletError.bindingMismatch) {
      try await svc.approve(request: id)
    }
  }

  @Test("an expired request becomes expired and is not signable")
  func expiryRejected() async throws {
    let store = Self.tmpStore()
    let chainStore = Self.tmpChainStore()
    let svc = WalletService(store: store, signing: StubSigner(), chainStore: chainStore)
    let id = UUID()
    let createdAt = Date().addingTimeInterval(-1000)
    let expiresAt = Date().addingTimeInterval(-100)
    let account = "0x1234567890abcdef1234567890abcdef12345678"
    let params: JSONValue = .array([.string("0x1234"), .string("0x6869")])
    let record = WalletPendingRequest(
      id: id,
      kind: .message,
      method: "personal_sign",
      origin: "https://dapp.example",
      chainId: "1",
      account: account,
      params: params,
      payloadDigest: CanonicalRequest.bindingDigestV2(
        requestID: id, kind: .message, method: "personal_sign",
        origin: "https://dapp.example", profileID: nil, chainId: "1", account: account,
        params: params, createdAt: createdAt, expiresAt: expiresAt),
      bindingVersion: 2,
      createdAt: createdAt,
      expiresAt: expiresAt
    )
    try await store.insert(record)
    await #expect(throws: WalletError.expired) {
      try await WalletService(store: store, signing: StubSigner(), chainStore: chainStore).approve(
        request: id)
    }
    let status = await svc.status(for: id)
    #expect(status?.status == "expired")
  }

  @Test("concurrent requests queue: only the oldest is approvable")
  func queuePolicy() async throws {
    let svc = service()
    let first = try await prepareMessage(svc)
    let second = try await prepareMessage(svc)
    // Oldest (first) is approvable.
    _ = try await svc.approve(request: first)
    // Second becomes active after the first is consumed.
    _ = try await svc.approve(request: second)
    let status = await svc.status(for: second)
    #expect(status?.status == "consumed")
  }

  @Test("approve of a queued (non-oldest) request is rejected")
  func queuedNotApprovable() async throws {
    let svc = service()
    _ = try await prepareMessage(svc)
    let second = try await prepareMessage(svc)
    await #expect(throws: WalletError.queued) {
      try await svc.approve(request: second)
    }
  }

  @Test("reject maps cleanly and never signs (record is not consumed)")
  func reject() async throws {
    let svc = service()
    let id = try await prepareMessage(svc)
    try await svc.reject(request: id)
    let status = await svc.status(for: id)
    #expect(status?.status == "rejected")
    #expect(status?.result == nil)
  }

  @Test("eth_requestAccounts connect resolves to the account array")
  func connectResolvesAccounts() async throws {
    let account = "0x1234567890abcdef1234567890abcdef12345678"
    let svc = service(signer: StubSigner(account: account))
    let id = try await svc.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: "https://dapp.example")
    let result = try await svc.approve(request: id)
    #expect(result == .array([.string(account)]))
  }

  @Test("summaries render per-kind canonical rows")
  func summaries() async throws {
    let svc = service()
    let id = try await svc.prepare(
      method: "eth_sendTransaction",
      params: .array([
        .object([
          "to": .string("0x0000000000000000000000000000000000000001"),
          "value": .string("0xde0b6b3a7640000"),
          "data": .string("0x1234"),
        ])
      ]),
      origin: "https://dapp.example"
    )
    let record = try #require(await svc.store.record(id))
    #expect(record.kind == .send)
    #expect(ApprovalSummary.title(for: record) == "Send transaction")
    let summary = try #require(await svc.summarize(request: id))
    #expect(summary.rows.contains { $0.label == "Value" && $0.value == "1 ETH" })
    #expect(summary.rows.contains { $0.label == "Data" && $0.value == "0x1234" })
  }

  @Test("personal_sign with standard [messageHex, address] params signs the message")
  func standardPersonalSignParams() async throws {
    let svc = service()
    let message = "standard order message"
    let messageHex = "0x" + Data(message.utf8).map { String(format: "%02x", $0) }.joined()
    let id = try await svc.prepare(
      method: "personal_sign",
      params: .array([
        .string(messageHex),
        .string("0x1234567890abcdef1234567890abcdef12345678"),
      ]),
      origin: "https://dapp.example")
    let result = try await svc.approve(request: id)
    #expect(result.stringValue?.hasPrefix("0x") == true)
    // The summary displays the decoded UTF-8 message from params[0].
    let summary = try await svc.summarize(request: id)
    #expect(summary?.rows.contains { $0.label == "Message" && $0.value == message } == true)
  }

  @Test("eth_signTypedData_v4 accepts the standard [address, jsonString] params")
  func standardTypedDataParams() async throws {
    let svc = service()
    let typedJSON = """
      {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"}],"Mail":[{"name":"contents","type":"string"}]},"primaryType":"Mail","domain":{"name":"Test","version":"1","chainId":1},"message":{"contents":"Hello, Bob!"}}
      """
    let id = try await svc.prepare(
      method: "eth_signTypedData_v4",
      params: .array([
        .string("0x1234567890abcdef1234567890abcdef12345678"),
        .string(typedJSON),
      ]),
      origin: "https://dapp.example")
    let result = try await svc.approve(request: id)
    #expect(result.stringValue?.hasPrefix("0x") == true)
    let summary = try await svc.summarize(request: id)
    #expect(summary?.rows.contains { $0.label == "Domain" && $0.value == "Test" } == true)
    #expect(summary?.rows.contains { $0.label == "Primary Type" && $0.value == "Mail" } == true)
    #expect(summary?.rows.contains { $0.label == "Version" && $0.value == "1" } == true)
    #expect(
      summary?.rows.contains { $0.label == "Domain Chain" && $0.value == "Ethereum" } == true)
    #expect(
      summary?.rows.contains { $0.label == "Message / contents" && $0.value == "Hello, Bob!" }
        == true)
  }

  @Test("Permit2 typed data approves and consumes with wide unsigned integers")
  func permit2TypedDataParams() async throws {
    let svc = service()
    let typedJSON = """
      {"types":{"PermitSingle":[{"name":"details","type":"PermitDetails"},{"name":"spender","type":"address"},{"name":"sigDeadline","type":"uint256"}],"PermitDetails":[{"name":"token","type":"address"},{"name":"amount","type":"uint160"},{"name":"expiration","type":"uint48"},{"name":"nonce","type":"uint48"}],"EIP712Domain":[{"name":"name","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}]},"domain":{"name":"Permit2","chainId":"8453","verifyingContract":"0x000000000022d473030f116ddee9f6b43ac78ba3"},"primaryType":"PermitSingle","message":{"details":{"token":"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913","amount":"1461501637330902918203684832716283019655932542975","expiration":"1790027953","nonce":"0"},"spender":"0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7","sigDeadline":"1787437753"}}
      """
    let id = try await svc.prepare(
      method: "eth_signTypedData_v4",
      params: .array([
        .string("0x1234567890abcdef1234567890abcdef12345678"),
        .string(typedJSON),
      ]),
      origin: "https://dapp.example")

    let result = try await svc.approve(request: id)
    #expect(result.stringValue?.hasPrefix("0x") == true)
    #expect(await svc.status(for: id)?.status == "consumed")
  }

  @Test("wallet_addEthereumChain accepts standard [chainObject] params")
  func standardChainParams() async throws {
    let svc = service()
    try await svc.connect(origin: "https://dapp.example")
    let id = try await svc.prepare(
      method: "wallet_addEthereumChain",
      params: .array([
        .object([
          "chainId": .string("0x89"),
          "chainName": .string("Polygon"),
          "rpcUrls": .array([.string("https://evm.stupidtech.net/v1/137")]),
        ])
      ]),
      origin: "https://dapp.example")
    let summary = try await svc.summarize(request: id)
    #expect(summary?.title == "Add network")
    #expect(summary?.rows.contains { $0.label == "Chain ID" && $0.value == "137" } == true)
    #expect(summary?.rows.contains { $0.label == "Name" && $0.value == "Polygon" } == true)
  }

  @Test("approval rejects a signer that no longer matches the persisted account")
  func signerReplacementRejected() async throws {
    let store = Self.tmpStore()
    let original = WalletService(
      store: store, signing: StubSigner(account: "0x1234567890abcdef1234567890abcdef12345678"),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: Self.tmpChainStore())
    let id = try await prepareMessage(original)
    let replacement = WalletService(
      store: store, signing: StubSigner(account: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: original.chainStore)
    await #expect(throws: WalletError.bindingMismatch) {
      try await replacement.approve(request: id)
    }
    #expect(await replacement.status(for: id)?.status == "pending")
  }

  @Test("prepare records carry the account-inclusive binding version 2 and revision zero")
  func bindingVersionTwoRecord() async throws {
    let svc = service()
    let id = try await prepareMessage(svc)
    let record = try #require(await svc.store.record(id))
    #expect(record.bindingVersion == 2)
    #expect(record.revision == 0)
    #expect(record.intentDigest != nil)
    // The persisted digest equals the recomputed account-inclusive canonical digest.
    let recomputed = CanonicalRequest.bindingDigestV2(
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
    #expect(recomputed == record.payloadDigest)
    _ = try await svc.approve(request: id)
  }

  @Test("mutating the persisted account invalidates the v2 binding")
  func accountMutationRejected() async throws {
    let svc = service()
    let id = try await prepareMessage(svc)
    let store = svc.store
    let original = try #require(await store.record(id))
    let mutated = WalletPendingRequest(
      id: original.id,
      kind: original.kind,
      method: original.method,
      origin: original.origin,
      profileID: original.profileID,
      chainId: original.chainId,
      account: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
      params: original.params,
      payloadDigest: original.payloadDigest,
      intentDigest: original.intentDigest,
      requestKey: original.requestKey,
      bindingVersion: original.bindingVersion,
      revision: original.revision,
      createdAt: original.createdAt,
      expiresAt: original.expiresAt
    )
    try await store.insert(mutated)
    await #expect(throws: WalletError.bindingMismatch) {
      try await svc.approve(request: id)
    }
  }

  @Test("mutating origin or timestamps invalidates the v2 binding")
  func originMutationRejected() async throws {
    let svc = service()
    let id = try await prepareMessage(svc)
    let store = svc.store
    let original = try #require(await store.record(id))

    let originMutated = WalletPendingRequest(
      id: original.id,
      kind: original.kind,
      method: original.method,
      origin: "https://evil.example",
      profileID: original.profileID,
      chainId: original.chainId,
      account: original.account,
      params: original.params,
      payloadDigest: original.payloadDigest,
      intentDigest: original.intentDigest,
      requestKey: original.requestKey,
      bindingVersion: original.bindingVersion,
      revision: original.revision,
      createdAt: original.createdAt,
      expiresAt: original.expiresAt
    )
    try await store.insert(originMutated)
    await #expect(throws: WalletError.bindingMismatch) {
      try await svc.approve(request: id)
    }

    let expiredMutated = WalletPendingRequest(
      id: original.id,
      kind: original.kind,
      method: original.method,
      origin: original.origin,
      profileID: original.profileID,
      chainId: original.chainId,
      account: original.account,
      params: original.params,
      payloadDigest: original.payloadDigest,
      intentDigest: original.intentDigest,
      requestKey: original.requestKey,
      bindingVersion: original.bindingVersion,
      revision: original.revision,
      createdAt: original.createdAt,
      expiresAt: original.expiresAt.addingTimeInterval(60)
    )
    try await store.insert(expiredMutated)
    await #expect(throws: WalletError.bindingMismatch) {
      try await svc.approve(request: id)
    }
  }

  @Test("records missing the required revision fail closed")
  func missingRevisionRejected() async throws {
    let store = Self.tmpStore()
    let id = UUID()
    let legacy = WalletPendingRequest(
      id: id,
      kind: .message,
      method: "personal_sign",
      origin: "https://dapp.example",
      chainId: "1",
      account: "0x1234567890abcdef1234567890abcdef12345678",
      params: .array([.string("0x1234"), .string("0x6869")]),
      payloadDigest: CanonicalRequest.digest(
        of: .array([.string("0x1234"), .string("0x6869")]), keyedBy: id),
      createdAt: Date(),
      expiresAt: Date().addingTimeInterval(600)
    )
    let encoded = try JSONEncoder().encode(legacy)
    guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: encoded) else {
      Issue.record("Expected an encoded request object")
      return
    }
    object.removeValue(forKey: "profileID")
    object.removeValue(forKey: "bindingVersion")
    object.removeValue(forKey: "revision")
    object.removeValue(forKey: "resolvedParams")
    object.removeValue(forKey: "error")
    try JSONEncoder().encode(JSONValue.object(object)).write(
      to: store.directory.appendingPathComponent("\(id.uuidString).json"), options: [.atomic])
    await #expect(throws: DecodingError.self) {
      try await store.record(id)
    }
  }

  @Test("intent digest v2 excludes the wallet-selected account and request identity")
  func intentDigestVersionTwo() throws {
    let origin = "https://dapp.example"
    let params: JSONValue = .array([.string("0x1234"), .string("0x6869")])
    let digestA = CanonicalRequest.intentDigestV2(
      method: "personal_sign", origin: origin, chainId: "8453", profileID: "profile-a",
      params: params)
    let digestB = CanonicalRequest.intentDigestV2(
      method: "personal_sign", origin: origin, chainId: "8453", profileID: "profile-a",
      params: params)
    #expect(digestA == digestB)
    // Changing any canonical intent field changes the digest; a different account does not,
    // because account selection is a separate wallet decision.
    #expect(
      CanonicalRequest.intentDigestV2(
        method: "personal_sign", origin: origin, chainId: "8453", profileID: "profile-a",
        params: .array([.string("0x9999"), .string("0x6869")]))
        != digestA)
    #expect(
      CanonicalRequest.intentDigestV2(
        method: "PERSONAL_SIGN", origin: origin, chainId: "8453", profileID: nil,
        params: params) != digestA)
  }

  @Test("requests for two connected accounts share one queue and use their persisted signers")
  func accountSpecificQueueAndSigners() async throws {
    let context = try await accountPolicyService()
    let first = try await context.service.prepare(
      method: "personal_sign",
      params: .array([.string("0x68656c6c6f"), .string(context.first)]),
      origin: "https://one.example", profileID: "profile-a")
    let second = try await context.service.prepare(
      method: "personal_sign",
      params: .array([.string("0x776f726c64"), .string(context.second)]),
      origin: "https://two.example", profileID: "profile-b")

    await #expect(throws: WalletError.queued) {
      try await context.service.approve(request: second, profileID: "profile-b")
    }
    for (id, profile, expected) in [
      (first, "profile-a", context.first), (second, "profile-b", context.second),
    ] {
      let record = try #require(await context.service.store.record(id))
      let result = try await context.service.approve(request: id, profileID: profile)
      let signature = try #require(result.stringValue.flatMap(Hex.data))
      let recovered = try #require(
        try? EthereumSigner.recoverAddress(
          digest: RequestExecutor.signableDigest(for: record), signature: signature))
      #expect(recovered.caseInsensitiveCompare(expected) == .orderedSame)
    }
  }

  @Test("account parameters must match the active origin account before persistence")
  func activeAccountParameterMismatch() async throws {
    let context = try await accountPolicyService()
    await #expect(throws: WalletError.invalidParams) {
      try await context.service.prepare(
        method: "personal_sign",
        params: .array([.string("0x6869"), .string(context.second)]),
        origin: "https://one.example", profileID: "profile-a")
    }
    await #expect(throws: WalletError.invalidParams) {
      try await context.service.prepare(
        method: "eth_signTypedData_v4",
        params: .array([.string(context.second), .string("{}")]),
        origin: "https://one.example", profileID: "profile-a")
    }
    await #expect(throws: WalletError.invalidParams) {
      try await context.service.prepare(
        method: "eth_sendTransaction",
        params: .array([
          .object([
            "from": .string(context.second),
            "to": .string("0x0000000000000000000000000000000000000001"),
          ])
        ]), origin: "https://one.example", profileID: "profile-a")
    }
    #expect(try await context.service.list(profileID: "profile-a").isEmpty)
  }

  @Test("active-account replacement terminalizes an immutable signing request")
  func activeAccountReplacementBeforeApproval() async throws {
    let context = try await accountPolicyService()
    let id = try await context.service.prepare(
      method: "personal_sign",
      params: .array([.string("0x6869"), .string(context.first)]),
      origin: "https://one.example", profileID: "profile-a")
    try await context.connectedSites.connect(
      site: ConnectedSite(
        domain: "one.example", address: context.second, origin: "https://one.example",
        profileID: "profile-a"))

    await #expect(throws: WalletError.self) {
      try await context.service.approve(request: id, profileID: "profile-a")
    }
    #expect(await context.service.status(for: id, profileID: "profile-a")?.status == "failed")
  }

  @Test("SIWE remains bound to its prepared connected account")
  func siweAccountImmutable() async throws {
    let context = try await accountPolicyService()
    let params: JSONValue = .array([
      .object([
        "version": .string("1"),
        "capabilities": .object([
          "signInWithEthereum": .object([
            "nonce": .string("12345678"), "chainId": .string("0x1"),
          ])
        ]),
      ])
    ])
    let id = try await context.service.prepare(
      method: "wallet_connect", params: params, origin: "https://one.example",
      profileID: "profile-a")
    #expect(try await context.service.store.record(id)?.account == context.first)
    try await context.connectedSites.connect(
      site: ConnectedSite(
        domain: "one.example", address: context.second, origin: "https://one.example",
        profileID: "profile-a"))

    await #expect(throws: WalletError.self) {
      try await context.service.approve(request: id, profileID: "profile-a")
    }
    #expect(try await context.service.store.record(id)?.account == context.first)
  }

  @Test("Gate F summaries expose revision and grouped available registry accounts")
  func gateFRebindAndAccounts() async throws {
    let context = try GateFContext()
    defer { context.remove() }
    let id = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: context.origin,
      profileID: context.profile, requestKey: "provider-request")
    let original = try #require(await context.pending.record(id))
    let groups = try await context.service.availableAccountGroups()

    #expect(groups.count == 2)
    #expect(groups.flatMap(\.accounts).map(\.address) == [context.first, context.second])
    #expect(
      try await context.service.summarize(request: id, profileID: context.profile)?.revision == 0)

    try await context.service.rebindConnect(
      request: id, account: context.second, reviewedRevision: 0, profileID: context.profile)
    let rebound = try #require(await context.pending.record(id))
    #expect(rebound.revision == 1)
    #expect(rebound.account == context.second)
    #expect(rebound.requestKey == original.requestKey)
    #expect(rebound.intentDigest == original.intentDigest)
    #expect(rebound.params == original.params)
    #expect(rebound.createdAt == original.createdAt)
    #expect(rebound.expiresAt == original.expiresAt)
    #expect(rebound.payloadDigest != original.payloadDigest)
    #expect(
      try await context.service.summarize(request: id, profileID: context.profile)?.revision == 1)
  }

  @Test("Gate F plain connect proposes the persisted connection default, not home")
  func gateFDefaultProposal() async throws {
    let context = try GateFContext()
    defer { context.remove() }
    _ = try context.connection.mutate { state in
      state.defaultAccount = context.second
    }

    let id = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: context.origin,
      profileID: context.profile)
    #expect(try await context.pending.record(id)?.account == context.second)
    #expect(try context.registry.loadReady()?.homeSelectedAddress == context.first)
  }

  @Test("Gate F rebind is restricted to the active plain-connect revision and available account")
  func gateFRebindRestrictions() async throws {
    let context = try GateFContext(includeUnavailableAccount: true)
    defer { context.remove() }
    let message = try await context.service.prepare(
      method: "personal_sign",
      params: .array([.string("0x6869"), .string(context.first)]),
      origin: "https://connected.example", profileID: context.profile)
    await #expect(throws: WalletError.bindingMismatch) {
      try await context.service.rebindConnect(
        request: message, account: context.second, reviewedRevision: 0,
        profileID: context.profile)
    }
    try await context.service.reject(request: message, profileID: context.profile)

    let first = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: context.origin,
      profileID: context.profile)
    let queued = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: "https://queued.example",
      profileID: context.profile)
    await #expect(throws: WalletError.queued) {
      try await context.service.rebindConnect(
        request: queued, account: context.second, reviewedRevision: 0,
        profileID: context.profile)
    }
    await #expect(throws: WalletError.bindingMismatch) {
      try await context.service.rebindConnect(
        request: first, account: context.unavailable, reviewedRevision: 0,
        profileID: context.profile)
    }
    try await context.service.rebindConnect(
      request: first, account: context.second, reviewedRevision: 0, profileID: context.profile)
    await #expect(throws: WalletError.bindingMismatch) {
      try await context.service.rebindConnect(
        request: first, account: context.first, reviewedRevision: 0,
        profileID: context.profile)
    }
    await #expect(throws: WalletError.bindingMismatch) {
      try await context.service.rebindConnect(
        request: first, account: context.first, reviewedRevision: 1,
        profileID: "other-profile")
    }
  }

  @Test("Gate F approval atomically commits the selected connection and leaves no marker")
  func gateFConnectCommit() async throws {
    let context = try GateFContext()
    defer { context.remove() }
    let id = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: context.origin,
      profileID: context.profile)
    try await context.service.rebindConnect(
      request: id, account: context.second, reviewedRevision: 0, profileID: context.profile)

    let result = try await context.service.approve(
      request: id, profileID: context.profile, reviewedRevision: 1)
    let state = try #require(try context.connection.load())
    #expect(result == .array([.string(context.second)]))
    #expect(state.defaultAccount == context.second)
    #expect(state.grants.contains { $0.account == context.second && $0.origin == context.origin })
    #expect(
      state.activeConnections.contains {
        $0.account == context.second && $0.origin == context.origin
          && $0.profileID == context.profile
      })
    #expect(state.connectCommits.isEmpty)
    #expect(await context.service.status(for: id, profileID: context.profile)?.status == "consumed")
    #expect(try context.registry.loadReady()?.homeSelectedAddress == context.first)
  }

  @Test("Gate F stale approve and reject leave the previous default unchanged")
  func gateFStaleDecisions() async throws {
    let context = try GateFContext()
    defer { context.remove() }
    let id = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: context.origin,
      profileID: context.profile)
    try await context.service.rebindConnect(
      request: id, account: context.second, reviewedRevision: 0, profileID: context.profile)

    await #expect(throws: WalletError.bindingMismatch) {
      try await context.service.approve(
        request: id, profileID: context.profile, reviewedRevision: 0)
    }
    await #expect(throws: WalletError.bindingMismatch) {
      try await context.service.reject(
        request: id, profileID: context.profile, reviewedRevision: 0)
    }
    #expect(try context.connection.load()?.defaultAccount == context.first)
    try await context.service.reject(
      request: id, profileID: context.profile, reviewedRevision: 1)
    #expect(try context.connection.load()?.defaultAccount == context.first)
  }

  @Test("Gate F rebind racing approve or reject permits exactly one reviewed transition")
  func gateFDecisionRaces() async throws {
    for approve in [true, false] {
      let context = try GateFContext()
      defer { context.remove() }
      let secondService = try context.makeService()
      let id = try await context.service.prepare(
        method: "eth_requestAccounts", params: .array([]), origin: context.origin,
        profileID: context.profile)

      async let rebind: GateFRaceOutcome = {
        do {
          try await context.service.rebindConnect(
            request: id, account: context.second, reviewedRevision: 0,
            profileID: context.profile)
          return .succeeded
        } catch {
          return .lost
        }
      }()
      async let decision: GateFRaceOutcome = {
        do {
          if approve {
            _ = try await secondService.approve(
              request: id, profileID: context.profile, reviewedRevision: 0)
          } else {
            try await secondService.reject(
              request: id, profileID: context.profile, reviewedRevision: 0)
          }
          return .succeeded
        } catch {
          return .lost
        }
      }()
      let outcomes = await [rebind, decision]
      #expect(outcomes.filter { $0 == .succeeded }.count == 1)
      if try await context.pending.record(id)?.status == .pending {
        if approve {
          _ = try await secondService.approve(
            request: id, profileID: context.profile, reviewedRevision: 1)
        } else {
          try await secondService.reject(
            request: id, profileID: context.profile, reviewedRevision: 1)
        }
      }
    }
  }

  @Test("Gate F status recovers an interrupted connect commit before expiry or rejection")
  func gateFMarkerRecoveryAndConflict() async throws {
    let context = try GateFContext()
    defer { context.remove() }
    let id = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: context.origin,
      profileID: context.profile)
    let record = try #require(await context.pending.record(id))
    try context.installMarker(for: record)

    let status = await context.service.status(for: id, profileID: context.profile)
    #expect(status?.status == "consumed")
    #expect(status?.result == .array([.string(context.first)]))
    #expect(try context.connection.load()?.connectCommits.isEmpty == true)

    let conflictID = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: "https://conflict.example",
      profileID: context.profile)
    let conflict = try #require(await context.pending.record(conflictID))
    try context.installMarker(for: conflict)
    var rejected = conflict
    rejected.status = .rejected
    try await context.pending.insert(rejected)
    let conflictStatus = await context.service.status(for: conflictID, profileID: context.profile)
    #expect(conflictStatus?.status == "failed")
    #expect(conflictStatus?.error?.nestedString(at: ["message"])?.contains("Conflicting") == true)
    await #expect(throws: WalletError.bindingMismatch) {
      try await context.service.approve(
        request: conflictID, profileID: context.profile, reviewedRevision: 0)
    }
    #expect(
      try context.connection.load()?.connectCommits.contains { $0.requestID == conflictID } == true)
  }

  @Test("Gate F terminal connect status survives later account removal")
  func gateFTerminalStatusAfterAccountRemoval() async throws {
    let context = try GateFContext()
    defer { context.remove() }
    let id = try await context.service.prepare(
      method: "eth_requestAccounts", params: .array([]), origin: context.origin,
      profileID: context.profile)
    try await context.service.rebindConnect(
      request: id, account: context.second, reviewedRevision: 0, profileID: context.profile)
    _ = try await context.service.approve(
      request: id, profileID: context.profile, reviewedRevision: 1)

    _ = try context.connection.mutate { state in
      state.grants.removeAll { $0.account == context.second }
      state.activeConnections.removeAll { $0.account == context.second }
      state.defaultAccount = context.first
    }
    let registry = try #require(try context.registry.loadReady())
    let deleting = try context.registry.update(expectedRevision: registry.revision) { current in
      var groups = current.groups
      let index = try #require(
        groups.firstIndex { group in
          group.accounts.contains { $0.address == context.second }
        })
      groups[index].lifecycle = .deleting
      return WalletRegistry(
        revision: current.revision + 1, adoptionState: current.adoptionState, groups: groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }
    _ = try context.registry.update(expectedRevision: deleting.revision) { current in
      WalletRegistry(
        revision: current.revision + 1, adoptionState: current.adoptionState,
        groups: current.groups.filter { group in
          !group.accounts.contains { $0.address == context.second }
        }, homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }

    let status = await context.service.status(for: id, profileID: context.profile)
    #expect(status?.status == "consumed")
    #expect(status?.result == .array([.string(context.second)]))
  }

  private func accountPolicyService() async throws -> (
    service: WalletService, connectedSites: ConnectedSitesStore, first: String, second: String
  ) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GateEApprovalTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "GateEApprovalTests-\(UUID().uuidString)"
    _ = try ConnectionStateStore(directory: directory, suiteName: suite)
      .getOrCreate(ConnectionState(revision: 0))
    let connectedSites = ConnectedSitesStore(suiteName: suite, directory: directory)
    let resolver = try DeterministicAccountResolver(secrets: [
      deterministicSecret(1), deterministicSecret(2),
    ])
    let first = try EthereumKeypair.from(secret: deterministicSecret(1)).address
    let second = try EthereumKeypair.from(secret: deterministicSecret(2)).address
    try await connectedSites.connect(
      site: ConnectedSite(
        domain: "one.example", address: first, origin: "https://one.example",
        profileID: "profile-a"))
    try await connectedSites.connect(
      site: ConnectedSite(
        domain: "two.example", address: second, origin: "https://two.example",
        profileID: "profile-b"))
    let service = WalletService(
      store: PendingRequestStore(directory: directory.appendingPathComponent("Pending")),
      signing: try resolver.signer(address: first), connectedSites: connectedSites,
      chainStore: ChainStore(directory: directory),
      networkStore: NetworkStore(directory: directory, legacySuiteName: suite),
      activityStore: ActivityStore(
        databaseURL: directory.appendingPathComponent("Activity.sqlite")),
      accountResolver: resolver)
    return (service, connectedSites, first, second)
  }
}

private final class GateFContext: @unchecked Sendable {
  let directory: URL
  let profile = "profile-a"
  let origin = "https://gate-f.example"
  let first: String
  let second: String
  let unavailable: String
  let registry: WalletRegistryStore
  let connection: ConnectionStateStore
  let pending: PendingRequestStore
  let suite: String
  let connectedSites: ConnectedSitesStore
  let resolver: DeterministicAccountResolver
  let service: WalletService

  init(includeUnavailableAccount: Bool = false) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GateFApprovalTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    first = try EthereumKeypair.from(secret: deterministicSecret(1)).address
    second = try EthereumKeypair.from(secret: deterministicSecret(2)).address
    unavailable = try EthereumKeypair.from(secret: deterministicSecret(3)).address
    registry = WalletRegistryStore(directory: directory)
    let createdAt = Date(timeIntervalSince1970: 1)
    var groups = [
      WalletGroup(
        id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
        accounts: [WalletAccount(address: first, derivationIndex: nil, createdAt: createdAt)],
        lifecycle: .active),
      WalletGroup(
        id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
        accounts: [WalletAccount(address: second, derivationIndex: nil, createdAt: createdAt)],
        lifecycle: .active),
    ]
    if includeUnavailableAccount {
      groups.append(
        WalletGroup(
          id: UUID(), kind: .privateKey, createdAt: createdAt, nextDerivationIndex: nil,
          accounts: [
            WalletAccount(address: unavailable, derivationIndex: nil, createdAt: createdAt)
          ],
          lifecycle: .active))
    }
    try registry.create(
      WalletRegistry(
        revision: 0, adoptionState: .migrating, groups: groups,
        homeSelectedAddress: first, legacyWalletAddressFallbackRemoved: true))
    _ = try registry.update(expectedRevision: 0) { current in
      WalletRegistry(
        revision: 1, adoptionState: .complete, groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    suite = "GateFApprovalTests-\(UUID().uuidString)"
    connection = ConnectionStateStore(directory: directory, suiteName: suite)
    let connectedGrant = ConnectionGrant(
      account: first, origin: "https://connected.example", legacyDomain: "connected.example",
      profileID: profile, connectedAt: .now, precision: .exact)
    _ = try connection.getOrCreate(
      ConnectionState(
        revision: 0, defaultAccount: first, grants: [connectedGrant],
        activeConnections: [
          ActiveConnection(
            origin: "https://connected.example", profileID: profile, account: first)
        ]))
    pending = PendingRequestStore(
      directory: directory.appendingPathComponent("PendingRequests", isDirectory: true))
    connectedSites = ConnectedSitesStore(suiteName: suite, directory: directory)
    resolver = try DeterministicAccountResolver(secrets: [
      deterministicSecret(1), deterministicSecret(2),
    ])
    service = WalletService(
      store: pending, signing: try resolver.signer(address: first),
      connectedSites: connectedSites, chainStore: ChainStore(directory: directory),
      networkStore: NetworkStore(directory: directory, legacySuiteName: suite),
      activityStore: ActivityStore(
        databaseURL: directory.appendingPathComponent("Activity.sqlite")),
      registryStore: registry, accountResolver: resolver)
  }

  func makeService() throws -> WalletService {
    WalletService(
      store: pending, signing: try resolver.signer(address: first),
      connectedSites: connectedSites, chainStore: ChainStore(directory: directory),
      networkStore: NetworkStore(directory: directory, legacySuiteName: suite),
      activityStore: ActivityStore(
        databaseURL: directory.appendingPathComponent("Activity.sqlite")),
      registryStore: registry, accountResolver: resolver)
  }

  func installMarker(for record: WalletPendingRequest) throws {
    _ = try connection.mutate { state in
      let grant = ConnectionGrant(
        account: record.account, origin: record.origin,
        legacyDomain: Origin.downHost(of: record.origin), profileID: record.profileID,
        connectedAt: .now, precision: .exact)
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
          bindingDigest: record.payloadDigest, result: .array([.string(record.account)]),
          committedAt: .now))
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private enum GateFRaceOutcome: Sendable {
  case succeeded
  case lost
}
