import Foundation

/// Fetches and caches ERC-7730 (clear signing) descriptors from the public
/// `ethereum/clear-signing-erc7730-registry` GitHub registry, keyed by chain + contract.
/// Fallbacks to cache when the network is unavailable; returns nil when no descriptor exists.
public actor ClearSigningRegistry {
  public static let shared = ClearSigningRegistry()

  private let base: URL
  private let session: URLSession
  private let cacheDirectory: URL
  private let indexTTL: TimeInterval
  private let descriptorTTL: TimeInterval

  private var cachedIndex: RegistryIndex?
  private var indexFetchedAt: Date?

  /// Maps `eip155:<chainId>:<addressLowerCase>` to a descriptor path.
  public struct RegistryIndex: Sendable {
    public let entries: [String: String]
  }

  public init(
    base: URL = URL(
      string: "https://raw.githubusercontent.com/ethereum/clear-signing-erc7730-registry/master")!,
    session: URLSession = .shared,
    cacheDirectory: URL? = nil,
    indexTTL: TimeInterval = 900,
    descriptorTTL: TimeInterval = 86_400
  ) {
    self.base = base
    self.session = session
    if let cacheDirectory {
      self.cacheDirectory = cacheDirectory
    } else if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: PendingRequestStore.defaultAppGroup)
    {
      self.cacheDirectory = container.appendingPathComponent("ClearSigning", isDirectory: true)
    } else {
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      )[0]
      self.cacheDirectory = applicationSupport.appendingPathComponent(
        "ClearSigning", isDirectory: true)
    }
    self.indexTTL = indexTTL
    self.descriptorTTL = descriptorTTL
  }

  /// Resolves and parses the descriptor for a transaction, or nil when unavailable.
  public func descriptor(chainId: String, address: String) async -> ClearSigningDescriptor? {
    let key = "eip155:\(chainId):\(address.lowercased())"
    guard let path = await index()?.entries[key] else { return nil }
    guard let data = await descriptorData(path: path) else { return nil }
    guard let descriptor = try? ClearSigningDescriptor.parse(data: data) else { return nil }
    // Security: never apply a descriptor that declares deployments that do not match.
    guard descriptor.deployments.isEmpty || descriptor.applies(chainId: chainId, to: address)
    else { return nil }
    return descriptor
  }

  // MARK: - Fetching

  private func index() async -> RegistryIndex? {
    if let cached = cachedIndex, let fetchedAt = indexFetchedAt,
      Date().timeIntervalSince(fetchedAt) < indexTTL
    {
      return cached
    }
    if let data = await fetchIndex() {
      if let parsed = try? JSONValue.parse(data), case .object(let object) = parsed {
        var entries: [String: String] = [:]
        for (key, value) in object {
          if case .string(let path) = value { entries[key] = path }
        }
        write(data, to: "index.json")
        let index = RegistryIndex(entries: entries)
        cachedIndex = index
        indexFetchedAt = Date()
        return index
      }
    }
    // Fall back to a stale cached index even after a fetch failure.
    return cachedIndex ?? loadCachedEntries()
  }

  private func descriptorData(path: String) async -> Data? {
    let cacheFile = sanitizedFileName(path)
    let fileURL = cacheDirectory.appendingPathComponent(cacheFile)
    if !isStale(at: fileURL), let cached = try? Data(contentsOf: fileURL) {
      return cached
    }
    let url = base.appendingPathComponent(path)
    if let data = await fetch(url) {
      write(data, to: cacheFile)
      return data
    }
    return try? Data(contentsOf: fileURL)
  }

  private func fetchIndex() async -> Data? {
    await fetch(base.appendingPathComponent("index.calldata.json"))
  }

  private func isStale(at fileURL: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
      let modification = attributes[.modificationDate] as? Date
    else { return true }
    return Date().timeIntervalSince(modification) >= descriptorTTL
  }

  private func fetch(_ url: URL) async -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    do {
      let (data, _) = try await session.data(for: request)
      return data
    } catch {
      return nil
    }
  }

  private func loadCachedEntries() -> RegistryIndex? {
    guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent("index.json")),
      let parsed = try? JSONValue.parse(data), case .object(let object) = parsed
    else { return nil }
    var entries: [String: String] = [:]
    for (key, value) in object {
      if case .string(let path) = value { entries[key] = path }
    }
    return RegistryIndex(entries: entries)
  }

  private func write(_ data: Data, to fileName: String) {
    try? FileManager.default.createDirectory(
      at: cacheDirectory, withIntermediateDirectories: true)
    let url = cacheDirectory.appendingPathComponent(fileName)
    // Atomic replace so a crash mid-write never leaves a corrupt cache entry.
    let temporary = cacheDirectory.appendingPathComponent(fileName + ".tmp")
    try? data.write(to: temporary)
    _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }

  private func sanitizedFileName(_ path: String) -> String {
    path.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
  }
}

/// No-op token resolver used when no wallet-provided resolver is configured.
public struct UnavailableTokenResolver: ClearSigningResolving {
  public init() {}
  public func tokenMetadata(chainID: String, tokenAddress: String) async
    -> ClearSigningTokenMetadata?
  {
    nil
  }
}

/// Resolves ERC-20 `symbol()`/`decimals()` for token-amount fields through the shared RPC.
public struct RPCTokenResolver: ClearSigningResolving {
  private let client: RPCClient
  private let resolver: RPCResolver

  public init(client: RPCClient = RPCClient(), resolver: RPCResolver = .persisted()) {
    self.client = client
    self.resolver = resolver
  }

  public func tokenMetadata(chainID: String, tokenAddress: String) async
    -> ClearSigningTokenMetadata?
  {
    let symbol = await callString(
      function: "0x95d89b41", chainID: chainID, token: tokenAddress)
    let decimals = await callUInt(
      function: "0x313ce567", chainID: chainID, token: tokenAddress)
    guard symbol != nil || decimals != nil else { return nil }
    return ClearSigningTokenMetadata(symbol: symbol, decimals: decimals)
  }

  private func callString(function: String, chainID: String, token: String) async -> String? {
    guard let data = await callData(function: function, chainID: chainID, token: token),
      data.count >= 64
    else { return nil }
    // ABI string result: offset word at [0..32] (32), length at [32..64], bytes thereafter.
    let length = Int(readWord(data[32..<64]))
    guard length >= 0, 64 + length <= data.count else { return nil }
    return String(data: data.subdata(in: 64..<(64 + length)), encoding: .utf8)
  }

  private func callUInt(function: String, chainID: String, token: String) async -> Int? {
    guard let data = await callData(function: function, chainID: chainID, token: token),
      data.count >= 32
    else { return nil }
    var raw = Array(data[0..<32])
    while raw.first == 0, raw.count > 1 { raw.removeFirst() }
    guard raw.count <= 8 else { return nil }
    var out = 0
    for byte in raw { out = (out << 8) | Int(byte) }
    return out
  }

  private func readWord(_ slice: Data) -> UInt64 {
    var value: UInt64 = 0
    for byte in slice {
      let shifted = value.multipliedReportingOverflow(by: 256)
      value = shifted.overflow ? UInt64.max : shifted.partialValue
      value = value &+ UInt64(byte)
    }
    return value
  }

  private func callData(function: String, chainID: String, token: String) async -> Data? {
    let params: JSONValue = .array([
      .object([
        "to": .string(token),
        "data": .string(function),
      ]),
      .string("latest"),
    ])
    do {
      switch try await client.call(
        url: resolver.resolve(chainID: chainID), method: "eth_call", params: params)
      {
      case .result(.string(let hex)):
        return Hex.data(hex).map { Data($0) }
      default:
        return nil
      }
    } catch {
      return nil
    }
  }
}

/// Puts the registry + formatter together: resolves a descriptor, matches the selector,
/// decodes calldata, and formats it for review.
public struct ClearSigningService {
  public let registry: ClearSigningRegistry
  public let tokenResolver: any ClearSigningResolving

  public init(
    registry: ClearSigningRegistry = .shared,
    tokenResolver: any ClearSigningResolving = UnavailableTokenResolver()
  ) {
    self.registry = registry
    self.tokenResolver = tokenResolver
  }

  public func display(chainId: String, to: String, data: String) async -> ClearSigningDisplay? {
    guard let dataBytes = Hex.data(data), dataBytes.count >= 4 else { return nil }
    guard let descriptor = await registry.descriptor(chainId: chainId, address: to) else {
      return nil
    }
    let targetSelector = Hex.encode(Array(dataBytes.prefix(4)))
    for (signature, format) in descriptor.formats {
      guard let parsed = try? ABI.parse(signature: signature),
        ABI.selector(name: parsed.name, arguments: parsed.arguments).dropFirst(2)
          == targetSelector
      else { continue }
      guard
        let decoded = ABI.decode(arguments: parsed.arguments, data: Array(dataBytes.dropFirst(4)))
      else { continue }
      let container = ClearSigningFormatter.Container(chainId: chainId, to: to)
      return await ClearSigningFormatter(
        format: format, decoded: decoded, container: container, resolver: tokenResolver
      ).display()
    }
    return nil
  }
}
