import Foundation

public enum NotificationRegistrationStoreError: Error, Sendable {
  case invalidState
  case unavailable
}

/// Versioned, atomic App Group store for the non-secret desired notification
/// state. Deliberately separate from the wallet registry and never holds key
/// material, a recovery phrase, or a backend credential.
public actor NotificationRegistrationStore {
  public static let defaultAppGroup = PendingRequestStore.defaultAppGroup
  private let fileURL: URL

  public init(fileURL: URL? = nil, appGroup: String = NotificationRegistrationStore.defaultAppGroup)
  {
    if let fileURL {
      self.fileURL = fileURL
    } else if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup
    ) {
      self.fileURL = container.appendingPathComponent("notificationRegistration.json")
    } else {
      guard
        let base = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first
      else {
        self.fileURL = URL(fileURLWithPath: "/tmp/notificationRegistration.json")
        return
      }
      let directory = base.appendingPathComponent("StupidWallet")
      self.fileURL = directory.appendingPathComponent("notificationRegistration.json")
    }
  }

  public func read() throws -> NotificationRegistrationState {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return NotificationRegistrationState()
    }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    do {
      return try decoder.decode(NotificationRegistrationState.self, from: data)
    } catch {
      // A malformed state must fail loud, not invent a fresh one silently.
      throw NotificationRegistrationStoreError.invalidState
    }
  }

  public func write(_ state: NotificationRegistrationState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    try data.write(to: fileURL, options: .atomic)
  }

  public func mutate(_ update: (inout NotificationRegistrationState) -> Void) throws {
    var state = try read()
    update(&state)
    try write(state)
  }
}
