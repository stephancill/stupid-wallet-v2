import Darwin
import Foundation

public enum ChainStoreError: Error, Sendable, Equatable {
  case invalidChainID
  case unavailable
}

/// Persists the active decimal chain ID in the shared App Group container. The app and
/// extension resolve all chain-sensitive work through this one value.
public struct ChainStore: Sendable {
  public struct SwitchJournal: Sendable, Codable, Equatable {
    public let requestID: UUID
    public let previousChainID: String
    public let targetChainID: String
  }

  public static let defaultChainID = "1"
  private let fileURL: URL?
  private let journalURL: URL?
  private let lockURL: URL?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    if let directory {
      fileURL = directory.appendingPathComponent("active-chain.conf", isDirectory: false)
      journalURL = directory.appendingPathComponent("active-chain-switch.json", isDirectory: false)
      lockURL = directory.appendingPathComponent("active-chain-switch.lock", isDirectory: false)
    } else {
      let container = WalletStore.containerURL(appGroup: appGroup)
      fileURL = container?.appendingPathComponent("active-chain.conf", isDirectory: false)
      journalURL = container?.appendingPathComponent(
        "active-chain-switch.json", isDirectory: false)
      lockURL = container?.appendingPathComponent("active-chain-switch.lock", isDirectory: false)
    }
  }

  public func currentChainID() throws -> String {
    guard let fileURL else { throw ChainStoreError.unavailable }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return Self.defaultChainID
    } catch {
      throw ChainStoreError.unavailable
    }
    guard let normalized = Self.normalize(String(decoding: data, as: UTF8.self)) else {
      throw ChainStoreError.invalidChainID
    }
    return normalized
  }

  public func setChainID(_ chainID: String) throws {
    guard let normalized = Self.normalize(chainID), let fileURL,
      let data = normalized.appending("\n").data(using: .utf8)
    else { throw ChainStoreError.invalidChainID }
    do {
      try data.write(to: fileURL, options: [.atomic])
    } catch {
      throw ChainStoreError.unavailable
    }
  }

  public func beginSwitch(requestID: UUID, previousChainID: String, targetChainID: String) throws {
    guard let previous = Self.normalize(previousChainID),
      let target = Self.normalize(targetChainID), let journalURL
    else { throw ChainStoreError.invalidChainID }
    let journal = SwitchJournal(
      requestID: requestID, previousChainID: previous, targetChainID: target)
    do {
      try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic])
    } catch {
      throw ChainStoreError.unavailable
    }
  }

  public func pendingSwitch() throws -> SwitchJournal? {
    guard let journalURL else { throw ChainStoreError.unavailable }
    do {
      return try JSONDecoder().decode(SwitchJournal.self, from: Data(contentsOf: journalURL))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw ChainStoreError.unavailable
    }
  }

  public func recoverSwitch(_ journal: SwitchJournal, consumed: Bool) throws {
    try setChainID(consumed ? journal.targetChainID : journal.previousChainID)
    try finishSwitch()
  }

  public func finishSwitch() throws {
    guard let journalURL else { throw ChainStoreError.unavailable }
    do {
      try FileManager.default.removeItem(at: journalURL)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw ChainStoreError.unavailable
    }
  }

  public func claimSwitch(wait: Bool = false) -> Int32? {
    guard let lockURL else { return nil }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    let operation = wait ? LOCK_EX : LOCK_EX | LOCK_NB
    guard flock(descriptor, operation) == 0 else {
      _ = close(descriptor)
      return nil
    }
    return descriptor
  }

  public func releaseSwitch(_ descriptor: Int32) {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }

  public static func normalize(_ chainID: String) -> String? {
    let raw = chainID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let value: Int?
    if raw.hasPrefix("0x") {
      value = Int(raw.dropFirst(2), radix: 16)
    } else {
      value = Int(raw)
    }
    guard let value, value > 0 else { return nil }
    return String(value)
  }

  public static func hexChainID(_ decimalChainID: String) -> String? {
    guard let value = Int(decimalChainID), value > 0 else { return nil }
    return "0x" + String(value, radix: 16)
  }
}
