import Foundation

/// A single JSON-RPC 2.0 response body that preserves arbitrary results and node error
/// objects exactly. Never re-casts an Ethereum RPC result to a Swift native type.
public enum RPCResponse: Sendable, Equatable {
  case result(JSONValue)
  case error(JSONValue)  // the full node error object (code/message/data) untouched
}

public enum RPCClientError: Error, Sendable, Equatable {
  /// Network or timeout failure distinct from a node JSON-RPC error.
  case transport
  /// The server body was not a parseable JSON-RPC response.
  case invalidResponse
  /// The node answered with a non-2xx HTTP status and no parseable JSON-RPC body.
  case httpStatus(Int)
}

/// Minimal, dependency-free JSON-RPC 2.0 client. It never casts results; callers see a
/// preserved `JSONValue` (result) or the node's structured error object.
public struct RPCClient: Sendable {
  public let session: URLSession
  public let requestTimeout: TimeInterval

  public init(session: URLSession = .shared, requestTimeout: TimeInterval = 15) {
    self.session = session
    self.requestTimeout = requestTimeout
  }

  /// Sends one request and returns the JSON-RPC response. A node error response is
  /// returned as `.error`; transport failures throw `RPCClientError`.
  public func call(
    url: URL,
    method: String,
    params: JSONValue,
    id: Int = 1
  ) async throws -> RPCResponse {
    let requestBody: [String: JSONValue] = [
      "jsonrpc": .string("2.0"),
      "id": .number(Double(id)),
      "method": .string(method),
      "params": params,
    ]
    let payload = try JSONEncoder().encode(JSONValue.object(requestBody))

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload
    request.timeoutInterval = requestTimeout

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw RPCClientError.transport
    }

    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      // Fall through to body parsing: some nodes return structured errors with a
      // non-2xx status. Only surface httpStatus when the body is not JSON-RPC.
      guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        throw RPCClientError.httpStatus(http.statusCode)
      }
      return try responseBody(from: parsed)
    }

    guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw RPCClientError.invalidResponse
    }
    return try responseBody(from: parsed)
  }

  private func responseBody(from parsed: JSONValue) throws -> RPCResponse {
    guard case .object(let object) = parsed else { throw RPCClientError.invalidResponse }
    // A node error takes precedence; preserve the full object.
    if let error = object["error"] {
      return .error(error)
    }
    // A present "result", even `null`, is returned verbatim so nullable results survive.
    if let result = object["result"] {
      return .result(result)
    }
    throw RPCClientError.invalidResponse
  }
}

/// Resolves the active RPC endpoint for a chain. One resolver is used by reads, sends,
/// polling, previews, and generic passthrough so there is never a second RPC hierarchy.
public struct RPCResolver: Sendable {
  /// Default endpoint for a decimal chain ID.
  public static func defaultURL(forChainID chainID: String) -> URL {
    URL(string: "https://evm.stupidtech.net/v1/\(chainID)")!
  }

  public var overrides: [String: URL]  // decimal chain ID -> user-selected endpoint

  public init(overrides: [String: URL] = [:]) {
    self.overrides = overrides
  }

  public static func persisted(store: RPCOverrideStore = RPCOverrideStore()) -> RPCResolver {
    RPCResolver(overrides: (try? store.all()) ?? [:])
  }

  /// The effective endpoint for a chain: a validated override or the stupidtech default.
  public func resolve(chainID: String) -> URL {
    overrides[chainID] ?? Self.defaultURL(forChainID: chainID)
  }
}

/// Why a user-supplied RPC override is rejected. Loud failures only; never weaken the
/// default routing to make a dapp work.
public enum RPCOverrideError: Error, Sendable, Equatable {
  case invalidURL
  case insecure
  case unreachable
  case chainMismatch(expected: String, actual: String)
}

public enum RPCOverrideValidator {
  /// Validates an endpoint before it may be saved for a chain:
  ///  1. syntactic URL validity;
  ///  2. HTTPS, except an explicit development-only loopback HTTP path;
  ///  3. a reachable `eth_chainId`;
  ///  4. exact equality between the endpoint's chain ID and the configured chain.
  public static func validate(
    url: URL,
    expectedChainID: String,
    client: RPCClient = RPCClient()
  ) async -> Result<Void, RPCOverrideError> {
    // 1. Syntax.
    guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
      return .failure(.invalidURL)
    }

    // 2. Security. H mud allowed only loopback.
    if scheme == "http" {
      let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
      guard isLoopback else { return .failure(.insecure) }
    } else if scheme != "https" {
      return .failure(.insecure)
    }

    // 3 + 4. Reachability and exact chain match.
    let response: RPCResponse
    do {
      response = try await client.call(url: url, method: "eth_chainId", params: .array([]))
    } catch {
      return .failure(.unreachable)
    }

    guard case .result(let value) = response,
      case .string(let actual) = value
    else {
      return .failure(.unreachable)
    }
    guard Self.chainIDsEqual(expected: expectedChainID, actual: actual) else {
      return .failure(.chainMismatch(expected: expectedChainID, actual: actual))
    }
    return .success(())
  }

  /// Compares a chain ID in decimal or hex form to `eth_chainId`'s hex response.
  private static func chainIDsEqual(expected: String, actual: String) -> Bool {
    func asInt(_ raw: String) -> Int? {
      let text = raw.lowercased()
      if text.hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
      return Int(text)
    }
    guard let expected = asInt(expected), let actual = asInt(actual) else {
      return expected == actual
    }
    return expected == actual
  }
}
