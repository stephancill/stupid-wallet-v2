import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum NotificationInstallationClientError: Error, Sendable {
  case invalidResponse
  case server(Int, String)
}

public struct NotificationInstallationSnapshot: Sendable, Equatable {
  public let installationID: String
  public let activeChains: Set<String>
  public let chainStages: [String: ChainRegistrationStage]
}

public struct NotificationInstallationClient: Sendable {
  private let baseURL: URL
  private let session: URLSession

  public init(
    baseURL: URL = URL(string: "https://wallet-api.stupidtech.net")
      ?? URL(fileURLWithPath: "/"),
    session: URLSession = .shared
  ) {
    self.baseURL = baseURL
    self.session = session
  }

  public func create(
    identity: NotificationInstallationIdentity,
    popupPublicKey: String? = nil,
    apnsToken: String,
    environment: String,
    settings: NotificationSettingsObservation,
    appVersion: String?,
    appBuild: String?
  ) async throws -> String {
    guard let publicKey = identity.publicKeySPKIBase64URL else {
      throw NotificationInstallationClientError.invalidResponse
    }
    let challenge: ChallengeResponse = try await request(
      method: "POST", path: "/v1/installations/challenges",
      body: ["publicKey": publicKey, "packageName": "co.za.stephancill.stupid-wallet"],
      identity: nil)
    var body: [String: Any] = [
      "challengeId": challenge.challengeId,
      "publicKey": publicKey,
      "apnsEnvironment": environment,
      "apnsToken": apnsToken,
      "notificationAuthorization": settings.authorization.rawValue,
      "notificationAlertSetting": settings.alertSetting.rawValue,
    ]
    body["popupLivenessPublicKey"] = popupPublicKey
    body["appVersion"] = appVersion
    body["appBuild"] = appBuild
    let created: InstallationResponse = try await request(
      method: "POST", path: "/v1/installations", body: body, identity: identity)
    return created.installationId
  }

  public func reconcile(
    identity: NotificationInstallationIdentity,
    token: String,
    environment: String,
    settings: NotificationSettingsObservation,
    addresses: Set<String>,
    chains: Set<String>,
    revision: Int
  ) async throws -> NotificationInstallationSnapshot {
    guard let id = identity.installationID else {
      throw NotificationInstallationClientError.invalidResponse
    }
    let escapedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let root = "/v1/installations/\(escapedID)"
    let _: OKResponse = try await request(
      method: "PUT", path: root + "/push-token",
      body: ["environment": environment, "token": token], identity: identity)
    let _: OKResponse = try await request(
      method: "PUT", path: root + "/notification-status",
      body: [
        "authorization": settings.authorization.rawValue,
        "alertSetting": settings.alertSetting.rawValue,
        "observeUnixMilliseconds": settings.observedAtUnixMilliseconds,
      ], identity: identity)
    let chainsResponse: ChainsResponse = try await request(
      method: "POST", path: root + "/renew",
      body: [
        "addresses": addresses.sorted(),
        "chains": ["revision": revision, "chainIds": chains.sorted()],
      ], identity: identity)
    return NotificationInstallationSnapshot(
      installationID: id,
      activeChains: Set(chainsResponse.activeChains),
      chainStages: Dictionary(
        uniqueKeysWithValues: chainsResponse.accepted.compactMap {
          guard let stage = ChainRegistrationStage(rawValue: $0.stage) else { return nil }
          return ($0.chainId, stage)
        }))
  }

  public func delete(identity: NotificationInstallationIdentity) async throws {
    guard let id = identity.installationID else { return }
    let escapedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let _: OKResponse = try await request(
      method: "DELETE", path: "/v1/installations/\(escapedID)", body: nil,
      identity: identity)
  }

  public func sendTestNotification(identity: NotificationInstallationIdentity) async throws {
    guard let id = identity.installationID else {
      throw NotificationInstallationClientError.invalidResponse
    }
    let escapedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let _: OKResponse = try await request(
      method: "POST", path: "/v1/installations/\(escapedID)/test-notification", body: nil,
      identity: identity)
  }

  private func request<Response: Decodable>(
    method: String,
    path: String,
    body: [String: Any]?,
    identity: NotificationInstallationIdentity?
  ) async throws -> Response {
    let bodyData =
      try body.map {
        try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
      } ?? Data()
    var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
    request.httpMethod = method
    if body != nil {
      request.httpBody = bodyData
      request.setValue("application/json", forHTTPHeaderField: "content-type")
    }
    if let identity {
      let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
      let requestID = "req_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
      let canonical = NotificationCanonicalRequest.canonical(
        method: method, pathAndQuery: path, timestamp: timestamp, requestID: requestID,
        bodyDigestBase64URL: NotificationCanonicalRequest.bodyDigest(of: bodyData))
      request.setValue(timestamp, forHTTPHeaderField: "x-wallet-timestamp")
      request.setValue(requestID, forHTTPHeaderField: "x-wallet-request-id")
      request.setValue(
        "v1,\(try identity.sign(canonical))", forHTTPHeaderField: "x-wallet-signature")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw NotificationInstallationClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let message =
        (try? JSONDecoder().decode(ServerError.self, from: data).message) ?? "Request failed"
      throw NotificationInstallationClientError.server(http.statusCode, message)
    }
    return try JSONDecoder().decode(Response.self, from: data)
  }
}

private struct ChallengeResponse: Decodable { let challengeId: String }
private struct InstallationResponse: Decodable { let installationId: String }
private struct OKResponse: Decodable { let ok: Bool }
private struct ChainsResponse: Decodable {
  struct Accepted: Decodable {
    let chainId: String
    let stage: String
  }
  let accepted: [Accepted]
  let activeChains: [String]
}
private struct ServerError: Decodable { let message: String }
