import Foundation

/// Bounded, categorical notification event kinds shared with the backend's
/// `eventKinds`. The backend classifies; the app renders these titles.
public enum NotificationEventKind: String, Sendable, Codable, Equatable, CaseIterable {
  case nativeReceived = "nativeReceived"
  case nativeSent = "nativeSent"
  case tokenReceived = "tokenReceived"
  case tokenSent = "tokenSent"
  case nftReceived = "nftReceived"
  case nftSent = "nftSent"
  case transactionSent = "transactionSent"
  case transactionFailed = "transactionFailed"
  case activityReverted = "activityReverted"
  case activityDetected = "activityDetected"

  /// The English categorical title for the MVP.
  public var title: String {
    switch self {
    case .nativeReceived: return "Received funds"
    case .nativeSent: return "Sent funds"
    case .tokenReceived: return "Token received"
    case .tokenSent: return "Token sent"
    case .nftReceived: return "NFT received"
    case .nftSent: return "NFT sent"
    case .transactionSent: return "Transaction sent"
    case .transactionFailed: return "Transaction failed"
    case .activityReverted: return "Activity reverted"
    case .activityDetected: return "Wallet activity"
    }
  }
}

/// Notification authorization observed through `UNUserNotificationCenter`.
public enum NotificationAuthorization: String, Sendable, Codable {
  case authorized
  case denied
  case notDetermined
  case provisional
  case ephemeral
}

/// Alert presentation setting observed for `.authorized` authorization.
public enum NotificationAlertSetting: String, Sendable, Codable {
  case enabled
  case disabled
  case unsupported
}

/// App-observed notification settings snapshot.
public struct NotificationSettingsObservation: Sendable, Codable, Equatable {
  public var authorization: NotificationAuthorization
  public var alertSetting: NotificationAlertSetting
  public var observedAtUnixMilliseconds: Int64

  public init(
    authorization: NotificationAuthorization,
    alertSetting: NotificationAlertSetting,
    observedAtUnixMilliseconds: Int64
  ) {
    self.authorization = authorization
    self.alertSetting = alertSetting
    self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
  }
}

/// Per-chain backend global stage.
public enum ChainRegistrationStage: String, Sendable, Codable {
  case staged
  case enabling
  case active
  case unsupported
  case error
  case operatorDisabled = "operatorDisabled"
}

/// One authenticated cursor-feed item returned by the backend events endpoint.
public struct NotificationCursorEvent: Sendable, Codable, Equatable {
  public let eventId: String
  public let cursor: String
  public let address: String
  public let addressRegistrationId: String
  public let chainId: String
  public let eventKind: NotificationEventKind
  public let createdAt: Int

  public init(
    eventId: String,
    cursor: String,
    address: String,
    addressRegistrationId: String,
    chainId: String,
    eventKind: NotificationEventKind,
    createdAt: Int
  ) {
    self.eventId = eventId
    self.cursor = cursor
    self.address = address
    self.addressRegistrationId = addressRegistrationId
    self.chainId = chainId
    self.eventKind = eventKind
    self.createdAt = createdAt
  }
}

/// Non-secret, versioned desired notification registration state held in the App
/// Group. Never contains a private key, seed, backend credential, or full APNs
/// delivery token (only hashes and opaque references are permitted).
public struct NotificationRegistrationState: Sendable, Codable, Equatable {
  public var version: Int
  public var installationId: String?
  public var installationPublicKeyHash: String?
  /// Last observed APNs token hash. Never the token itself.
  public var apnsTokenHash: String?
  public var settings: NotificationSettingsObservation?
  public var enrolledAddresses: Set<String>
  /// Non-secret labels used only to build the local notification display map.
  public var displayLabelsByAddress: [String: String]
  public var configuredChains: Set<String>
  public var chainStages: [String: ChainRegistrationStage]
  public var chainInventoryRevision: Int
  public var acknowledgedChainRevision: Int
  public var lastCursorEventID: String?
  public var lastSuccessfulReconciliationUnixMs: Int?
  public var pendingCleanup: Bool
  public var lastPublicError: String?

  public init(
    version: Int = 1,
    installationId: String? = nil,
    installationPublicKeyHash: String? = nil,
    apnsTokenHash: String? = nil,
    settings: NotificationSettingsObservation? = nil,
    enrolledAddresses: Set<String> = [],
    displayLabelsByAddress: [String: String] = [:],
    configuredChains: Set<String> = [],
    chainStages: [String: ChainRegistrationStage] = [:],
    chainInventoryRevision: Int = 0,
    acknowledgedChainRevision: Int = 0,
    lastCursorEventID: String? = nil,
    lastSuccessfulReconciliationUnixMs: Int? = nil,
    pendingCleanup: Bool = false,
    lastPublicError: String? = nil
  ) {
    self.version = version
    self.installationId = installationId
    self.installationPublicKeyHash = installationPublicKeyHash
    self.apnsTokenHash = apnsTokenHash
    self.settings = settings
    self.enrolledAddresses = enrolledAddresses
    self.displayLabelsByAddress = displayLabelsByAddress
    self.configuredChains = configuredChains
    self.chainStages = chainStages
    self.chainInventoryRevision = chainInventoryRevision
    self.acknowledgedChainRevision = acknowledgedChainRevision
    self.lastCursorEventID = lastCursorEventID
    self.lastSuccessfulReconciliationUnixMs = lastSuccessfulReconciliationUnixMs
    self.pendingCleanup = pendingCleanup
    self.lastPublicError = lastPublicError
  }

  public mutating func synchronizeInstallationMetadata(
    installationID: String, publicKeyHash: String?
  ) {
    installationId = installationID
    installationPublicKeyHash = publicKeyHash
  }

  private enum CodingKeys: String, CodingKey {
    case version, installationId, installationPublicKeyHash, apnsTokenHash, settings
    case enrolledAddresses, displayLabelsByAddress, configuredChains, chainStages,
      chainInventoryRevision
    case acknowledgedChainRevision, lastCursorEventID, lastSuccessfulReconciliationUnixMs
    case pendingCleanup, lastPublicError
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    installationId = try values.decodeIfPresent(String.self, forKey: .installationId)
    installationPublicKeyHash = try values.decodeIfPresent(
      String.self, forKey: .installationPublicKeyHash)
    apnsTokenHash = try values.decodeIfPresent(String.self, forKey: .apnsTokenHash)
    settings = try values.decodeIfPresent(NotificationSettingsObservation.self, forKey: .settings)
    enrolledAddresses = try values.decode(Set<String>.self, forKey: .enrolledAddresses)
    displayLabelsByAddress =
      try values.decodeIfPresent([String: String].self, forKey: .displayLabelsByAddress) ?? [:]
    configuredChains = try values.decode(Set<String>.self, forKey: .configuredChains)
    chainStages =
      try values.decodeIfPresent(
        [String: ChainRegistrationStage].self, forKey: .chainStages) ?? [:]
    chainInventoryRevision = try values.decode(Int.self, forKey: .chainInventoryRevision)
    acknowledgedChainRevision = try values.decode(Int.self, forKey: .acknowledgedChainRevision)
    lastCursorEventID = try values.decodeIfPresent(String.self, forKey: .lastCursorEventID)
    lastSuccessfulReconciliationUnixMs = try values.decodeIfPresent(
      Int.self, forKey: .lastSuccessfulReconciliationUnixMs)
    pendingCleanup = try values.decode(Bool.self, forKey: .pendingCleanup)
    lastPublicError = try values.decodeIfPresent(String.self, forKey: .lastPublicError)
  }
}

/// One normalized remote EVM observation persisted separately from the shipped,
/// sender-centric `transactions` table.
public struct ObservedActivity: Sendable, Codable, Equatable {
  public let eventID: String
  public let chainID: String
  public let trackedAddress: String
  public let observationState: String  // "observed" | "reorged"
  public let transactionHash: String?
  public let blockNumber: String?
  public let initiatedByTrackedAddress: Bool
  public let createdAtUnixMs: Int

  public init(
    eventID: String,
    chainID: String,
    trackedAddress: String,
    observationState: String,
    transactionHash: String?,
    blockNumber: String?,
    initiatedByTrackedAddress: Bool,
    createdAtUnixMs: Int
  ) {
    self.eventID = eventID
    self.chainID = chainID
    self.trackedAddress = trackedAddress
    self.observationState = observationState
    self.transactionHash = transactionHash
    self.blockNumber = blockNumber
    self.initiatedByTrackedAddress = initiatedByTrackedAddress
    self.createdAtUnixMs = createdAtUnixMs
  }
}
