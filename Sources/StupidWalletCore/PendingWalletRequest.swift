import Darwin
import Foundation

public enum PendingRequestStoreError: Error, Equatable, Sendable {
  case duplicateCallBundleID
  case conflictingRequestKey
  case corrupt
  case unavailable
}

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
  /// Approval-binding identity. Version 1 hashes request ID plus canonical params; version 2
  /// hashes the account-inclusive canonical object. `nil` identifies a retained legacy record.
  public let bindingVersion: Int?
  /// Monotonic transition counter starting at zero; increments only on the one permitted
  /// plain-connect account rebind.
  public var revision: UInt64
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

  private enum CodingKeys: String, CodingKey {
    case id, kind, method, origin, profileID, chainId, account, params, bindingVersion, revision
    case payloadDigest, intentDigest, requestKey, resolvedParams, createdAt, expiresAt, status
    case result, error
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(RequestKind.self, forKey: .kind)
    method = try container.decode(String.self, forKey: .method)
    origin = try container.decode(String.self, forKey: .origin)
    profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
    chainId = try container.decode(String.self, forKey: .chainId)
    account = try container.decode(String.self, forKey: .account)
    params = try container.decode(JSONValue.self, forKey: .params)
    bindingVersion = try container.decodeIfPresent(Int.self, forKey: .bindingVersion)
    revision = try container.decode(UInt64.self, forKey: .revision)
    payloadDigest = try container.decode(String.self, forKey: .payloadDigest)
    intentDigest = try container.decodeIfPresent(String.self, forKey: .intentDigest)
    requestKey = try container.decodeIfPresent(String.self, forKey: .requestKey)
    resolvedParams = try container.decodeIfPresent(JSONValue.self, forKey: .resolvedParams)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    status = try container.decode(Status.self, forKey: .status)
    result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
    error = try container.decodeIfPresent(JSONValue.self, forKey: .error)
  }

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
    bindingVersion: Int? = nil,
    revision: UInt64 = 0,
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
    self.bindingVersion = bindingVersion
    self.revision = revision
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

  nonisolated let directory: URL

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

  /// Atomically inserts a pending request unless the same provider request and intent already
  /// exists in retained state, returning the original request's ID in the latter case. The operation is
  /// serialized both across the in-process actor and **across processes** (app ↔ extension)
  /// by an OS advisory lock, so duplicate re-sent requests cannot race into two records.
  public func insertIfAbsent(
    _ request: WalletPendingRequest, rejectingCallBundleID callBundleID: String? = nil
  ) throws -> UUID? {
    guard request.requestKey != nil || callBundleID != nil else {
      try insert(request)
      return nil
    }
    let lock = try acquirePrepareLock()
    defer { releasePrepareLock(lock) }
    if let requestKey = request.requestKey {
      let matches = try retainedRecordsForRetryIdentity().filter {
        $0.requestKey == requestKey
      }
      guard matches.count <= 1 else { throw PendingRequestStoreError.corrupt }
      if let existing = matches.first {
        guard existing.intentDigest == request.intentDigest else {
          throw PendingRequestStoreError.conflictingRequestKey
        }
        return existing.id
      }
    }
    if let callBundleID,
      try pending().contains(where: { pending in
        guard pending.kind == .batch, case .object(let params) = pending.params else {
          return false
        }
        return params["id"]?.stringValue == callBundleID
          && pending.origin == request.origin
          && pending.profileID == request.profileID
          && pending.account.caseInsensitiveCompare(request.account) == .orderedSame
      })
    {
      throw PendingRequestStoreError.duplicateCallBundleID
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
    try all().filter { $0.status == .pending }
      .sorted { $0.createdAt > $1.createdAt }
  }

  /// Every retained canonical record. UUID-named request files fail closed when unreadable
  /// or malformed rather than disappearing from migration and replay handling.
  public func all() throws -> [WalletPendingRequest] {
    try retainedRecordsForLifecycleCleanup()
  }

  /// Synchronous lifecycle access used only while a group and each request are claimed.
  /// Keeping this file operation nonisolated lets registry adoption resume deletion before
  /// exposing the wallet, without bridging async work through a blocking semaphore.
  nonisolated func retainedRecordsForLifecycleCleanup() throws -> [WalletPendingRequest] {
    var result = try retainedRecordsForClaimedTransition()
    for index in result.indices where result[index].status == .pending && result[index].isExpired {
      result[index].status = .expired
      try persistForLifecycleCleanup(result[index])
    }
    return result
  }

  /// Raw retained records for code that already owns the relevant request claim. This does
  /// not expire or otherwise mutate records before connect-marker recovery runs.
  nonisolated func retainedRecordsForClaimedTransition() throws -> [WalletPendingRequest] {
    let files =
      try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    var result: [WalletPendingRequest] = []
    for file in files
    where file.pathExtension == "json"
      && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
    {
      let data: Data
      do {
        data = try Data(contentsOf: file)
      } catch {
        throw PendingRequestStoreError.unavailable
      }
      guard let request = try? JSONDecoder().decode(WalletPendingRequest.self, from: data) else {
        throw PendingRequestStoreError.corrupt
      }
      result.append(request)
    }
    return result
  }

  /// Retained binding-v2 records participating in provider retry identity. Unsupported
  /// rebuild bindings are not migration or deduplication inputs and are not fully decoded.
  private nonisolated func retainedRecordsForRetryIdentity() throws -> [WalletPendingRequest] {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    var result: [WalletPendingRequest] = []
    for file in files
    where file.pathExtension == "json"
      && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
    {
      let data: Data
      do {
        data = try Data(contentsOf: file)
      } catch {
        throw PendingRequestStoreError.unavailable
      }
      guard let binding = try? JSONDecoder().decode(RetainedBinding.self, from: data) else {
        throw PendingRequestStoreError.corrupt
      }
      guard binding.bindingVersion == 2 else { continue }
      guard let request = try? JSONDecoder().decode(WalletPendingRequest.self, from: data) else {
        throw PendingRequestStoreError.corrupt
      }
      result.append(request)
    }
    return result
  }

  nonisolated func persistForLifecycleCleanup(_ request: WalletPendingRequest) throws {
    let data = try JSONEncoder().encode(request)
    try data.write(
      to: directory.appendingPathComponent(request.id.uuidString + ".json"), options: [.atomic])
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

private struct RetainedBinding: Decodable {
  let bindingVersion: Int?
}
