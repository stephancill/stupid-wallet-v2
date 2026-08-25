import Foundation
import SQLite3
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

  @Test("repeated deterministic signatures are distinct request events")
  func repeatedSignatureEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    let signature = [UInt8](repeating: 7, count: 65)
    let first = request(kind: .message, method: "personal_sign")
    try await store.recordSignature(request: first, signature: signature)
    let messageHex = "0x" + Hex.encode(Array("signed again".utf8))
    let second = request(
      kind: .message, method: "personal_sign",
      params: .array([.string(messageHex), .string(account)]))
    try await store.recordSignature(request: second, signature: signature)
    try await store.recordSignature(request: second, signature: signature)

    let records = try await store.activities()
    #expect(records.count == 2)
    #expect(Set(records.compactMap(\.requestID)) == [first.id, second.id])
    #expect(records.contains { $0.signedMessage == messageHex })
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

  @Test("account-scoped activity and connected-app details never mix accounts")
  func filtersByAccount() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    let otherAccount = "0x0000000000000000000000000000000000000002"
    try await store.recordTransaction(
      request: request(
        kind: .send, method: "eth_sendTransaction", requestedAccount: account),
      hash: "0x" + String(repeating: "11", count: 32), nonce: "0x0")
    try await store.recordTransaction(
      request: request(
        kind: .send, method: "eth_sendTransaction", requestedAccount: otherAccount),
      hash: "0x" + String(repeating: "22", count: 32), nonce: "0x0")
    try await store.recordSignature(
      request: request(
        kind: .message, method: "personal_sign", requestedAccount: otherAccount),
      signature: [9, 9, 9])

    let first = try await store.activities(account: account)
    #expect(first.count == 1)
    #expect(first.allSatisfy { $0.account.caseInsensitiveCompare(account) == .orderedSame })

    let site = ConnectedSite(
      domain: "dapp.example", address: otherAccount, origin: "https://dapp.example")
    let second = try await store.activities(for: site, account: otherAccount)
    #expect(second.count == 2)
    #expect(second.allSatisfy { $0.belongs(to: site) })
    #expect(second.allSatisfy { $0.account.caseInsensitiveCompare(account) != .orderedSame })
  }

  @Test("legacy signature rows keep their IDs when request identity is migrated")
  func migratesSignatureIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Activity.sqlite")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let repeatedDigest = "0x" + Hex.encode(Keccak.keccak256([1, 2]))
    let setup = """
      CREATE TABLE apps (
        id INTEGER PRIMARY KEY AUTOINCREMENT, domain TEXT, uri TEXT, scheme TEXT,
        UNIQUE(domain, uri, scheme));
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT, tx_hash TEXT NOT NULL UNIQUE,
        app_id INTEGER NOT NULL, chain_id_hex TEXT NOT NULL, method TEXT,
        from_address TEXT, created_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending', request_id TEXT, nonce TEXT,
        updated_at INTEGER, block_number TEXT, error TEXT, profile_id TEXT,
        transaction_data TEXT, call_bundle_id TEXT,
        FOREIGN KEY(app_id) REFERENCES apps(id));
      CREATE TABLE signatures (
        id INTEGER PRIMARY KEY AUTOINCREMENT, signature_hash TEXT NOT NULL UNIQUE,
        app_id INTEGER NOT NULL, chain_id_hex TEXT NOT NULL, method TEXT NOT NULL,
        from_address TEXT, message_content TEXT NOT NULL, signature_hex TEXT NOT NULL,
        created_at INTEGER NOT NULL, request_id TEXT, profile_id TEXT,
        FOREIGN KEY(app_id) REFERENCES apps(id));
      INSERT INTO apps (id, domain, uri, scheme)
      VALUES (1, 'dapp.example', 'https://dapp.example', 'https');
      INSERT INTO signatures
        (id, signature_hash, app_id, chain_id_hex, method, from_address,
         message_content, signature_hex, created_at)
      VALUES (7, '\(repeatedDigest)', 1, '0x2105', 'personal_sign',
              '\(account)', 'legacy', '0x0102', 1);
      PRAGMA user_version=8;
      """
    #expect(sqlite3_exec(database, setup, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let store = ActivityStore(databaseURL: url)
    let secondStore = ActivityStore(databaseURL: url)
    async let firstOpen = store.activities(account: account)
    async let secondOpen = secondStore.activities(account: account)
    let (migrated, concurrentlyMigrated) = try await (firstOpen, secondOpen)
    #expect(migrated.map(\.id) == ["signature-7"])
    #expect(concurrentlyMigrated.map(\.id) == ["signature-7"])
    try await store.recordSignature(
      request: request(kind: .message, method: "personal_sign"), signature: [1, 2])
    #expect(try await store.activities(account: account).count == 2)
  }

  @Test("unresolved transaction limits are applied after account and status filtering")
  func unresolvedLimit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    let store = ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    try await store.recordTransaction(
      request: request(kind: .send, method: "eth_sendTransaction"),
      hash: "0x" + String(repeating: "33", count: 32), nonce: "0x0",
      at: Date(timeIntervalSince1970: 1))
    for offset in 2...4 {
      try await store.recordSignature(
        request: request(kind: .message, method: "personal_sign"),
        signature: [UInt8(offset)], at: Date(timeIntervalSince1970: TimeInterval(offset)))
    }

    let unresolved = try await store.unresolvedTransactions(account: account, limit: 1)
    #expect(unresolved.count == 1)
    #expect(unresolved.first?.transactionHash == "0x" + String(repeating: "33", count: 32))
  }

  @Test("unknown future activity schemas fail closed without downgrade")
  func rejectsFutureSchema() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Activity.sqlite")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    #expect(sqlite3_exec(database, "PRAGMA user_version=10;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let store = ActivityStore(databaseURL: url)
    await #expect(throws: ActivityStoreError.sqlite("Unsupported activity schema version 10")) {
      try await store.activities(account: account)
    }
  }

  @Test("unknown older and malformed known activity schemas fail closed")
  func rejectsUnknownOlderSchemas() async throws {
    for version in [5, 8] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ActivityStoreTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("Activity.sqlite")
      var database: OpaquePointer?
      #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
      #expect(
        sqlite3_exec(database, "PRAGMA user_version=\(version);", nil, nil, nil) == SQLITE_OK)
      sqlite3_close(database)

      let store = ActivityStore(databaseURL: url)
      await #expect(
        throws: ActivityStoreError.sqlite("Unsupported activity schema version \(version)")
      ) {
        try await store.activities(account: account)
      }
    }
  }

  @Test(
    "every shipped activity schema migrates to version 9",
    arguments: [1, 2, 3, 4, 6, 7, 8, 9])
  func migratesShippedSchemas(version: Int) async throws {
    let url = try makeDatabase(sql: schema(version: version))

    let store = ActivityStore(databaseURL: url)
    #expect(try await store.activities(account: account).isEmpty)

    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 9)
  }

  @Test("near-valid malformed version 9 activity schemas fail closed")
  func rejectsMalformedCurrentSchemas() async throws {
    let malformedSchemas = [
      schema(version: 9, signatureHashType: "BLOB"),
      schema(version: 9, includeForeignKeys: false),
      schema(version: 9, includeCurrentIndexes: false),
      schema(version: 9, uniqueRequestIndex: false),
    ]
    for sql in malformedSchemas {
      let url = try makeDatabase(sql: sql)
      let store = ActivityStore(databaseURL: url)
      await #expect(throws: ActivityStoreError.sqlite("Unsupported activity schema version 9")) {
        try await store.activities(account: account)
      }
    }
  }

  private let account = "0x0000000000000000000000000000000000000001"

  private func makeDatabase(sql: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ActivityStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Activity.sqlite")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    return url
  }

  private func schema(
    version: Int, signatureHashType: String = "TEXT", includeForeignKeys: Bool = true,
    includeCurrentIndexes: Bool = true, uniqueRequestIndex: Bool = true
  ) -> String {
    var transactionColumns = """
      id INTEGER PRIMARY KEY AUTOINCREMENT, tx_hash TEXT NOT NULL UNIQUE,
      app_id INTEGER NOT NULL, chain_id_hex TEXT NOT NULL, method TEXT,
      from_address TEXT, created_at INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending'
      """
    if version >= 3 {
      transactionColumns +=
        ", request_id TEXT, nonce TEXT, updated_at INTEGER, block_number TEXT, error TEXT"
    }
    if version >= 4 { transactionColumns += ", profile_id TEXT" }
    if version >= 6 { transactionColumns += ", transaction_data TEXT" }
    if version >= 8 { transactionColumns += ", call_bundle_id TEXT" }
    if includeForeignKeys { transactionColumns += ", FOREIGN KEY(app_id) REFERENCES apps(id)" }

    var sql = """
      CREATE TABLE apps (
        id INTEGER PRIMARY KEY AUTOINCREMENT, domain TEXT, uri TEXT, scheme TEXT,
        UNIQUE(domain, uri, scheme));
      CREATE TABLE transactions (\(transactionColumns));
      """
    if version != 1 {
      let digestUniqueness = version == 9 ? "" : " UNIQUE"
      var signatureColumns = """
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        signature_hash \(signatureHashType) NOT NULL\(digestUniqueness),
        app_id INTEGER NOT NULL, chain_id_hex TEXT NOT NULL, method TEXT NOT NULL,
        from_address TEXT, message_content TEXT NOT NULL, signature_hex TEXT NOT NULL,
        created_at INTEGER NOT NULL
        """
      if version >= 3 { signatureColumns += ", request_id TEXT" }
      if version >= 4 { signatureColumns += ", profile_id TEXT" }
      if includeForeignKeys { signatureColumns += ", FOREIGN KEY(app_id) REFERENCES apps(id)" }
      sql += "CREATE TABLE signatures (\(signatureColumns));"
    }
    if version == 9, includeCurrentIndexes {
      sql += """
        CREATE INDEX transactions_account_created
        ON transactions(lower(from_address), created_at DESC, id DESC);
        CREATE INDEX signatures_account_created
        ON signatures(lower(from_address), created_at DESC, id DESC);
        CREATE INDEX idx_transactions_created_at ON transactions(created_at DESC);
        CREATE INDEX idx_transactions_created_id_desc
        ON transactions(created_at DESC, id DESC);
        CREATE INDEX idx_signatures_created_at ON signatures(created_at DESC, id DESC);
        CREATE \(uniqueRequestIndex ? "UNIQUE " : "")INDEX signatures_request_id
        ON signatures(request_id) WHERE request_id IS NOT NULL;
        """
    }
    sql += "PRAGMA user_version=\(version);"
    return sql
  }

  private func request(
    kind: RequestKind, method: String, origin: String = "https://dapp.example",
    profileID: String? = nil, params: JSONValue = .array([]), requestedAccount: String? = nil
  ) -> WalletPendingRequest {
    let id = UUID()
    return WalletPendingRequest(
      id: id, kind: kind, method: method, origin: origin, profileID: profileID, chainId: "8453",
      account: requestedAccount ?? account, params: params,
      payloadDigest: CanonicalRequest.digest(of: params, keyedBy: id))
  }
}
