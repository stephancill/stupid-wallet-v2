import Foundation
import Testing

@testable import StupidWalletCore

@Suite(.serialized)
struct ENSResolverTests {
  private let receiver = [UInt8](repeating: 0x22, count: 20)

  @Test("ENSIP-15 normalizes case, composed Unicode and emoji, and rejects ambiguous names")
  func normalization() throws {
    #expect(try ENSResolver.normalize(name: "  My.Name.eTh  ") == "my.name.eth")
    #expect(try ENSResolver.normalize(name: "e\u{301}.eth") == "é.eth")
    #expect(try ENSResolver.normalize(name: "RaFFY🚴‍♂️.eTh") == "raffy🚴‍♂.eth")
    #expect(try ENSResolver.normalize(name: "ensfairy.xyz") == "ensfairy.xyz")
    for name in ["", "eth", "a..eth", "paypal. eth", "раypal.eth", "xn--test.eth"] {
      #expect(throws: ENSResolutionError.invalidName) { try ENSResolver.normalize(name: name) }
    }
  }

  @Test("namehash, DNS and Universal Resolver calldata match viem 2.55.19")
  func vectors() throws {
    let name = "ur.integration-tests.eth"
    let node = ENSResolver.namehash(normalizedName: name)
    let dns = try ENSResolver.dnsEncode(normalizedName: name)
    #expect(Hex.encode(node) == "0d568aa97357167ff455f59b93f8a4fd9e4d1c25c340fed31ea35cca22a2d866")
    #expect(Hex.encode(dns) == "02757211696e746567726174696f6e2d74657374730365746800")
    let call =
      [0x90, 0x61, 0xb9, 0x23] + ENSABI.pair(first: dns, second: [0x3b, 0x3b, 0x57, 0xde] + node)
    #expect(
      Hex.encode(call) == "9061b923"
        + "0000000000000000000000000000000000000000000000000000000000000040"
        + "0000000000000000000000000000000000000000000000000000000000000080"
        + "000000000000000000000000000000000000000000000000000000000000001a"
        + "02757211696e746567726174696f6e2d74657374730365746800000000000000"
        + "0000000000000000000000000000000000000000000000000000000000000024"
        + "3b3b57de0d568aa97357167ff455f59b93f8a4fd9e4d1c25c340fed31ea35cca22a2d866"
        + "00000000000000000000000000000000000000000000000000000000")
  }

  @Test("mainnet resolution respects the selected mainnet RPC and returns a checksummed address")
  func mainnet() async throws {
    let result = universalResult(address: receiver)
    let resolver = makeResolver { request in
      let body = try requestBody(request)
      return rpcResult(body.nestedString(at: ["method"]) == "eth_chainId" ? "0x1" : result)
    }
    let resolution = try await resolver.resolve(name: "UR.integration-tests.ETH", chainID: "1")
    #expect(resolution.name == "ur.integration-tests.eth")
    #expect(resolution.address == "0x2222222222222222222222222222222222222222")
    #expect(resolution.chainID == "1")
    #expect(
      ENSURLProtocol.requests.allSatisfy { $0.url?.absoluteString == "https://ens.example/rpc" })
    let call = try requestBody(#require(ENSURLProtocol.requests.last))
    #expect(call.nestedString(at: ["method"]) == "eth_call")
    guard case .object(let object) = call, case .array(let params)? = object["params"],
      case .object(let transaction)? = params.first
    else {
      Issue.record("Missing eth_call params")
      return
    }
    #expect(transaction["to"] == .string(ENSResolver.universalResolver))
  }

  @Test("L2 resolution requests the chain-specific coin type without falling back to mainnet")
  func chainSpecific() async throws {
    let result = universalResult(address: receiver, multicoin: true)
    let resolver = makeResolver { request in
      let body = try requestBody(request)
      return rpcResult(body.nestedString(at: ["method"]) == "eth_chainId" ? "0x1" : result)
    }
    let resolution = try await resolver.resolve(name: "test.ses.eth", chainID: "8453")
    #expect(resolution.chainID == "8453")
    let body = try requestBody(#require(ENSURLProtocol.requests.last))
    guard case .object(let object) = body, case .array(let params)? = object["params"],
      case .object(let transaction)? = params.first, case .string(let hex)? = transaction["data"],
      let call = Hex.data(hex)
    else {
      Issue.record("Missing eth_call data")
      return
    }
    let record = try ENSABI.bytes(data: Array(call.dropFirst(4)), slot: 32, minimumOffset: 64)
    #expect(Array(record.prefix(4)) == [0xf1, 0xcb, 0x7e, 0x06])
    #expect(Array(record.suffix(32)) == ENSABI.word(0x8000_2105))
    #expect(try ENSResolver.coinType(chainID: "1") == 60)
    #expect(throws: ENSResolutionError.unsupportedChain) {
      try ENSResolver.coinType(chainID: "2147483648")
    }
  }

  @Test("missing or malformed address records never become recipients")
  func missingRecords() async throws {
    for (bytes, chain, error) in [
      ([UInt8](repeating: 0, count: 20), "1", ENSResolutionError.noAddress),
      ([], "8453", ENSResolutionError.noAddress),
      ([0x22], "8453", ENSResolutionError.invalidResponse),
    ] {
      let result = universalResult(address: bytes, multicoin: chain != "1")
      let resolver = makeResolver { request in
        let body = try requestBody(request)
        return rpcResult(body.nestedString(at: ["method"]) == "eth_chainId" ? "0x1" : result)
      }
      await #expect(throws: error) {
        try await resolver.resolve(name: "example.eth", chainID: chain)
      }
      #expect(ENSURLProtocol.requests.count == 2)
    }
  }

  @Test("a wrong-chain mainnet endpoint fails before contract or gateway reads")
  func wrongChain() async throws {
    let resolver = makeResolver { _ in rpcResult("0x2105") }
    await #expect(throws: ENSResolutionError.chainMismatch) {
      try await resolver.resolve(name: "example.eth", chainID: "8453")
    }
    #expect(ENSURLProtocol.requests.count == 1)
  }

  @Test("CCIP replies are verified by the original contract callback before exposing the address")
  func offchain() async throws {
    let result = universalResult(address: receiver)
    let lookup = offchainError(sender: ENSResolver.universalResolver)
    let resolver = makeResolver { request in
      if request.url?.path == "/gateway" {
        #expect(request.httpMethod == "POST")
        let body = try requestBody(request)
        #expect(body.nestedString(at: ["sender"]) == ENSResolver.universalResolver)
        return .object(["data": .string("0x1234")])
      }
      let body = try requestBody(request)
      if body.nestedString(at: ["method"]) == "eth_chainId" { return rpcResult("0x1") }
      if requestData(body).hasPrefix("0xabcdef12") {
        let expected = "0xabcdef12" + Hex.encode(ENSABI.pair(first: [0x12, 0x34], second: [0x56]))
        #expect(requestData(body) == expected)
        return rpcResult(result)
      }
      return lookup
    }
    let resolved = try await resolver.resolve(name: "test.offchaindemo.eth", chainID: "1")
    #expect(resolved.address == "0x2222222222222222222222222222222222222222")
    #expect(ENSURLProtocol.requests.map { $0.url?.path } == ["/rpc", "/rpc", "/gateway", "/rpc"])
  }

  @Test("forged CCIP senders and unverified gateway replies cannot become recipients")
  func offchainAuthority() async throws {
    let forged = offchainError(sender: "0x1111111111111111111111111111111111111111")
    var resolver = makeResolver { request in
      let body = try requestBody(request)
      return body.nestedString(at: ["method"]) == "eth_chainId" ? rpcResult("0x1") : forged
    }
    await #expect(throws: ENSResolutionError.offchainSenderMismatch) {
      try await resolver.resolve(name: "example.eth", chainID: "1")
    }
    #expect(ENSURLProtocol.requests.count == 2)

    let lookup = offchainError(sender: ENSResolver.universalResolver)
    let failure = JSONValue.object(["message": .string("invalid proof")])
    resolver = makeResolver { request in
      if request.url?.path == "/gateway" { return .object(["data": .string("0x2222")]) }
      let body = try requestBody(request)
      if body.nestedString(at: ["method"]) == "eth_chainId" { return rpcResult("0x1") }
      if requestData(body).hasPrefix("0xabcdef12") { return .object(["error": failure]) }
      return lookup
    }
    await #expect(throws: ENSResolutionError.rpc(failure)) {
      try await resolver.resolve(name: "example.eth", chainID: "1")
    }
  }

  @Test("CCIP substitutes GET URLs and tries the next advertised HTTPS gateway after failure")
  func gatewayRouting() async throws {
    let result = universalResult(address: receiver)
    let lookup = offchainError(
      sender: ENSResolver.universalResolver,
      templates: [
        "http://ens.example/insecure", "https://ens.example/broken",
        "https://ens.example/gateway/{sender}/{data}",
      ])
    let resolver = makeResolver { request in
      if request.url?.path == "/broken" { return .object(["data": .string("invalid hex")]) }
      if request.url?.path.hasPrefix("/gateway/") == true {
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/gateway/\(ENSResolver.universalResolver)/0xab")
        return .object(["data": .string("0x1234")])
      }
      let body = try requestBody(request)
      if body.nestedString(at: ["method"]) == "eth_chainId" { return rpcResult("0x1") }
      return requestData(body).hasPrefix("0xabcdef12") ? rpcResult(result) : lookup
    }
    _ = try await resolver.resolve(name: "example.eth", chainID: "1")
    #expect(ENSURLProtocol.requests.count == 5)
    #expect(ENSURLProtocol.requests.allSatisfy { $0.url?.scheme == "https" })
    for value in ["http://example.com", "file:///etc/passwd", "https://user:pass@example.com"] {
      #expect(!ENSResolver.isGatewayURL(url: try #require(URL(string: value))))
    }
  }

  @Test("oversized gateway bodies stop before the contract callback")
  func gatewaySize() async throws {
    let lookup = offchainError(sender: ENSResolver.universalResolver)
    let resolver = makeResolver { request in
      if request.url?.path == "/gateway" {
        return .object(["data": .string("0x" + String(repeating: "00", count: 524_288))])
      }
      let body = try requestBody(request)
      return body.nestedString(at: ["method"]) == "eth_chainId" ? rpcResult("0x1") : lookup
    }
    await #expect(throws: ENSResolutionError.gatewayUnavailable) {
      try await resolver.resolve(name: "example.eth", chainID: "1")
    }
    #expect(ENSURLProtocol.requests.count == 3)
  }

  @Test("CCIP recursion and response offsets are bounded")
  func bounds() async throws {
    let lookup = offchainError(sender: ENSResolver.universalResolver)
    let resolver = makeResolver { request in
      if request.url?.path == "/gateway" { return .object(["data": .string("0x1234")]) }
      let body = try requestBody(request)
      return body.nestedString(at: ["method"]) == "eth_chainId" ? rpcResult("0x1") : lookup
    }
    await #expect(throws: ENSResolutionError.offchainLimit) {
      try await resolver.resolve(name: "example.eth", chainID: "1")
    }
    #expect(ENSURLProtocol.requests.filter { $0.url?.path == "/gateway" }.count == 4)
    for data in [
      [], [UInt8](repeating: 0xff, count: 64), ENSABI.word(32) + ENSABI.word(UInt64.max),
    ] {
      #expect(throws: ENSResolutionError.invalidResponse) { try ENSABI.bytes(data: data, slot: 0) }
    }
  }

  @Test("cancelled name lookups do not publish a resolved address")
  func cancellation() async throws {
    let result = universalResult(address: receiver)
    let resolver = makeResolver { request in
      let body = try requestBody(request)
      return rpcResult(body.nestedString(at: ["method"]) == "eth_chainId" ? "0x1" : result)
    }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await resolver.resolve(name: "example.eth", chainID: "1")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ENSURLProtocol.requests.isEmpty)
  }

  private func makeResolver(
    handler: @escaping @Sendable (URLRequest) throws -> JSONValue
  ) -> ENSResolver {
    ENSURLProtocol.install(handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ENSURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return ENSResolver(
      rpcResolver: RPCResolver(overrides: ["1": URL(string: "https://ens.example/rpc")!]),
      client: RPCClient(session: session), gatewaySession: session)
  }

  private func universalResult(address: [UInt8], multicoin: Bool = false) -> String {
    let record =
      multicoin
      ? ENSABI.word(32) + ENSABI.dynamic(address) : [UInt8](repeating: 0, count: 12) + address
    return "0x"
      + Hex.encode(
        ENSABI.word(64) + [UInt8](repeating: 0, count: 12) + receiver + ENSABI.dynamic(record))
  }

  private func offchainError(
    sender: String, templates: [String] = ["https://ens.example/gateway"]
  ) -> JSONValue {
    var offsets: [UInt8] = []
    var tails: [UInt8] = []
    for template in templates {
      offsets += ENSABI.word(UInt64(templates.count * 32 + tails.count))
      tails += ENSABI.dynamic(Array(template.utf8))
    }
    let urls = ENSABI.word(UInt64(templates.count)) + offsets + tails
    let call = ENSABI.dynamic([0xab])
    let data =
      [UInt8](repeating: 0, count: 12) + (Hex.data(sender) ?? [])
      + ENSABI.word(160) + ENSABI.word(UInt64(160 + urls.count))
      + [0xab, 0xcd, 0xef, 0x12] + [UInt8](repeating: 0, count: 28)
      + ENSABI.word(UInt64(160 + urls.count + call.count)) + urls + call + ENSABI.dynamic([0x56])
    return .object([
      "error": .object([
        "code": .number(3), "message": .string("execution reverted"),
        "data": .string("0x556f1830" + Hex.encode(data)),
      ])
    ])
  }
}

private func rpcResult(_ result: String) -> JSONValue { .object(["result": .string(result)]) }

private func requestData(_ body: JSONValue) -> String {
  guard case .object(let object) = body, case .array(let params)? = object["params"],
    case .object(let transaction)? = params.first, case .string(let data)? = transaction["data"]
  else { return "" }
  return data
}

private func requestBody(_ request: URLRequest) throws -> JSONValue {
  if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
  guard let stream = request.httpBodyStream else { throw ENSResolutionError.invalidResponse }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count <= 0 { break }
    data.append(contentsOf: buffer.prefix(count))
  }
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

private final class ENSURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> JSONValue)?
  nonisolated(unsafe) private static var recorded: [URLRequest] = []

  static var requests: [URLRequest] { lock.withLock { recorded } }

  static func install(handler: @escaping @Sendable (URLRequest) throws -> JSONValue) {
    lock.withLock {
      Self.handler = handler
      recorded = []
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let handler = Self.lock.withLock {
      Self.recorded.append(request)
      return Self.handler
    }
    do {
      guard let handler, let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
      else { throw ENSResolutionError.invalidResponse }
      let data = try JSONEncoder().encode(handler(request))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}
