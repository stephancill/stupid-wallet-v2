import Darwin
import Foundation

public enum Simple7702AccountDeploymentStoreError: Error, Sendable, Equatable {
  case unavailable
  case invalidChainID
}

/// Positive-only cache of implementation runtime hashes verified on a configured chain.
public struct Simple7702AccountDeploymentStore: Sendable {
  private struct Entry: Codable {
    let code: String
    let rpcURL: String
  }

  private let fileURL: URL?
  private let lockURL: URL?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    let container = directory ?? WalletStore.containerURL(appGroup: appGroup)
    fileURL = container?.appendingPathComponent("simple-7702-deployments.json", isDirectory: false)
    lockURL = container?.appendingPathComponent("simple-7702-deployments.lock", isDirectory: false)
  }

  public func verifiedCode(chainID: String, runtimeHash: String, rpcURL: URL) -> [UInt8]? {
    guard let normalized = ChainStore.normalize(chainID), let values = try? all() else {
      return nil
    }
    guard let entry = values[normalized], entry.rpcURL == rpcURL.absoluteString,
      let code = Hex.data(entry.code), !code.isEmpty,
      ("0x" + Hex.encode(Keccak.keccak256(code))).caseInsensitiveCompare(runtimeHash)
        == .orderedSame
    else { return nil }
    return code
  }

  public func recordVerified(chainID: String, code: [UInt8], rpcURL: URL) throws {
    guard let normalized = ChainStore.normalize(chainID) else {
      throw Simple7702AccountDeploymentStoreError.invalidChainID
    }
    try withLock {
      var values = try all()
      values[normalized] = Entry(code: "0x" + Hex.encode(code), rpcURL: rpcURL.absoluteString)
      try write(values)
    }
  }

  public func remove(chainID: String) throws {
    guard let normalized = ChainStore.normalize(chainID) else {
      throw Simple7702AccountDeploymentStoreError.invalidChainID
    }
    try withLock {
      var values = try all()
      values.removeValue(forKey: normalized)
      try write(values)
    }
  }

  private func all() throws -> [String: Entry] {
    guard let fileURL else { throw Simple7702AccountDeploymentStoreError.unavailable }
    do {
      return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return [:]
    } catch {
      throw Simple7702AccountDeploymentStoreError.unavailable
    }
  }

  private func write(_ values: [String: Entry]) throws {
    guard let fileURL else { throw Simple7702AccountDeploymentStoreError.unavailable }
    do {
      try JSONEncoder().encode(values).write(to: fileURL, options: [.atomic])
    } catch {
      throw Simple7702AccountDeploymentStoreError.unavailable
    }
  }

  private func withLock<T>(_ operation: () throws -> T) throws -> T {
    guard let lockURL else { throw Simple7702AccountDeploymentStoreError.unavailable }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
      if descriptor >= 0 { _ = close(descriptor) }
      throw Simple7702AccountDeploymentStoreError.unavailable
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    return try operation()
  }
}
