import Foundation

public enum BalanceCacheError: Error, Sendable, Equatable {
  case unavailable
}

/// Atomic, account-bound persistence for the last successfully aggregated native balance.
public struct BalanceCache: Sendable {
  private struct Snapshot: Codable {
    let account: String
    let balance: String
  }

  private let fileURL: URL?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    let container = directory ?? WalletStore.containerURL(appGroup: appGroup)
    fileURL = container?.appendingPathComponent("native-balance-cache.json", isDirectory: false)
  }

  public func balance(account: String) throws -> String? {
    guard let fileURL else { throw BalanceCacheError.unavailable }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw BalanceCacheError.unavailable
    }
    guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
      throw BalanceCacheError.unavailable
    }
    guard snapshot.account.caseInsensitiveCompare(account) == .orderedSame else { return nil }
    return snapshot.balance
  }

  public func save(balance: String, account: String) throws {
    guard let fileURL else { throw BalanceCacheError.unavailable }
    do {
      try JSONEncoder().encode(Snapshot(account: account, balance: balance))
        .write(to: fileURL, options: [.atomic])
    } catch {
      throw BalanceCacheError.unavailable
    }
  }

  public func remove(account: String) throws {
    guard let fileURL else { throw BalanceCacheError.unavailable }
    guard try balance(account: account) != nil else { return }
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      throw BalanceCacheError.unavailable
    }
  }
}
