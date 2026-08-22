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
  }

  public let id: UUID
  public let kind: RequestKind
  public let method: String
  public let origin: String
  public let chainId: String
  public let account: String
  public let params: JSONValue
  public let payloadDigest: String
  public let createdAt: Date
  public let expiresAt: Date
  public var status: Status
  public var result: JSONValue?

  public var isExpired: Bool { Date() > expiresAt }

  public init(
    id: UUID = UUID(),
    kind: RequestKind,
    method: String,
    origin: String,
    chainId: String,
    account: String,
    params: JSONValue,
    payloadDigest: String,
    createdAt: Date = Date(),
    expiresAt: Date = Date().addingTimeInterval(600),
    status: Status = .pending,
    result: JSONValue? = nil
  ) {
    self.id = id
    self.kind = kind
    self.method = method
    self.origin = origin
    self.chainId = chainId
    self.account = account
    self.params = params
    self.payloadDigest = payloadDigest
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.status = status
    self.result = result
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
}
