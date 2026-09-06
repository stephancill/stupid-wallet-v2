import Foundation

/// A displayable label/value pair produced for a decoded ERC-7730 field.
public struct ClearSigningField: Sendable, Equatable {
  public let label: String
  public let value: String

  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
}

/// The human-readable result of formatting a decoded transaction against an ERC-7730
/// descriptor. `intent` is the headline action; `interpolatedIntent` (when present) is a full
/// sentence with formatted values; `fields` are labelled details.
public struct ClearSigningDisplay: Sendable, Equatable {
  public let intent: String?
  public let interpolatedIntent: String?
  public let fields: [ClearSigningField]
  public let contractName: String?
  public let owner: String?

  public init(
    intent: String?,
    interpolatedIntent: String?,
    fields: [ClearSigningField],
    contractName: String?,
    owner: String?
  ) {
    self.intent = intent
    self.interpolatedIntent = interpolatedIntent
    self.fields = fields
    self.contractName = contractName
    self.owner = owner
  }
}

/// Resolves token metadata (symbol/decimals) for `tokenAmount` fields. A wallet provides an
/// implementation backed by RPC (`symbol()`, `decimals()`); nil means fall back to raw format.
public protocol ClearSigningResolving {
  func tokenMetadata(chainID: String, tokenAddress: String) async -> ClearSigningTokenMetadata?
}

public struct ClearSigningTokenMetadata: Sendable, Equatable {
  public let symbol: String?
  public let decimals: Int?

  public init(symbol: String?, decimals: Int?) {
    self.symbol = symbol
    self.decimals = decimals
  }
}

/// A no-op token resolver used when no wallet-provided resolver is available.
public struct UnavailableClearSigningResolver: ClearSigningResolving {
  public init() {}
  public func tokenMetadata(chainID: String, tokenAddress: String) async
    -> ClearSigningTokenMetadata?
  {
    nil
  }
}

/// A parsed ERC-7730 (clear signing) descriptor for contract calldata.
public struct ClearSigningDescriptor: Sendable, Equatable {
  public struct Deployment: Sendable, Equatable {
    public let chainId: Int
    public let address: String
  }

  public struct Token: Sendable, Equatable {
    public let name: String?
    public let ticker: String?
    public let decimals: Int?

    public init(name: String?, ticker: String?, decimals: Int?) {
      self.name = name
      self.ticker = ticker
      self.decimals = decimals
    }
  }

  public struct Metadata: Sendable, Equatable {
    public let owner: String?
    public let contractName: String?
    public let token: Token?

    public init(owner: String?, contractName: String?, token: Token?) {
      self.owner = owner
      self.contractName = contractName
      self.token = token
    }
  }

  public struct Field: Sendable, Equatable {
    public let path: String
    public let label: String?
    public let format: String?
    public let params: [String: JSONValue]

    public init(path: String, label: String?, format: String?, params: [String: JSONValue]) {
      self.path = path
      self.label = label
      self.format = format
      self.params = params
    }
  }

  public struct Format: Sendable, Equatable {
    public let intent: String?
    public let interpolatedIntent: String?
    public let fields: [Field]

    public init(intent: String?, interpolatedIntent: String?, fields: [Field]) {
      self.intent = intent
      self.interpolatedIntent = interpolatedIntent
      self.fields = fields
    }
  }

  public let contextID: String?
  public let deployments: [Deployment]
  public let metadata: Metadata
  public let formats: [String: Format]

  public init(
    contextID: String?,
    deployments: [Deployment],
    metadata: Metadata,
    formats: [String: Format]
  ) {
    self.contextID = contextID
    self.deployments = deployments
    self.metadata = metadata
    self.formats = formats
  }

  /// Parses a descriptor from JSON bytes. Unknown/optional keys are tolerated so registry
  /// files stay forward compatible.
  public static func parse(data: Data) throws -> ClearSigningDescriptor {
    guard let value = try? JSONValue.parse(data),
      case .object(let root) = value
    else { throw ClearSigningError.invalidDescriptor }

    var deployments: [Deployment] = []
    var metadata = Metadata(owner: nil, contractName: nil, token: nil)
    var formats: [String: Format] = [:]
    var contextID: String?

    if case .object(let context)? = root["context"] {
      contextID = context["$id"]?.stringValue
      if case .object(let contract)? = context["contract"],
        case .array(let deploymentList)? = contract["deployments"]
      {
        for deployment in deploymentList {
          guard case .object(let d) = deployment,
            let chainId = Self.intValue(d["chainId"]),
            let address = d["address"]?.stringValue
          else { continue }
          deployments.append(Deployment(chainId: chainId, address: address.lowercased()))
        }
      }
    }

    if case .object(let m) = root["metadata"] {
      let owner = m["owner"]?.stringValue
      let contractName = m["contractName"]?.stringValue
      var token: Token?
      if case .object(let t) = m["token"] {
        token = Token(
          name: t["name"]?.stringValue, ticker: t["ticker"]?.stringValue,
          decimals: Self.intValue(t["decimals"]))
      }
      metadata = Metadata(owner: owner, contractName: contractName, token: token)
    }

    if case .object(let display) = root["display"],
      case .object(let formatMap) = display["formats"]
    {
      for (signature, formatValue) in formatMap {
        guard case .object(let f) = formatValue else { continue }
        formats[signature] = Format(
          intent: f["intent"]?.stringValue,
          interpolatedIntent: f["interpolatedIntent"]?.stringValue,
          fields: Self.parseFields(f["fields"]))
      }
    }

    return ClearSigningDescriptor(
      contextID: contextID, deployments: deployments, metadata: metadata, formats: formats)
  }

  private static func parseFields(_ payload: JSONValue?) -> [Field] {
    guard case .array(let array)? = payload else { return [] }
    return array.compactMap { item -> Field? in
      guard case .object(let object) = item, let path = object["path"]?.stringValue else {
        return nil
      }
      var params: [String: JSONValue] = [:]
      if case .object(let p)? = object["params"] { params = p }
      return Field(
        path: path, label: object["label"]?.stringValue,
        format: object["format"]?.stringValue, params: params)
    }
  }

  /// Whether the (chainId, address) target matches one of the declared deployments. An empty
  /// deployment list (generic template files) is treated as "applies" and must be opted into
  /// explicitly by the caller.
  public func applies(chainId: String, to address: String) -> Bool {
    guard !deployments.isEmpty else { return false }
    let normalizedAddress = address.lowercased()
    return deployments.contains { deployment in
      deployment.address == normalizedAddress && String(deployment.chainId) == chainId
    }
  }

  public var displayToken: Token? { metadata.token }

  static func intValue(_ value: JSONValue?) -> Int? {
    guard let value else { return nil }
    if case .number(let number) = value, number.isFinite { return Int(number) }
    if case .string(let string) = value { return Int(string) }
    return nil
  }
}

public enum ClearSigningError: Error, Sendable {
  case invalidDescriptor
  case transport
}
