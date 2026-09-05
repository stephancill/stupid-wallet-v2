import Foundation
import LocalAuthentication

/// Scoped to one approved request. Never stores key bytes or an authenticated context for reuse.
public final class ProtectedOperationCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var context: LAContext?
  public init() {}

  public var isCancelled: Bool { lock.withLock { cancelled } }
  public func cancel() {
    let current = lock.withLock {
      cancelled = true
      return context
    }
    current?.invalidate()
  }
  func attach(_ newContext: LAContext) -> Bool {
    lock.withLock {
      guard !cancelled else { return false }
      context = newContext
      return true
    }
  }
  func detach() { lock.withLock { context = nil } }
}
