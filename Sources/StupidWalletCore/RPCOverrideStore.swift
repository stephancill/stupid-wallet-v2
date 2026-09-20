import Darwin
import Foundation

public enum RPCOverrideStoreError: Error, Sendable, Equatable {
  case unavailable
  case invalidChainID
}

/// Atomic App Group persistence for user-selected, pre-validated RPC endpoints.
public struct RPCOverrideStore: Sendable {
  private let fileURL: URL?
  private let lockURL: URL?
  private let deploymentStore: Simple7702AccountDeploymentStore

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    let container = directory ?? WalletStore.containerURL(appGroup: appGroup)
    fileURL = container?.appendingPathComponent("rpc-overrides.json", isDirectory: false)
    lockURL = container?.appendingPathComponent("rpc-overrides.lock")
    deploymentStore = Simple7702AccountDeploymentStore(directory: directory, appGroup: appGroup)
  }

  public func all() throws -> [String: URL] {
    try withLock { try allUnlocked() }
  }

  func withLockedOverrides<T>(_ body: ([String: URL]) throws -> T) throws -> T {
    try withLock { try body(allUnlocked()) }
  }

  private func allUnlocked() throws -> [String: URL] {
    guard let fileURL else { throw RPCOverrideStoreError.unavailable }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return [:]
    } catch {
      throw RPCOverrideStoreError.unavailable
    }
    guard let strings = try? JSONDecoder().decode([String: String].self, from: data) else {
      throw RPCOverrideStoreError.unavailable
    }
    return strings.reduce(into: [:]) { result, entry in
      if let chainID = ChainStore.normalize(entry.key), let url = URL(string: entry.value) {
        result[chainID] = url
      }
    }
  }

  public func set(_ url: URL, forChainID chainID: String) throws {
    guard let normalized = ChainStore.normalize(chainID), let fileURL else {
      throw RPCOverrideStoreError.invalidChainID
    }
    try withLock {
      do {
        try deploymentStore.remove(chainID: normalized)
        var values = try allUnlocked().mapValues(\.absoluteString)
        values[normalized] = url.absoluteString
        try JSONEncoder().encode(values).write(to: fileURL, options: [.atomic])
      } catch { throw RPCOverrideStoreError.unavailable }
    }
  }

  public func remove(forChainID chainID: String) throws {
    guard let normalized = ChainStore.normalize(chainID), let fileURL else {
      throw RPCOverrideStoreError.invalidChainID
    }
    try withLock {
      do {
        try deploymentStore.remove(chainID: normalized)
        var values = try allUnlocked().mapValues(\.absoluteString)
        values.removeValue(forKey: normalized)
        try JSONEncoder().encode(values).write(to: fileURL, options: [.atomic])
      } catch { throw RPCOverrideStoreError.unavailable }
    }
  }

  private func withLock<T>(_ body: () throws -> T) throws -> T {
    guard let lockURL else { throw RPCOverrideStoreError.unavailable }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw RPCOverrideStoreError.unavailable }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw RPCOverrideStoreError.unavailable }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }
}
