import Darwin
import Foundation

public enum BalanceCacheError: Error, Sendable, Equatable {
  case unavailable
  case invalidRevision
}

/// One account's last successfully aggregated native balance.
public struct BalanceCacheEntry: Codable, Sendable, Equatable {
  public let account: String
  public let balance: String
  public let updatedAt: Date
  /// Registry revision captured when the refresh that produced this entry began.
  public let registryRevision: UInt64?

  public init(
    account: String,
    balance: String,
    updatedAt: Date,
    registryRevision: UInt64? = nil
  ) {
    self.account = account
    self.balance = balance
    self.updatedAt = updatedAt
    self.registryRevision = registryRevision
  }
}

public struct BalanceCacheSnapshot: Sendable, Equatable {
  public let revision: UInt64
  public let entries: [BalanceCacheEntry]

  public init(revision: UInt64, entries: [BalanceCacheEntry]) {
    self.revision = revision
    self.entries = entries
  }

  public func entry(account: String) -> BalanceCacheEntry? {
    entries.first { $0.account.caseInsensitiveCompare(account) == .orderedSame }
  }
}

/// Atomic, account-bound persistence for the last successfully aggregated native balance.
///
/// The payload is a versioned dictionary keyed by normalized address in one App Group file.
public struct BalanceCache: Sendable {
  private static let currentSchemaVersion = 1

  private struct Payload: Codable {
    let schemaVersion: Int
    let revision: UInt64
    var entries: [String: BalanceCacheEntry]
  }

  private let fileURL: URL?
  private let lockURL: URL?
  private let faultInjector: any PersistenceFaultInjecting

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    self.init(directory: directory, appGroup: appGroup, faultInjector: NoPersistenceFaults())
  }

  init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    faultInjector: any PersistenceFaultInjecting
  ) {
    let container = directory ?? WalletStore.containerURL(appGroup: appGroup)
    fileURL = container?.appendingPathComponent("native-balance-cache.json", isDirectory: false)
    lockURL = container?.appendingPathComponent("native-balance-cache.lock", isDirectory: false)
    self.faultInjector = faultInjector
  }

  /// The versioned account-bound snapshot.
  public func load() throws -> BalanceCacheSnapshot? {
    try withLock { try loadUnlocked() }
  }

  private func loadUnlocked() throws -> BalanceCacheSnapshot? {
    guard let fileURL else { throw BalanceCacheError.unavailable }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw BalanceCacheError.unavailable
    }

    if let payload = try? Self.decode(Payload.self, from: data) {
      guard payload.schemaVersion == Self.currentSchemaVersion else {
        throw BalanceCacheError.unavailable
      }
      return BalanceCacheSnapshot(
        revision: payload.revision, entries: Array(payload.entries.values))
    }

    throw BalanceCacheError.unavailable
  }

  /// The last successful formatted total for an account, case-insensitively.
  public func balance(account: String) throws -> String? {
    try load()?.entry(account: account)?.balance
  }

  /// The full cache entry for an account, case-insensitively.
  public func entry(account: String) throws -> BalanceCacheEntry? {
    try load()?.entry(account: account)
  }

  public func save(balance: String, account: String, registryRevision: UInt64? = nil) throws {
    try withLock {
      let existing = try loadUnlocked()
      guard (existing?.revision ?? 0) < UInt64.max else {
        throw BalanceCacheError.invalidRevision
      }
      var payload = Payload(
        schemaVersion: Self.currentSchemaVersion,
        revision: (existing?.revision ?? 0) + 1,
        entries: [:])
      for entry in existing?.entries ?? [] {
        payload.entries[Self.normalized(entry.account)] = entry
      }
      payload.entries[Self.normalized(account)] = BalanceCacheEntry(
        account: account, balance: balance, updatedAt: Date(), registryRevision: registryRevision)
      try writeUnlocked(payload)
    }
  }

  public func remove(account: String) throws {
    try withLock {
      guard let snapshot = try loadUnlocked() else { return }
      guard snapshot.entry(account: account) != nil else { return }
      guard snapshot.revision < UInt64.max else { throw BalanceCacheError.invalidRevision }
      var payload = Payload(
        schemaVersion: Self.currentSchemaVersion,
        revision: snapshot.revision + 1,
        entries: [:])
      for entry in snapshot.entries
      where entry.account.caseInsensitiveCompare(account)
        != .orderedSame
      {
        payload.entries[Self.normalized(entry.account)] = entry
      }
      try writeUnlocked(payload)
    }
  }

  public func removeAll() throws {
    try withLock {
      let current = try loadUnlocked()
      guard (current?.revision ?? 0) < UInt64.max else {
        throw BalanceCacheError.invalidRevision
      }
      try writeUnlocked(
        Payload(
          schemaVersion: Self.currentSchemaVersion,
          revision: (current?.revision ?? 0) + 1,
          entries: [:]))
    }
  }

  func revision() throws -> UInt64? {
    try load()?.revision
  }

  private func writeUnlocked(_ payload: Payload) throws {
    guard let fileURL else { throw BalanceCacheError.unavailable }
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      encoder.outputFormatting = [.sortedKeys]
      try faultInjector.hit(.cacheBeforeWrite)
      try Self.durableReplace(data: encoder.encode(payload), at: fileURL)
      try faultInjector.hit(.cacheAfterWrite)
    } catch let error as PersistenceFaultSimulationError {
      throw error
    } catch let error as BalanceCacheError {
      throw error
    } catch {
      throw BalanceCacheError.unavailable
    }
  }

  private func withLock<T>(_ operation: () throws -> T) throws -> T {
    guard let lockURL else { throw BalanceCacheError.unavailable }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw BalanceCacheError.unavailable }
    guard flock(descriptor, LOCK_EX) == 0 else {
      _ = close(descriptor)
      throw BalanceCacheError.unavailable
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    return try operation()
  }

  private static func normalized(_ account: String) -> String {
    account.lowercased()
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      return try decoder.decode(type, from: data)
    } catch {
      throw BalanceCacheError.unavailable
    }
  }

  private static func durableReplace(data: Data, at fileURL: URL) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
    var descriptor = open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw BalanceCacheError.unavailable }

    var shouldRemoveTemporary = true
    defer {
      if descriptor >= 0 {
        _ = close(descriptor)
      }
      if shouldRemoveTemporary {
        _ = unlink(temporaryURL.path)
      }
    }

    let wroteAllBytes = data.withUnsafeBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
      var offset = 0
      while offset < rawBuffer.count {
        let count = Darwin.write(
          descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
    guard wroteAllBytes, fsync(descriptor) == 0, close(descriptor) == 0 else {
      throw BalanceCacheError.unavailable
    }
    descriptor = -1

    guard rename(temporaryURL.path, fileURL.path) == 0 else {
      throw BalanceCacheError.unavailable
    }
    shouldRemoveTemporary = false

    try synchronizeDirectory(directoryURL)
  }

  private static func synchronizeDirectory(_ directoryURL: URL) throws {
    let directoryDescriptor = open(directoryURL.path, O_RDONLY)
    guard directoryDescriptor >= 0 else { throw BalanceCacheError.unavailable }
    defer { _ = close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw BalanceCacheError.unavailable }
  }
}
