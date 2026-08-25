import Darwin
import Foundation

public enum WalletRegistryAdoptionError: Error, Sendable, Equatable {
  case unavailable
  case corrupt
  case noSecretForAddress
  case noSeedForGroup(UUID)
  case migrationFailed(WalletMigrationFailure)
  case fallbackNotRemoved
  case invalidConnectionState
  case invalidBalanceCache
}

/// Existence probe over a registered protected secret without releasing key bytes.
public protocol ProtectedSecretProbing: Sendable {
  func secretExists(account: String) -> Bool
}

public protocol ProtectedSeedProbing: Sendable {
  func seedExists(groupID: UUID) -> Bool
}

extension KeychainSeedStore: ProtectedSeedProbing {
  public func seedExists(groupID: UUID) -> Bool {
    contains(groupID: groupID)
  }
}

extension KeychainKeyStore: ProtectedSecretProbing {
  public func secretExists(account: String) -> Bool {
    contains(account: account)
  }
}

public struct WalletRegistryAdoptionResult: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case noWallet
    case adopted
    case alreadyAdopted
  }

  public let kind: Kind
  public let registry: WalletRegistry?

  public init(kind: Kind, registry: WalletRegistry?) {
    self.kind = kind
    self.registry = registry
  }
}

/// Idempotent Gate A adoption: brings old Dawn-format wallet state into the wallet registry
/// as one private-key group, under a `.migrating` barrier that no app or extension operation
/// may skip.
///
/// Sequence per `docs/multi-account-implementation-plan.md`:
/// 1. Recover/load the registry.
/// 2. Authenticate and prove the old Dawn account.
/// 3. Adopt the registry as `.migrating` with the matching fail-closed projection.
/// 4. Adopt Dawn hostname grants and initialize the connection default.
/// 5. Validate the empty-or-account-bound balance cache.
/// 6. Remove and verify the absence of `sw2.walletAddress`.
/// 7. Validate registry, connection state, projection, fallback absence, and cache, then
///    atomically advance the registry to `.complete`.
///
public struct WalletRegistryAdoption: Sendable {
  private let directory: URL?
  private let suiteName: String
  private let registryStore: WalletRegistryStore
  private let connectionStore: ConnectionStateStore
  private let balanceCache: BalanceCache
  private let probe: any ProtectedSecretProbing
  private let seedProbe: any ProtectedSeedProbing
  private let migrationBackend: any OldWalletBackend
  private let claimURL: URL?
  private let faultInjector: any PersistenceFaultInjecting

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    probe: any ProtectedSecretProbing = KeychainKeyStore(),
    seedProbe: any ProtectedSeedProbing = KeychainSeedStore(),
    migrationBackend: any OldWalletBackend = SecurityWalletBackend()
  ) {
    self.init(
      directory: directory,
      appGroup: appGroup,
      probe: probe,
      seedProbe: seedProbe,
      migrationBackend: migrationBackend,
      faultInjector: NoPersistenceFaults())
  }

  init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    probe: any ProtectedSecretProbing = KeychainKeyStore(),
    seedProbe: any ProtectedSeedProbing = KeychainSeedStore(),
    migrationBackend: any OldWalletBackend = SecurityWalletBackend(),
    faultInjector: any PersistenceFaultInjecting
  ) {
    self.directory = directory
    suiteName = appGroup
    registryStore = WalletRegistryStore(
      directory: directory, appGroup: appGroup, faultInjector: faultInjector)
    connectionStore = ConnectionStateStore(
      directory: directory, suiteName: appGroup, faultInjector: faultInjector)
    balanceCache = BalanceCache(
      directory: directory, appGroup: appGroup, faultInjector: faultInjector)
    self.probe = probe
    self.seedProbe = seedProbe
    self.migrationBackend = migrationBackend
    let container =
      directory ?? WalletStore.containerURL(appGroup: appGroup) ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
    claimURL = container.appendingPathComponent(
      "wallet-registry-adoption.lock", isDirectory: false)
    self.faultInjector = faultInjector
  }

  public func ensureAdopted() async throws -> WalletRegistryAdoptionResult {
    try withAdoptionCoordination {
      try adoptUnlocked()
    }
  }

  private func adoptUnlocked() throws -> WalletRegistryAdoptionResult {
    let loaded = try registryStore.load()
    if let loaded, loaded.adoptionState == .complete {
      try WalletGroupManager(
        directory: directory, appGroup: suiteName
      ).resumeDeletingGroups()
      guard let ready = try registryStore.loadReady() else {
        throw WalletRegistryAdoptionError.corrupt
      }
      // A downgraded build may have reintroduced the rebuild fallback; remove and verify
      // its absence on every entry, not only during first adoption.
      try removeFallback()
      try validateReadyState(registry: ready)
      return WalletRegistryAdoptionResult(kind: .alreadyAdopted, registry: ready)
    }
    if let loaded, loaded.groups.isEmpty, loaded.homeSelectedAddress == nil {
      return try resumeEmptyBootstrap(loaded)
    }

    let proven: String
    if let loaded {
      guard let home = loaded.homeSelectedAddress else { throw WalletRegistryAdoptionError.corrupt }
      proven = home
    } else {
      guard let resolved = try resolveProvenAddress() else {
        if hasUnsupportedRebuildRegistration() {
          return WalletRegistryAdoptionResult(kind: .noWallet, registry: nil)
        }
        return try bootstrapEmptyRegistry()
      }
      proven = resolved
    }

    var current = loaded
    if current == nil {
      let migrating = migratingRegistry(address: proven)
      do {
        try registryStore.create(migrating)
        current = migrating
      } catch WalletRegistryError.alreadyExists {
        guard
          let reloaded = try registryStore.load(),
          reloaded.adoptionState == .complete
        else {
          throw WalletRegistryAdoptionError.corrupt
        }
        try removeFallback()
        return WalletRegistryAdoptionResult(kind: .alreadyAdopted, registry: reloaded)
      }
    }
    guard let registry = current, registry.adoptionState == .migrating else {
      throw WalletRegistryAdoptionError.corrupt
    }
    try validateSecretSources(registry: registry)

    // Dawn grants have hostname precision. Current-rebuild normalized grants are not inputs.
    let initialConnectionState = try connectionStore.initialMigratedState(
      defaultAccount: proven)
    let connection = try connectionStore.getOrCreate(initialConnectionState)
    if let defaultAccount = connection.defaultAccount,
      defaultAccount.caseInsensitiveCompare(proven) != .orderedSame
    {
      throw WalletRegistryAdoptionError.corrupt
    }
    try connection.validate(against: registry)

    // Dawn has no supported singleton cache. Only the current account-bound shape is valid.
    try validateBalanceCache(registry: registry)

    // Remove and verify the rebuild-era fallback before any multi-account state is enabled.
    try removeFallback()

    // Persist the fallback-removal commitment, then advance to `.complete`.
    try faultInjector.hit(.fallbackStateBeforeCommit)
    let withoutFallback = try registryStore.update(expectedRevision: registry.revision) {
      current in
      WalletRegistry(
        revision: current.revision + 1,
        adoptionState: current.adoptionState,
        groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    _ = try connectionStore.load()
    try validateBalanceCache(registry: withoutFallback)
    try faultInjector.hit(.completionStateBeforeCommit)
    let complete = try registryStore.update(expectedRevision: withoutFallback.revision) {
      current in
      WalletRegistry(
        revision: current.revision + 1,
        adoptionState: .complete,
        groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
    }
    try validateReadyState(registry: complete)
    return WalletRegistryAdoptionResult(kind: .adopted, registry: complete)
  }

  private func resolveProvenAddress() throws -> String? {
    let nonempty = { (value: String?) -> String? in
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    // Rebuild registrations are exclusion signals, never identity inputs. In particular,
    // retained Dawn material must not silently turn an installed rebuild into a supported source.
    if hasUnsupportedRebuildRegistration() {
      return nil
    }

    let oldAddress = migrationBackend.oldAddress()

    if oldAddress != nil {
      switch WalletMigration.migrate(backend: migrationBackend) {
      case .success(.migrated(let address)):
        guard let address = nonempty(address), probe.secretExists(account: address) else {
          throw WalletRegistryAdoptionError.noSecretForAddress
        }
        return address
      case .success(.alreadyMigrated), .success(.noOldWallet), .success(.skippedNewWalletExists):
        guard let address = nonempty(oldAddress), probe.secretExists(account: address) else {
          throw WalletRegistryAdoptionError.noSecretForAddress
        }
        return address
      case .failure(let failure):
        throw WalletRegistryAdoptionError.migrationFailed(failure)
      }
    }
    return nil
  }

  private func hasUnsupportedRebuildRegistration() -> Bool {
    let nonempty = { (value: String?) -> Bool in
      guard let value else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    return nonempty(WalletStore.activeAddress(directory: directory))
      || nonempty(defaults.string(forKey: WalletFactory.walletAddressKey))
  }

  private func bootstrapEmptyRegistry() throws -> WalletRegistryAdoptionResult {
    let migrating = WalletRegistry(
      revision: 0,
      adoptionState: .migrating,
      groups: [],
      homeSelectedAddress: nil,
      legacyWalletAddressFallbackRemoved: false)
    try registryStore.create(migrating)
    return try resumeEmptyBootstrap(migrating)
  }

  private func resumeEmptyBootstrap(_ registry: WalletRegistry) throws
    -> WalletRegistryAdoptionResult
  {
    guard registry.adoptionState == .migrating, registry.groups.isEmpty,
      registry.homeSelectedAddress == nil
    else { throw WalletRegistryAdoptionError.corrupt }
    _ = try connectionStore.getOrCreate(ConnectionState(revision: 0))
    try removeFallback()
    let withoutFallback: WalletRegistry
    if registry.legacyWalletAddressFallbackRemoved {
      withoutFallback = registry
    } else {
      try faultInjector.hit(.fallbackStateBeforeCommit)
      withoutFallback = try registryStore.update(expectedRevision: registry.revision) { current in
        WalletRegistry(
          revision: current.revision + 1,
          adoptionState: .migrating,
          groups: current.groups,
          homeSelectedAddress: current.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: true)
      }
    }
    try faultInjector.hit(.completionStateBeforeCommit)
    let complete = try registryStore.update(expectedRevision: withoutFallback.revision) { current in
      WalletRegistry(
        revision: current.revision + 1,
        adoptionState: .complete,
        groups: current.groups,
        homeSelectedAddress: current.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: true)
    }
    try validateReadyState(registry: complete)
    return WalletRegistryAdoptionResult(kind: .noWallet, registry: complete)
  }

  private func removeFallback() throws {
    try faultInjector.hit(.fallbackBeforeRemove)
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removeObject(forKey: WalletFactory.walletAddressKey)
    defaults.synchronize()
    if let remaining = defaults.string(forKey: WalletFactory.walletAddressKey),
      !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw WalletRegistryAdoptionError.fallbackNotRemoved
    }
    try faultInjector.hit(.fallbackAfterRemove)
  }

  private func validateReadyState(registry: WalletRegistry) throws {
    guard registry.adoptionState == .complete,
      registry.legacyWalletAddressFallbackRemoved
    else { throw WalletRegistryAdoptionError.corrupt }
    try validateSecretSources(registry: registry)
    try registryStore.validateProjection(for: registry)
    guard let connection = try connectionStore.load() else {
      throw WalletRegistryAdoptionError.invalidConnectionState
    }
    try connection.validate(against: registry)

    try validateBalanceCache(registry: registry)
  }

  private func validateSecretSources(registry: WalletRegistry) throws {
    for group in registry.groups where group.lifecycle == .active {
      switch group.kind {
      case .privateKey:
        guard let account = group.accounts.first?.address, probe.secretExists(account: account)
        else {
          throw WalletRegistryAdoptionError.noSecretForAddress
        }
      case .seed:
        guard seedProbe.seedExists(groupID: group.id) else {
          throw WalletRegistryAdoptionError.noSeedForGroup(group.id)
        }
      }
    }
  }

  private func validateBalanceCache(registry: WalletRegistry) throws {
    let registered = Set(registry.groups.flatMap(\.accounts).map { $0.address.lowercased() })
    if let cache = try balanceCache.load(),
      cache.entries.contains(where: { !registered.contains($0.account.lowercased()) })
    {
      throw WalletRegistryAdoptionError.invalidBalanceCache
    }
  }

  private func migratingRegistry(address: String) -> WalletRegistry {
    let createdAt = Date()
    let group = WalletGroup(
      id: UUID(),
      kind: .privateKey,
      createdAt: createdAt,
      nextDerivationIndex: nil,
      accounts: [
        WalletAccount(address: address, derivationIndex: nil, createdAt: createdAt)
      ],
      lifecycle: .active)
    return WalletRegistry(
      schemaVersion: WalletRegistry.currentSchemaVersion,
      revision: 0,
      adoptionState: .migrating,
      groups: [group],
      homeSelectedAddress: address,
      legacyWalletAddressFallbackRemoved: false)
  }

  private func withAdoptionCoordination<T>(_ operation: () throws -> T) throws -> T {
    try faultInjector.hit(.adoptionClaimBefore)
    guard let claimURL else { throw WalletRegistryAdoptionError.unavailable }
    let descriptor = open(claimURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw WalletRegistryAdoptionError.unavailable }
    guard close(descriptor) == 0 else { throw WalletRegistryAdoptionError.unavailable }

    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var result: Result<T, Error>?
    coordinator.coordinate(
      writingItemAt: claimURL,
      options: [],
      error: &coordinationError
    ) { _ in
      result = Result { try operation() }
    }
    if let result { return try result.get() }
    throw WalletRegistryAdoptionError.unavailable
  }
}
