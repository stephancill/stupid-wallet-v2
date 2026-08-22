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

  private func service(
    _ store: PendingRequestStore? = nil, signer: any Signing = StubSigner()
  ) -> WalletService {
    WalletService(store: store ?? Self.tmpStore(), signing: signer)
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
    let svc = WalletService(store: store, signing: StubSigner())
    let id = UUID()
    let record = WalletPendingRequest(
      id: id,
      kind: .message,
      method: "personal_sign",
      origin: "https://dapp.example",
      chainId: "1",
      account: "0x1234",
      params: .array([.string("0x1234"), .string("0x6869")]),
      payloadDigest: CanonicalRequest.digest(
        of: .array([.string("0x1234"), .string("0x6869")]), keyedBy: id),
      createdAt: Date().addingTimeInterval(-1000),
      expiresAt: Date().addingTimeInterval(-100)
    )
    try await store.insert(record)
    await #expect(throws: WalletError.expired) {
      try await WalletService(store: store, signing: StubSigner()).approve(
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
          "data": .string("0x"),
        ])
      ]),
      origin: "https://dapp.example"
    )
    let summary = try await svc.summarize(request: id)
    #expect(summary?.kind == "send")
    #expect(summary?.title == "Send transaction")
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
  }

  @Test("wallet_addEthereumChain accepts standard [chainObject] params")
  func standardChainParams() async throws {
    let svc = service()
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
    #expect(summary?.rows.contains { $0.label == "Chain ID" && $0.value == "0x89" } == true)
    #expect(summary?.rows.contains { $0.label == "Name" && $0.value == "Polygon" } == true)
  }
}
