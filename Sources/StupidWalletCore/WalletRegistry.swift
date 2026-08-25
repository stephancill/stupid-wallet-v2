import Darwin
import Foundation

public enum WalletRegistryAdoptionState: String, Codable, Sendable {
  case migrating
  case complete
}

public enum WalletGroupKind: String, Codable, Sendable {
  case seed
  case privateKey
}

public enum WalletGroupLifecycle: String, Codable, Sendable {
  case active
  case deleting
}

public struct WalletAccount: Codable, Sendable, Equatable, Identifiable {
  public let address: String
  public let derivationIndex: UInt32?
  public let createdAt: Date

  public var id: String { address.lowercased() }

  public init(address: String, derivationIndex: UInt32?, createdAt: Date) {
    self.address = address
    self.derivationIndex = derivationIndex
    self.createdAt = createdAt
  }
}

public struct WalletGroup: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let kind: WalletGroupKind
  public let createdAt: Date
  public var nextDerivationIndex: UInt32?
  public var accounts: [WalletAccount]
  public var lifecycle: WalletGroupLifecycle

  public init(
    id: UUID,
    kind: WalletGroupKind,
    createdAt: Date,
    nextDerivationIndex: UInt32?,
    accounts: [WalletAccount],
    lifecycle: WalletGroupLifecycle
  ) {
    self.id = id
    self.kind = kind
    self.createdAt = createdAt
    self.nextDerivationIndex = nextDerivationIndex
    self.accounts = accounts
    self.lifecycle = lifecycle
  }
}

public struct WalletRegistry: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let revision: UInt64
  public var adoptionState: WalletRegistryAdoptionState
  public var groups: [WalletGroup]
  public var homeSelectedAddress: String?
  public var legacyWalletAddressFallbackRemoved: Bool

  public init(
    schemaVersion: Int = WalletRegistry.currentSchemaVersion,
    revision: UInt64,
    adoptionState: WalletRegistryAdoptionState,
    groups: [WalletGroup],
    homeSelectedAddress: String?,
    legacyWalletAddressFallbackRemoved: Bool
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.adoptionState = adoptionState
    self.groups = groups
    self.homeSelectedAddress = homeSelectedAddress
    self.legacyWalletAddressFallbackRemoved = legacyWalletAddressFallbackRemoved
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw WalletRegistryError.unsupportedSchemaVersion(schemaVersion)
    }

    var groupIDs = Set<UUID>()
    var addresses = Set<String>()
    var activeAddresses = Set<String>()
    var accountCount = 0

    for group in groups {
      guard groupIDs.insert(group.id).inserted else {
        throw WalletRegistryError.invalid(.duplicateGroup)
      }

      switch group.kind {
      case .privateKey:
        guard group.accounts.count == 1, group.nextDerivationIndex == nil,
          group.accounts[0].derivationIndex == nil
        else {
          throw WalletRegistryError.invalid(.invalidPrivateKeyGroup)
        }
      case .seed:
        guard !group.accounts.isEmpty, let nextDerivationIndex = group.nextDerivationIndex,
          nextDerivationIndex <= Self.derivationIndexLimit
        else {
          throw WalletRegistryError.invalid(.invalidSeedGroup)
        }

        var previousIndex: UInt32?
        for account in group.accounts {
          guard let index = account.derivationIndex, index < Self.derivationIndexLimit else {
            throw WalletRegistryError.invalid(.invalidSeedGroup)
          }
          guard previousIndex.map({ index > $0 }) ?? true else {
            throw WalletRegistryError.invalid(.invalidSeedDerivationOrder)
          }
          previousIndex = index
        }
        guard previousIndex.map({ nextDerivationIndex > $0 }) ?? false else {
          throw WalletRegistryError.invalid(.invalidNextDerivationIndex)
        }
      }

      for account in group.accounts {
        guard Self.isCanonicalAddress(account.address) else {
          throw WalletRegistryError.invalid(.invalidAddress)
        }
        let normalized = account.address.lowercased()
        guard addresses.insert(normalized).inserted else {
          throw WalletRegistryError.invalid(.duplicateAddress)
        }
        if group.lifecycle == .active {
          activeAddresses.insert(normalized)
        }
        accountCount += 1
      }
    }

    if let homeSelectedAddress {
      guard Self.isCanonicalAddress(homeSelectedAddress),
        activeAddresses.contains(homeSelectedAddress.lowercased())
      else {
        throw WalletRegistryError.invalid(.invalidHomeSelection)
      }
    }

    if !legacyWalletAddressFallbackRemoved {
      guard adoptionState == .migrating, accountCount <= 1,
        groups.allSatisfy({ $0.kind == .privateKey })
      else {
        throw WalletRegistryError.invalid(.legacyFallbackStillEnabled)
      }
    }
  }

  fileprivate static let derivationIndexLimit: UInt32 = 1 << 31

  private static func isCanonicalAddress(_ address: String) -> Bool {
    guard address.hasPrefix("0x"), address.count == 42,
      let bytes = Hex.data(String(address.dropFirst(2))), bytes.count == 20
    else {
      return false
    }
    return EIP55.checksum(from: bytes) == address
  }
}

public enum WalletRegistryValidationError: Sendable, Equatable {
  case duplicateGroup
  case invalidAddress
  case duplicateAddress
  case invalidPrivateKeyGroup
  case invalidSeedGroup
  case invalidSeedDerivationOrder
  case invalidNextDerivationIndex
  case invalidHomeSelection
  case legacyFallbackStillEnabled
}

public enum WalletRegistryError: Error, Sendable, Equatable {
  case unavailable
  case corrupt
  case missing
  case alreadyExists
  case adoptionIncomplete
  case unsupportedSchemaVersion(Int)
  case invalid(WalletRegistryValidationError)
  case staleRevision(expected: UInt64, actual: UInt64)
  case invalidRevision
  case invalidTransition
  case transitionConflict
}

enum WalletRegistryFileState: Codable, Sendable, Equatable {
  case absent
  case present(Data)
}

enum WalletRegistrySnapshot: Codable, Sendable, Equatable {
  case absent
  case present(WalletRegistry)
}

struct WalletRegistryTransition: Codable, Sendable, Equatable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let previousRegistry: WalletRegistrySnapshot
  let nextRegistry: WalletRegistry
  let previousProjection: WalletRegistryFileState
  let intendedProjection: WalletRegistryFileState

  init(
    schemaVersion: Int = WalletRegistryTransition.currentSchemaVersion,
    previousRegistry: WalletRegistrySnapshot,
    nextRegistry: WalletRegistry,
    previousProjection: WalletRegistryFileState,
    intendedProjection: WalletRegistryFileState
  ) {
    self.schemaVersion = schemaVersion
    self.previousRegistry = previousRegistry
    self.nextRegistry = nextRegistry
    self.previousProjection = previousProjection
    self.intendedProjection = intendedProjection
  }
}

/// Persists the authoritative wallet registry and its rebuild compatibility projection.
public struct WalletRegistryStore: Sendable {
  private let fileURL: URL?
  private let projectionURL: URL?
  private let journalURL: URL?
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
    fileURL = container?.appendingPathComponent("wallet-registry.json", isDirectory: false)
    projectionURL = container?.appendingPathComponent("wallet-address.conf", isDirectory: false)
    journalURL = container?.appendingPathComponent(
      "wallet-registry-transition.json", isDirectory: false)
    lockURL = container?.appendingPathComponent("wallet-registry.lock", isDirectory: false)
    self.faultInjector = faultInjector
  }

  public func load() throws -> WalletRegistry? {
    try withLock {
      try recoverTransitionUnlocked()
      let registry = try loadRegistryUnlocked()
      if let registry {
        try repairProjectionUnlocked(for: registry)
      }
      return registry
    }
  }

  public func loadReady() throws -> WalletRegistry? {
    guard let registry = try load() else { return nil }
    guard registry.adoptionState == .complete else {
      throw WalletRegistryError.adoptionIncomplete
    }
    return registry
  }

  /// Runs a short local-state operation while the complete registry snapshot remains stable.
  /// Callers may acquire only later lock domains (for example connection state) inside `body`.
  func withLockedReady<T>(_ body: (WalletRegistry) throws -> T) throws -> T {
    try withLock {
      try recoverTransitionUnlocked()
      guard let registry = try loadRegistryUnlocked() else { throw WalletRegistryError.missing }
      guard registry.adoptionState == .complete else {
        throw WalletRegistryError.adoptionIncomplete
      }
      try repairProjectionUnlocked(for: registry)
      return try body(registry)
    }
  }

  /// Confirms that the fail-closed rebuild projection exactly matches a registry snapshot.
  public func validateProjection(for registry: WalletRegistry) throws {
    try withLock {
      try recoverTransitionUnlocked()
      guard try loadRegistryUnlocked() == registry, let projectionURL else {
        throw WalletRegistryError.transitionConflict
      }
      guard try Self.readFileState(at: projectionURL) == Self.projection(for: registry) else {
        throw WalletRegistryError.transitionConflict
      }
    }
  }

  public func create(_ registry: WalletRegistry) throws {
    try withLock {
      try recoverTransitionUnlocked()
      guard try loadRegistryUnlocked() == nil else { throw WalletRegistryError.alreadyExists }
      let persisted = try Self.persistenceNormalized(registry)
      guard persisted.revision == 0 else { throw WalletRegistryError.invalidRevision }
      try persisted.validate()
      guard persisted.adoptionState == .migrating else {
        throw WalletRegistryError.invalidTransition
      }
      try commitOrRecoverUnlocked(previous: nil, next: persisted)
    }
  }

  @discardableResult
  public func update(
    expectedRevision: UInt64,
    _ transform: (WalletRegistry) throws -> WalletRegistry
  ) throws -> WalletRegistry {
    try withLock {
      try recoverTransitionUnlocked()
      guard let current = try loadRegistryUnlocked() else { throw WalletRegistryError.missing }
      guard current.revision == expectedRevision else {
        throw WalletRegistryError.staleRevision(
          expected: expectedRevision, actual: current.revision)
      }
      guard expectedRevision < UInt64.max else { throw WalletRegistryError.invalidRevision }

      let updated = try Self.persistenceNormalized(transform(current))
      guard updated.revision == expectedRevision + 1 else {
        throw WalletRegistryError.invalidRevision
      }
      try updated.validate()
      try Self.validateTransition(from: current, to: updated)
      try commitOrRecoverUnlocked(previous: current, next: updated)
      return updated
    }
  }

  private func commitOrRecoverUnlocked(previous: WalletRegistry?, next: WalletRegistry) throws {
    do {
      try commitTransitionUnlocked(previous: previous, next: next)
    } catch {
      if isSimulatedPersistenceInterruption(error) { throw error }
      try recoverTransitionUnlocked()
      guard try loadRegistryUnlocked() == next else { throw error }
    }
  }

  private func commitTransitionUnlocked(previous: WalletRegistry?, next: WalletRegistry) throws {
    guard let journalURL, let projectionURL else { throw WalletRegistryError.unavailable }
    let previousProjection = try Self.readFileState(at: projectionURL)
    let transition = WalletRegistryTransition(
      previousRegistry: previous.map(WalletRegistrySnapshot.present) ?? .absent,
      nextRegistry: next,
      previousProjection: previousProjection,
      intendedProjection: try Self.projection(for: next))

    try Self.durableReplace(data: try Self.encode(transition), at: journalURL)
    try faultInjector.hit(.journalAfterWrite)
    do {
      try faultInjector.hit(.projectionBeforeWrite)
      try Self.apply(transition.intendedProjection, at: projectionURL)
      try faultInjector.hit(.projectionAfterWrite)
    } catch {
      if isSimulatedPersistenceInterruption(error) { throw error }
      do {
        try Self.apply(transition.previousProjection, at: projectionURL)
        try Self.durableRemove(at: journalURL)
      } catch {
        throw WalletRegistryError.unavailable
      }
      throw error
    }

    try faultInjector.hit(.registryBeforeWrite)
    try writeRegistryUnlocked(next)
    try faultInjector.hit(.registryAfterWrite)
    try Self.durableRemove(at: journalURL)
  }

  private func recoverTransitionUnlocked() throws {
    guard let journalURL, let projectionURL else { throw WalletRegistryError.unavailable }
    guard case .present(let data) = try Self.readFileState(at: journalURL) else { return }

    let transition: WalletRegistryTransition = try Self.decode(data)
    guard transition.schemaVersion == WalletRegistryTransition.currentSchemaVersion else {
      throw WalletRegistryError.corrupt
    }
    try transition.nextRegistry.validate()
    guard transition.intendedProjection == (try Self.projection(for: transition.nextRegistry))
    else {
      throw WalletRegistryError.corrupt
    }

    let current = try loadRegistryUnlocked()
    switch transition.previousRegistry {
    case .absent:
      guard transition.nextRegistry.revision == 0,
        transition.nextRegistry.adoptionState == .migrating
      else {
        throw WalletRegistryError.corrupt
      }
      if let current, current != transition.nextRegistry {
        throw WalletRegistryError.transitionConflict
      }
    case .present(let previous):
      try previous.validate()
      guard previous.revision < UInt64.max,
        transition.nextRegistry.revision == previous.revision + 1
      else {
        throw WalletRegistryError.corrupt
      }
      try Self.validateTransition(from: previous, to: transition.nextRegistry)
      guard current == previous || current == transition.nextRegistry else {
        throw WalletRegistryError.transitionConflict
      }
    }

    try Self.apply(transition.intendedProjection, at: projectionURL)
    if current != transition.nextRegistry {
      try writeRegistryUnlocked(transition.nextRegistry)
    }
    try Self.durableRemove(at: journalURL)
  }

  private func repairProjectionUnlocked(for registry: WalletRegistry) throws {
    guard let projectionURL else { throw WalletRegistryError.unavailable }
    let expected = try Self.projection(for: registry)
    guard try Self.readFileState(at: projectionURL) != expected else { return }
    try Self.apply(expected, at: projectionURL)
  }

  private func loadRegistryUnlocked() throws -> WalletRegistry? {
    guard let fileURL else { throw WalletRegistryError.unavailable }
    guard case .present(let data) = try Self.readFileState(at: fileURL) else { return nil }

    let registry: WalletRegistry = try Self.decode(data)
    try registry.validate()
    return registry
  }

  private func writeRegistryUnlocked(_ registry: WalletRegistry) throws {
    guard let fileURL else { throw WalletRegistryError.unavailable }
    try Self.durableReplace(data: try Self.encode(registry), at: fileURL)
  }

  private func withLock<T>(_ operation: () throws -> T) throws -> T {
    guard let lockURL else { throw WalletRegistryError.unavailable }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw WalletRegistryError.unavailable }
    guard flock(descriptor, LOCK_EX) == 0 else {
      _ = close(descriptor)
      throw WalletRegistryError.unavailable
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    return try operation()
  }

  private static func validateTransition(from current: WalletRegistry, to next: WalletRegistry)
    throws
  {
    guard current.schemaVersion == next.schemaVersion,
      !(current.adoptionState == .complete && next.adoptionState != .complete),
      !(current.legacyWalletAddressFallbackRemoved
        && !next.legacyWalletAddressFallbackRemoved)
    else {
      throw WalletRegistryError.invalidTransition
    }
    if next.adoptionState == .complete {
      guard current.legacyWalletAddressFallbackRemoved else {
        throw WalletRegistryError.invalidTransition
      }
    }

    let currentGroups = Dictionary(uniqueKeysWithValues: current.groups.map { ($0.id, $0) })
    let nextGroups = Dictionary(uniqueKeysWithValues: next.groups.map { ($0.id, $0) })

    if !current.legacyWalletAddressFallbackRemoved {
      guard next.groups.count == current.groups.count,
        next.homeSelectedAddress == current.homeSelectedAddress
      else {
        throw WalletRegistryError.invalidTransition
      }
    }

    for group in current.groups {
      guard let updated = nextGroups[group.id] else {
        guard group.lifecycle == .deleting else {
          throw WalletRegistryError.invalidTransition
        }
        continue
      }
      guard updated.kind == group.kind, updated.createdAt == group.createdAt,
        !(group.lifecycle == .deleting && updated.lifecycle != .deleting)
      else {
        throw WalletRegistryError.invalidTransition
      }

      if group.lifecycle == .deleting || updated.lifecycle == .deleting {
        guard updated.accounts == group.accounts,
          updated.nextDerivationIndex == group.nextDerivationIndex
        else {
          throw WalletRegistryError.invalidTransition
        }
      } else if group.kind == .privateKey {
        guard updated.accounts == group.accounts else {
          throw WalletRegistryError.invalidTransition
        }
      } else {
        if updated.accounts == group.accounts {
          guard updated.nextDerivationIndex == group.nextDerivationIndex else {
            throw WalletRegistryError.invalidTransition
          }
          continue
        }
        let addedAccounts = updated.accounts.dropFirst(group.accounts.count)
        guard updated.accounts.starts(with: group.accounts), addedAccounts.count == 1,
          let currentIndex = group.nextDerivationIndex,
          let nextIndex = updated.nextDerivationIndex,
          let addedIndex = addedAccounts.first?.derivationIndex,
          addedIndex >= currentIndex, addedIndex < WalletRegistry.derivationIndexLimit,
          nextIndex == addedIndex + 1
        else {
          throw WalletRegistryError.invalidTransition
        }
      }
    }

    for group in next.groups where currentGroups[group.id] == nil {
      guard current.legacyWalletAddressFallbackRemoved, group.lifecycle == .active else {
        throw WalletRegistryError.invalidTransition
      }
      if group.kind == .seed {
        guard group.accounts.count == 1, group.accounts[0].derivationIndex == 0,
          group.nextDerivationIndex == 1
        else {
          throw WalletRegistryError.invalidTransition
        }
      }
    }

    if !current.legacyWalletAddressFallbackRemoved {
      guard nextGroups.keys.allSatisfy({ currentGroups[$0] != nil }) else {
        throw WalletRegistryError.invalidTransition
      }
    }
  }

  private static func projection(for registry: WalletRegistry) throws -> WalletRegistryFileState {
    guard let home = registry.homeSelectedAddress else { return .absent }
    for group in registry.groups where group.lifecycle == .active {
      guard group.accounts.contains(where: { $0.address == home }) else { continue }
      guard group.kind == .privateKey else { return .absent }
      guard let data = home.appending("\n").data(using: .utf8) else {
        throw WalletRegistryError.unavailable
      }
      return .present(data)
    }
    throw WalletRegistryError.invalid(.invalidHomeSelection)
  }

  private static func readFileState(at url: URL) throws -> WalletRegistryFileState {
    do {
      return .present(try Data(contentsOf: url))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .absent
    } catch {
      throw WalletRegistryError.unavailable
    }
  }

  private static func apply(_ state: WalletRegistryFileState, at url: URL) throws {
    switch state {
    case .absent:
      try durableRemove(at: url)
    case .present(let data):
      try durableReplace(data: data, at: url)
    }
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(value)
    } catch {
      throw WalletRegistryError.unavailable
    }
  }

  private static func decode<T: Decodable>(_ data: Data) throws -> T {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      return try decoder.decode(T.self, from: data)
    } catch {
      throw WalletRegistryError.corrupt
    }
  }

  private static func persistenceNormalized<T: Codable>(_ value: T) throws -> T {
    try decode(encode(value))
  }

  private static func durableRemove(at fileURL: URL) throws {
    guard unlink(fileURL.path) == 0 else {
      if errno == ENOENT { return }
      throw WalletRegistryError.unavailable
    }
    try synchronizeDirectory(fileURL.deletingLastPathComponent())
  }

  private static func durableReplace(data: Data, at fileURL: URL) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
    var descriptor = open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw WalletRegistryError.unavailable }

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
      throw WalletRegistryError.unavailable
    }
    descriptor = -1

    guard rename(temporaryURL.path, fileURL.path) == 0 else {
      throw WalletRegistryError.unavailable
    }
    shouldRemoveTemporary = false

    try synchronizeDirectory(directoryURL)
  }

  private static func synchronizeDirectory(_ directoryURL: URL) throws {
    let directoryDescriptor = open(directoryURL.path, O_RDONLY)
    guard directoryDescriptor >= 0 else { throw WalletRegistryError.unavailable }
    defer { _ = close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw WalletRegistryError.unavailable }
  }
}
