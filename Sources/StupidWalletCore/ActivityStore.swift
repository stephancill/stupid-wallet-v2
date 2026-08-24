import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

  public func belongs(to site: ConnectedSite) -> Bool {
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
      self.databaseURL = base.appendingPathComponent("StupidWallet/Activity.sqlite")
    }
  }

  public func recordTransaction(
    request: WalletPendingRequest, hash: String, nonce: String, at date: Date = Date()
  ) throws {
    try withDatabase { database in
      let appID = try upsertApp(database, origin: request.origin)
      let sql = """
        INSERT INTO transactions
          (tx_hash, app_id, chain_id_hex, method, from_address, created_at, status,
           request_id, nonce, updated_at, profile_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(tx_hash) DO UPDATE SET
          status = excluded.status, request_id = excluded.request_id,
          nonce = excluded.nonce, updated_at = excluded.updated_at,
          profile_id = excluded.profile_id;
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
      }
    }
  }

  public func recordSignature(
    request: WalletPendingRequest, signature: [UInt8], at date: Date = Date()
  ) throws {
    let digest = "0x" + Hex.encode(Keccak.keccak256(signature))
    try withDatabase { database in
      let appID = try upsertApp(database, origin: request.origin)
      let sql = """
        INSERT OR IGNORE INTO signatures
          (signature_hash, app_id, chain_id_hex, method, from_address,
           message_content, signature_hex, created_at, request_id, profile_id)
        VALUES (?, ?, ?, ?, ?, '', '', ?, ?, ?);
        """
      try execute(database, sql: sql) { statement in
        bind(digest, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, appID)
        bind(Self.chainHex(request.chainId), to: 3, in: statement)
        bind(request.method, to: 4, in: statement)
        bind(request.account, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(date.timeIntervalSince1970))
        bind(request.id.uuidString, to: 7, in: statement)
        bindOptional(request.profileID, to: 8, in: statement)
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
    try activities(limit: 500).filter {
      $0.kind == .transaction && [.submitted, .pending].contains($0.status)
    }
  }

  public func activities(limit: Int = 100) throws -> [ActivityRecord] {
    try activities(limit: limit, appFilter: nil, filterProfile: false, profileID: nil)
  }

  public func activities(for site: ConnectedSite, limit: Int = 100) throws -> [ActivityRecord] {
    if let origin = site.origin {
      return try activities(
        limit: limit, appFilter: ("a.uri", origin), filterProfile: true,
        profileID: site.profileID)
    }
    return try activities(
      limit: limit, appFilter: ("a.domain", site.domain), filterProfile: false,
      profileID: nil)
  }

  private func activities(
    limit: Int,
    appFilter: (column: String, value: String)?,
    filterProfile: Bool,
    profileID: String?
  ) throws -> [ActivityRecord] {
    try withDatabase { database in
      func filter(recordAlias: String) -> String {
        var conditions: [String] = []
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
               t.block_number, t.error, t.profile_id
        FROM transactions t LEFT JOIN apps a ON a.id = t.app_id
        \(filter(recordAlias: "t"))
        UNION ALL
        SELECT 'signature', CAST(s.id AS TEXT), s.request_id, NULL,
               s.chain_id_hex, s.method, COALESCE(s.from_address, ''),
               COALESCE(a.uri, a.domain, ''), NULL, s.created_at, s.created_at,
               'signed', NULL, NULL, s.profile_id
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
            profileID: text(statement, 14)))
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
        id INTEGER PRIMARY KEY AUTOINCREMENT, signature_hash TEXT NOT NULL UNIQUE,
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
    try addColumn(database, table: "signatures", name: "request_id", type: "TEXT")
    try addColumn(database, table: "signatures", name: "profile_id", type: "TEXT")
    try exec(database, "PRAGMA user_version=4;")
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
}
