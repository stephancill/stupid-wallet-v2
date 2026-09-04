import CryptoKit
import Foundation

public struct NotificationDisplayAlias: Codable, Equatable, Sendable {
  public let label: String
  public let address: String

  public init(label: String, address: String) {
    self.label = label
    self.address = address
  }
}

public struct NotificationDisplayState: Codable, Equatable, Sendable {
  public var aliases: [String: NotificationDisplayAlias]

  public init(aliases: [String: NotificationDisplayAlias] = [:]) {
    self.aliases = aliases
  }
}

public enum NotificationDisplayStoreError: Error, Sendable {
  case unavailable
}

/// Non-secret App Group state used only to enrich notification presentation locally.
public actor NotificationDisplayStore {
  private static let defaultsKey = "notificationDisplayState"
  private let explicitFileURL: URL?
  private let appGroup: String

  public init(
    fileURL: URL? = nil,
    appGroup: String = NotificationRegistrationStore.defaultAppGroup
  ) {
    explicitFileURL = fileURL
    self.appGroup = appGroup
  }

  public func read() -> NotificationDisplayState {
    Self.read(fileURL: explicitFileURL, appGroup: appGroup)
  }

  public func write(_ state: NotificationDisplayState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    if let explicitFileURL {
      let directory = explicitFileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: explicitFileURL, options: .atomic)
      return
    }
    guard let defaults = UserDefaults(suiteName: appGroup) else {
      throw NotificationDisplayStoreError.unavailable
    }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  public nonisolated static func read(
    fileURL: URL? = nil,
    appGroup: String = NotificationRegistrationStore.defaultAppGroup
  ) -> NotificationDisplayState {
    if let fileURL {
      guard let data = try? Data(contentsOf: fileURL),
        let state = try? JSONDecoder().decode(NotificationDisplayState.self, from: data)
      else { return NotificationDisplayState() }
      return state
    }
    guard let defaults = UserDefaults(suiteName: appGroup),
      let data = defaults.data(forKey: defaultsKey),
      let state = try? JSONDecoder().decode(NotificationDisplayState.self, from: data)
    else { return NotificationDisplayState() }
    return state
  }
}

public enum NotificationRegistrationID {
  /// Must remain byte-for-byte compatible with the backend's `opaqueRegistrationId`.
  public static func opaque(installationID: String, address: String) -> String {
    let normalizedAddress = address.lowercased()
    let digest = SHA256.hash(data: Data("\(installationID)\0\(normalizedAddress)".utf8))
    return "ar_\(NotificationBase64URL.encode(Data(digest)).prefix(24))"
  }
}
