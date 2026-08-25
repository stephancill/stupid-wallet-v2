import Darwin
import Foundation

public struct TransactionSubmissionLock: Sendable {
  private let directory: URL?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    self.directory =
      directory
      ?? WalletStore.containerURL(appGroup: appGroup)?
      .appendingPathComponent("PendingRequests", isDirectory: true)
  }

  func claim(account: String, chainID: String) -> TransactionSubmissionClaim? {
    guard let directory, let normalizedChainID = ChainStore.normalize(chainID) else { return nil }
    let identity = Array("\(account.lowercased()):\(normalizedChainID)".utf8)
    let name = Hex.encode(Keccak.keccak256(identity)) + ".transaction.lock"
    let descriptor = open(
      directory.appendingPathComponent(name).path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      _ = close(descriptor)
      return nil
    }
    return TransactionSubmissionClaim(descriptor: descriptor)
  }
}

final class TransactionSubmissionClaim: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32?

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func release() {
    lock.withLock {
      guard let descriptor else { return }
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
      self.descriptor = nil
    }
  }

  deinit {
    release()
  }
}
