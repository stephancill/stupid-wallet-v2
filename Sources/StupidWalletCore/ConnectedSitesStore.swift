import Foundation

/// A connection grant from an authorized dapp to one wallet account.
public struct ConnectedSite: Sendable, Codable, Equatable, Identifiable {
  /// Lowercased hostname — the stable persisted key (same as the old app).
  public let domain: String
  /// The EIP-55 account this connection was granted to.
  public let address: String
  /// When the connection was established.
  public let connectedAt: Date
  /// Normalized scheme + host + effective port for new grants. Nil for legacy entries.
  public let origin: String?
  /// Safari profile identifier supplied by native Safari context when available.
  public let profileID: String?

  public var id: String {
    [origin ?? domain, profileID ?? "default", address.lowercased()].joined(separator: "|")
  }

  public init(
    domain: String,
    address: String,
    connectedAt: Date = Date(),
    origin: String? = nil,
    profileID: String? = nil
  ) {
    self.domain = domain.lowercased()
    self.address = address
    self.connectedAt = connectedAt
    self.origin = origin.map(Origin.normalize)
    self.profileID = profileID
  }
}

/// Account-scoped facade over the atomic connection-state authority. The legacy
/// `connectedSites` dictionary is written only by `ConnectionStateStore` as a downgrade mirror.
public actor ConnectedSitesStore {
  public static let defaultAppGroup = PendingRequestStore.defaultAppGroup
  nonisolated let connectionStore: ConnectionStateStore
  private let registryStore: WalletRegistryStore?

  public init(
    appGroupID: String = ConnectedSitesStore.defaultAppGroup,
    directory: URL? = nil
  ) {
    connectionStore = ConnectionStateStore(directory: directory, suiteName: appGroupID)
    registryStore = WalletRegistryStore(directory: directory, appGroup: appGroupID)
  }

  /// Hermetic-test initializer. The caller owns cleanup of the suite and directory.
  public init(suiteName: String, directory: URL) {
    connectionStore = ConnectionStateStore(directory: directory, suiteName: suiteName)
    registryStore = nil
  }

  /// Convenience hermetic initializer retained for tests that do not need to inspect files.
  public init(suiteName: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ConnectedSitesStore-\(suiteName)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stateStore = ConnectionStateStore(directory: directory, suiteName: suiteName)
    _ = try? stateStore.getOrCreate(ConnectionState(revision: 0))
    connectionStore = stateStore
    registryStore = nil
  }

  /// All connected sites, most recently connected first.
  public func all() throws -> [ConnectedSite] {
    try sites(account: nil)
  }

  /// Grants belonging to one account. Legacy grants remain visible only while their domain
  /// has no exact grants, matching the authorization fallback policy.
  public func grants(account: String) throws -> [ConnectedSite] {
    try sites(account: account)
  }

  /// Whether the account is currently active for an exact origin/profile, or is authorized
  /// by the retained hostname fallback when that domain has no exact grants.
  public func isConnected(origin: String, address: String, profileID: String? = nil) throws -> Bool
  {
    try visibleAccount(origin: origin, profileID: profileID)?.caseInsensitiveCompare(address)
      == .orderedSame
  }

  /// The one account visible to an origin/profile from one validated registry + connection
  /// snapshot. Home and default selections are never provider-visible through this operation.
  public func visibleAccount(origin: String, profileID: String? = nil, exactOnly: Bool = false)
    throws
    -> String?
  {
    let state = try loadValidatedState()
    let normalized = Origin.normalize(origin)
    if let active = state.activeConnections.first(where: {
      $0.origin == normalized && $0.profileID == profileID
    }) {
      return active.account
    }
    // Chrome is a new client: Dawn hostname grants never authorize a Chrome profile.
    guard !exactOnly, profileID?.hasPrefix("chrome:") != true else { return nil }
    let domain = Origin.downHost(of: origin)
    if state.grants.contains(where: { $0.precision == .exact && $0.legacyDomain == domain }) {
      return nil
    }
    return state.grants.first {
      $0.precision == .hostname && $0.legacyDomain == domain
    }?.account
  }

  /// Exact active-grant check for privacy-sensitive wallet capability and batch-status reads.
  public func hasExactGrant(origin: String, address: String, profileID: String? = nil) throws
    -> Bool
  {
    let state = try loadValidatedState()
    let normalized = Origin.normalize(origin)
    guard
      state.activeConnections.contains(where: {
        $0.origin == normalized && $0.profileID == profileID
          && $0.account.caseInsensitiveCompare(address) == .orderedSame
      })
    else { return false }
    return state.grants.contains {
      $0.precision == .exact && $0.origin == normalized && $0.profileID == profileID
        && $0.account.caseInsensitiveCompare(address) == .orderedSame
    }
  }

  /// Establishes or refreshes one account grant. Exact connections become active without
  /// deleting another account's retained grant for the same origin/profile.
  public func connect(site: ConnectedSite) throws {
    let account = try canonicalAddress(site.address)
    try mutate { state in
      let grant = ConnectionGrant(
        account: account,
        origin: site.origin,
        legacyDomain: site.domain,
        profileID: site.origin == nil ? nil : site.profileID,
        connectedAt: site.connectedAt,
        precision: site.origin == nil ? .hostname : .exact)
      state.grants.removeAll { $0.id == grant.id }
      state.grants.append(grant)
      if let origin = grant.origin {
        state.activeConnections.removeAll {
          $0.origin == origin && $0.profileID == grant.profileID
        }
        state.activeConnections.append(
          ActiveConnection(origin: origin, profileID: grant.profileID, account: account))
      }
      if state.defaultAccount == nil { state.defaultAccount = account }
    }
  }

  /// Revokes the connection currently visible to one provider origin. Removing an exact grant
  /// also removes that account's retained hostname fallback so disconnect cannot reveal it again.
  public func disconnect(
    account: String, origin: String, profileID: String? = nil
  ) throws {
    let normalized = Origin.normalize(origin)
    let domain = Origin.downHost(of: origin)
    try mutate { state in
      state.grants.removeAll {
        $0.account.caseInsensitiveCompare(account) == .orderedSame
          && (($0.precision == .exact && $0.origin == normalized && $0.profileID == profileID)
            || ($0.precision == .hostname && $0.legacyDomain == domain))
      }
      state.activeConnections.removeAll {
        $0.origin == normalized && $0.profileID == profileID
          && $0.account.caseInsensitiveCompare(account) == .orderedSame
      }
    }
  }

  /// Removes the exact or hostname grant represented by a connected-app row.
  public func disconnect(site: ConnectedSite) throws {
    if let origin = site.origin {
      try mutate { state in
        state.grants.removeAll {
          $0.account.caseInsensitiveCompare(site.address) == .orderedSame
            && $0.precision == .exact && $0.origin == Origin.normalize(origin)
            && $0.profileID == site.profileID
        }
        state.activeConnections.removeAll {
          $0.origin == Origin.normalize(origin) && $0.profileID == site.profileID
            && $0.account.caseInsensitiveCompare(site.address) == .orderedSame
        }
      }
      return
    }
    try mutate { state in
      state.grants.removeAll {
        $0.precision == .hostname && $0.legacyDomain == site.domain
          && $0.account.caseInsensitiveCompare(site.address) == .orderedSame
      }
    }
  }

  /// Revokes every grant and active mapping tied to one account.
  public func disconnectAll(account: String) throws {
    try mutate { state in
      state.grants.removeAll { $0.account.caseInsensitiveCompare(account) == .orderedSame }
      state.activeConnections.removeAll {
        $0.account.caseInsensitiveCompare(account) == .orderedSame
      }
    }
  }

  private func sites(account: String?) throws -> [ConnectedSite] {
    let state = try loadValidatedState()
    let exactDomains = Set(
      state.grants.filter { $0.precision == .exact }.map(\.legacyDomain))
    return state.grants.compactMap { grant in
      if let account,
        grant.account.caseInsensitiveCompare(account) != .orderedSame
      {
        return nil
      }
      if grant.precision == .hostname, exactDomains.contains(grant.legacyDomain) { return nil }
      return ConnectedSite(
        domain: grant.legacyDomain,
        address: grant.account,
        connectedAt: grant.connectedAt,
        origin: grant.origin,
        profileID: grant.profileID)
    }.sorted { $0.connectedAt > $1.connectedAt }
  }

  private func loadValidatedState() throws -> ConnectionState {
    if let registryStore {
      return try registryStore.withLockedReady { registry in
        guard let state = try connectionStore.load() else { throw ConnectionStateError.missing }
        try state.validate(against: registry)
        return state
      }
    }
    guard let state = try connectionStore.load() else { throw ConnectionStateError.missing }
    return state
  }

  private func mutate(_ transform: (inout ConnectionState) throws -> Void) throws {
    if let registryStore {
      try registryStore.withLockedReady { registry in
        _ = try connectionStore.mutate { state in
          try transform(&state)
          try state.validate(against: registry)
        }
      }
    } else {
      _ = try connectionStore.mutate(transform)
    }
  }

  private func canonicalAddress(_ address: String) throws -> String {
    guard address.hasPrefix("0x"), address.count == 42,
      let bytes = Hex.data(String(address.dropFirst(2))), bytes.count == 20
    else { throw ConnectionStateError.invalid(.invalidAddress) }
    return EIP55.checksum(from: bytes)
  }
}
