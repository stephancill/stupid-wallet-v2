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

  private func request(kind: RequestKind, method: String) -> WalletPendingRequest {
    let id = UUID()
    let params = JSONValue.array([])
    return WalletPendingRequest(
      id: id, kind: kind, method: method, origin: "https://dapp.example", chainId: "8453",
      account: "0x0000000000000000000000000000000000000001", params: params,
      payloadDigest: CanonicalRequest.digest(of: params, keyedBy: id))
  }
}
