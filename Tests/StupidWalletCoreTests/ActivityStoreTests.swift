import Foundation
import Testing

@testable import StupidWalletCore

struct ActivityStoreTests {
  @Test("legacy-compatible SQLite activity stores transaction data and signed messages")
  func storesUnifiedActivity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    let transactionData = "0xabcdef"
    let signedMessage = "hello activity"
    let messageHex = "0x" + Hex.encode(Array(signedMessage.utf8))
    let transaction = request(
      kind: .send, method: "eth_sendTransaction",
      params: .array([.object(["data": .string(transactionData)])]))
    let signature = request(
      kind: .message, method: "personal_sign",
      params: .array([.string(messageHex), .string(account)]))

    try await store.recordTransaction(
      request: transaction, hash: "0x" + String(repeating: "ab", count: 32), nonce: "0x2")
    try await store.recordSignature(request: signature, signature: [1, 2, 3])

    let records = try await store.activities()
    #expect(records.count == 2)
    #expect(records.contains { $0.kind == .transaction && $0.status == .submitted })
    #expect(records.contains { $0.kind == .signature && $0.status == .signed })
    #expect(records.first { $0.kind == .transaction }?.nonce == "0x2")
    #expect(records.first { $0.kind == .transaction }?.transactionData == transactionData)
    #expect(records.first { $0.kind == .signature }?.signedMessage == messageHex)
    #expect(records.first { $0.kind == .signature }?.signature == "0x010203")
  }

  @Test("typed-data activity stores the exact signed JSON")
  func storesTypedDataMessage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    let typedData = #"{"primaryType":"Mail","message":{"contents":"Hello"}}"#
    let signature = request(
      kind: .typedData, method: "eth_signTypedData_v4",
      params: .array([.string(account), .string(typedData)]))

    try await store.recordSignature(request: signature, signature: [4, 5, 6])

    let record = try #require(await store.activities().first)
    #expect(record.signedMessage == typedData)
  }

  @Test("a repeated deterministic signature enriches an older redacted row")
  func enrichesRedactedSignature() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    let signature = [UInt8](repeating: 7, count: 65)
    try await store.recordSignature(
      request: request(kind: .message, method: "personal_sign"), signature: signature)
    let messageHex = "0x" + Hex.encode(Array("signed again".utf8))
    try await store.recordSignature(
      request: request(
        kind: .message, method: "personal_sign",
        params: .array([.string(messageHex), .string(account)])),
      signature: signature)

    let records = try await store.activities()
    #expect(records.count == 1)
    #expect(records.first?.signedMessage == messageHex)
    #expect(records.first?.signature == "0x" + String(repeating: "07", count: 65))
  }

  @Test("transaction lifecycle updates are durable")
  func updatesTransaction() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("Activity.sqlite")
    let hash = "0x" + String(repeating: "cd", count: 32)
    let first = ActivityStore(databaseURL: url)
    try await first.recordTransaction(
      request: request(kind: .send, method: "eth_sendTransaction"), hash: hash, nonce: "0x3")
    try await first.updateTransaction(hash: hash, status: .confirmed, blockNumber: "0x99")

    let reopened = ActivityStore(databaseURL: url)
    let record = try await reopened.activities().first
    #expect(record?.status == .confirmed)
    #expect(record?.blockNumber == "0x99")
  }

  @Test("activity can be filtered by a connected app")
  func filtersByConnectedApp() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    try await store.recordTransaction(
      request: request(
        kind: .send, method: "eth_sendTransaction", origin: "https://dapp.example"),
      hash: "0x" + String(repeating: "aa", count: 32), nonce: "0x0")
    try await store.recordTransaction(
      request: request(
        kind: .send, method: "eth_sendTransaction", origin: "http://dapp.example:8080"),
      hash: "0x" + String(repeating: "bb", count: 32), nonce: "0x1")
    try await store.recordTransaction(
      request: request(
        kind: .send, method: "eth_sendTransaction", origin: "https://other.example"),
      hash: "0x" + String(repeating: "cc", count: 32), nonce: "0x2")
    try await store.recordTransaction(
      request: request(
        kind: .send, method: "eth_sendTransaction", origin: "https://dapp.example",
        profileID: "profile-a"),
      hash: "0x" + String(repeating: "dd", count: 32), nonce: "0x3")

    let normalizedSite = ConnectedSite(
      domain: "dapp.example", address: account, origin: "https://dapp.example")
    let normalizedActivity = try await store.activities(for: normalizedSite)
    #expect(normalizedActivity.map(\.origin) == ["https://dapp.example"])

    let legacySite = ConnectedSite(domain: "dapp.example", address: account)
    let legacyActivity = try await store.activities(for: legacySite)
    #expect(
      Set(legacyActivity.map(\.origin)) == [
        "https://dapp.example", "http://dapp.example:8080",
      ])

    let profileSite = ConnectedSite(
      domain: "dapp.example", address: account, origin: "https://dapp.example",
      profileID: "profile-a")
    let profileActivity = try await store.activities(for: profileSite)
    #expect(profileActivity.count == 1)
    #expect(profileActivity.first?.profileID == "profile-a")
    #expect(profileActivity.first?.belongs(to: profileSite) == true)
    #expect(profileActivity.first?.belongs(to: normalizedSite) == false)
  }

  private let account = "0x0000000000000000000000000000000000000001"

  private func request(
    kind: RequestKind, method: String, origin: String = "https://dapp.example",
    profileID: String? = nil, params: JSONValue = .array([])
  ) -> WalletPendingRequest {
    let id = UUID()
    return WalletPendingRequest(
      id: id, kind: kind, method: method, origin: origin, profileID: profileID, chainId: "8453",
      account: account, params: params,
      payloadDigest: CanonicalRequest.digest(of: params, keyedBy: id))
  }
}
