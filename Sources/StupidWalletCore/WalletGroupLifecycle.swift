import Darwin
import Foundation

public enum WalletGroupLifecycleClaimError: Error, Sendable, Equatable {
  case unavailable
}

/// Cross-process coordination for operations that may release or delete a group's secret.
public struct WalletGroupLifecycleCoordinator: Sendable {
  private let directory: URL?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    self.directory = directory ?? WalletStore.containerURL(appGroup: appGroup)
  }

  public func withClaim<T>(groupID: UUID, operation: () throws -> T) throws -> T {
    guard
      let claimURL = directory?.appendingPathComponent(
        "wallet-group-\(groupID.uuidString.lowercased()).lock", isDirectory: false)
    else {
      throw WalletGroupLifecycleClaimError.unavailable
    }
    let descriptor = open(claimURL.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, close(descriptor) == 0 else {
      if descriptor >= 0 { _ = close(descriptor) }
      throw WalletGroupLifecycleClaimError.unavailable
    }

    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var result: Result<T, Error>?
    coordinator.coordinate(writingItemAt: claimURL, options: [], error: &coordinationError) { _ in
      result = Result { try operation() }
    }
    guard let result else { throw WalletGroupLifecycleClaimError.unavailable }
    return try result.get()
  }
}
