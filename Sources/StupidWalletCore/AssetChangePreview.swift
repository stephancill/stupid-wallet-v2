import Foundation

/// A display-only interpretation of eth_simulateV1 transfer logs for the signing account.
/// Neither the simulation nor its metadata is an input to the canonical signing decision.
struct AssetChangePreview {
  private static let transferTopic =
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  private static let nativeEmitter = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

  static func rows(
    transaction: [String: JSONValue], account: String, chainID: String,
    client: RPCClient, resolver: RPCResolver,
    tokenResolver: any ClearSigningResolving
  ) async -> [(String, String)] {
    var call: [String: JSONValue] = ["from": .string(account)]
    for field in ["to", "value", "data", "gas"] {
      if let value = transaction[field] { call[field] = value }
    }
    let payload: JSONValue = .array([
      .object([
        "blockStateCalls": .array([.object(["calls": .array([.object(call)])])]),
        "traceTransfers": .bool(true),
      ]),
      .string("latest"),
    ])
    let response: RPCResponse
    do {
      response = try await client.call(
        url: resolver.resolve(chainID: chainID), method: "eth_simulateV1", params: payload)
    } catch {
      return [("Simulation", "Unavailable (RPC request failed)")]
    }
    if case .error(let error) = response {
      if case .object(let object) = error, object["code"] == .number(-32601) {
        return [("Simulation", "Unsupported by selected RPC")]
      }
      return [("Simulation", "Unavailable (RPC rejected simulation)")]
    }
    guard case .result(.array(let blocks)) = response,
      blocks.count == 1, case .object(let block) = blocks[0],
      case .array(let calls)? = block["calls"], calls.count == 1,
      case .object(let result) = calls[0],
      let status = result["status"]?.stringValue
    else { return [("Simulation", "Unavailable (unsupported RPC response)")] }
    if status == "0x0" { return [("Simulation", "Transaction reverted in simulation")] }
    guard status == "0x1", case .array(let logs)? = result["logs"], logs.count <= 256 else {
      return [("Simulation", "Unavailable (invalid call result)")]
    }

    // Count only well-formed ERC-20 Transfer(address,address,uint256) logs. Other events
    // (including ERC-721's identically named event) are not fungible asset changes.
    var totals: [String: (received: String, sent: String)] = [:]
    let signer = account.lowercased().dropFirst(2)
    for entry in logs {
      guard case .object(let log) = entry,
        let emitter = log["address"]?.stringValue,
        let address = try? WalletToken.normalizeAddress(emitter),
        case .array(let topics)? = log["topics"], topics.count == 3,
        topics[0].stringValue?.lowercased() == transferTopic,
        let from = topics[1].stringValue?.lowercased(),
        let to = topics[2].stringValue?.lowercased(),
        from.count == 66, to.count == 66,
        from.hasPrefix("0x" + String(repeating: "0", count: 24)),
        to.hasPrefix("0x" + String(repeating: "0", count: 24)),
        let bytes = log["data"]?.stringValue.flatMap(Hex.data), bytes.count == 32
      else { continue }
      let fromAccount = from.suffix(40) == signer
      let toAccount = to.suffix(40) == signer
      if !fromAccount && !toAccount { continue }
      let key = address.lowercased()
      let amount = ABI.decimal(from: bytes)
      var total = totals[key] ?? ("0", "0")
      if fromAccount { total.sent = DecimalValue.sum([total.sent, amount]) ?? total.sent }
      if toAccount {
        total.received = DecimalValue.sum([total.received, amount]) ?? total.received
      }
      totals[key] = total
      if totals.count > 32 { return [("Simulation", "Unavailable (too many assets)")] }
    }

    var changes: [String] = []
    for address in totals.keys.sorted(by: {
      ($0 == nativeEmitter ? "" : $0) < ($1 == nativeEmitter ? "" : $1)
    }) {
      guard let total = totals[address] else { continue }
      let comparison = DecimalValue.compare(total.received, total.sent)
      if comparison == .orderedSame { continue }
      let incoming = comparison == .orderedDescending
      guard
        let raw = DecimalValue.subtract(
          incoming ? total.received : total.sent, incoming ? total.sent : total.received),
        let amount = TokenTransfer.rawUnits(fromDecimal: raw, decimals: 0)
      else { return [("Simulation", "Unavailable (invalid asset amount)")] }
      let quantity: String
      let symbol: String
      if address == nativeEmitter {
        quantity = ClearSigningFormatter.scaledDecimal(raw: amount, decimals: 18)
        symbol = WalletService.nativeCurrencySymbol(chainID: chainID)
      } else {
        let metadata = await tokenResolver.tokenMetadata(chainID: chainID, tokenAddress: address)
        if let decimals = metadata?.decimals, (0...255).contains(decimals) {
          quantity = ClearSigningFormatter.scaledDecimal(raw: amount, decimals: decimals)
          symbol = metadata?.symbol.flatMap { $0.isEmpty || $0.count > 64 ? nil : $0 } ?? address
        } else {
          quantity = raw
          symbol = "base units · \(address)"
        }
      }
      changes.append("\(incoming ? "+" : "−")\(quantity) \(symbol)")
    }
    if changes.isEmpty { return [("Simulation", "No net fungible asset changes detected")] }
    return changes.enumerated().map { ("Asset Change \($0.offset + 1)", $0.element) }
  }
}
