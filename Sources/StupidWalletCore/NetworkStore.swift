import Darwin
import Foundation

public enum NetworkStoreError: Error, Sendable, Equatable {
  case unavailable
  case invalidNetwork
  case alreadyExists
}

public struct WalletNetwork: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public var name: String
  public var includeInBalance: Bool

  public init(id: String, name: String, includeInBalance: Bool = true) {
    self.id = id
    self.name = name
    self.includeInBalance = includeInBalance
  }
}

/// Shared network metadata and aggregate-balance preferences. Dapp RPC suggestions are
/// deliberately not stored here; only user-validated overrides belong in `RPCOverrideStore`.
public struct NetworkStore: @unchecked Sendable {
  public static let initialNetworks = [
    WalletNetwork(id: "1", name: "Ethereum"),
    WalletNetwork(id: "8453", name: "Base"),
    WalletNetwork(id: "42161", name: "Arbitrum One"),
    WalletNetwork(id: "10", name: "Optimism"),
  ]

  private static let knownNames = ["137": "Polygon"]
  private let fileURL: URL?
  private let removedFileURL: URL?
  private let lockURL: URL?
  private let legacyDefaults: UserDefaults?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    legacySuiteName: String? = nil
  ) {
    let container = directory ?? WalletStore.containerURL(appGroup: appGroup)
    fileURL = container?.appendingPathComponent("networks.json", isDirectory: false)
    removedFileURL = container?.appendingPathComponent("removed-networks.json", isDirectory: false)
    lockURL = container?.appendingPathComponent("networks.lock", isDirectory: false)
    legacyDefaults = UserDefaults(suiteName: legacySuiteName ?? appGroup)
  }

  public func all() throws -> [WalletNetwork] {
    let stored = try storedCustomNetworks()
    let legacy = legacyNetworks()
    let excluded = legacyExcludedChainIDs()
    let removed = try removedChainIDs()
    let initial = Self.initialNetworks.map { network in
      var network = network
      network.includeInBalance = !excluded.contains(network.id)
      return network
    }
    let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
    let legacyByID = Dictionary(uniqueKeysWithValues: legacy.map { ($0.id, $0) })
    let initialIDs = Set(initial.map(\.id))
    let addedIDs = Set(storedByID.keys).union(legacyByID.keys).subtracting(initialIDs)
    let added = addedIDs.compactMap { id -> WalletNetwork? in
      guard var network = storedByID[id] ?? legacyByID[id] else { return nil }
      network.includeInBalance = !excluded.contains(id) && network.includeInBalance
      return network
    }
    return initial.filter { !removed.contains($0.id) }
      + added.filter { !removed.contains($0.id) }.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  public func network(chainID: String) throws -> WalletNetwork? {
    guard let normalized = ChainStore.normalize(chainID) else { return nil }
    return try all().first { $0.id == normalized }
  }

  public func add(name: String, chainID: String) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, let normalized = ChainStore.normalize(chainID) else {
      throw NetworkStoreError.invalidNetwork
    }
    guard try network(chainID: normalized) == nil else { throw NetworkStoreError.alreadyExists }
    if Self.initialNetworks.contains(where: { $0.id == normalized }) {
      try restore(chainID: normalized)
      return
    }
    try upsertCustom(name: trimmedName, chainID: normalized)
  }

  public func remove(chainID: String) throws {
    guard let normalized = ChainStore.normalize(chainID), try network(chainID: normalized) != nil
    else {
      throw NetworkStoreError.invalidNetwork
    }
    try withLock {
      var stored = try storedCustomNetworks()
      stored.removeAll { $0.id == normalized }
      try write(stored)
      var removed = try removedChainIDs()
      removed.insert(normalized)
      try writeRemovedChainIDs(removed)
    }
  }

  public func record(chainID: String, suggestedName: String? = nil) throws {
    guard let normalized = ChainStore.normalize(chainID) else {
      throw NetworkStoreError.invalidNetwork
    }
    if Self.initialNetworks.contains(where: { $0.id == normalized }) {
      try restore(chainID: normalized)
      return
    }
    let trimmedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let existing = try network(chainID: normalized)
    let genericName = "Chain \(normalized)"
    let name =
      existing.flatMap { $0.name == genericName ? nil : $0.name }
      ?? trimmedName.flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.knownNames[normalized] ?? genericName
    try upsertCustom(name: name, chainID: normalized)
  }

  public func setIncluded(_ included: Bool, chainID: String) throws {
    guard let normalized = ChainStore.normalize(chainID), try network(chainID: normalized) != nil
    else {
      throw NetworkStoreError.invalidNetwork
    }
    try withLock {
      var custom = try storedCustomNetworks()
      if let index = custom.firstIndex(where: { $0.id == normalized }) {
        custom[index].includeInBalance = included
        try write(custom)
      }
      var excluded = legacyExcludedChainIDs()
      if included { excluded.remove(normalized) } else { excluded.insert(normalized) }
      legacyDefaults?.set(excluded.map(Self.hexChainID).sorted(), forKey: "excludedFromBalance")
    }
  }

  private func upsertCustom(name: String, chainID: String) throws {
    try withLock {
      var custom = try storedCustomNetworks()
      if let index = custom.firstIndex(where: { $0.id == chainID }) {
        custom[index].name = name
      } else {
        custom.append(
          WalletNetwork(
            id: chainID, name: name,
            includeInBalance: !legacyExcludedChainIDs().contains(chainID)))
      }
      try write(custom)
      var removed = try removedChainIDs()
      if removed.remove(chainID) != nil { try writeRemovedChainIDs(removed) }
    }
  }

  private func restore(chainID: String) throws {
    try withLock {
      var removed = try removedChainIDs()
      if removed.remove(chainID) != nil { try writeRemovedChainIDs(removed) }
    }
  }

  private func storedCustomNetworks() throws -> [WalletNetwork] {
    guard let fileURL else { throw NetworkStoreError.unavailable }
    do {
      return try JSONDecoder().decode([WalletNetwork].self, from: Data(contentsOf: fileURL))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    } catch {
      throw NetworkStoreError.unavailable
    }
  }

  private func write(_ networks: [WalletNetwork]) throws {
    guard let fileURL else { throw NetworkStoreError.unavailable }
    do {
      try JSONEncoder().encode(networks).write(to: fileURL, options: [.atomic])
    } catch {
      throw NetworkStoreError.unavailable
    }
  }

  private func removedChainIDs() throws -> Set<String> {
    guard let removedFileURL else { throw NetworkStoreError.unavailable }
    do {
      return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: removedFileURL)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    } catch {
      throw NetworkStoreError.unavailable
    }
  }

  private func writeRemovedChainIDs(_ chainIDs: Set<String>) throws {
    guard let removedFileURL else { throw NetworkStoreError.unavailable }
    do {
      try JSONEncoder().encode(chainIDs.sorted()).write(to: removedFileURL, options: [.atomic])
    } catch {
      throw NetworkStoreError.unavailable
    }
  }

  private func legacyNetworks() -> [WalletNetwork] {
    guard
      let chains = legacyDefaults?.dictionary(forKey: "customChains")
        as? [String: [String: Any]]
    else { return [] }
    return chains.compactMap { rawID, metadata in
      guard let id = ChainStore.normalize(rawID) else { return nil }
      let name = metadata["chainName"] as? String ?? Self.knownNames[id] ?? "Chain \(id)"
      return WalletNetwork(
        id: id, name: name, includeInBalance: !legacyExcludedChainIDs().contains(id))
    }
  }

  private func legacyExcludedChainIDs() -> Set<String> {
    Set(
      (legacyDefaults?.stringArray(forKey: "excludedFromBalance") ?? []).compactMap {
        ChainStore.normalize($0)
      })
  }

  private static func hexChainID(_ decimal: String) -> String {
    ChainStore.hexChainID(decimal) ?? decimal
  }

  private func withLock<T>(_ operation: () throws -> T) throws -> T {
    guard let lockURL else { throw NetworkStoreError.unavailable }
    let descriptor = open(lockURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
      if descriptor >= 0 { _ = close(descriptor) }
      throw NetworkStoreError.unavailable
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    return try operation()
  }
}
