import Foundation

@testable import StupidWalletCore

/// A tiny URLProtocol stub so RPC tests never touch the network.
final class StubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var shouldFail = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    if Self.shouldFail {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

extension URLSession {
  /// A session whose requests are answered by ``StubURLProtocol``, never the network.
  static let stubSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }()
}

func jsonObject(_ value: [String: Any]) -> Data {
  try! JSONSerialization.data(withJSONObject: value)
}

func httpResponse(_ status: Int = 200) -> HTTPURLResponse {
  HTTPURLResponse(
    url: URL(string: "https://example.com/rpc")!, statusCode: status,
    httpVersion: "HTTP/1.1", headerFields: nil)!
}

/// Deterministic signing stub for approval tests: returns a fixed 65-byte signature.
struct StubSigner: Signing {
  var account: String
  var hasKeyValue = true
  init(account: String = "0x1234567890abcdef1234567890abcdef12345678") {
    self.account = account
  }
  func hasKey() -> Bool { hasKeyValue }
  func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    guard hasKeyValue else { throw SigningError.missingKey(account: account) }
    var sig = [UInt8](repeating: 0, count: 65)
    sig[64] = 27 + (digest[0] & 0x01)
    return sig
  }
}
