import Foundation
import Testing

@testable import StupidWalletCore

struct ActivityStoreTests {
  @Test("legacy-compatible SQLite activity stores transaction and redacted signature rows")
  func storesUnifiedActivity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    let transaction = request(kind: .send, method: "eth_sendTransaction")
    let signature = request(kind: .message, method: "personal_sign")

    try await store.recordTransaction(
      request: transaction, hash: "0x" + String(repeating: "ab", count: 32), nonce: "0x2")
    try await store.recordSignature(request: signature, signature: [1, 2, 3])

    let records = try await store.activities()
    #expect(records.count == 2)
    #expect(records.contains { $0.kind == .transaction && $0.status == .submitted })
    #expect(records.contains { $0.kind == .signature && $0.status == .signed })
    #expect(records.first { $0.kind == .transaction }?.nonce == "0x2")
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
    profileID: String? = nil
  ) -> WalletPendingRequest {
    let id = UUID()
    let params = JSONValue.array([])
    return WalletPendingRequest(
      id: id, kind: kind, method: method, origin: origin, profileID: profileID, chainId: "8453",
      account: account, params: params,
      payloadDigest: CanonicalRequest.digest(of: params, keyedBy: id))
  }
}
