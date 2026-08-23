import Foundation

public enum NativeBalanceError: Error, Sendable, Equatable {
  case invalidQuantity
  case rpc(JSONValue)
  case transport
}

public struct NativeNetworkBalance: Sendable, Equatable {
  public let chainID: String
  public let wei: [UInt8]?

  public init(chainID: String, wei: [UInt8]?) {
    self.chainID = chainID
    self.wei = wei
  }

  public var hasNonZeroBalance: Bool {
    wei?.contains { $0 != 0 } == true
  }
}

public struct NativeBalanceService: Sendable {
  public let resolver: RPCResolver
  public let client: RPCClient

  public init(resolver: RPCResolver = .persisted(), client: RPCClient = RPCClient()) {
    self.resolver = resolver
    self.client = client
  }

  public func balance(account: String, chainID: String) async throws -> String {
    Self.formatEther(bytes: try await weiBalance(account: account, chainID: chainID))
  }

  public func aggregateBalance(account: String, chainIDs: [String]) async throws -> String {
    guard !chainIDs.isEmpty else { return Self.formatEther(bytes: [0]) }
    let results = await balances(account: account, chainIDs: chainIDs)
    let balances = results.compactMap(\.wei)
    guard !balances.isEmpty else { throw NativeBalanceError.transport }
    return Self.formatEther(bytes: balances.reduce([0], Self.add))
  }

  public func balances(account: String, chainIDs: [String]) async -> [NativeNetworkBalance] {
    let fetched = await withTaskGroup(
      of: (String, [UInt8]?).self, returning: [String: [UInt8]?].self
    ) { group in
      for chainID in chainIDs {
        group.addTask {
          (chainID, try? await weiBalance(account: account, chainID: chainID))
        }
      }
      var values: [String: [UInt8]?] = [:]
      for await (chainID, balance) in group {
        values[chainID] = balance
      }
      return values
    }
    return chainIDs.map { NativeNetworkBalance(chainID: $0, wei: fetched[$0] ?? nil) }
  }

  public func weiBalance(account: String, chainID: String) async throws -> [UInt8] {
    let response: RPCResponse
    do {
      response = try await client.call(
        url: resolver.resolve(chainID: chainID),
        method: "eth_getBalance",
        params: .array([.string(account), .string("latest")])
      )
    } catch {
      throw NativeBalanceError.transport
    }
    switch response {
    case .error(let error):
      throw NativeBalanceError.rpc(error)
    case .result(.string(let quantity)):
      guard let bytes = Hex.quantityData(hex: quantity) else {
        throw NativeBalanceError.invalidQuantity
      }
      return bytes
    default:
      throw NativeBalanceError.invalidQuantity
    }
  }

  public static func add(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    var left = Array(lhs.reversed())
    let right = Array(rhs.reversed())
    if left.count < right.count { left += [UInt8](repeating: 0, count: right.count - left.count) }
    var carry = 0
    for index in 0..<left.count {
      let value = Int(left[index]) + (index < right.count ? Int(right[index]) : 0) + carry
      left[index] = UInt8(value & 0xff)
      carry = value >> 8
    }
    if carry > 0 { left.append(UInt8(carry)) }
    return Array(left.reversed())
  }

  public static func formatEther(bytes: [UInt8]) -> String {
    var digits = [0]
    for byte in bytes {
      var carry = Int(byte)
      for index in digits.indices {
        let value = digits[index] * 256 + carry
        digits[index] = value % 10
        carry = value / 10
      }
      while carry > 0 {
        digits.append(carry % 10)
        carry /= 10
      }
    }
    var decimal = digits.reversed().map(String.init).joined()
    if decimal.count <= 18 {
      decimal = String(repeating: "0", count: 19 - decimal.count) + decimal
    }
    let split = decimal.index(decimal.endIndex, offsetBy: -18)
    let whole = decimal[..<split]
    let fraction = decimal[split...].prefix(6)
    return "\(whole).\(fraction)"
  }
}
