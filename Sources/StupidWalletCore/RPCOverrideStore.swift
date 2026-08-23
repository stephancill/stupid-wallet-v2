import Foundation

public enum RPCOverrideStoreError: Error, Sendable, Equatable {
  case unavailable
  case invalidChainID
}

/// Atomic App Group persistence for user-selected, pre-validated RPC endpoints.
public struct RPCOverrideStore: Sendable {
  private let fileURL: URL?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    let container = directory ?? WalletStore.containerURL(appGroup: appGroup)
    fileURL = container?.appendingPathComponent("rpc-overrides.json", isDirectory: false)
  }

  public func all() throws -> [String: URL] {
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
    var values = try all().mapValues(\.absoluteString)
    values[normalized] = url.absoluteString
    do {
      try JSONEncoder().encode(values).write(to: fileURL, options: [.atomic])
    } catch {
      throw RPCOverrideStoreError.unavailable
    }
  }

  public func remove(forChainID chainID: String) throws {
    guard let normalized = ChainStore.normalize(chainID), let fileURL else {
      throw RPCOverrideStoreError.invalidChainID
    }
    var values = try all().mapValues(\.absoluteString)
    values.removeValue(forKey: normalized)
    do {
      try JSONEncoder().encode(values).write(to: fileURL, options: [.atomic])
    } catch {
      throw RPCOverrideStoreError.unavailable
    }
  }
}
