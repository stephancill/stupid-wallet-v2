import Darwin
import Foundation

/// Canonical, one-time pending signing request. Crucially the popup never supplies
/// signing params; native code reloads this persisted record, recomputes the digest, and
/// verifies it matches the record before signing.
public struct WalletPendingRequest: Sendable, Codable, Equatable {
  public enum Status: String, Sendable, Codable {
    case pending
    case consumed
    case rejected
    case expired
    case failed
  }

  public let id: UUID
  public let kind: RequestKind
  public let method: String
  public let origin: String
  public let profileID: String?
  public let chainId: String
  public let account: String
  /// Immutable dapp intent bound by `payloadDigest` and shown for approval.
  public let params: JSONValue
  public let payloadDigest: String
  /// Stable identity of the canonical intent used with `requestKey` for idempotent
  /// `prepare`. Absent on records written before this field existed.
  public let intentDigest: String?
  /// Stable per-provider-session request identity. Transport retries reuse this key;
  /// separate requests use different keys even when their canonical intent is identical.
  public let requestKey: String?
  /// Wallet-resolved nonce/gas values used for signing, populated only after approval.
  public var resolvedParams: JSONValue?
  public let createdAt: Date
  public let expiresAt: Date
  public var status: Status
  public var result: JSONValue?
  public var error: JSONValue?

  public var isExpired: Bool { Date() > expiresAt }

  public init(
    id: UUID = UUID(),
    kind: RequestKind,
    method: String,
    origin: String,
    profileID: String? = nil,
    chainId: String,
    account: String,
    params: JSONValue,
    payloadDigest: String,
    intentDigest: String? = nil,
    requestKey: String? = nil,
    resolvedParams: JSONValue? = nil,
    createdAt: Date = Date(),
    expiresAt: Date = Date().addingTimeInterval(600),
    status: Status = .pending,
    result: JSONValue? = nil,
    error: JSONValue? = nil
  ) {
    self.id = id
    self.kind = kind
    self.method = method
    self.origin = origin
    self.profileID = profileID
    self.chainId = chainId
    self.account = account
    self.params = params
    self.payloadDigest = payloadDigest
    self.intentDigest = intentDigest
    self.requestKey = requestKey
    self.resolvedParams = resolvedParams
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.status = status
    self.result = result
    self.error = error
  }
}

/// Persists pending requests under the shared App Group container so the app and
/// extension read/write the same durable records across processes and service-worker
/// suspension. Falls back to the extension process sandbox only when no App Group ID is
/// configured (e.g. in hermetic tests that pass an explicit directory).
public actor PendingRequestStore {
  public static let defaultAppGroup = "group.co.za.stephancill.stupid-wallet"
  private static let fallbackAppGroup = defaultAppGroup

  private let directory: URL

  public init(directory: URL? = nil, appGroupID: String = PendingRequestStore.defaultAppGroup) {
    if let directory {
      self.directory = directory
    } else if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupID
    ) {
      self.directory = container.appendingPathComponent("PendingRequests")
    } else {
      let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
      self.directory = base.appendingPathComponent("StupidWallet/PendingRequests")
    }
    try? FileManager.default.createDirectory(
      at: self.directory, withIntermediateDirectories: true)
  }

  public func insert(_ request: WalletPendingRequest) throws {
    let data = try JSONEncoder().encode(request)
    try data.write(to: fileURL(for: request.id), options: [.atomic])
  }

  /// Atomically inserts a pending request unless the same provider request and intent are
  /// already pending, returning the existing request's ID in the latter case. The operation is
  /// serialized both across the in-process actor and **across processes** (app ↔ extension)
  /// by an OS advisory lock, so duplicate re-sent requests cannot race into two records.
  public func insertIfAbsent(_ request: WalletPendingRequest) throws -> UUID? {
    guard request.requestKey != nil else {
      try insert(request)
      return nil
    }
    let lock = try acquirePrepareLock()
    defer { releasePrepareLock(lock) }
    if let existing = try pending().first(where: {
      $0.requestKey == request.requestKey
        && $0.intentDigest == request.intentDigest
        && $0.status == .pending
    }) {
      return existing.id
    }
    try insert(request)
    return nil
  }

  /// Cross-process advisory lock guarding the idempotent prepare check-and-insert. The app
  /// and Safari extension run in different processes with separate store actors, so the
  /// actor alone cannot prevent two concurrent identical prepares from both inserting.
  private nonisolated func acquirePrepareLock() throws -> Int32 {
    let url = directory.appendingPathComponent(".prepare.lock", isDirectory: false)
    let descriptor = open(url.path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
      let code = errno
      _ = close(descriptor)
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    return descriptor
  }

  private nonisolated func releasePrepareLock(_ descriptor: Int32) {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }

  /// Cross-instance/process one-time claim. Each Safari native message creates a fresh
  /// service/store actor, so actor isolation alone cannot prevent concurrent approvals.
  public nonisolated func claim(_ id: UUID) -> Int32? {
    let descriptor = open(claimURL(for: id).path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return nil
    }
    return descriptor
  }

  public nonisolated func releaseClaim(_ descriptor: Int32) {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }

  public func record(_ id: UUID) throws -> WalletPendingRequest? {
    let file = fileURL(for: id)
    guard let data = try? Data(contentsOf: file) else { return nil }
    var request = try JSONDecoder().decode(WalletPendingRequest.self, from: data)
    // Expired records are never consumable.
    if request.status == .pending && request.isExpired {
      request.status = .expired
      try persist(request)
    }
    return request
  }

  public func remove(_ id: UUID) {
    try? FileManager.default.removeItem(at: fileURL(for: id))
  }

  /// All currently-pending records; expired ones are re-normalized first.
  public func pending() throws -> [WalletPendingRequest] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    var result: [WalletPendingRequest] = []
    for file in files where file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file) else { continue }
      guard
        var request = try? JSONDecoder().decode(
          WalletPendingRequest.self, from: data)
      else { continue }
      if request.status == .pending && request.isExpired {
        request.status = .expired
        try? persist(request)
      }
      if request.status == .pending {
        result.append(request)
      }
    }
    return result.sorted { $0.createdAt > $1.createdAt }
  }

  private func persist(_ request: WalletPendingRequest) throws {
    let data = try JSONEncoder().encode(request)
    try data.write(to: fileURL(for: request), options: [.atomic])
  }

  private func fileURL(for request: WalletPendingRequest) -> URL {
    fileURL(for: request.id)
  }

  private func fileURL(for id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString + ".json")
  }

  private nonisolated func claimURL(for id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString + ".claim")
  }
}
