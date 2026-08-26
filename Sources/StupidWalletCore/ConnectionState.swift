import Darwin
import Foundation

/// A durable connection grant from an authorized dapp to one wallet account.
///
/// Exact grants bind a normalized account, normalized origin, and Safari profile. Legacy
/// grants retain the shipped domain-only precision and authorize only their stored account.
public struct ConnectionGrant: Codable, Sendable, Equatable, Identifiable {
  public let account: String
  /// Normalized origin for exact grants; `nil` for legacy hostname grants.
  public let origin: String?
  /// Lowercased display host; the compatibility key used to mirror the legacy dictionary.
  public let legacyDomain: String
  public let profileID: String?
  public let connectedAt: Date
  public let precision: GrantPrecision

  public init(
    account: String,
    origin: String?,
    legacyDomain: String,
    profileID: String?,
    connectedAt: Date,
    precision: GrantPrecision
  ) {
    self.account = account
    self.origin = origin.map(Origin.normalize)
    self.legacyDomain = legacyDomain.lowercased()
    self.profileID = profileID
    self.connectedAt = connectedAt
    self.precision = precision
  }

  public var id: String {
    if let origin {
      return "exact|\(origin)|\(profileID ?? "default")|\(account.lowercased())"
    }
    return "legacy|\(legacyDomain)|\(account.lowercased())"
  }

  /// The identity used to match an active connection to its exact grant.
  public var activeKey: String? {
    guard let origin else { return nil }
    return Self.activeKey(origin: origin, profileID: profileID, account: account)
  }

  public static func activeKey(origin: String, profileID: String?, account: String) -> String {
    "exact|\(Origin.normalize(origin))|\(profileID ?? "default")|\(account.lowercased())"
  }
}

public enum GrantPrecision: String, Codable, Sendable {
  case exact
  case hostname
}

/// The one granted account currently exposed to an origin/profile through `eth_accounts`.
public struct ActiveConnection: Codable, Sendable, Equatable, Identifiable {
  public let origin: String
  public let profileID: String?
  public let account: String

  public init(origin: String, profileID: String?, account: String) {
    self.origin = Origin.normalize(origin)
    self.profileID = profileID
    self.account = account
  }

  public var id: String { "\(origin)|\(profileID ?? "default")" }
}

/// A recoverable marker written atomically with a successful plain-connect commit. It is
/// authoritative for recovery until the matching pending record is durably consumed.
public struct ConnectCommit: Codable, Sendable, Equatable, Identifiable {
  public let requestID: UUID
  public let requestRevision: UInt64
  public let connectionRevision: UInt64
  public let origin: String
  public let profileID: String?
  public let account: String
  public let bindingDigest: String
  public let result: JSONValue
  public let committedAt: Date

  public init(
    requestID: UUID,
    requestRevision: UInt64,
    connectionRevision: UInt64,
    origin: String,
    profileID: String?,
    account: String,
    bindingDigest: String,
    result: JSONValue,
    committedAt: Date
  ) {
    self.requestID = requestID
    self.requestRevision = requestRevision
    self.connectionRevision = connectionRevision
    self.origin = Origin.normalize(origin)
    self.profileID = profileID
    self.account = account
    self.bindingDigest = bindingDigest
    self.result = result
    self.committedAt = committedAt
  }

  public var id: UUID { requestID }

  func matches(_ request: WalletPendingRequest) -> Bool {
    request.id == requestID && request.kind == .connect && request.bindingVersion == 2
      && request.revision == requestRevision && request.origin == origin
      && request.profileID == profileID && request.account == account
      && request.payloadDigest == bindingDigest && result == .array([.string(account)])
      && CanonicalRequest.bindingDigestV2(
        requestID: request.id, kind: request.kind, method: request.method, origin: request.origin,
        profileID: request.profileID, chainId: request.chainId, account: request.account,
        params: request.params, createdAt: request.createdAt, expiresAt: request.expiresAt)
        == bindingDigest
  }
}

/// One versioned, atomic App Group file describing every connection grant, the active
/// account per origin/profile, the persisted default connection account, and durable
/// connect-commit markers. It replaces normalized-grant authority in `UserDefaults`.
public struct ConnectionState: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let revision: UInt64
  public var defaultAccount: String?
  public var grants: [ConnectionGrant]
  public var activeConnections: [ActiveConnection]
  public var connectCommits: [ConnectCommit]

  public init(
    schemaVersion: Int = ConnectionState.currentSchemaVersion,
    revision: UInt64,
    defaultAccount: String? = nil,
    grants: [ConnectionGrant] = [],
    activeConnections: [ActiveConnection] = [],
    connectCommits: [ConnectCommit] = []
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.defaultAccount = defaultAccount
    self.grants = grants
    self.activeConnections = activeConnections
    self.connectCommits = connectCommits
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw ConnectionStateError.unsupportedSchemaVersion(schemaVersion)
    }

    var grantIDs = Set<String>()
    var activeKeys = Set<String>()

    for grant in grants {
      guard Self.isCanonicalAddress(grant.account) else {
        throw ConnectionStateError.invalid(.invalidAddress)
      }
      guard grantIDs.insert(grant.id).inserted else {
        throw ConnectionStateError.invalid(.duplicateGrant)
      }

      switch grant.precision {
      case .exact:
        guard let origin = grant.origin, Origin.normalize(origin) == origin,
          grant.legacyDomain == Origin.downHost(of: origin).lowercased()
        else {
          throw ConnectionStateError.invalid(.invalidExactGrant)
        }
      case .hostname:
        guard grant.origin == nil, !grant.legacyDomain.isEmpty,
          grant.legacyDomain == grant.legacyDomain.lowercased()
        else {
          throw ConnectionStateError.invalid(.invalidLegacyGrant)
        }
      }
    }

    for active in activeConnections {
      guard Self.isCanonicalAddress(active.account) else {
        throw ConnectionStateError.invalid(.invalidAddress)
      }
      guard activeKeys.insert(active.id).inserted else {
        throw ConnectionStateError.invalid(.duplicateActive)
      }
      let key = ConnectionGrant.activeKey(
        origin: active.origin, profileID: active.profileID, account: active.account)
      guard grantIDs.contains(key) else {
        throw ConnectionStateError.invalid(.activeWithoutGrant)
      }
    }

    if let defaultAccount {
      guard Self.isCanonicalAddress(defaultAccount) else {
        throw ConnectionStateError.invalid(.invalidDefault)
      }
    }

    var commitIDs = Set<UUID>()
    for commit in connectCommits {
      guard commitIDs.insert(commit.requestID).inserted else {
        throw ConnectionStateError.invalid(.duplicateCommit)
      }
      guard Self.isCanonicalAddress(commit.account),
        Origin.normalize(commit.origin) == commit.origin,
        commit.connectionRevision > 0,
        commit.connectionRevision <= revision,
        commit.bindingDigest.count == 64,
        Hex.data(commit.bindingDigest)?.count == 32,
        commit.result == .array([.string(commit.account)])
      else {
        throw ConnectionStateError.invalid(.invalidCommit)
      }
      if commit.connectionRevision == revision {
        let hasGrant = grants.contains {
          $0.precision == .exact && $0.origin == commit.origin
            && $0.profileID == commit.profileID && $0.account == commit.account
        }
        let hasActive = activeConnections.contains {
          $0.origin == commit.origin && $0.profileID == commit.profileID
            && $0.account == commit.account
        }
        guard hasGrant, hasActive, defaultAccount == commit.account else {
          throw ConnectionStateError.invalid(.invalidCommit)
        }
      }
    }
  }

  /// Dormant grants for unregistered accounts are retained for migration compatibility, but
  /// active and default accounts must resolve to an active registered wallet group.
  public func validate(against registry: WalletRegistry) throws {
    try validate()
    try registry.validate()
    let activeAccounts = Set(
      registry.groups
        .filter { $0.lifecycle == .active }
        .flatMap(\.accounts)
        .map { $0.address.lowercased() })

    if let defaultAccount, !activeAccounts.contains(defaultAccount.lowercased()) {
      throw ConnectionStateError.invalid(.unregisteredDefault)
    }
    if activeConnections.contains(where: { !activeAccounts.contains($0.account.lowercased()) }) {
      throw ConnectionStateError.invalid(.unregisteredActive)
    }
  }

  private static func isCanonicalAddress(_ address: String) -> Bool {
    guard address.hasPrefix("0x"), address.count == 42,
      let bytes = Hex.data(String(address.dropFirst(2))), bytes.count == 20
    else {
      return false
    }
    return EIP55.checksum(from: bytes) == address
  }
}

public enum ConnectionStateValidationError: Sendable, Equatable {
  case invalidAddress
  case duplicateGrant
  case invalidExactGrant
  case invalidLegacyGrant
  case duplicateActive
  case activeWithoutGrant
  case invalidDefault
  case duplicateCommit
  case invalidCommit
  case unregisteredDefault
  case unregisteredActive
}

public enum ConnectionStateError: Error, Sendable, Equatable {
  case unavailable
  case corrupt
  case missing
  case alreadyExists
  case unsupportedSchemaVersion(Int)
  case invalid(ConnectionStateValidationError)
  case staleRevision(expected: UInt64, actual: UInt64)
  case invalidRevision
}

/// Persists the authoritative connection state as one atomic App Group file guarded by an
/// OS advisory lock, and mirrors the legacy `connectedSites` hostname dictionary after
/// every successful write for best-effort downgrade/legacy compatibility.
public struct ConnectionStateStore: @unchecked Sendable {
  /// The shared legacy App Group `connectedSites` hostname key, kept as a mirror.
  static let legacyKey = "connectedSites"

  private let fileURL: URL?
  private let lockURL: URL?
  private let suiteName: String?
  private let faultInjector: any PersistenceFaultInjecting

  /// Creates a store writing `connection-state.json` under `directory` (or the App Group
  /// container) and reading/writing the legacy mirror through the named suite.
  public init(directory: URL? = nil, suiteName: String? = nil) {
    self.init(
      directory: directory, suiteName: suiteName, faultInjector: NoPersistenceFaults())
  }

  init(
    directory: URL? = nil,
    suiteName: String? = nil,
    faultInjector: any PersistenceFaultInjecting
  ) {
    let container =
      directory ?? WalletStore.containerURL(appGroup: PendingRequestStore.defaultAppGroup)
    fileURL = container?.appendingPathComponent("connection-state.json", isDirectory: false)
    lockURL = container?.appendingPathComponent("connection-state.lock", isDirectory: false)
    self.suiteName = suiteName
    self.faultInjector = faultInjector
  }

  public init(
    appGroup: String = PendingRequestStore.defaultAppGroup,
    directory: URL? = nil
  ) {
    self.init(directory: directory, suiteName: appGroup)
  }

  /// Hermetic-test initializer persisting to a throwaway directory and suite.
  public init(suiteName: String, directory: URL? = nil) {
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    self.init(directory: directory, suiteName: suiteName)
  }

  private var defaults: UserDefaults {
    suiteName.map { UserDefaults(suiteName: $0) ?? .standard } ?? .standard
  }

  public func load() throws -> ConnectionState? {
    try withLock {
      try loadUnlocked()
    }
  }

  func withLockedState<T>(_ operation: (ConnectionState) throws -> T) throws -> T {
    try withLock {
      guard let state = try loadUnlocked() else { throw ConnectionStateError.missing }
      return try operation(state)
    }
  }

  public func getOrCreate(_ state: ConnectionState) throws -> ConnectionState {
    try withLock {
      if let current = try loadUnlocked() { return current }
      let persisted = try Self.persistenceNormalized(state)
      guard persisted.revision == 0 else { throw ConnectionStateError.invalidRevision }
      try persisted.validate()
      try writeUnlocked(persisted)
      mirrorLegacy(persisted)
      return persisted
    }
  }

  @discardableResult
  public func update(
    expectedRevision: UInt64,
    _ transform: (ConnectionState) throws -> ConnectionState
  ) throws -> ConnectionState {
    try withLock {
      guard let current = try loadUnlocked() else { throw ConnectionStateError.missing }
      guard current.revision == expectedRevision else {
        throw ConnectionStateError.staleRevision(
          expected: expectedRevision, actual: current.revision)
      }
      guard expectedRevision < UInt64.max else { throw ConnectionStateError.invalidRevision }

      let updated = try Self.persistenceNormalized(transform(current))
      guard updated.revision == expectedRevision + 1 else {
        throw ConnectionStateError.invalidRevision
      }
      try updated.validate()
      try writeUnlocked(updated)
      mirrorLegacy(updated)
      return updated
    }
  }

  /// Applies one revision-incrementing mutation while holding the cross-process lock.
  /// Unlike `update(expectedRevision:)`, this is suitable for independent app and extension
  /// writers because the transform always receives the latest durable value.
  @discardableResult
  public func mutate(
    _ transform: (inout ConnectionState) throws -> Void
  ) throws -> ConnectionState {
    try withLock {
      guard var current = try loadUnlocked() else { throw ConnectionStateError.missing }
      guard current.revision < UInt64.max else { throw ConnectionStateError.invalidRevision }
      try transform(&current)
      current = ConnectionState(
        revision: current.revision + 1,
        defaultAccount: current.defaultAccount,
        grants: current.grants,
        activeConnections: current.activeConnections,
        connectCommits: current.connectCommits)
      let updated = try Self.persistenceNormalized(current)
      try updated.validate()
      try writeUnlocked(updated)
      mirrorLegacy(updated)
      return updated
    }
  }

  /// Builds an initial revision-zero connection state from Dawn hostname grants currently
  /// held in `UserDefaults`, without writing. Current-rebuild normalized grants are ignored.
  public func initialMigratedState(defaultAccount: String? = nil) throws -> ConnectionState {
    var grants: [ConnectionGrant] = []

    for site in try readLegacySites() {
      grants.append(
        ConnectionGrant(
          account: site.account,
          origin: nil,
          legacyDomain: site.legacyDomain,
          profileID: nil,
          connectedAt: site.connectedAt,
          precision: .hostname))
    }

    let resolvedDefault: String?
    if let defaultAccount {
      resolvedDefault = defaultAccount
    } else {
      resolvedDefault =
        grants
        .sorted { $0.connectedAt > $1.connectedAt }
        .first?.account
    }

    return ConnectionState(
      schemaVersion: ConnectionState.currentSchemaVersion,
      revision: 0,
      defaultAccount: resolvedDefault,
      grants: grants,
      activeConnections: [])
  }

  private func loadUnlocked() throws -> ConnectionState? {
    guard let fileURL else { throw ConnectionStateError.unavailable }
    guard case .present(let data) = try Self.readFileState(at: fileURL) else { return nil }
    let state: ConnectionState = try Self.decode(data)
    try state.validate()
    return state
  }

  private func writeUnlocked(_ state: ConnectionState) throws {
    guard let fileURL else { throw ConnectionStateError.unavailable }
    try faultInjector.hit(.connectionBeforeWrite)
    try Self.durableReplace(data: try Self.encode(state), at: fileURL)
    try faultInjector.hit(.connectionAfterWrite)
  }

  /// Best-effort downgrade compatibility mirror of the shared `connectedSites` hostname
  /// dictionary. Cannot represent multiple accounts for one domain, so exact-grant
  /// collisions resolve to the most recently connected account.
  private func mirrorLegacy(_ state: ConnectionState) {
    var dict: [String: [String: Any]] = [:]
    for grant in state.grants {
      let existing = dict[grant.legacyDomain]
      if let existing, let connectedAt = existing["connectedAt"] as? String,
        (Self.parseISODate(connectedAt) ?? .distantPast) > grant.connectedAt
      {
        continue
      }
      dict[grant.legacyDomain] = [
        "address": grant.account, "connectedAt": Self.isoString(from: grant.connectedAt),
      ]
    }
    defaults.set(dict, forKey: Self.legacyKey)
  }

  private static func isoString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func readLegacySites() throws -> [ConnectionGrant] {
    guard let stored = defaults.object(forKey: Self.legacyKey) else { return [] }
    guard let dict = stored as? [String: [String: Any]] else {
      throw ConnectionStateError.corrupt
    }
    var out: [ConnectionGrant] = []
    out.reserveCapacity(dict.count)
    for (domain, meta) in dict {
      guard let address = meta["address"] as? String else {
        throw ConnectionStateError.corrupt
      }
      let connectedAt: Date
      if let value = meta["connectedAt"] {
        guard let string = value as? String, let parsed = Self.parseISODate(string) else {
          throw ConnectionStateError.corrupt
        }
        connectedAt = parsed
      } else {
        connectedAt = .distantPast
      }
      out.append(
        ConnectionGrant(
          account: address,
          origin: nil,
          legacyDomain: domain,
          profileID: nil,
          connectedAt: connectedAt,
          precision: .hostname))
    }
    return out
  }

  private func withLock<T>(_ operation: () throws -> T) throws -> T {
    guard let lockURL else { throw ConnectionStateError.unavailable }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw ConnectionStateError.unavailable }
    guard flock(descriptor, LOCK_EX) == 0 else {
      _ = close(descriptor)
      throw ConnectionStateError.unavailable
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    return try operation()
  }

  private static func readFileState(at url: URL) throws -> FileState {
    do {
      return .present(try Data(contentsOf: url))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .absent
    } catch {
      throw ConnectionStateError.unavailable
    }
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(value)
    } catch {
      throw ConnectionStateError.unavailable
    }
  }

  private static func decode<T: Decodable>(_ data: Data) throws -> T {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      return try decoder.decode(T.self, from: data)
    } catch {
      throw ConnectionStateError.corrupt
    }
  }

  private static func persistenceNormalized<T: Codable>(_ value: T) throws -> T {
    try decode(encode(value))
  }

  private enum FileState {
    case absent
    case present(Data)
  }

  private static func durableReplace(data: Data, at fileURL: URL) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
    var descriptor = open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw ConnectionStateError.unavailable }

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
      throw ConnectionStateError.unavailable
    }
    descriptor = -1

    guard rename(temporaryURL.path, fileURL.path) == 0 else {
      throw ConnectionStateError.unavailable
    }
    shouldRemoveTemporary = false

    try synchronizeDirectory(directoryURL)
  }

  private static func synchronizeDirectory(_ directoryURL: URL) throws {
    let directoryDescriptor = open(directoryURL.path, O_RDONLY)
    guard directoryDescriptor >= 0 else { throw ConnectionStateError.unavailable }
    defer { _ = close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw ConnectionStateError.unavailable }
  }

  private static func parseISODate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let fraction = ISO8601DateFormatter()
    fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fraction.date(from: string) { return date }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    if let date = whole.date(from: string) { return date }
    return nil
  }
}
