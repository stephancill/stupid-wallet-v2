import Foundation

public enum NativeBalanceError: Error, Sendable, Equatable {
  case invalidQuantity
  case rpc(JSONValue)
  case transport
}

public struct NativeBalanceService: Sendable {
  public let resolver: RPCResolver
  public let client: RPCClient

  public init(resolver: RPCResolver = .persisted(), client: RPCClient = RPCClient()) {
    self.resolver = resolver
    self.client = client
  }

  public func balance(account: String, chainID: String) async throws -> String {
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
      return Self.formatEther(bytes: bytes)
    default:
      throw NativeBalanceError.invalidQuantity
    }
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
