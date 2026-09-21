import ENSNormalize
import Foundation

public struct ENSResolution: Sendable, Equatable {
  public let name: String
  public let address: String
  public let chainID: String
}

public enum ENSResolutionError: Error, Sendable, Equatable, LocalizedError {
  case invalidName
  case unsupportedChain
  case chainMismatch
  case noAddress
  case invalidResponse
  case offchainSenderMismatch
  case offchainLimit
  case gatewayUnavailable
  case rpc(JSONValue)

  public var errorDescription: String? {
    switch self {
    case .invalidName: "Enter a valid ENS name or Ethereum address."
    case .unsupportedChain: "ENS address records are not supported for this network."
    case .chainMismatch: "The Ethereum RPC returned the wrong network for ENS resolution."
    case .noAddress: "This name has no receiving address for the selected network."
    case .invalidResponse: "ENS returned an invalid response. Try again."
    case .offchainSenderMismatch: "The ENS offchain lookup could not be verified."
    case .offchainLimit: "The ENS lookup exceeded its offchain resolution limit."
    case .gatewayUnavailable: "The ENS offchain service is unavailable. Try again."
    case .rpc: "The Ethereum RPC could not resolve this name. Try again."
    }
  }
}

/// ENSIP-23 forward resolution on Ethereum mainnet, including contract-verified EIP-3668 reads.
public struct ENSResolver: Sendable {
  static let universalResolver = "0xeeeeeeee14d718c2b47d9923deab1335e144eeee"
  static let offchainLookupSelector: [UInt8] = [0x55, 0x6f, 0x18, 0x30]
  static let maximumResponseBytes = 1_048_576

  private let rpcResolver: RPCResolver
  private let client: RPCClient
  private let gatewaySession: URLSession

  public init(
    rpcResolver: RPCResolver, client: RPCClient = RPCClient(), gatewaySession: URLSession? = nil
  ) {
    self.rpcResolver = rpcResolver
    self.client = client
    if let gatewaySession {
      self.gatewaySession = gatewaySession
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.urlCache = nil
      self.gatewaySession = URLSession(configuration: configuration)
    }
  }

  public func resolve(name: String, chainID: String) async throws -> ENSResolution {
    try Task.checkCancellation()
    let normalized = try Self.normalize(name: name)
    let coinType = try Self.coinType(chainID: chainID)
    let endpoint = rpcResolver.resolve(chainID: "1")
    let chain = try await client.call(url: endpoint, method: "eth_chainId", params: .array([]))
    try Task.checkCancellation()
    if case .error(let error) = chain { throw ENSResolutionError.rpc(error) }
    guard case .result(.string(let chainHex)) = chain, ChainStore.normalize(chainHex) == "1" else {
      throw ENSResolutionError.chainMismatch
    }

    let node = Self.namehash(normalizedName: normalized)
    let recordCall: [UInt8]
    if coinType == 60 {
      recordCall = [0x3b, 0x3b, 0x57, 0xde] + node  // addr(bytes32)
    } else {
      recordCall = [0xf1, 0xcb, 0x7e, 0x06] + node + ENSABI.word(coinType)  // addr(bytes32,uint256)
    }
    let call =
      [0x90, 0x61, 0xb9, 0x23]
      + ENSABI.pair(first: try Self.dnsEncode(normalizedName: normalized), second: recordCall)
    let result = try await read(data: call, endpoint: endpoint, depth: 0)
    let encodedRecord = try ENSABI.bytes(data: result, slot: 0, minimumOffset: 64)
    _ = try ENSABI.address(data: result, offset: 32)
    let addressBytes: [UInt8]
    if coinType == 60 {
      guard encodedRecord.count == 32 else { throw ENSResolutionError.invalidResponse }
      addressBytes = try ENSABI.addressBytes(data: encodedRecord, offset: 0)
    } else {
      addressBytes = try ENSABI.bytes(data: encodedRecord, slot: 0)
      guard addressBytes.count == 20 || addressBytes.isEmpty else {
        throw ENSResolutionError.invalidResponse
      }
    }
    guard addressBytes.contains(where: { $0 != 0 }) else { throw ENSResolutionError.noAddress }
    try Task.checkCancellation()
    return ENSResolution(
      name: normalized, address: EIP55.checksum(from: addressBytes), chainID: chainID)
  }

  static func normalize(name: String) throws -> String {
    let input = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard input.utf8.count <= 1024, let normalized = try? ENSIP15.normalize(input),
      normalized.contains("."), !normalized.isEmpty
    else { throw ENSResolutionError.invalidName }
    _ = try dnsEncode(normalizedName: normalized)
    return normalized
  }

  static func coinType(chainID: String) throws -> UInt64 {
    guard ChainStore.normalize(chainID) == chainID,
      let chain = UInt64(chainID), chain > 0, chain < 0x8000_0000
    else { throw ENSResolutionError.unsupportedChain }
    return chain == 1 ? 60 : chain | 0x8000_0000
  }

  static func namehash(normalizedName: String) -> [UInt8] {
    normalizedName.split(separator: ".").reversed().reduce([UInt8](repeating: 0, count: 32)) {
      Keccak.keccak256($0 + Keccak.keccak256(Array($1.utf8)))
    }
  }

  static func dnsEncode(normalizedName: String) throws -> [UInt8] {
    var result: [UInt8] = []
    for label in normalizedName.split(separator: ".", omittingEmptySubsequences: false) {
      let bytes = Array(label.utf8)
      guard !bytes.isEmpty, bytes.count <= 255 else { throw ENSResolutionError.invalidName }
      result.append(UInt8(bytes.count))
      result += bytes
    }
    guard result.count < 1024 else { throw ENSResolutionError.invalidName }
    return result + [0]
  }

  private func read(data: [UInt8], endpoint: URL, depth: Int) async throws -> [UInt8] {
    try Task.checkCancellation()
    let response = try await client.call(
      url: endpoint, method: "eth_call",
      params: .array([
        .object(["to": .string(Self.universalResolver), "data": .string("0x" + Hex.encode(data))]),
        .string("latest"),
      ]))
    try Task.checkCancellation()
    switch response {
    case .result(.string(let hex)):
      return try Self.responseBytes(hex: hex)
    case .result:
      throw ENSResolutionError.invalidResponse
    case .error(let error):
      guard let hex = error.nestedString(at: ["data"]) ?? error.nestedString(at: ["data", "data"]),
        let revert = try? Self.responseBytes(hex: hex)
      else { throw ENSResolutionError.rpc(error) }
      guard Array(revert.prefix(4)) == Self.offchainLookupSelector else {
        let missing = Array(Keccak.keccak256(Array("ResolverNotFound(bytes)".utf8)).prefix(4))
        if Array(revert.prefix(4)) == missing { throw ENSResolutionError.noAddress }
        throw ENSResolutionError.rpc(error)
      }
      guard depth < 4 else { throw ENSResolutionError.offchainLimit }
      let lookup = try OffchainLookup(data: Array(revert.dropFirst(4)))
      // Only the contract being called may request a gateway or validate its reply.
      guard lookup.sender.lowercased() == Self.universalResolver else {
        throw ENSResolutionError.offchainSenderMismatch
      }
      let answer = try await gatewayAnswer(lookup: lookup)
      return try await read(
        data: lookup.callback + ENSABI.pair(first: answer, second: lookup.extraData),
        endpoint: endpoint, depth: depth + 1)
    }
  }

  private func gatewayAnswer(lookup: OffchainLookup) async throws -> [UInt8] {
    let sender = lookup.sender.lowercased()
    let dataHex = "0x" + Hex.encode(lookup.callData)
    for template in lookup.urls {
      try Task.checkCancellation()
      let expanded = template.replacingOccurrences(of: "{sender}", with: sender)
        .replacingOccurrences(of: "{data}", with: dataHex)
      guard let url = URL(string: expanded), Self.isGatewayURL(url: url)
      else { continue }
      var request = URLRequest(url: url)
      request.timeoutInterval = 10
      if !template.contains("{data}") {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
          JSONValue.object(["sender": .string(sender), "data": .string(dataHex)]))
      }
      do {
        let (bytes, response) = try await gatewaySession.bytes(
          for: request, delegate: ENSGatewayRedirectPolicy())
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let finalURL = http.url, Self.isGatewayURL(url: finalURL),
          http.expectedContentLength <= Self.maximumResponseBytes
        else { continue }
        var data = Data()
        for try await byte in bytes {
          guard data.count < Self.maximumResponseBytes else {
            throw ENSResolutionError.invalidResponse
          }
          data.append(byte)
        }
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data),
          let hex = body.nestedString(at: ["data"])
        else { continue }
        return try Self.responseBytes(hex: hex)
      } catch {
        try Task.checkCancellation()
      }
    }
    throw ENSResolutionError.gatewayUnavailable
  }

  static func responseBytes(hex: String) throws -> [UInt8] {
    guard hex.hasPrefix("0x"), hex.count <= maximumResponseBytes * 2 + 2,
      let bytes = Hex.data(hex)
    else { throw ENSResolutionError.invalidResponse }
    return bytes
  }

  static func isGatewayURL(url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
  }
}

private final class ENSGatewayRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, ENSResolver.isGatewayURL(url: url) else { return nil }
    return request
  }
}

private struct OffchainLookup {
  let sender: String
  let urls: [String]
  let callData: [UInt8]
  let callback: [UInt8]
  let extraData: [UInt8]

  init(data: [UInt8]) throws {
    sender = try ENSABI.address(data: data, offset: 0)
    let offset = try ENSABI.offset(data: data, slot: 32, minimumOffset: 160)
    let count = try ENSABI.integer(data: data, offset: offset, limit: 8)
    let base = offset + 32
    guard count > 0, count * 32 <= data.count - base else {
      throw ENSResolutionError.invalidResponse
    }
    urls = try (0..<count).map { index in
      let bytes = try ENSABI.bytes(
        data: data, slot: base + index * 32, base: base, minimumOffset: count * 32)
      guard bytes.count <= 2048, let url = String(bytes: bytes, encoding: .utf8) else {
        throw ENSResolutionError.invalidResponse
      }
      return url
    }
    callData = try ENSABI.bytes(data: data, slot: 64, minimumOffset: 160)
    guard data.count >= 160, data[100..<128].allSatisfy({ $0 == 0 }) else {
      throw ENSResolutionError.invalidResponse
    }
    callback = Array(data[96..<100])
    extraData = try ENSABI.bytes(data: data, slot: 128, minimumOffset: 160)
  }
}

/// Narrow ABI framing for ENS/CCIP, with bounded offsets before every addition or slice.
enum ENSABI {
  static func word(_ value: UInt64) -> [UInt8] {
    [UInt8](repeating: 0, count: 24)
      + stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) }
  }

  static func dynamic(_ bytes: [UInt8]) -> [UInt8] {
    word(UInt64(bytes.count)) + bytes + [UInt8](repeating: 0, count: (32 - bytes.count % 32) % 32)
  }

  static func pair(first: [UInt8], second: [UInt8]) -> [UInt8] {
    let firstTail = dynamic(first)
    return word(64) + word(UInt64(64 + firstTail.count)) + firstTail + dynamic(second)
  }

  static func integer(data: [UInt8], offset: Int, limit: Int) throws -> Int {
    guard offset >= 0, offset <= data.count, data.count - offset >= 32 else {
      throw ENSResolutionError.invalidResponse
    }
    var value = 0
    for byte in data[offset..<(offset + 32)] {
      guard Int(byte) <= limit, value <= (limit - Int(byte)) / 256 else {
        throw ENSResolutionError.invalidResponse
      }
      value = value * 256 + Int(byte)
    }
    return value
  }

  static func offset(data: [UInt8], slot: Int, base: Int = 0, minimumOffset: Int = 32) throws -> Int
  {
    guard base >= 0, base <= data.count else { throw ENSResolutionError.invalidResponse }
    let relative = try integer(data: data, offset: slot, limit: data.count - base)
    guard relative >= minimumOffset, relative % 32 == 0 else {
      throw ENSResolutionError.invalidResponse
    }
    return base + relative
  }

  static func bytes(data: [UInt8], slot: Int, base: Int = 0, minimumOffset: Int = 32) throws
    -> [UInt8]
  {
    let start = try offset(data: data, slot: slot, base: base, minimumOffset: minimumOffset)
    let count = try integer(data: data, offset: start, limit: data.count)
    let payload = start + 32
    guard count <= data.count - payload else { throw ENSResolutionError.invalidResponse }
    return Array(data[payload..<(payload + count)])
  }

  static func addressBytes(data: [UInt8], offset: Int) throws -> [UInt8] {
    guard offset >= 0, offset <= data.count, data.count - offset >= 32,
      data[offset..<(offset + 12)].allSatisfy({ $0 == 0 })
    else { throw ENSResolutionError.invalidResponse }
    return Array(data[(offset + 12)..<(offset + 32)])
  }

  static func address(data: [UInt8], offset: Int) throws -> String {
    EIP55.checksum(from: try addressBytes(data: data, offset: offset))
  }
}
