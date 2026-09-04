import Foundation

/// Compose the desired notification enrollment from current wallet accounts,
/// configured chains, and the backend's globally active chains — the contract the
/// app sends to the backend on reconciliation.
public enum NotificationDesiredState {
  public struct Desired: Sendable, Equatable {
    public let addresses: Set<String>
    public let configuredChains: Set<String>
    public let addressChainPairs: Set<String>

    public init(
      addresses: Set<String>,
      configuredChains: Set<String>,
      addressChainPairs: Set<String>
    ) {
      self.addresses = addresses
      self.configuredChains = configuredChains
      self.addressChainPairs = addressChainPairs
    }
  }

  /// Desired enrollment = every elected wallet account crossed with every configured
  /// chain that is globally webhook-active. Only `activeChains` produce effective pairs;
  /// inactive chains are still configured and reported but contribute no subscription.
  public static func desired(
    activeWalletAddresses: [String],
    configuredChains: [String],
    activeGlobalChains: [String]
  ) -> Desired {
    let addresses = Set(activeWalletAddresses.map { $0.lowercased() })
    let configured = Set(configuredChains)
    let active = Set(activeGlobalChains)
    let effectiveChains = configured.intersection(active)
    var pairs = Set<String>()
    for address in addresses {
      for chainId in effectiveChains where !chainId.isEmpty {
        pairs.insert("\(chainId):\(address)")
      }
    }
    return Desired(
      addresses: addresses,
      configuredChains: configured,
      addressChainPairs: pairs)
  }
}

/// Eligibility and cadence policies that decide when a full containing-app
/// reconciliation is due and whether an installation currently contributes
/// registrations to the backend.
public enum NotificationReconciliationPolicy {
  /// An installation is notification-capable when system authorization permits
  /// alerts and it has a fresh APNs token.
  public static func isEligible(
    authorization: NotificationAuthorization?,
    alertSetting: NotificationAlertSetting?,
    apnsTokenHash: String?
  ) -> Bool {
    guard let authorization, let alertSetting else { return false }
    let allowed =
      authorization == .authorized || authorization == .provisional
    return allowed && alertSetting == .enabled && !(apnsTokenHash ?? "").isEmpty
  }

  /// Foreground full-state renewal is due when the liveness window has ≤ 14 days left.
  /// Threshold measured in milliseconds.
  public static func isLivenessRenewalDue(
    livenessExpiresAtMs: Int64,
    nowMs: Int64,
    thresholdDays: Int = 14
  ) -> Bool {
    let remaining = livenessExpiresAtMs - nowMs
    let thresholdMs = Int64(thresholdDays) * 24 * 60 * 60 * 1000
    return remaining <= thresholdMs
  }

  /// A signed settings update should be resent when the observed settings wait is
  /// within 30 days of the freshness ceiling.
  public static func isSettingsRefreshDue(
    settingsValidUntilMs: Int64?,
    nowMs: Int64,
    thresholdDays: Int = 30
  ) -> Bool {
    guard let settingsValidUntilMs else { return false }
    let remaining = settingsValidUntilMs - nowMs
    let thresholdMs = Int64(thresholdDays) * 24 * 60 * 60 * 1000
    return remaining <= thresholdMs
  }

  /// Types of events that atomically decide whether a full containing-app sync runs.
  public enum Trigger: Sendable, Equatable {
    case initialLoad
    case enrollmentChange
    case accountLifecycle
    case networkStoreChange
    case tokenRotation
    case staleState
    case foregroundRenewal
    case settingsRefresh
  }

  /// Public, deterministic ordering note: every trigger forces a full reconciliation
  /// (the MVP has no partial-sync path).
  public static func requiresFullReconciliation(_ trigger: Trigger) -> Bool {
    true
  }

  /// Popup liveness may run at most once per 24 hours; later popups are coalesced.
  public static func isPopupRenewalDue(
    lastPopupRenewalMs: Int64?,
    nowMs: Int64,
    coalescingWindowHours: Int = 24
  ) -> Bool {
    guard let lastPopupRenewalMs else { return true }
    return (nowMs - lastPopupRenewalMs) >= Int64(coalescingWindowHours) * 60 * 60 * 1000
  }
}
