import Foundation

public enum TokenError: Error, Sendable, Equatable, LocalizedError {
  case invalidAddress
  case invalidMetadata
  case invalidBalance
  case invalidResponse
  case notContract
  case duplicate
  case unavailable
  case corrupt
  case configurationChanged
  case rpc(JSONValue)
  case transport

  public var errorDescription: String? {
    switch self {
    case .invalidAddress: "Enter a valid token contract address."
    case .invalidMetadata:
      "The token must return a valid symbol and decimals. Check its network and address, then retry."
    case .invalidBalance: "The token returned an invalid balance."
    case .invalidResponse:
      "The RPC returned an invalid batch response. Check the network’s RPC URL and retry."
    case .notContract: "No contract was found at this address on this network."
    case .duplicate: "That token is already in your wallet on this network."
    case .unavailable: "Token data could not be saved or loaded. Please retry."
    case .corrupt: "Stored token data is invalid and could not be loaded."
    case .configurationChanged: "The account, tokens, or network settings changed. Please retry."
    case .rpc(let error):
      "RPC: \(error.nestedString(at: ["message"]) ?? "The balance read failed.")"
    case .transport: "The RPC could not be reached. Please retry."
    }
  }
}

public struct WalletToken: Codable, Sendable, Equatable, Identifiable {
  public let chainID: String
  public let address: String
  public let symbol: String
  public let decimals: UInt8
  public var id: String { "\(chainID):\(address.lowercased())" }

  public init(chainID: String, address: String, symbol: String, decimals: UInt8) throws {
    guard let chain = ChainStore.normalize(chainID) else { throw TokenError.invalidAddress }
    self.chainID = chain
    self.address = try Self.normalizeAddress(address)
    guard let bytes = Hex.data(self.address), bytes.contains(where: { $0 != 0 }) else {
      throw TokenError.invalidAddress
    }
    guard !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      symbol.utf8.count <= 64,
      !symbol.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw TokenError.invalidMetadata }
    self.symbol = symbol
    self.decimals = decimals
  }

  static func normalizeAddress(_ input: String) throws -> String {
    let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address.count == 42, address.lowercased().hasPrefix("0x"),
      let bytes = Hex.data(address), bytes.count == 20
    else { throw TokenError.invalidAddress }
    return "0x" + Hex.encode(bytes)
  }

  /// Whether the text is a complete 20-byte contract address.
  public static func looksLikeAddress(_ text: String) -> Bool {
    (try? normalizeAddress(text)) != nil
  }

  public func exactBalance(raw: [UInt8]) -> String {
    ClearSigningFormatter.scaledDecimal(raw: raw, decimals: Int(decimals))
  }

  public func displayBalance(raw: [UInt8]) -> String {
    let exact = exactBalance(raw: raw)
    let parts = exact.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[1].count > 6 else { return exact }
    var fraction = String(parts[1].prefix(6))
    while fraction.last == "0" { fraction.removeLast() }
    if parts[0] == "0", fraction.isEmpty { return "<0.000001" }
    return fraction.isEmpty ? String(parts[0]) : "\(parts[0]).\(fraction)"
  }
}

public struct TokenBalanceEntry: Codable, Sendable, Equatable {
  public let raw: [UInt8]
  public let updatedAt: Date
  public let endpoint: URL
}

public struct TokenImport: Sendable {
  public let token: WalletToken
  public let balance: TokenBalanceEntry
  public let account: String
}

public struct ERC20Reader: Sendable {
  public let client: RPCClient

  public init(client: RPCClient = RPCClient()) { self.client = client }

  public func inspect(chainID: String, address: String, account: String, endpoint: URL) async throws
    -> TokenImport
  {
    let address = try WalletToken.normalizeAddress(address)
    let account = try WalletToken.normalizeAddress(account)
    let responses: [RPCResponse]
    do {
      responses = try await client.readBatch(
        url: endpoint,
        reads: [
          RPCRead(method: "eth_getCode", params: .array([.string(address), .string("latest")])),
          Self.call(address: address, data: "0x95d89b41"),
          Self.call(address: address, data: "0x313ce567"),
          try Self.balanceRead(address: address, account: account),
        ])
    } catch is CancellationError { throw CancellationError() } catch RPCClientError.invalidResponse
    { throw TokenError.invalidResponse } catch { throw TokenError.transport }
    let code = try Self.bytes(response: responses[0])
    guard !code.isEmpty else { throw TokenError.notContract }
    let symbolData = try Self.bytes(response: responses[1])
    // A standard ABI string with a bounded length; never convert an arbitrary uint256 to Int.
    guard symbolData.count >= 96, symbolData.prefix(31).allSatisfy({ $0 == 0 }),
      symbolData[31] == 32, symbolData[32..<63].allSatisfy({ $0 == 0 })
    else { throw TokenError.invalidMetadata }
    let length = Int(symbolData[63])
    guard (1...64).contains(length), symbolData.count == 64 + ((length + 31) / 32) * 32,
      symbolData[(64 + length)...].allSatisfy({ $0 == 0 }),
      let symbol = String(bytes: symbolData[64..<(64 + length)], encoding: .utf8)
    else { throw TokenError.invalidMetadata }
    let decimalData = try Self.bytes(response: responses[2])
    guard decimalData.count == 32, decimalData.prefix(31).allSatisfy({ $0 == 0 }) else {
      throw TokenError.invalidMetadata
    }
    let token = try WalletToken(
      chainID: chainID, address: address, symbol: symbol, decimals: decimalData[31])
    return TokenImport(
      token: token,
      balance: TokenBalanceEntry(
        raw: try Self.balance(response: responses[3]), updatedAt: Date(), endpoint: endpoint),
      account: account)
  }

  static func balanceRead(address: String, account: String) throws -> RPCRead {
    let account = try WalletToken.normalizeAddress(account)
    return call(
      address: address,
      data: "0x70a08231" + String(repeating: "0", count: 24) + account.dropFirst(2))
  }

  static func call(address: String, data: String) -> RPCRead {
    RPCRead(
      method: "eth_call",
      params: .array([
        .object(["to": .string(address), "data": .string(data)]), .string("latest"),
      ]))
  }

  static func bytes(response: RPCResponse) throws -> [UInt8] {
    switch response {
    case .error(let error): throw TokenError.rpc(error)
    case .result(.string(let value)):
      guard value.hasPrefix("0x"), let bytes = Hex.data(value) else {
        throw TokenError.invalidBalance
      }
      return bytes
    default: throw TokenError.invalidBalance
    }
  }

  static func balance(response: RPCResponse) throws -> [UInt8] {
    let bytes = try bytes(response: response)
    guard bytes.count == 32 else { throw TokenError.invalidBalance }
    return bytes
  }
}
