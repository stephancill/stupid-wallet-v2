import Foundation
import Testing

@testable import StupidWalletCore

struct SIWETests {
  private let account = "0x1234567890abcdef1234567890abcdef12345678"
  private let origin = "https://example.com:8443"
  private let issuedAt = "2026-08-25T12:34:56Z"

  @Test("canonical ERC-7846 SIWE fields produce exact EIP-4361 bytes")
  func canonicalMessage() throws {
    let prepared = try SIWE.prepare(
      params: request([
        "nonce": .string("aB123456"), "chainId": .string("0x2105"),
        "scheme": .string("https"), "domain": .string("example.com:8443"),
        "uri": .string("https://example.com:8443/session"),
        "statement": .string("Sign in to continue."), "issuedAt": .string(issuedAt),
        "expirationTime": .string("2026-08-25T13:34:56.123Z"),
        "notBefore": .string("2026-08-25T12:30:00+00:00"),
        "requestId": .string("login-7"),
        "resources": .array([
          .string("https://example.com:8443/terms"), .string("ipfs://bafy-test"),
        ]),
      ]), account: account, origin: origin)

    let expected = """
      https://example.com:8443 wants you to sign in with your Ethereum account:
      0x1234567890abcdef1234567890abcdef12345678

      Sign in to continue.

      URI: https://example.com:8443/session
      Version: 1
      Chain ID: 8453
      Nonce: aB123456
      Issued At: 2026-08-25T12:34:56Z
      Expiration Time: 2026-08-25T13:34:56.123Z
      Not Before: 2026-08-25T12:30:00+00:00
      Request ID: login-7
      Resources:
      - https://example.com:8443/terms
      - ipfs://bafy-test
      """
    #expect(prepared.chainID == "8453")
    #expect(try SIWE.message(from: prepared.params) == expected)
    let id = UUID()
    let pending = WalletPendingRequest(
      id: id, kind: .siwe, method: "wallet_connect", origin: origin, chainId: prepared.chainID,
      account: account, params: prepared.params,
      payloadDigest: CanonicalRequest.digest(of: prepared.params, keyedBy: id))
    #expect(
      try RequestExecutor.signableDigest(for: pending)
        == MessageHash.eip191(message: Data(expected.utf8)))
    #expect(
      SIWE.validatePersisted(
        params: prepared.params, account: account, origin: origin, chainID: "8453"))
  }

  @Test("legacy top-level chainIds supplies an omitted SIWE chain and is returned")
  func legacyChainIDs() async throws {
    let service = makeService()
    let params = request(
      ["nonce": .string("12345678"), "issuedAt": .string(issuedAt)],
      chainIDs: ["0x2105", "0x1"])
    let id = try await service.prepare(method: "wallet_connect", params: params, origin: origin)
    let persisted = try #require(await service.store.record(id))
    #expect(persisted.kind == .siwe)
    #expect(persisted.chainId == "8453")
    #expect(try SIWE.message(from: persisted.params).contains("Chain ID: 8453"))

    let result = try await service.approve(request: id)
    guard case .object(let response) = result,
      case .array(let accounts)? = response["accounts"], case .object(let first)? = accounts.first,
      case .object(let capabilities)? = first["capabilities"],
      case .object(let siwe)? = capabilities["signInWithEthereum"]
    else {
      Issue.record("Missing ERC-7846 SIWE response")
      return
    }
    #expect(first["address"] == .string(account))
    #expect(siwe["message"] == persisted.params.objectValue?["message"])
    #expect(siwe["signature"]?.stringValue?.hasPrefix("0x") == true)
    #expect(response["chainIds"] == .array([.string("0x2105"), .string("0x1")]))
    #expect(await service.isConnected(origin: origin))

    let activity = try #require(await service.activities().first)
    let signedMessage = try SIWE.message(from: persisted.params)
    #expect(activity.method == "wallet_connect")
    #expect(activity.signedMessage == signedMessage)
    #expect(activity.signature == siwe["signature"]?.stringValue)
  }

  @Test("canonical SIWE response omits legacy chainIds")
  func canonicalResponseShape() async throws {
    let service = makeService()
    let id = try await service.prepare(
      method: "wallet_connect",
      params: request([
        "nonce": .string("12345678"), "chainId": .string("0x1"),
        "issuedAt": .string(issuedAt),
      ]), origin: "https://example.com")
    guard case .object(let response) = try await service.approve(request: id) else {
      Issue.record("Missing response object")
      return
    }
    #expect(response["chainIds"] == nil)
  }

  @Test("SIWE summary exposes security-relevant fields")
  func summary() async throws {
    let service = makeService()
    let id = try await service.prepare(
      method: "wallet_connect",
      params: request([
        "nonce": .string("12345678"), "chainId": .string("0x1"),
        "statement": .string("Authenticate this session"), "issuedAt": .string(issuedAt),
      ]), origin: "https://example.com")
    let summary = try #require(await service.summarize(request: id))
    #expect(summary.kind == "siwe")
    #expect(summary.title == "Sign in with Ethereum")
    #expect(summary.rows.contains { $0.label == "Domain" && $0.value == "example.com" })
    #expect(summary.rows.contains { $0.label == "Nonce" && $0.value == "12345678" })
    #expect(summary.rows.contains { $0.label == "Statement" })
    #expect(summary.rows.contains { $0.label == "Message" })
  }

  @Test("SIWE rejects malformed or origin-conflicting inputs")
  func rejectsInvalid() {
    let invalidInputs: [[String: JSONValue]] = [
      ["nonce": .string("short"), "chainId": .string("0x1")],
      ["nonce": .string("1234567!"), "chainId": .string("0x1")],
      ["nonce": .string("12345678")],
      ["nonce": .string("12345678"), "chainId": .string("1")],
      ["nonce": .string("12345678"), "chainId": .string("0x1"), "version": .string("2")],
      ["nonce": .string("12345678"), "chainId": .string("0x1"), "scheme": .string("http")],
      ["nonce": .string("12345678"), "chainId": .string("0x1"), "domain": .string("evil.example")],
      ["nonce": .string("12345678"), "chainId": .string("0x1"), "domain": .string("example.com")],
      [
        "nonce": .string("12345678"), "chainId": .string("0x1"),
        "uri": .string("https://evil.example"),
      ],
      ["nonce": .string("12345678"), "chainId": .string("0x1"), "statement": .string("one\ntwo")],
      ["nonce": .string("12345678"), "chainId": .string("0x1"), "issuedAt": .string("not-a-date")],
      [
        "nonce": .string("12345678"), "chainId": .string("0x1"),
        "resources": .array(Array(repeating: .string("https://example.com"), count: 11)),
      ],
    ]
    for input in invalidInputs {
      #expect(throws: WalletError.invalidParams) {
        try SIWE.prepare(params: request(input), account: account, origin: origin)
      }
    }
  }

  @Test("SIWE rejects expired and inconsistently ordered validity windows")
  func rejectsInvalidValidityWindows() {
    let now = Date(timeIntervalSince1970: 1_787_662_096)
    let invalidInputs: [[String: JSONValue]] = [
      [
        "nonce": .string("12345678"), "chainId": .string("0x1"),
        "issuedAt": .string("2026-08-25T12:00:00Z"),
        "expirationTime": .string("2026-08-25T12:30:00Z"),
      ],
      [
        "nonce": .string("12345678"), "chainId": .string("0x1"),
        "issuedAt": .string("2026-08-25T13:00:00Z"),
        "expirationTime": .string("2026-08-25T12:30:00Z"),
      ],
      [
        "nonce": .string("12345678"), "chainId": .string("0x1"),
        "issuedAt": .string("2026-08-25T12:00:00Z"),
        "notBefore": .string("2026-08-25T14:00:00Z"),
        "expirationTime": .string("2026-08-25T13:00:00Z"),
      ],
    ]
    for input in invalidInputs {
      #expect(throws: WalletError.invalidParams) {
        try SIWE.prepare(params: request(input), account: account, origin: origin, now: now)
      }
    }
  }

  @Test("SIWE permits loopback HTTP but rejects network HTTP origins")
  func rejectsNetworkHTTP() throws {
    _ = try SIWE.prepare(
      params: request([
        "nonce": .string("12345678"), "chainId": .string("0x1"),
      ]), account: account, origin: "http://127.0.0.1:5173")
    #expect(throws: WalletError.invalidParams) {
      try SIWE.prepare(
        params: request([
          "nonce": .string("12345678"), "chainId": .string("0x1"),
          "domain": .string("example.com"), "uri": .string("http://example.com"),
        ]), account: account, origin: "http://example.com")
    }
  }

  @Test("unsupported wallet_connect capabilities are rejected")
  func rejectsUnsupportedConnectCapabilities() async {
    let service = makeService()
    await #expect(throws: WalletError.invalidParams) {
      try await service.prepare(
        method: "wallet_connect",
        params: .array([
          .object([
            "version": .string("1"),
            "capabilities": .object(["unsupported": .object([:])]),
          ])
        ]), origin: origin)
    }
  }

  @Test("plain wallet_connect retains the account-array result")
  func plainConnectCompatibility() async throws {
    let service = makeService()
    let id = try await service.prepare(
      method: "wallet_connect", params: .array([.object(["version": .string("1")])]),
      origin: "https://example.com")
    #expect(try await service.approve(request: id) == .array([.string(account)]))
  }

  private func request(
    _ siwe: [String: JSONValue], chainIDs: [String]? = nil
  ) -> JSONValue {
    var request: [String: JSONValue] = [
      "version": .string("1"),
      "capabilities": .object(["signInWithEthereum": .object(siwe)]),
    ]
    if let chainIDs { request["chainIds"] = .array(chainIDs.map(JSONValue.string)) }
    return .array([.object(request)])
  }

  private func makeService() -> WalletService {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SIWETests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return WalletService(
      store: PendingRequestStore(directory: directory.appendingPathComponent("Pending")),
      signing: StubSigner(account: account),
      connectedSites: ConnectedSitesStore(suiteName: UUID().uuidString),
      chainStore: ChainStore(directory: directory),
      networkStore: NetworkStore(directory: directory, legacySuiteName: UUID().uuidString),
      activityStore: ActivityStore(databaseURL: directory.appendingPathComponent("Activity.sqlite"))
    )
  }
}

extension JSONValue {
  fileprivate var objectValue: [String: JSONValue]? {
    guard case .object(let object) = self else { return nil }
    return object
  }
}
