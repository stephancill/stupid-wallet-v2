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
      store: store ?? Self.tmpStore(), signing: signer, chainStore: Self.tmpChainStore(),
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
    await svc.connect(origin: "https://dapp.example")
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
}
