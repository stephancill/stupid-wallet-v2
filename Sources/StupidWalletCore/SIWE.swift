import Foundation

public enum SIWE {
  public struct Prepared: Sendable, Equatable {
    public let params: JSONValue
    public let chainID: String
  }

  private static let maximumMessageLength = 16_384
  private static let maximumResourceCount = 10

  public static func prepare(
    params: JSONValue, account: String, origin rawOrigin: String, now: Date = Date()
  ) throws -> Prepared {
    guard case .array(let values) = params, values.count == 1,
      case .object(let request) = values[0], request["version"]?.stringValue == "1",
      case .object(let capabilities)? = request["capabilities"], capabilities.count == 1,
      case .object(let input)? = capabilities["signInWithEthereum"]
    else { throw WalletError.invalidParams }
    guard request.keys.allSatisfy(Set(["version", "capabilities", "chainIds"]).contains) else {
      throw WalletError.invalidParams
    }

    let allowedFields: Set<String> = [
      "nonce", "chainId", "version", "scheme", "domain", "uri", "statement", "issuedAt",
      "expirationTime", "notBefore", "requestId", "resources",
    ]
    guard input.keys.allSatisfy(allowedFields.contains) else { throw WalletError.invalidParams }

    let origin = Origin.normalize(rawOrigin)
    guard let originURL = URLComponents(string: origin),
      let originScheme = originURL.scheme, let originHost = originURL.host,
      originScheme == "https"
        || (originScheme == "http"
          && ["localhost", "127.0.0.1", "::1"].contains(originHost.lowercased()))
    else { throw WalletError.invalidParams }

    let legacyChainIDs: [String]
    if let value = request["chainIds"] {
      guard case .array(let chainValues) = value, !chainValues.isEmpty, chainValues.count <= 32
      else { throw WalletError.invalidParams }
      legacyChainIDs = try chainValues.map { value in
        guard let chain = value.stringValue, let normalized = normalizedHexChainID(chain) else {
          throw WalletError.invalidParams
        }
        return normalized
      }
    } else {
      legacyChainIDs = []
    }

    guard let nonce = input["nonce"]?.stringValue, nonce.count >= 8, nonce.count <= 96,
      nonce.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) && $0.isASCII
      })
    else { throw WalletError.invalidParams }

    let chainHex = input["chainId"]?.stringValue ?? legacyChainIDs.first
    guard let chainHex, let normalizedChainHex = normalizedHexChainID(chainHex),
      let chainID = ChainStore.normalize(normalizedChainHex)
    else { throw WalletError.invalidParams }

    let version = input["version"]?.stringValue ?? "1"
    guard version == "1" else { throw WalletError.invalidParams }

    let scheme = input["scheme"]?.stringValue
    if let scheme {
      guard scheme.count <= 32, validScheme(scheme), scheme.lowercased() == originScheme else {
        throw WalletError.invalidParams
      }
    }

    let defaultDomain = authority(host: originHost, port: originURL.port)
    let domain = input["domain"]?.stringValue ?? defaultDomain
    guard domain.count <= 255, validURICharacters(domain, allowingSpace: false),
      let domainURL = authorityComponents(domain: domain, scheme: scheme ?? originScheme),
      domainURL.host?.lowercased() == originHost.lowercased(),
      effectivePort(domainURL) == effectivePort(originURL)
    else { throw WalletError.invalidParams }

    let uri = input["uri"]?.stringValue ?? origin
    guard uri.count <= 2_048, validURICharacters(uri, allowingSpace: false),
      let uriURL = URLComponents(string: uri), uriURL.scheme != nil,
      uriURL.host != nil, uriURL.user == nil, uriURL.password == nil,
      uriURL.scheme?.lowercased() == originScheme,
      uriURL.host?.lowercased() == originHost.lowercased(),
      effectivePort(uriURL) == effectivePort(originURL)
    else { throw WalletError.invalidParams }

    let statement = input["statement"]?.stringValue
    if let statement {
      guard statement.utf8.count <= 1_024, !statement.contains("\n"), !statement.contains("\r"),
        validStatement(statement)
      else { throw WalletError.invalidParams }
    }

    let issuedAt = input["issuedAt"]?.stringValue ?? makeRFC3339Formatter().string(from: now)
    guard let issuedDate = parsedDate(issuedAt) else { throw WalletError.invalidParams }
    let expirationTime = try optionalDate(input["expirationTime"])
    let notBefore = try optionalDate(input["notBefore"])
    let expirationDate = expirationTime.flatMap(parsedDate)
    let notBeforeDate = notBefore.flatMap(parsedDate)
    if let expirationDate {
      guard expirationDate > issuedDate, expirationDate > now else {
        throw WalletError.invalidParams
      }
    }
    if let notBeforeDate, let expirationDate {
      guard notBeforeDate < expirationDate else { throw WalletError.invalidParams }
    }

    let requestID = input["requestId"]?.stringValue
    if let requestID {
      guard requestID.utf8.count <= 1_024, validRequestID(requestID)
      else { throw WalletError.invalidParams }
    }

    var resources: [String] = []
    if let value = input["resources"] {
      guard case .array(let resourceValues) = value,
        resourceValues.count <= maximumResourceCount
      else { throw WalletError.invalidParams }
      resources = try resourceValues.map { value in
        guard let resource = value.stringValue, resource.utf8.count <= 2_048,
          validURICharacters(resource, allowingSpace: false),
          let components = URLComponents(string: resource), components.scheme != nil,
          !resource.contains("\n"), !resource.contains("\r")
        else { throw WalletError.invalidParams }
        return resource
      }
    }

    var message = ""
    if let scheme { message += "\(scheme)://" }
    message += "\(domain) wants you to sign in with your Ethereum account:\n\(account)\n\n"
    if let statement { message += "\(statement)\n" }
    message +=
      "\nURI: \(uri)\nVersion: 1\nChain ID: \(chainID)\nNonce: \(nonce)\nIssued At: \(issuedAt)"
    if let expirationTime { message += "\nExpiration Time: \(expirationTime)" }
    if let notBefore { message += "\nNot Before: \(notBefore)" }
    if let requestID { message += "\nRequest ID: \(requestID)" }
    if !resources.isEmpty {
      message += "\nResources:"
      for resource in resources { message += "\n- \(resource)" }
    }
    guard message.utf8.count <= maximumMessageLength else { throw WalletError.invalidParams }

    var canonical: [String: JSONValue] = [
      "message": .string(message), "domain": .string(domain), "uri": .string(uri),
      "version": .string(version), "chainId": .string(chainID), "nonce": .string(nonce),
      "issuedAt": .string(issuedAt),
    ]
    if let scheme { canonical["scheme"] = .string(scheme) }
    if let statement { canonical["statement"] = .string(statement) }
    if let expirationTime { canonical["expirationTime"] = .string(expirationTime) }
    if let notBefore { canonical["notBefore"] = .string(notBefore) }
    if let requestID { canonical["requestId"] = .string(requestID) }
    if !resources.isEmpty { canonical["resources"] = .array(resources.map(JSONValue.string)) }
    if !legacyChainIDs.isEmpty {
      canonical["responseChainIds"] = .array(legacyChainIDs.map(JSONValue.string))
    }
    return Prepared(params: .object(canonical), chainID: chainID)
  }

  public static func message(from params: JSONValue) throws -> String {
    guard case .object(let object) = params, let message = object["message"]?.stringValue,
      !message.isEmpty, message.utf8.count <= maximumMessageLength
    else { throw WalletError.invalidParams }
    return message
  }

  public static func validatePersisted(
    params: JSONValue, account: String, origin: String, chainID: String
  ) -> Bool {
    guard case .object(var input) = params,
      let chainHex = ChainStore.hexChainID(chainID), input["chainId"] == .string(chainID)
    else { return false }
    let responseChainIDs = input.removeValue(forKey: "responseChainIds")
    input.removeValue(forKey: "message")
    input["chainId"] = .string(chainHex)
    var request: [String: JSONValue] = [
      "version": .string("1"),
      "capabilities": .object(["signInWithEthereum": .object(input)]),
    ]
    if let responseChainIDs { request["chainIds"] = responseChainIDs }
    guard
      let regenerated = try? prepare(
        params: .array([.object(request)]), account: account, origin: origin)
    else { return false }
    return regenerated.params == params && regenerated.chainID == chainID
  }

  private static func normalizedHexChainID(_ value: String) -> String? {
    guard value.lowercased().hasPrefix("0x"), let decimal = ChainStore.normalize(value) else {
      return nil
    }
    return ChainStore.hexChainID(decimal)
  }

  private static func validScheme(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil
  }

  private static func validURICharacters(_ value: String, allowingSpace: Bool) -> Bool {
    value.unicodeScalars.allSatisfy {
      $0.isASCII && !CharacterSet.controlCharacters.contains($0)
        && (allowingSpace || $0.value != 0x20)
    }
  }

  private static func validStatement(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=% -]*$"#,
      options: .regularExpression) != nil
  }

  private static func validRequestID(_ value: String) -> Bool {
    value.range(
      of: #"^(?:[A-Za-z0-9._~!$&'()*+,;=:@-]|%[0-9A-Fa-f]{2})*$"#,
      options: .regularExpression) != nil
  }

  private static func authorityComponents(domain: String, scheme: String) -> URLComponents? {
    guard let components = URLComponents(string: "\(scheme)://\(domain)"),
      components.user == nil, components.password == nil, components.host != nil,
      components.path.isEmpty, components.query == nil, components.fragment == nil
    else { return nil }
    return components
  }

  private static func authority(host: String, port: Int?) -> String {
    port.map { "\(host):\($0)" } ?? host
  }

  private static func effectivePort(_ components: URLComponents) -> Int? {
    components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
  }

  private static func optionalDate(_ value: JSONValue?) throws -> String? {
    guard let value else { return nil }
    guard let string = value.stringValue, validDate(string) else { throw WalletError.invalidParams }
    return string
  }

  private static func validDate(_ value: String) -> Bool {
    parsedDate(value) != nil
  }

  private static func parsedDate(_ value: String) -> Date? {
    guard value.utf8.count <= 64,
      value.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
        options: .regularExpression) != nil
    else { return nil }
    return makeRFC3339Formatter().date(from: value)
      ?? makeRFC3339Formatter(fractional: true).date(from: value)
  }

  private static func makeRFC3339Formatter(fractional: Bool = false) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions =
      fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter
  }
}
