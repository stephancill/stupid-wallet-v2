import Foundation

/// A connection grant from an authorized dapp to the active wallet.
///
/// Persisted in the SAME App Group `UserDefaults` `connectedSites` key used by the legacy
/// app, shaped as `[lowercased-hostname: { address, connectedAt }]`. Reusing this key means
/// a shipped new app immediately sees the user's existing connections with no migration.
/// The persisted identity is a hostname (scheme/port agnostic) to preserve the old format;
/// the review surface reads the normalized origin separately for display/validation.
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

  public var id: String { [origin ?? domain, profileID ?? "default"].joined(separator: "|") }

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

/// Reads/writes the legacy App Group `UserDefaults` `connectedSites` entry so both the old
/// and new app share one durable grant list across processes. Non-secret (no key material).
public actor ConnectedSitesStore {
  public static let defaultAppGroup = PendingRequestStore.defaultAppGroup
  private static let key = "connectedSites"
  private static let normalizedKey = "connectedOriginsV2"

  private struct NormalizedGrant: Sendable, Codable {
    let origin: String
    let address: String
    let connectedAt: Date
    let profileID: String?
  }

  private let defaults: UserDefaults
  private let isoFormatter: ISO8601DateFormatter
  private let isoFormatterNoFraction: ISO8601DateFormatter

  public init(appGroupID: String = ConnectedSitesStore.defaultAppGroup) {
    self.defaults = UserDefaults(suiteName: appGroupID) ?? .standard
    let fraction = ISO8601DateFormatter()
    fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.isoFormatter = fraction
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    self.isoFormatterNoFraction = whole
  }

  /// Hermetic-test initializer: persists to a throwaway suite instead of the App Group.
  public init(suiteName: String) {
    self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    self.defaults.removePersistentDomain(forName: suiteName)
    let fraction = ISO8601DateFormatter()
    fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.isoFormatter = fraction
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    self.isoFormatterNoFraction = whole
  }

  /// All connected sites, most recently connected first.
  public func all() -> [ConnectedSite] {
    let normalized = normalizedGrants().values.map {
      ConnectedSite(
        domain: Origin.downHost(of: $0.origin),
        address: $0.address,
        connectedAt: $0.connectedAt,
        origin: $0.origin,
        profileID: $0.profileID)
    }
    let normalizedDomains = Set(normalized.map(\.domain))
    let legacyOnly = legacySites().filter { !normalizedDomains.contains($0.domain) }
    return (normalized + legacyOnly).sorted { $0.connectedAt > $1.connectedAt }
  }

  /// Whether the given normalized origin has a connection grant for the account.
  public func isConnected(origin: String, address: String, profileID: String? = nil) -> Bool {
    let normalized = Origin.normalize(origin)
    let grants = normalizedGrants()
    if let grant = grants[normalizedKey(origin: normalized, profileID: profileID)],
      grant.address.caseInsensitiveCompare(address) == .orderedSame
    {
      return true
    }
    let domain = Origin.downHost(of: origin)
    if grants.values.contains(where: { Origin.downHost(of: $0.origin) == domain }) {
      return false
    }
    // Existing hostname-only grants retain authorization by product decision. Every new
    // approval also writes the stronger normalized grant below.
    return legacySites().contains {
      $0.domain == domain && $0.address.caseInsensitiveCompare(address) == .orderedSame
    }
  }

  /// Establishes (or refreshes) a connection grant for the hostname, preserving the legacy
  /// `[domain: {address, connectedAt}]` shape so a downgraded/differently-versioned reader
  /// of the key sees a valid entry. Idempotent re-connect just updates the timestamp.
  public func connect(site: ConnectedSite) {
    if let origin = site.origin {
      var grants = normalizedGrants()
      let normalized = Origin.normalize(origin)
      grants[normalizedKey(origin: normalized, profileID: site.profileID)] = NormalizedGrant(
        origin: normalized,
        address: site.address,
        connectedAt: site.connectedAt,
        profileID: site.profileID)
      persistNormalized(grants)
    }
    var dict = legacyDictionary()
    dict[site.domain] = meta(address: site.address, connectedAt: site.connectedAt)
    defaults.set(dict, forKey: ConnectedSitesStore.key)
  }

  /// Removes a connection grant by hostname. Idempotent.
  public func disconnect(origin: String, profileID: String? = nil) {
    let normalized = Origin.normalize(origin)
    var grants = normalizedGrants()
    grants.removeValue(forKey: normalizedKey(origin: normalized, profileID: profileID))
    persistNormalized(grants)
    let domain = Origin.downHost(of: origin)
    var dict = legacyDictionary()
    dict.removeValue(forKey: domain)
    defaults.set(dict, forKey: ConnectedSitesStore.key)
  }

  /// Revokes every legacy and normalized grant tied to an account being forgotten.
  public func disconnectAll(address: String) {
    var grants = normalizedGrants()
    grants = grants.filter {
      $0.value.address.caseInsensitiveCompare(address) != .orderedSame
    }
    persistNormalized(grants)

    var dict = legacyDictionary()
    dict = dict.filter {
      guard let stored = $0.value["address"] as? String else { return true }
      return stored.caseInsensitiveCompare(address) != .orderedSame
    }
    defaults.set(dict, forKey: ConnectedSitesStore.key)
  }

  // MARK: Legacy shape

  private func legacyDictionary() -> [String: [String: Any]] {
    (defaults.dictionary(forKey: ConnectedSitesStore.key) as? [String: [String: Any]])
      ?? [:]
  }

  private func meta(address: String, connectedAt: Date) -> [String: Any] {
    ["address": address, "connectedAt": isoFormatter.string(from: connectedAt)]
  }

  private func legacySites() -> [ConnectedSite] {
    let dict = legacyDictionary()
    var out: [ConnectedSite] = []
    out.reserveCapacity(dict.count)
    for (domain, meta) in dict {
      guard let address = meta["address"] as? String else { continue }
      out.append(
        ConnectedSite(
          domain: domain,
          address: address,
          connectedAt: parseISODate(meta["connectedAt"] as? String)
        ))
    }
    return out
  }

  private func normalizedKey(origin: String, profileID: String?) -> String {
    origin + "|" + (profileID ?? "default")
  }

  private func normalizedGrants() -> [String: NormalizedGrant] {
    guard let data = defaults.data(forKey: ConnectedSitesStore.normalizedKey) else { return [:] }
    return (try? JSONDecoder().decode([String: NormalizedGrant].self, from: data)) ?? [:]
  }

  private func persistNormalized(_ grants: [String: NormalizedGrant]) {
    guard let data = try? JSONEncoder().encode(grants) else { return }
    defaults.set(data, forKey: ConnectedSitesStore.normalizedKey)
  }

  private func parseISODate(_ string: String?) -> Date {
    guard let string, !string.isEmpty else { return .distantPast }
    if let date = isoFormatter.date(from: string) { return date }
    if let date = isoFormatterNoFraction.date(from: string) { return date }
    return ISO8601DateFormatter().date(from: string) ?? .distantPast
  }
}
