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

struct DeterministicAccountResolver: AccountResolving {
  let secrets: [String: [UInt8]]

  init(secrets: [[UInt8]]) throws {
    var values: [String: [UInt8]] = [:]
    for secret in secrets {
      values[try EthereumKeypair.from(secret: secret).address.lowercased()] = secret
    }
    self.secrets = values
  }

  func signer(address: String) throws -> any Signing {
    guard let secret = secrets[address.lowercased()] else { throw SigningError.accountUnavailable }
    return DeterministicAccountSigner(account: address, secret: secret)
  }

  func exportPrivateKey(address _: String) throws -> String {
    throw SigningError.accountUnavailable
  }
}

struct DeterministicAccountSigner: Signing {
  let account: String
  let secret: [UInt8]

  func hasKey() -> Bool { true }

  func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    try EthereumSigner.sign(digest: digest, keypair: EthereumKeypair.from(secret: secret))
  }
}

func deterministicSecret(_ value: UInt8) -> [UInt8] {
  var secret = [UInt8](repeating: 0, count: 32)
  secret[31] = value
  return secret
}

final class OneShotPersistenceFaultInjector: PersistenceFaultInjecting, @unchecked Sendable {
  enum Outcome: Sendable {
    case failure
    case interruption
  }

  private let point: PersistenceFaultPoint
  private let outcome: Outcome
  private let lock = NSLock()
  private var fired = false

  init(_ point: PersistenceFaultPoint, outcome: Outcome = .interruption) {
    self.point = point
    self.outcome = outcome
  }

  func hit(_ point: PersistenceFaultPoint) throws {
    lock.lock()
    defer { lock.unlock() }
    guard point == self.point, !fired else { return }
    fired = true
    switch outcome {
    case .failure:
      throw PersistenceFaultSimulationError.failure(point)
    case .interruption:
      throw PersistenceFaultSimulationError.interruption(point)
    }
  }
}
