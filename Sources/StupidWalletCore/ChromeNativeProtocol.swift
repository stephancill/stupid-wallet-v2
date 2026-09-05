import Foundation

/// Chrome's stdio transport is bounded before JSON decoding. Never log frame contents.
public enum ChromeNativeFrames {
  public static let maximumBytes = 256 * 1024
  public enum Failure: Error { case truncated, oversized, empty }

  public static func read(from input: FileHandle) throws -> Data? {
    guard let header = try exact(4, from: input, allowEOF: true) else { return nil }
    let count = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    guard count > 0 else { throw Failure.empty }
    guard count <= maximumBytes else { throw Failure.oversized }
    return try exact(Int(count), from: input, allowEOF: false)
  }

  public static func write(_ value: JSONValue, to output: FileHandle) throws {
    let data = try value.data()
    guard data.count <= maximumBytes else { throw Failure.oversized }
    var count = UInt32(data.count)
    let header = withUnsafeBytes(of: &count) { Data($0) }
    try output.write(contentsOf: header + data)
  }

  private static func exact(_ count: Int, from input: FileHandle, allowEOF: Bool) throws -> Data? {
    var data = Data()
    while data.count < count {
      let next = try input.read(upToCount: count - data.count) ?? Data()
      if next.isEmpty {
        if data.isEmpty && allowEOF { return nil }
        throw Failure.truncated
      }
      data.append(next)
    }
    return data
  }
}

/// One handshake and one profile binding per native port. Reconnection never retries a mutation.
public struct ChromeNativeSession: Sendable {
  public static let version = 3
  private var profileID: String?
  public init() {}

  public enum Failure: Error { case schema, version, handshake, profile }

  public mutating func accept(_ json: JSONValue) throws -> Request {
    guard case .object(let object) = json,
      Set(object.keys) == ["version", "id", "profileId", "message"],
      let id = object["id"]?.stringValue, UUID(uuidString: id) != nil,
      let profile = object["profileId"]?.stringValue,
      profile.hasPrefix("chrome:"),
      UUID(uuidString: String(profile.dropFirst(7))) != nil,
      case .object(let message)? = object["message"],
      let action = message["action"]?.stringValue
    else { throw Failure.schema }
    guard object["version"] == .number(Double(Self.version)) else { throw Failure.version }
    if action == "hello" {
      guard Set(message.keys) == ["action"], profileID == nil else { throw Failure.handshake }
      profileID = profile
    } else {
      guard let profileID else { throw Failure.handshake }
      guard profile == profileID else { throw Failure.profile }
      try Self.validate(message, action: action)
    }
    return Request(id: id, profileID: profile, action: action, message: .object(message))
  }

  public struct Request: Sendable {
    public let id: String
    public let profileID: String
    public let action: String
    public let message: JSONValue

    public func response(_ response: JSONValue) -> JSONValue {
      .object([
        "version": .number(Double(ChromeNativeSession.version)), "id": .string(id),
        "response": response,
      ])
    }
  }

  private static func validate(_ message: [String: JSONValue], action: String) throws {
    if action == "pairStatus" || action == "pairRevoke" {
      guard Set(message.keys) == ["action"] else { throw Failure.schema }
      return
    }
    if action == "pairBegin" {
      guard Set(message.keys) == ["action", "publicKey"],
        let key = message["publicKey"]?.stringValue,
        ChromePairing.validKey(key)
      else { throw Failure.schema }
      return
    }
    if action == "pairConfirm" {
      guard Set(message.keys) == ["action", "nonce", "signature"],
        let nonce = message["nonce"]?.stringValue, UUID(uuidString: nonce) != nil,
        let signature = message["signature"]?.stringValue,
        Data(base64Encoded: signature)?.count == 64
      else { throw Failure.schema }
      return
    }
    let allowed: Set<String>
    switch action {
    case "chain", "list": allowed = ["action"]
    case "visibleAccounts", "isConnected", "disconnectSite": allowed = ["action", "origin"]
    case "prepare": allowed = ["action", "method", "params", "origin", "requestKey"]
    case "passthrough": allowed = ["action", "method", "params", "origin"]
    case "switchChain", "getCapabilities", "getCallsStatus":
      allowed = ["action", "params", "origin"]
    case "get", "summary", "approve", "reject", "connectAccounts", "rebindConnect", "contextResult",
      "invalidate":
      allowed = ["action", "payload"]
    default: throw Failure.schema
    }
    guard Set(message.keys).isSubset(of: allowed) else { throw Failure.schema }
    if allowed.contains("origin") {
      guard let origin = message["origin"]?.stringValue,
        let url = URL(string: origin), ["http", "https"].contains(url.scheme),
        url.host != nil, url.user == nil, url.password == nil,
        url.path.isEmpty, url.query == nil, url.fragment == nil
      else { throw Failure.schema }
    }
    if allowed.contains("method") {
      guard let method = message["method"]?.stringValue, !method.isEmpty,
        method.utf8.count <= 256
      else { throw Failure.schema }
    }
    if let key = message["requestKey"] {
      guard let value = key.stringValue, !value.isEmpty, value.utf8.count <= 128 else {
        throw Failure.schema
      }
    }
    if allowed.contains("payload") {
      guard case .object(let payload)? = message["payload"],
        let id = payload["requestId"]?.stringValue, UUID(uuidString: id) != nil
      else { throw Failure.schema }
      let fields: Set<String>
      switch action {
      case "get", "summary", "invalidate": fields = ["requestId"]
      case "contextResult": fields = ["requestId", "nonce", "valid", "signature"]
      case "approve": fields = ["requestId", "revision", "bindingDigest"]
      case "rebindConnect": fields = ["requestId", "revision", "account"]
      default: fields = ["requestId", "revision"]
      }
      guard Set(payload.keys) == fields else { throw Failure.schema }
      if action == "contextResult" {
        guard let nonce = payload["nonce"]?.stringValue, UUID(uuidString: nonce) != nil,
          case .bool = payload["valid"]
        else { throw Failure.schema }
      }
      if fields.contains("bindingDigest"), message["payload"] != nil {
        guard let digest = payload["bindingDigest"]?.stringValue, !digest.isEmpty,
          digest.utf8.count <= 256
        else { throw Failure.schema }
      }
      if action == "contextResult" {
        guard let signature = payload["signature"]?.stringValue,
          signature.isEmpty || Data(base64Encoded: signature)?.count == 64
        else { throw Failure.schema }
      }
      if fields.contains("revision") {
        guard NativeWalletEnvelope(.object(message)).reviewedRevision() != nil else {
          throw Failure.schema
        }
      }
      if fields.contains("account"), payload["account"]?.stringValue == nil {
        throw Failure.schema
      }
    }
  }
}
