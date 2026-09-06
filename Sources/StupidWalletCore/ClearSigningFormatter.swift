import Foundation

/// Applies a matched ERC-7730 calldata format to decoded calldata arguments and produces a
/// labelled, human-readable review display. `tokenAmount` fields may consult the wallet's
/// token resolver (async); everything else is deterministic.
public struct ClearSigningFormatter {
  public struct Container: Sendable {
    public let chainId: String
    public let to: String
    public let from: String?
    public let value: ABIValue?

    public init(chainId: String, to: String, from: String? = nil, value: ABIValue? = nil) {
      self.chainId = chainId
      self.to = to
      self.from = from
      self.value = value
    }
  }

  private let format: ClearSigningDescriptor.Format
  private let decoded: [String: ABIValue]
  private let container: Container
  private let resolver: any ClearSigningResolving

  public init(
    format: ClearSigningDescriptor.Format,
    decoded: [String: ABIValue],
    container: Container,
    resolver: any ClearSigningResolving
  ) {
    self.format = format
    self.decoded = decoded
    self.container = container
    self.resolver = resolver
  }

  public func display() async -> ClearSigningDisplay {
    var fields: [ClearSigningField] = []
    for field in format.fields {
      guard let value = value(at: field.path) else { continue }
      let text: String
      if isAmountField(field) {
        text = await formatAmount(value, field: field)
      } else {
        text = Self.text(value, field: field)
      }
      fields.append(
        ClearSigningField(label: field.label ?? Self.lastComponent(field.path), value: text))
    }
    return ClearSigningDisplay(
      intent: format.intent,
      interpolatedIntent: nil,
      fields: fields,
      contractName: nil,
      owner: nil)
  }

  // MARK: - Path resolution
  //
  // Paths use ERC-7730 roots: `#` (decoded args, default), `@` (container), with dotted
  // segments and bracket selectors (`recipients[0]`).

  func value(at path: String) -> ABIValue? {
    Self.value(at: path, decoded: decoded, container: container)
  }

  static func value(
    at path: String, decoded: [String: ABIValue], container: Container
  ) -> ABIValue? {
    var p = path
    if p.hasPrefix("#.") {
      p = String(p.dropFirst(2))
    } else if p.hasPrefix("#") {
      p = String(p.dropFirst(1))
    }

    if p.hasPrefix("@.") {
      switch String(p.dropFirst(2)) {
      case "to": return .address(container.to)
      case "from": return container.from.map(ABIValue.address)
      case "chainId": return .uint256(chainIDBytes(container.chainId))
      case "value": return container.value
      default: return nil
      }
    }
    if p.hasPrefix("@") {
      return components(String(p.dropFirst(1))).first.flatMap {
        decoded[$0]
      }
    }
    return components(p).reduce(ABIValue.object(decoded) as ABIValue?) { partial, component in
      descend(partial, component)
    }
  }

  private static func descend(_ value: ABIValue?, _ component: String) -> ABIValue? {
    guard let value else { return nil }
    switch value {
    case .object(let object): return object[component]
    case .array(let array):
      guard let index = Int(component), index >= 0, index < array.count else { return nil }
      return array[index]
    default: return nil
    }
  }

  private static func components(_ path: String) -> [String] {
    var result: [String] = []
    var current = ""
    var readingIndex = false
    var indexBuffer = ""
    for char in path {
      if !readingIndex, char == "[" {
        readingIndex = true
        if !current.isEmpty {
          result.append(current)
          current = ""
        }
        indexBuffer = ""
      } else if readingIndex, char == "]" {
        readingIndex = false
        if !indexBuffer.isEmpty { result.append(indexBuffer) }
      } else if readingIndex {
        indexBuffer.append(char)
      } else if char == "." {
        if !current.isEmpty {
          result.append(current)
          current = ""
        }
      } else {
        current.append(char)
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private static func lastComponent(_ path: String) -> String {
    components(path).last ?? path
  }

  // MARK: - Formatting

  private func isAmountField(_ field: ClearSigningDescriptor.Field) -> Bool {
    let name = (field.format ?? "").lowercased()
    return name.contains("amount") || name == "number" || name == "int" || name == "uint"
  }

  private func formatAmount(_ value: ABIValue, field: ClearSigningDescriptor.Field) async -> String
  {
    guard let bytes = rawBytes(value) else { return value.displayString }
    let tokenAddress = await tokenAddress(for: field)

    var decimals: Int?
    var symbol: String?
    if let tokenAddress,
      let metadata = await resolver.tokenMetadata(
        chainID: container.chainId, tokenAddress: tokenAddress)
    {
      decimals = metadata.decimals
      symbol = metadata.symbol
    }

    let scaled = Self.scaledDecimal(raw: bytes, decimals: decimals)
    guard let symbol, !symbol.isEmpty else { return scaled }
    return "\(scaled) \(symbol)"
  }

  /// Resolves the token address a `tokenPath` parameter refers to (a decoded `#.x` address or
  /// the container's `@.to`).
  private func tokenAddress(for field: ClearSigningDescriptor.Field) async -> String? {
    guard let tokenPath = field.params["tokenPath"]?.stringValue else { return nil }
    if tokenPath == "@.to" { return container.to }
    guard let value = value(at: tokenPath) else { return nil }
    if case .address(let address) = value { return address }
    return nil
  }

  private func rawBytes(_ value: ABIValue) -> [UInt8]? {
    switch value {
    case .uint256(let bytes), .int(let bytes): return bytes
    default: return nil
    }
  }

  private static func text(_ value: ABIValue, field: ClearSigningDescriptor.Field) -> String {
    switch (field.format ?? "").lowercased() {
    case "address", "addressname", "addr":
      // Emit the canonical full address so display surfaces can render a deterministic
      // blockie/avatar derived from it (abbreviating here would discard the entropy).
      return value.hexDisplay
    case "bool":
      return value.displayString
    case "bytes", "bytes32", "bytes64":
      return value.hexDisplay
    case "enum", "ring", "string", "text", "date", "days":
      return value.displayString
    default:
      return value.displayString
    }
  }

  public static func shortAddress(_ address: String) -> String {
    guard address.hasPrefix("0x") else { return address }
    if address.count <= 10 { return address }
    return "\(address.prefix(6))…\(address.suffix(4))"
  }

  /// Renders a big-endian amount scaled by `decimals` decimal places, trimming trailing zeros.
  public static func scaledDecimal(raw: [UInt8], decimals: Int?) -> String {
    let whole = ABI.decimal(from: raw)
    guard let decimals, decimals > 0 else { return whole }
    if whole == "0" { return "0" }
    let padded = String(repeating: "0", count: max(0, decimals - whole.count + 1)) + whole
    let split = padded.index(padded.endIndex, offsetBy: -decimals)
    var integerPart = String(padded[..<split])
    var fractionPart = String(padded[split...])
    while fractionPart.last == "0" { fractionPart.removeLast() }
    if integerPart.isEmpty { integerPart = "0" }
    return fractionPart.isEmpty ? integerPart : "\(integerPart).\(fractionPart)"
  }
}

/// Builds the 32-byte big-endian representation of a decimal/hex chain identifier.
private func chainIDBytes(_ chainId: String) -> [UInt8] {
  var out = [UInt8](repeating: 0, count: 32)
  let value = UInt64(chainId) ?? 0
  var big = value.bigEndian
  withUnsafeBytes(of: &big) { bytes in
    for (index, byte) in bytes.enumerated() { out[24 + index] = byte }
  }
  return out
}
