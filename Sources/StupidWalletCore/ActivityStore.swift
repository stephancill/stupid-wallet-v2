import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct SQLiteColumn: Equatable {
  let type: String
  let isNotNull: Bool
  let defaultValue: String?
  let primaryKeyIndex: Int
}

public enum ActivityKind: String, Sendable, Equatable {
  case transaction
  case signature
}

public enum ActivityStatus: String, Sendable, Equatable {
  case signed
  case submitted
  case pending
  case confirmed
  case reverted
  case dropped
  case replaced
}

public struct ActivityRecord: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: ActivityKind
  public let requestID: UUID?
  public let transactionHash: String?
  public let chainID: String
  public let method: String
  public let account: String
  public let origin: String
  public let nonce: String?
  public let createdAt: Date
  public let updatedAt: Date
  public let status: ActivityStatus
  public let blockNumber: String?
  public let error: String?
  public let profileID: String?
  public let transactionData: String?
  public let signedMessage: String?
  public let signature: String?
  public let callBundleID: String?

  public func belongs(to site: ConnectedSite) -> Bool {
    guard account.caseInsensitiveCompare(site.address) == .orderedSame else { return false }
    if let origin = site.origin {
      return origin == Origin.normalize(self.origin) && site.profileID == profileID
    }
    return site.domain == Origin.downHost(of: self.origin)
  }
}

public enum ActivityStoreError: Error, Sendable, Equatable {
  case unavailable
  case sqlite(String)
}

/// SQLite activity shared by the app and extension. The schema extends the shipped
/// `Activity.sqlite` tables so upgrades retain existing history.
public actor ActivityStore {
  private let databaseURL: URL

  public init(
    databaseURL: URL? = nil,
    appGroupID: String = PendingRequestStore.defaultAppGroup
  ) {
    if let databaseURL {
      self.databaseURL = databaseURL
    } else if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupID)
    {
      self.databaseURL = container.appendingPathComponent("Activity.sqlite")
    } else {
      let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
      let directory = base.appendingPathComponent("StupidWallet")
      self.databaseURL = directory.appendingPathComponent("Activity.sqlite")
    }
  }

  public func recordTransaction(
    request: WalletPendingRequest, hash: String, nonce: String, callBundleID: String? = nil,
    at date: Date = Date()
  ) throws {
    try withDatabase { database in
      let appID = try upsertApp(database, origin: request.origin)
      let sql = """
        INSERT INTO transactions
          (tx_hash, app_id, chain_id_hex, method, from_address, created_at, status,
           request_id, nonce, updated_at, profile_id, transaction_data, call_bundle_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(tx_hash) DO UPDATE SET
          status = excluded.status, request_id = excluded.request_id,
          nonce = excluded.nonce, updated_at = excluded.updated_at,
          profile_id = excluded.profile_id,
          transaction_data = excluded.transaction_data,
          call_bundle_id = excluded.call_bundle_id;
        """
      try execute(database, sql: sql) { statement in
        bind(hash.lowercased(), to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, appID)
        bind(Self.chainHex(request.chainId), to: 3, in: statement)
        bind(request.method, to: 4, in: statement)
        bind(request.account, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(date.timeIntervalSince1970))
        bind(ActivityStatus.submitted.rawValue, to: 7, in: statement)
        bind(request.id.uuidString, to: 8, in: statement)
        bind(nonce, to: 9, in: statement)
        sqlite3_bind_int64(statement, 10, Int64(date.timeIntervalSince1970))
        bindOptional(request.profileID, to: 11, in: statement)
        bindOptional(
          Self.transactionData(request.resolvedParams ?? request.params), to: 12, in: statement)
        bindOptional(callBundleID, to: 13, in: statement)
      }
    }
  }

  public func recordSignature(
    request: WalletPendingRequest, signature: [UInt8], at date: Date = Date()
  ) throws {
    let digest = "0x" + Hex.encode(Keccak.keccak256(signature))
    let signatureHex = "0x" + Hex.encode(signature)
    try withDatabase { database in
      let appID = try upsertApp(database, origin: request.origin)
      let sql = """
        INSERT INTO signatures
          (signature_hash, app_id, chain_id_hex, method, from_address,
            message_content, signature_hex, created_at, request_id, profile_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(request_id) WHERE request_id IS NOT NULL DO NOTHING;
        """
      try execute(database, sql: sql) { statement in
        bind(digest, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, appID)
        bind(Self.chainHex(request.chainId), to: 3, in: statement)
        bind(request.method, to: 4, in: statement)
        bind(request.account, to: 5, in: statement)
        bind(Self.signedMessage(request), to: 6, in: statement)
        bind(signatureHex, to: 7, in: statement)
        sqlite3_bind_int64(statement, 8, Int64(date.timeIntervalSince1970))
        bind(request.id.uuidString, to: 9, in: statement)
        bindOptional(request.profileID, to: 10, in: statement)
      }
    }
  }

  public func updateTransaction(
    hash: String,
    status: ActivityStatus,
    blockNumber: String? = nil,
    error: String? = nil,
    at date: Date = Date()
  ) throws {
    try withDatabase { database in
      try execute(
        database,
        sql: """
          UPDATE transactions
          SET status = ?, block_number = ?, error = ?, updated_at = ?
          WHERE lower(tx_hash) = lower(?);
          """
      ) { statement in
        bind(status.rawValue, to: 1, in: statement)
        bindOptional(blockNumber, to: 2, in: statement)
        bindOptional(error, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, Int64(date.timeIntervalSince1970))
        bind(hash, to: 5, in: statement)
      }
    }
  }

  public func unresolvedTransactions() throws -> [ActivityRecord] {
    try queryUnresolvedTransactions(account: nil, limit: 500)
  }

  public func unresolvedTransactions(account: String, limit: Int = 500) throws
    -> [ActivityRecord]
  {
    try queryUnresolvedTransactions(account: account, limit: limit)
  }

  public func activities(limit: Int = 100) throws -> [ActivityRecord] {
    try activities(
      account: nil, limit: limit, appFilter: nil, filterProfile: false, profileID: nil)
  }

  public func activities(account: String, limit: Int = 100) throws -> [ActivityRecord] {
    try activities(
      account: account, limit: limit, appFilter: nil, filterProfile: false, profileID: nil)
  }

  public func activities(for site: ConnectedSite, limit: Int = 100) throws -> [ActivityRecord] {
    try activities(for: site, account: site.address, limit: limit)
  }

  public func activities(
    for site: ConnectedSite, account: String, limit: Int = 100
  ) throws -> [ActivityRecord] {
    if let origin = site.origin {
      return try activities(
        account: account, limit: limit, appFilter: ("a.uri", origin), filterProfile: true,
        profileID: site.profileID)
    }
    return try activities(
      account: account, limit: limit, appFilter: ("a.domain", site.domain), filterProfile: false,
      profileID: nil)
  }

  public func callBundle(
    id: String, origin: String, profileID: String?, account: String
  ) throws -> ActivityRecord? {
    try withDatabase { database in
      let profileClause = profileID == nil ? "t.profile_id IS NULL" : "t.profile_id = ?"
      let sql = """
        SELECT CAST(t.id AS TEXT), t.request_id, t.tx_hash, t.chain_id_hex,
               COALESCE(t.method, 'eth_sendTransaction'), COALESCE(t.from_address, ''),
               COALESCE(a.uri, a.domain, ''), t.nonce, t.created_at,
               COALESCE(t.updated_at, t.created_at), t.status, t.block_number, t.error,
               t.profile_id, t.transaction_data, t.call_bundle_id
        FROM transactions t LEFT JOIN apps a ON a.id = t.app_id
        WHERE lower(t.method) = 'wallet_sendcalls'
          AND (lower(t.tx_hash) = lower(?) OR t.call_bundle_id = ?)
          AND lower(COALESCE(a.uri, a.domain, '')) = lower(?)
          AND lower(COALESCE(t.from_address, '')) = lower(?)
          AND \(profileClause)
        LIMIT 1;
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw sqliteError(database)
      }
      defer { sqlite3_finalize(statement) }
      bind(id, to: 1, in: statement)
      bind(id, to: 2, in: statement)
      bind(Origin.normalize(origin), to: 3, in: statement)
      bind(account, to: 4, in: statement)
      if let profileID { bind(profileID, to: 5, in: statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return ActivityRecord(
        id: "transaction-\(text(statement, 0) ?? "0")", kind: .transaction,
        requestID: text(statement, 1).flatMap(UUID.init(uuidString:)),
        transactionHash: text(statement, 2),
        chainID: Self.decimalChainID(text(statement, 3) ?? "0x1"),
        method: text(statement, 4) ?? "", account: text(statement, 5) ?? "",
        origin: text(statement, 6) ?? "", nonce: text(statement, 7),
        createdAt: Date(
          timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8))),
        updatedAt: Date(
          timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9))),
        status: ActivityStatus(rawValue: text(statement, 10) ?? "") ?? .pending,
        blockNumber: text(statement, 11), error: text(statement, 12),
        profileID: text(statement, 13), transactionData: text(statement, 14),
        signedMessage: nil, signature: nil, callBundleID: text(statement, 15))
    }
  }

  private func activities(
    account: String?,
    limit: Int,
    appFilter: (column: String, value: String)?,
    filterProfile: Bool,
    profileID: String?
  ) throws -> [ActivityRecord] {
    try withDatabase { database in
      func filter(recordAlias: String) -> String {
        var conditions: [String] = []
        if account != nil {
          conditions.append("lower(COALESCE(\(recordAlias).from_address, '')) = lower(?)")
        }
        if let appFilter {
          conditions.append("lower(\(appFilter.column)) = lower(?)")
        }
        if filterProfile {
          conditions.append(
            profileID == nil ? "\(recordAlias).profile_id IS NULL" : "\(recordAlias).profile_id = ?"
          )
        }
        return conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
      }
      let sql = """
        SELECT 'transaction', CAST(t.id AS TEXT), t.request_id, t.tx_hash,
               t.chain_id_hex, COALESCE(t.method, 'eth_sendTransaction'),
               COALESCE(t.from_address, ''), COALESCE(a.uri, a.domain, ''), t.nonce,
               t.created_at, COALESCE(t.updated_at, t.created_at), t.status,
               t.block_number, t.error, t.profile_id, t.transaction_data, NULL, NULL,
               t.call_bundle_id
        FROM transactions t LEFT JOIN apps a ON a.id = t.app_id
        \(filter(recordAlias: "t"))
        UNION ALL
        SELECT 'signature', CAST(s.id AS TEXT), s.request_id, NULL,
               s.chain_id_hex, s.method, COALESCE(s.from_address, ''),
                COALESCE(a.uri, a.domain, ''), NULL, s.created_at, s.created_at,
                  'signed', NULL, NULL, s.profile_id, NULL, s.message_content, s.signature_hex,
                  NULL
        FROM signatures s LEFT JOIN apps a ON a.id = s.app_id
        \(filter(recordAlias: "s"))
        ORDER BY 10 DESC, 2 DESC LIMIT ?;
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw sqliteError(database)
      }
      defer { sqlite3_finalize(statement) }
      var bindingIndex: Int32 = 1
      for _ in 0..<2 {
        if let account {
          bind(account, to: bindingIndex, in: statement)
          bindingIndex += 1
        }
        if let appFilter {
          bind(appFilter.value, to: bindingIndex, in: statement)
          bindingIndex += 1
        }
        if filterProfile, let profileID {
          bind(profileID, to: bindingIndex, in: statement)
          bindingIndex += 1
        }
      }
      sqlite3_bind_int(statement, bindingIndex, Int32(max(0, limit)))
      var records: [ActivityRecord] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let kind = ActivityKind(rawValue: text(statement, 0) ?? "") ?? .transaction
        let rowID = text(statement, 1) ?? "0"
        let status = ActivityStatus(rawValue: text(statement, 11) ?? "") ?? .pending
        records.append(
          ActivityRecord(
            id: "\(kind.rawValue)-\(rowID)", kind: kind,
            requestID: text(statement, 2).flatMap(UUID.init(uuidString:)),
            transactionHash: text(statement, 3),
            chainID: Self.decimalChainID(text(statement, 4) ?? "0x1"),
            method: text(statement, 5) ?? "", account: text(statement, 6) ?? "",
            origin: text(statement, 7) ?? "", nonce: text(statement, 8),
            createdAt: Date(
              timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9))),
            updatedAt: Date(
              timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 10))),
            status: status, blockNumber: text(statement, 12), error: text(statement, 13),
            profileID: text(statement, 14), transactionData: text(statement, 15),
            signedMessage: text(statement, 16), signature: text(statement, 17),
            callBundleID: text(statement, 18)))
      }
      return records
    }
  }

  private func queryUnresolvedTransactions(account: String?, limit: Int) throws
    -> [ActivityRecord]
  {
    try withDatabase { database in
      let accountClause = account == nil ? "" : "AND lower(COALESCE(t.from_address, '')) = lower(?)"
      let sql = """
        SELECT CAST(t.id AS TEXT), t.request_id, t.tx_hash, t.chain_id_hex,
               COALESCE(t.method, 'eth_sendTransaction'), COALESCE(t.from_address, ''),
               COALESCE(a.uri, a.domain, ''), t.nonce, t.created_at,
               COALESCE(t.updated_at, t.created_at), t.status, t.block_number, t.error,
               t.profile_id, t.transaction_data, t.call_bundle_id
        FROM transactions t LEFT JOIN apps a ON a.id = t.app_id
        WHERE t.status IN ('submitted', 'pending') \(accountClause)
        ORDER BY t.created_at DESC, t.id DESC LIMIT ?;
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw sqliteError(database)
      }
      defer { sqlite3_finalize(statement) }
      var bindingIndex: Int32 = 1
      if let account {
        bind(account, to: bindingIndex, in: statement)
        bindingIndex += 1
      }
      sqlite3_bind_int(statement, bindingIndex, Int32(max(0, limit)))
      var records: [ActivityRecord] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        records.append(
          ActivityRecord(
            id: "transaction-\(text(statement, 0) ?? "0")", kind: .transaction,
            requestID: text(statement, 1).flatMap(UUID.init(uuidString:)),
            transactionHash: text(statement, 2),
            chainID: Self.decimalChainID(text(statement, 3) ?? "0x1"),
            method: text(statement, 4) ?? "", account: text(statement, 5) ?? "",
            origin: text(statement, 6) ?? "", nonce: text(statement, 7),
            createdAt: Date(
              timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8))),
            updatedAt: Date(
              timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9))),
            status: ActivityStatus(rawValue: text(statement, 10) ?? "") ?? .pending,
            blockNumber: text(statement, 11), error: text(statement, 12),
            profileID: text(statement, 13), transactionData: text(statement, 14),
            signedMessage: nil, signature: nil, callBundleID: text(statement, 15)))
      }
      return records
    }
  }

  private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        databaseURL.path, &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        nil) == SQLITE_OK, let database
    else { throw ActivityStoreError.unavailable }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5_000)
    try exec(database, "PRAGMA journal_mode=WAL;")
    try exec(database, "PRAGMA foreign_keys=ON;")
    try createSchema(database)
    return try body(database)
  }

  private func createSchema(_ database: OpaquePointer) throws {
    try exec(database, "BEGIN IMMEDIATE;")
    do {
      let version = try schemaVersion(database)
      try validateSchema(database, version: version)
      try exec(
        database,
        """
        CREATE TABLE IF NOT EXISTS apps (
          id INTEGER PRIMARY KEY AUTOINCREMENT, domain TEXT, uri TEXT, scheme TEXT,
          UNIQUE(domain, uri, scheme));
        CREATE TABLE IF NOT EXISTS transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT, tx_hash TEXT NOT NULL UNIQUE,
          app_id INTEGER NOT NULL, chain_id_hex TEXT NOT NULL, method TEXT,
          from_address TEXT, created_at INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          FOREIGN KEY(app_id) REFERENCES apps(id));
        CREATE TABLE IF NOT EXISTS signatures (
          id INTEGER PRIMARY KEY AUTOINCREMENT, signature_hash TEXT NOT NULL,
          app_id INTEGER NOT NULL, chain_id_hex TEXT NOT NULL, method TEXT NOT NULL,
          from_address TEXT, message_content TEXT NOT NULL, signature_hex TEXT NOT NULL,
          created_at INTEGER NOT NULL, FOREIGN KEY(app_id) REFERENCES apps(id));
        """)
      try addColumn(database, table: "transactions", name: "request_id", type: "TEXT")
      try addColumn(database, table: "transactions", name: "nonce", type: "TEXT")
      try addColumn(database, table: "transactions", name: "updated_at", type: "INTEGER")
      try addColumn(database, table: "transactions", name: "block_number", type: "TEXT")
      try addColumn(database, table: "transactions", name: "error", type: "TEXT")
      try addColumn(database, table: "transactions", name: "profile_id", type: "TEXT")
      try addColumn(database, table: "transactions", name: "transaction_data", type: "TEXT")
      try addColumn(database, table: "transactions", name: "call_bundle_id", type: "TEXT")
      try addColumn(database, table: "signatures", name: "request_id", type: "TEXT")
      try addColumn(database, table: "signatures", name: "profile_id", type: "TEXT")
      try migrateSignatureIdentity(database)
      try exec(
        database,
        """
        CREATE INDEX IF NOT EXISTS transactions_account_created
        ON transactions(lower(from_address), created_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS signatures_account_created
        ON signatures(lower(from_address), created_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_transactions_created_at
        ON transactions(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_transactions_created_id_desc
        ON transactions(created_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_signatures_created_at
        ON signatures(created_at DESC, id DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS signatures_request_id
        ON signatures(request_id) WHERE request_id IS NOT NULL;
        PRAGMA user_version=9;
        COMMIT;
        """)
    } catch {
      try? exec(database, "ROLLBACK;")
      throw error
    }
  }

  private func schemaVersion(_ database: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func validateSchema(_ database: OpaquePointer, version: Int) throws {
    let supportedVersions: Set<Int> = [0, 1, 2, 3, 4, 6, 7, 8, 9]
    guard supportedVersions.contains(version) else { throw unsupportedSchema(version) }

    let tables = try tableNames(database)
    if version == 0, tables.isEmpty { return }
    let dawnV1Tables: Set<String> = ["apps", "transactions"]
    let completeTables = dawnV1Tables.union(["signatures"])
    if version == 0 {
      guard tables == dawnV1Tables || tables == completeTables else {
        throw unsupportedSchema(version)
      }
    } else if version == 1 {
      guard tables == dawnV1Tables else { throw unsupportedSchema(version) }
    } else {
      guard tables == completeTables else { throw unsupportedSchema(version) }
    }

    let nullableText = SQLiteColumn(
      type: "TEXT", isNotNull: false, defaultValue: nil, primaryKeyIndex: 0)
    let requiredText = SQLiteColumn(
      type: "TEXT", isNotNull: true, defaultValue: nil, primaryKeyIndex: 0)
    let nullableInteger = SQLiteColumn(
      type: "INTEGER", isNotNull: false, defaultValue: nil, primaryKeyIndex: 0)
    let requiredInteger = SQLiteColumn(
      type: "INTEGER", isNotNull: true, defaultValue: nil, primaryKeyIndex: 0)
    let identifier = SQLiteColumn(
      type: "INTEGER", isNotNull: false, defaultValue: nil, primaryKeyIndex: 1)
    let status = SQLiteColumn(
      type: "TEXT", isNotNull: true, defaultValue: "'pending'", primaryKeyIndex: 0)

    let expectedApps = [
      "id": identifier, "domain": nullableText, "uri": nullableText, "scheme": nullableText,
    ]
    var expectedTransactions = [
      "id": identifier, "tx_hash": requiredText, "app_id": requiredInteger,
      "chain_id_hex": requiredText, "method": nullableText, "from_address": nullableText,
      "created_at": requiredInteger, "status": status,
    ]
    if version >= 3 {
      expectedTransactions.merge([
        "request_id": nullableText, "nonce": nullableText, "updated_at": nullableInteger,
        "block_number": nullableText, "error": nullableText,
      ]) { current, _ in current }
    }
    if version >= 4 { expectedTransactions["profile_id"] = nullableText }
    if version >= 6 { expectedTransactions["transaction_data"] = nullableText }
    if version >= 8 { expectedTransactions["call_bundle_id"] = nullableText }

    guard try columnDefinitions(database, table: "apps") == expectedApps,
      try columnDefinitions(database, table: "transactions") == expectedTransactions,
      try hasAppForeignKey(database, table: "transactions")
    else { throw unsupportedSchema(version) }

    let appDefinition = try tableDefinition(database, table: "apps")
    let transactionDefinition = try tableDefinition(database, table: "transactions")
    guard appDefinition.contains("unique(domain, uri, scheme)"),
      transactionDefinition.contains("tx_hash text not null unique")
    else { throw unsupportedSchema(version) }

    if tables.contains("signatures") {
      var expectedSignatures = [
        "id": identifier, "signature_hash": requiredText, "app_id": requiredInteger,
        "chain_id_hex": requiredText, "method": requiredText, "from_address": nullableText,
        "message_content": requiredText, "signature_hex": requiredText,
        "created_at": requiredInteger,
      ]
      if version >= 3 { expectedSignatures["request_id"] = nullableText }
      if version >= 4 { expectedSignatures["profile_id"] = nullableText }
      guard try columnDefinitions(database, table: "signatures") == expectedSignatures,
        try hasAppForeignKey(database, table: "signatures")
      else { throw unsupportedSchema(version) }
      let signatureDefinition = try tableDefinition(database, table: "signatures")
      let digestIsUnique = signatureDefinition.contains("signature_hash text not null unique")
      guard version == 9 ? !digestIsUnique : digestIsUnique else {
        throw unsupportedSchema(version)
      }
    }

    if version == 9 {
      let requiredIndexes = [
        "transactions_account_created":
          "create index transactions_account_created on transactions(lower(from_address), created_at desc, id desc)",
        "signatures_account_created":
          "create index signatures_account_created on signatures(lower(from_address), created_at desc, id desc)",
        "idx_transactions_created_at":
          "create index idx_transactions_created_at on transactions(created_at desc)",
        "idx_transactions_created_id_desc":
          "create index idx_transactions_created_id_desc on transactions(created_at desc, id desc)",
        "idx_signatures_created_at":
          "create index idx_signatures_created_at on signatures(created_at desc, id desc)",
        "signatures_request_id":
          "create unique index signatures_request_id on signatures(request_id) where request_id is not null",
      ]
      for (name, definition) in requiredIndexes {
        guard try indexDefinition(database, name: name).contains(definition) else {
          throw unsupportedSchema(version)
        }
      }
    }
  }

  private func tableNames(_ database: OpaquePointer) throws -> Set<String> {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';", -1,
        &statement, nil) == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    var result: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = text(statement, 0) { result.insert(name) }
    }
    return result
  }

  private func columnDefinitions(
    _ database: OpaquePointer, table: String
  ) throws -> [String: SQLiteColumn] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil)
        == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    var result: [String: SQLiteColumn] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = text(statement, 1), let type = text(statement, 2) else { continue }
      result[name] = SQLiteColumn(
        type: type.uppercased(), isNotNull: sqlite3_column_int(statement, 3) != 0,
        defaultValue: text(statement, 4),
        primaryKeyIndex: Int(sqlite3_column_int(statement, 5)))
    }
    return result
  }

  private func hasAppForeignKey(_ database: OpaquePointer, table: String) throws -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA foreign_key_list(\(table));", -1, &statement, nil)
        == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    var matches = 0
    var total = 0
    while sqlite3_step(statement) == SQLITE_ROW {
      total += 1
      if text(statement, 2) == "apps", text(statement, 3) == "app_id", text(statement, 4) == "id" {
        matches += 1
      }
    }
    return total == 1 && matches == 1
  }

  private func tableDefinition(_ database: OpaquePointer, table: String) throws -> String {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;", -1,
        &statement, nil) == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    bind(table, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW, let definition = text(statement, 0) else {
      throw sqliteError(database)
    }
    return definition.lowercased().components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  private func indexDefinition(_ database: OpaquePointer, name: String) throws -> String {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?;", -1,
        &statement, nil) == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    bind(name, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW, let definition = text(statement, 0) else {
      return ""
    }
    return definition.lowercased().components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  private func unsupportedSchema(_ version: Int) -> ActivityStoreError {
    ActivityStoreError.sqlite("Unsupported activity schema version \(version)")
  }

  private func migrateSignatureIdentity(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'signatures';",
        -1, &statement, nil) == SQLITE_OK
    else { throw sqliteError(database) }
    guard sqlite3_step(statement) == SQLITE_ROW, let definition = text(statement, 0) else {
      sqlite3_finalize(statement)
      throw sqliteError(database)
    }
    sqlite3_finalize(statement)
    statement = nil
    guard definition.lowercased().contains("signature_hash text not null unique") else { return }

    try exec(
      database,
      """
      CREATE TABLE signatures_v9 (
        id INTEGER PRIMARY KEY AUTOINCREMENT, signature_hash TEXT NOT NULL,
        app_id INTEGER NOT NULL, chain_id_hex TEXT NOT NULL, method TEXT NOT NULL,
        from_address TEXT, message_content TEXT NOT NULL, signature_hex TEXT NOT NULL,
        created_at INTEGER NOT NULL, request_id TEXT, profile_id TEXT,
        FOREIGN KEY(app_id) REFERENCES apps(id));
      INSERT INTO signatures_v9
        (id, signature_hash, app_id, chain_id_hex, method, from_address,
         message_content, signature_hex, created_at, request_id, profile_id)
      SELECT id, signature_hash, app_id, chain_id_hex, method, from_address,
             message_content, signature_hex, created_at, request_id, profile_id
      FROM signatures;
      DROP TABLE signatures;
      ALTER TABLE signatures_v9 RENAME TO signatures;
      """)
  }

  private func addColumn(
    _ database: OpaquePointer, table: String, name: String, type: String
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil)
        == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if text(statement, 1) == name { return }
    }
    try exec(database, "ALTER TABLE \(table) ADD COLUMN \(name) \(type);")
  }

  private func upsertApp(_ database: OpaquePointer, origin: String) throws -> Int64 {
    let url = URL(string: origin)
    let domain = url?.host ?? Origin.downHost(of: origin)
    let scheme = url?.scheme
    try execute(
      database,
      sql: "INSERT OR IGNORE INTO apps (domain, uri, scheme) VALUES (?, ?, ?);"
    ) { statement in
      bind(domain, to: 1, in: statement)
      bind(origin, to: 2, in: statement)
      bindOptional(scheme, to: 3, in: statement)
    }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT id FROM apps WHERE domain = ? AND uri = ? LIMIT 1;", -1, &statement,
        nil) == SQLITE_OK
    else { throw sqliteError(database) }
    defer { sqlite3_finalize(statement) }
    bind(domain, to: 1, in: statement)
    bind(origin, to: 2, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
    return sqlite3_column_int64(statement, 0)
  }

  private func execute(
    _ database: OpaquePointer, sql: String, bindings: (OpaquePointer?) -> Void
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError(database)
    }
    defer { sqlite3_finalize(statement) }
    bindings(statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
  }

  private func exec(_ database: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw sqliteError(database)
    }
  }

  private func sqliteError(_ database: OpaquePointer) -> ActivityStoreError {
    ActivityStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
  }

  private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
  }

  private func bindOptional(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
    if let value {
      bind(value, to: index, in: statement)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
  }

  private static func chainHex(_ chainID: String) -> String {
    if chainID.lowercased().hasPrefix("0x") { return chainID.lowercased() }
    return Int(chainID).map { "0x" + String($0, radix: 16) } ?? chainID
  }

  private static func decimalChainID(_ chainID: String) -> String {
    if chainID.lowercased().hasPrefix("0x"), let value = Int(chainID.dropFirst(2), radix: 16) {
      return String(value)
    }
    return chainID
  }

  private static func transactionData(_ params: JSONValue) -> String? {
    guard case .array(let values) = params, case .object(let transaction)? = values.first else {
      return nil
    }
    return transaction["data"]?.stringValue ?? transaction["input"]?.stringValue
  }

  private static func signedMessage(_ request: WalletPendingRequest) -> String {
    switch request.kind {
    case .siwe:
      return (try? SIWE.message(from: request.params)) ?? ""
    case .message:
      guard case .array(let values) = request.params else { return "" }
      return values.first?.stringValue ?? ""
    case .typedData:
      if case .array(let values) = request.params, values.count >= 2 {
        return values[1].stringValue ?? ""
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return (try? String(decoding: encoder.encode(request.params), as: UTF8.self)) ?? ""
    default:
      return ""
    }
  }
}
