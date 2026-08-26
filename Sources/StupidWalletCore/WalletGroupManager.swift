import Foundation
import Security

public enum WalletGroupManagerError: Error, Sendable, Equatable {
  case registryNotReady
  case groupNotFound
  case groupNotActive
  case wrongGroupKind
  case duplicateAccount
  case secureStorage
  case verificationFailed
  case derivationExhausted
  case registryChanged
  case pendingRequestBusy
  case corruptState
  case invalidLabel
  case accountNotFound
  case lastSeedAccount
}

/// Gate B wallet-group provisioning over the authoritative registry.
public struct WalletGroupManager: Sendable {
  private let registryStore: WalletRegistryStore
  private let keyStore: any WalletKeyStoring
  private let seedStore: any WalletSeedStoring
  private let lifecycle: WalletGroupLifecycleCoordinator
  private let connectionStore: ConnectionStateStore
  private let balanceCache: BalanceCache
  private let pendingStore: PendingRequestStore
  private let migrationBackend: SecurityWalletBackend

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    keyStore: KeychainKeyStore = KeychainKeyStore(),
    seedStore: KeychainSeedStore = KeychainSeedStore()
  ) {
    registryStore = WalletRegistryStore(directory: directory, appGroup: appGroup)
    self.keyStore = keyStore
    self.seedStore = seedStore
    lifecycle = WalletGroupLifecycleCoordinator(directory: directory, appGroup: appGroup)
    connectionStore = ConnectionStateStore(directory: directory, suiteName: appGroup)
    balanceCache = BalanceCache(directory: directory, appGroup: appGroup)
    pendingStore = PendingRequestStore(
      directory: directory?.appendingPathComponent("PendingRequests", isDirectory: true),
      appGroupID: appGroup)
    migrationBackend = SecurityWalletBackend(appGroup: appGroup)
  }

  init(
    registryStore: WalletRegistryStore,
    keyStore: any WalletKeyStoring,
    seedStore: any WalletSeedStoring,
    lifecycle: WalletGroupLifecycleCoordinator,
    connectionStore: ConnectionStateStore,
    balanceCache: BalanceCache,
    pendingStore: PendingRequestStore,
    migrationBackend: SecurityWalletBackend
  ) {
    self.registryStore = registryStore
    self.keyStore = keyStore
    self.seedStore = seedStore
    self.lifecycle = lifecycle
    self.connectionStore = connectionStore
    self.balanceCache = balanceCache
    self.pendingStore = pendingStore
    self.migrationBackend = migrationBackend
  }

  @discardableResult
  public func importPrivateKey(
    privateKey: String,
    label: String = "Private Key Wallet"
  ) throws -> WalletGroup {
    let label = try Self.validatedLabel(label)
    guard var secret = Hex.data(privateKey), secret.count == 32,
      let pair = try? EthereumKeypair.from(secret: secret)
    else {
      throw WalletGroupManagerError.verificationFailed
    }
    defer { secret = [UInt8](repeating: 0, count: secret.count) }
    guard let registry = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    guard !Self.contains(account: pair.address, in: registry) else {
      throw WalletGroupManagerError.duplicateAccount
    }

    let groupID = UUID()
    return try lifecycle.withClaim(groupID: groupID) {
      let inserted: Bool
      do {
        try keyStore.save(key: secret, account: pair.address)
        inserted = true
      } catch KeychainKeyStore.StorageError.saveFailed(let status)
        where status == errSecDuplicateItem
      {
        inserted = false
      } catch {
        throw WalletGroupManagerError.secureStorage
      }

      var registered = false
      defer {
        if inserted && !registered { try? keyStore.delete(account: pair.address) }
      }
      var loaded: [UInt8]
      do {
        loaded = try keyStore.load(
          account: pair.address, reason: "Unlock your wallet to verify the imported key")
      } catch {
        throw WalletGroupManagerError.verificationFailed
      }
      defer { loaded = [UInt8](repeating: 0, count: loaded.count) }
      guard loaded == secret else { throw WalletGroupManagerError.verificationFailed }
      try Self.verify(privateKey: loaded, expectedAccount: pair.address)

      guard let current = try registryStore.loadReady() else {
        throw WalletGroupManagerError.registryNotReady
      }
      guard !Self.contains(account: pair.address, in: current) else {
        throw WalletGroupManagerError.duplicateAccount
      }
      let createdAt = Date()
      let group = WalletGroup(
        id: groupID,
        kind: .privateKey,
        createdAt: createdAt,
        nextDerivationIndex: nil,
        accounts: [
          WalletAccount(address: pair.address, derivationIndex: nil, createdAt: createdAt)
        ],
        lifecycle: .active,
        label: label)
      let updated = try registryStore.update(expectedRevision: current.revision) { registry in
        WalletRegistry(
          revision: registry.revision + 1,
          adoptionState: registry.adoptionState,
          groups: registry.groups + [group],
          homeSelectedAddress: registry.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: registry.legacyWalletAddressFallbackRemoved)
      }
      registered = true
      guard let persisted = updated.groups.first(where: { $0.id == groupID }) else {
        throw WalletGroupManagerError.registryChanged
      }
      return persisted
    }
  }

  @discardableResult
  public func importSeedGroup(
    mnemonic: String,
    label: String = "Seed Wallet"
  ) throws -> WalletGroup {
    var entropy = try EthereumSeedPhrase.entropy(mnemonic: mnemonic)
    defer { entropy = [UInt8](repeating: 0, count: entropy.count) }
    return try registerSeedGroup(entropy: entropy, label: label)
  }

  @discardableResult
  public func registerSeedGroup(
    entropy: [UInt8],
    label: String = "Seed Wallet"
  ) throws -> WalletGroup {
    let label = try Self.validatedLabel(label)
    guard let registry = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    let candidate = try EthereumSeedPhrase.derivePrivateKey(entropy: entropy, index: 0)
    var candidateKey = candidate.privateKey
    defer { candidateKey = [UInt8](repeating: 0, count: candidateKey.count) }
    let account = try EthereumKeypair.from(secret: candidateKey).address
    guard !Self.contains(account: account, in: registry) else {
      throw WalletGroupManagerError.duplicateAccount
    }

    let groupID = UUID()
    return try lifecycle.withClaim(groupID: groupID) {
      do {
        try seedStore.save(entropy: entropy, groupID: groupID)
      } catch {
        throw WalletGroupManagerError.secureStorage
      }

      var registered = false
      defer {
        if !registered { try? seedStore.delete(groupID: groupID) }
      }

      var loaded: [UInt8]
      do {
        loaded = try seedStore.load(
          groupID: groupID, reason: "Unlock your wallet to verify the imported seed")
      } catch {
        throw WalletGroupManagerError.verificationFailed
      }
      defer { loaded = [UInt8](repeating: 0, count: loaded.count) }
      guard loaded == entropy else { throw WalletGroupManagerError.verificationFailed }

      var verified = try EthereumSeedPhrase.privateKey(entropy: loaded, index: 0)
      defer { verified = [UInt8](repeating: 0, count: verified.count) }
      try Self.verify(privateKey: verified, expectedAccount: account)

      guard let current = try registryStore.loadReady() else {
        throw WalletGroupManagerError.registryNotReady
      }
      guard !Self.contains(account: account, in: current) else {
        throw WalletGroupManagerError.duplicateAccount
      }
      let createdAt = Date()
      let group = WalletGroup(
        id: groupID,
        kind: .seed,
        createdAt: createdAt,
        nextDerivationIndex: 1,
        accounts: [
          WalletAccount(address: account, derivationIndex: 0, createdAt: createdAt)
        ],
        lifecycle: .active,
        label: label,
        seedIdentityAddress: account)
      let updated = try registryStore.update(expectedRevision: current.revision) { registry in
        var groups = registry.groups
        groups.append(group)
        return WalletRegistry(
          revision: registry.revision + 1,
          adoptionState: registry.adoptionState,
          groups: groups,
          homeSelectedAddress: registry.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: registry.legacyWalletAddressFallbackRemoved)
      }
      registered = true
      guard let persisted = updated.groups.first(where: { $0.id == groupID }) else {
        throw WalletGroupManagerError.registryChanged
      }
      return persisted
    }
  }

  @discardableResult
  public func deriveAccount(groupID: UUID) throws -> WalletAccount {
    try lifecycle.withClaim(groupID: groupID) {
      guard let initial = try registryStore.loadReady() else {
        throw WalletGroupManagerError.registryNotReady
      }
      guard let group = initial.groups.first(where: { $0.id == groupID }) else {
        throw WalletGroupManagerError.groupNotFound
      }
      guard group.lifecycle == .active else { throw WalletGroupManagerError.groupNotActive }
      guard group.kind == .seed, let requestedIndex = group.nextDerivationIndex else {
        throw WalletGroupManagerError.wrongGroupKind
      }
      guard requestedIndex < 0x8000_0000 else {
        throw WalletGroupManagerError.derivationExhausted
      }

      var entropy: [UInt8]
      do {
        entropy = try seedStore.load(
          groupID: groupID, reason: "Unlock your wallet to add an account")
      } catch {
        throw WalletGroupManagerError.secureStorage
      }
      defer { entropy = [UInt8](repeating: 0, count: entropy.count) }
      var derived = try EthereumSeedPhrase.derivePrivateKey(
        entropy: entropy, index: requestedIndex)
      defer { derived.privateKey = [UInt8](repeating: 0, count: derived.privateKey.count) }
      let account = try EthereumKeypair.from(secret: derived.privateKey).address
      try Self.verify(privateKey: derived.privateKey, expectedAccount: account)

      guard let current = try registryStore.loadReady(),
        let currentGroup = current.groups.first(where: { $0.id == groupID })
      else {
        throw WalletGroupManagerError.registryChanged
      }
      guard currentGroup.lifecycle == .active, currentGroup.kind == .seed,
        currentGroup.nextDerivationIndex == requestedIndex
      else {
        throw WalletGroupManagerError.registryChanged
      }
      guard !Self.contains(account: account, in: current) else {
        throw WalletGroupManagerError.duplicateAccount
      }

      let walletAccount = WalletAccount(
        address: account, derivationIndex: derived.derivationIndex, createdAt: Date(),
        label: "Account \(derived.derivationIndex + 1)")
      _ = try registryStore.update(expectedRevision: current.revision) { registry in
        var groups = registry.groups
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
          throw WalletGroupManagerError.registryChanged
        }
        groups[index].accounts.append(walletAccount)
        groups[index].nextDerivationIndex = derived.derivationIndex + 1
        return WalletRegistry(
          revision: registry.revision + 1,
          adoptionState: registry.adoptionState,
          groups: groups,
          homeSelectedAddress: registry.homeSelectedAddress,
          legacyWalletAddressFallbackRemoved: registry.legacyWalletAddressFallbackRemoved)
      }
      return walletAccount
    }
  }

  /// Selects containing-app state only. Connection defaults, grants, and active accounts
  /// remain authoritative in the separate connection-state store.
  @discardableResult
  public func selectHomeAccount(address: String) throws -> WalletRegistry {
    guard let current = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    guard
      let group = current.groups.first(where: { group in
        group.lifecycle == .active
          && group.accounts.contains {
            $0.lifecycle == .active
              && $0.address.caseInsensitiveCompare(address) == .orderedSame
          }
      }),
      let account = group.accounts.first(where: {
        $0.lifecycle == .active && $0.address.caseInsensitiveCompare(address) == .orderedSame
      })
    else {
      throw WalletGroupManagerError.groupNotFound
    }
    let sourceExists: Bool
    switch group.kind {
    case .privateKey:
      sourceExists = keyStore.contains(account: account.address)
    case .seed:
      sourceExists = seedStore.contains(groupID: group.id)
    }
    guard sourceExists else { throw WalletGroupManagerError.secureStorage }
    if current.homeSelectedAddress?.caseInsensitiveCompare(account.address) == .orderedSame {
      return current
    }
    return try registryStore.update(expectedRevision: current.revision) { registry in
      guard registry.adoptionState == .complete else {
        throw WalletGroupManagerError.registryNotReady
      }
      guard
        registry.groups.contains(where: { candidate in
          candidate.id == group.id && candidate.lifecycle == .active
            && candidate.accounts.contains {
              $0.lifecycle == .active && $0.address == account.address
            }
        })
      else {
        throw WalletGroupManagerError.registryChanged
      }
      return WalletRegistry(
        revision: registry.revision + 1,
        adoptionState: registry.adoptionState,
        groups: registry.groups,
        homeSelectedAddress: account.address,
        legacyWalletAddressFallbackRemoved: registry.legacyWalletAddressFallbackRemoved)
    }
  }

  @discardableResult
  public func updateLabels(
    groupLabels: [UUID: String],
    accountLabels: [String: String]
  ) throws -> WalletRegistry {
    guard let current = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    let validatedGroupLabels = try Dictionary(
      uniqueKeysWithValues: groupLabels.map { ($0.key, try Self.validatedLabel($0.value)) })
    var validatedAccountLabels: [String: String] = [:]
    for (address, label) in accountLabels {
      let normalized = address.lowercased()
      guard validatedAccountLabels[normalized] == nil else {
        throw WalletGroupManagerError.registryChanged
      }
      validatedAccountLabels[normalized] = try Self.validatedLabel(label)
    }

    return try registryStore.update(expectedRevision: current.revision) { registry in
      var groups = registry.groups
      for (groupID, label) in validatedGroupLabels {
        guard let index = groups.firstIndex(where: { $0.id == groupID && $0.lifecycle == .active })
        else { throw WalletGroupManagerError.registryChanged }
        groups[index].label = label
      }
      for (address, label) in validatedAccountLabels {
        guard
          let groupIndex = groups.firstIndex(where: { group in
            group.lifecycle == .active
              && group.accounts.contains {
                $0.lifecycle == .active && $0.address.lowercased() == address
              }
          }),
          let accountIndex = groups[groupIndex].accounts.firstIndex(where: {
            $0.lifecycle == .active && $0.address.lowercased() == address
          })
        else { throw WalletGroupManagerError.registryChanged }
        groups[groupIndex].accounts[accountIndex].label = label
      }
      return WalletRegistry(
        revision: registry.revision + 1,
        adoptionState: registry.adoptionState,
        groups: groups,
        homeSelectedAddress: registry.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: registry.legacyWalletAddressFallbackRemoved)
    }
  }

  /// Marks the group inactive before deleting any secret, then commits each cleanup phase
  /// forward. A later adoption entry resumes any group left in `.deleting`.
  public func deleteGroup(groupID: UUID) throws {
    try lifecycle.withClaim(groupID: groupID) {
      try deleteClaimedGroup(groupID: groupID)
    }
  }

  public func deleteAccount(groupID: UUID, address: String) throws {
    try lifecycle.withClaim(groupID: groupID) {
      try deleteClaimedAccount(groupID: groupID, address: address)
    }
  }

  public func resumeDeletingGroups() throws {
    guard let registry = try registryStore.loadReady() else { return }
    for group in registry.groups where group.lifecycle == .deleting {
      try lifecycle.withClaim(groupID: group.id) {
        try deleteClaimedGroup(groupID: group.id)
      }
    }
    guard let refreshed = try registryStore.loadReady() else { return }
    for group in refreshed.groups where group.lifecycle == .active {
      for account in group.accounts where account.lifecycle == .deleting {
        try lifecycle.withClaim(groupID: group.id) {
          try deleteClaimedAccount(groupID: group.id, address: account.address)
        }
      }
    }
  }

  private func deleteClaimedAccount(groupID: UUID, address: String) throws {
    guard var registry = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    guard var group = registry.groups.first(where: { $0.id == groupID }) else {
      throw WalletGroupManagerError.groupNotFound
    }
    guard group.lifecycle == .active else { throw WalletGroupManagerError.groupNotActive }
    guard
      var account = group.accounts.first(where: {
        $0.address.caseInsensitiveCompare(address) == .orderedSame
      })
    else { throw WalletGroupManagerError.accountNotFound }

    if group.kind == .privateKey {
      try deleteClaimedGroup(groupID: groupID)
      return
    }

    if account.lifecycle == .active {
      guard group.accounts.filter({ $0.lifecycle == .active }).count > 1 else {
        throw WalletGroupManagerError.lastSeedAccount
      }
      let removedAddress = account.address.lowercased()
      let survivingHome: String?
      if registry.homeSelectedAddress?.lowercased() == removedAddress {
        survivingHome =
          registry.groups.lazy
          .filter { $0.lifecycle == .active }
          .flatMap(\.accounts)
          .first(where: {
            $0.lifecycle == .active && $0.address.lowercased() != removedAddress
          })?.address
      } else {
        survivingHome = registry.homeSelectedAddress
      }
      registry = try registryStore.update(expectedRevision: registry.revision) { current in
        var groups = current.groups
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
          groups[groupIndex].lifecycle == .active,
          let accountIndex = groups[groupIndex].accounts.firstIndex(where: {
            $0.lifecycle == .active
              && $0.address.caseInsensitiveCompare(address) == .orderedSame
          })
        else { throw WalletGroupManagerError.registryChanged }
        groups[groupIndex].accounts[accountIndex].lifecycle = .deleting
        return WalletRegistry(
          revision: current.revision + 1,
          adoptionState: current.adoptionState,
          groups: groups,
          homeSelectedAddress: survivingHome,
          legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
      }
      guard let updatedGroup = registry.groups.first(where: { $0.id == groupID }),
        let updatedAccount = updatedGroup.accounts.first(where: {
          $0.address.caseInsensitiveCompare(address) == .orderedSame
        })
      else { throw WalletGroupManagerError.registryChanged }
      group = updatedGroup
      account = updatedAccount
    }

    guard account.lifecycle == .deleting else { throw WalletGroupManagerError.registryChanged }
    let removedAccounts = Set([account.address.lowercased()])
    try terminalizePendingRequests(accounts: removedAccounts)
    try removeConnections(accounts: removedAccounts)
    try balanceCache.remove(account: account.address)

    guard let current = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    _ = try registryStore.update(expectedRevision: current.revision) { value in
      var groups = value.groups
      guard let groupIndex = groups.firstIndex(where: { $0.id == group.id }),
        groups[groupIndex].lifecycle == .active,
        groups[groupIndex].accounts.contains(where: {
          $0.lifecycle == .deleting
            && $0.address.caseInsensitiveCompare(account.address) == .orderedSame
        })
      else { throw WalletGroupManagerError.registryChanged }
      groups[groupIndex].accounts.removeAll {
        $0.address.caseInsensitiveCompare(account.address) == .orderedSame
      }
      return WalletRegistry(
        revision: value.revision + 1,
        adoptionState: value.adoptionState,
        groups: groups,
        homeSelectedAddress: value.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: value.legacyWalletAddressFallbackRemoved)
    }
  }

  private func deleteClaimedGroup(groupID: UUID) throws {
    guard var registry = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    guard var group = registry.groups.first(where: { $0.id == groupID }) else { return }

    if group.lifecycle == .active {
      let removed = Set(group.accounts.map { $0.address.lowercased() })
      let survivingHome: String?
      if let home = registry.homeSelectedAddress, removed.contains(home.lowercased()) {
        survivingHome =
          registry.groups
          .filter { $0.id != groupID && $0.lifecycle == .active }
          .flatMap(\.accounts)
          .first(where: { $0.lifecycle == .active })?.address
      } else {
        survivingHome = registry.homeSelectedAddress
      }
      registry = try registryStore.update(expectedRevision: registry.revision) { current in
        var groups = current.groups
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
          groups[index].lifecycle == .active
        else { throw WalletGroupManagerError.registryChanged }
        groups[index].lifecycle = .deleting
        return WalletRegistry(
          revision: current.revision + 1,
          adoptionState: current.adoptionState,
          groups: groups,
          homeSelectedAddress: survivingHome,
          legacyWalletAddressFallbackRemoved: current.legacyWalletAddressFallbackRemoved)
      }
      guard let updated = registry.groups.first(where: { $0.id == groupID }) else {
        throw WalletGroupManagerError.registryChanged
      }
      group = updated
    }

    let removedAccounts = Set(group.accounts.map { $0.address.lowercased() })
    try terminalizePendingRequests(accounts: removedAccounts)
    try deleteSecret(for: group)
    try removeConnections(accounts: removedAccounts)
    for account in group.accounts {
      try balanceCache.remove(account: account.address)
      if migrationBackend.oldAddress()?.caseInsensitiveCompare(account.address) == .orderedSame {
        migrationBackend.forgetMigrationMaterial(address: account.address)
      }
    }

    guard let current = try registryStore.loadReady() else {
      throw WalletGroupManagerError.registryNotReady
    }
    guard let currentGroup = current.groups.first(where: { $0.id == groupID }) else { return }
    guard currentGroup.lifecycle == .deleting else {
      throw WalletGroupManagerError.registryChanged
    }
    _ = try registryStore.update(expectedRevision: current.revision) { value in
      WalletRegistry(
        revision: value.revision + 1,
        adoptionState: value.adoptionState,
        groups: value.groups.filter { $0.id != groupID },
        homeSelectedAddress: value.homeSelectedAddress,
        legacyWalletAddressFallbackRemoved: value.legacyWalletAddressFallbackRemoved)
    }
  }

  private func terminalizePendingRequests(accounts: Set<String>) throws {
    var records = try pendingStore.retainedRecordsForClaimedTransition()
    let commits =
      try connectionStore.load()?.connectCommits.filter {
        accounts.contains($0.account.lowercased())
      } ?? []
    for marker in commits {
      guard let claim = pendingStore.claim(marker.requestID) else {
        throw WalletGroupManagerError.pendingRequestBusy
      }
      do {
        guard
          var record = try pendingStore.retainedRecordsForClaimedTransition().first(where: {
            $0.id == marker.requestID
          }), marker.matches(record),
          record.status == .pending
            || (record.status == .consumed && record.result == marker.result)
        else { throw WalletGroupManagerError.corruptState }
        if record.status == .pending {
          record.status = .consumed
          record.result = marker.result
          try pendingStore.persistForLifecycleCleanup(record)
        }
        guard
          try pendingStore.retainedRecordsForClaimedTransition().contains(where: {
            $0.id == marker.requestID && $0.status == .consumed && $0.result == marker.result
          })
        else { throw WalletGroupManagerError.corruptState }
        _ = try connectionStore.mutate { state in
          guard state.connectCommits.first(where: { $0.requestID == marker.requestID }) == marker
          else { throw WalletGroupManagerError.corruptState }
          state.connectCommits.removeAll { $0.requestID == marker.requestID }
        }
        pendingStore.releaseClaim(claim)
      } catch {
        pendingStore.releaseClaim(claim)
        throw error
      }
    }
    records = try pendingStore.retainedRecordsForLifecycleCleanup()
    for record in records
    where accounts.contains(record.account.lowercased()) && record.status == .pending {
      guard let claim = pendingStore.claim(record.id) else {
        throw WalletGroupManagerError.pendingRequestBusy
      }
      defer { pendingStore.releaseClaim(claim) }
      guard
        var current = try pendingStore.retainedRecordsForLifecycleCleanup().first(where: {
          $0.id == record.id
        })
      else { throw WalletGroupManagerError.corruptState }
      guard current.status == .pending else { continue }
      current.status = .failed
      current.error = .object([
        "code": .number(4100),
        "message": .string("The wallet account was removed before approval"),
      ])
      try pendingStore.persistForLifecycleCleanup(current)
    }
  }

  private func deleteSecret(for group: WalletGroup) throws {
    do {
      switch group.kind {
      case .privateKey:
        guard let account = group.accounts.first?.address else {
          throw WalletGroupManagerError.corruptState
        }
        try keyStore.delete(account: account)
        guard !keyStore.contains(account: account) else {
          throw WalletGroupManagerError.secureStorage
        }
      case .seed:
        try seedStore.delete(groupID: group.id)
        guard !seedStore.contains(groupID: group.id) else {
          throw WalletGroupManagerError.secureStorage
        }
      }
    } catch let error as WalletGroupManagerError {
      throw error
    } catch {
      throw WalletGroupManagerError.secureStorage
    }
  }

  private func removeConnections(accounts: Set<String>) throws {
    try registryStore.withLockedReady { registry in
      let survivingDefault =
        registry.homeSelectedAddress
        ?? registry.groups
        .filter { $0.lifecycle == .active }
        .flatMap(\.accounts)
        .first(where: { $0.lifecycle == .active })?.address
      _ = try connectionStore.mutate { current in
        if current.connectCommits.contains(where: { accounts.contains($0.account.lowercased()) }) {
          throw WalletGroupManagerError.corruptState
        }
        let candidate = ConnectionState(
          revision: current.revision,
          defaultAccount: current.defaultAccount.map { accounts.contains($0.lowercased()) }
            == true ? survivingDefault : current.defaultAccount,
          grants: current.grants.filter { !accounts.contains($0.account.lowercased()) },
          activeConnections: current.activeConnections.filter {
            !accounts.contains($0.account.lowercased())
          },
          connectCommits: current.connectCommits)
        try candidate.validate(against: registry)
        current.defaultAccount = candidate.defaultAccount
        current.grants = candidate.grants
        current.activeConnections = candidate.activeConnections
      }
    }
  }

  private static func contains(account: String, in registry: WalletRegistry) -> Bool {
    registry.groups.contains { group in
      group.seedIdentityAddress?.caseInsensitiveCompare(account) == .orderedSame
        || group.accounts.contains {
          $0.address.caseInsensitiveCompare(account) == .orderedSame
        }
    }
  }

  private static func validatedLabel(_ label: String) throws -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw WalletGroupManagerError.invalidLabel }
    return trimmed
  }

  private static func verify(privateKey: [UInt8], expectedAccount: String) throws {
    do {
      let pair = try EthereumKeypair.from(secret: privateKey)
      let digest = Keccak.keccak256(Array("stupid-wallet provisioning proof".utf8))
      let signature = try EthereumSigner.sign(digest: digest, keypair: pair)
      let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: signature)
      guard recovered?.caseInsensitiveCompare(expectedAccount) == .orderedSame else {
        throw WalletGroupManagerError.verificationFailed
      }
    } catch let error as WalletGroupManagerError {
      throw error
    } catch {
      throw WalletGroupManagerError.verificationFailed
    }
  }
}
