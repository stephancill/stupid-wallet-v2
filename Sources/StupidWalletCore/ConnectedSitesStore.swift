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

  public var id: String { domain }

  public init(domain: String, address: String, connectedAt: Date = Date()) {
    self.domain = domain.lowercased()
    self.address = address
    self.connectedAt = connectedAt
  }
}

/// Reads/writes the legacy App Group `UserDefaults` `connectedSites` entry so both the old
/// and new app share one durable grant list across processes. Non-secret (no key material).
public actor ConnectedSitesStore {
  public static let defaultAppGroup = PendingRequestStore.defaultAppGroup
  private static let key = "connectedSites"

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
    sites().sorted { $0.connectedAt > $1.connectedAt }
  }

  /// Whether the given normalized origin has a connection grant for the account.
  public func isConnected(origin: String, address: String) -> Bool {
    let domain = Origin.downHost(of: origin)
    return sites().contains { $0.domain == domain && $0.address == address }
  }

  /// Establishes (or refreshes) a connection grant for the hostname, preserving the legacy
  /// `[domain: {address, connectedAt}]` shape so a downgraded/differently-versioned reader
  /// of the key sees a valid entry. Idempotent re-connect just updates the timestamp.
  public func connect(site: ConnectedSite) {
    var dict = legacyDictionary()
    dict[site.domain] = meta(address: site.address, connectedAt: site.connectedAt)
    defaults.set(dict, forKey: ConnectedSitesStore.key)
  }

  /// Removes a connection grant by hostname. Idempotent.
  public func disconnect(origin: String) {
    let domain = Origin.downHost(of: origin)
    var dict = legacyDictionary()
    dict.removeValue(forKey: domain)
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

  private func sites() -> [ConnectedSite] {
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

  private func parseISODate(_ string: String?) -> Date {
    guard let string, !string.isEmpty else { return .distantPast }
    if let date = isoFormatter.date(from: string) { return date }
    if let date = isoFormatterNoFraction.date(from: string) { return date }
    return ISO8601DateFormatter().date(from: string) ?? .distantPast
  }
}