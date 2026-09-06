import XCTest

@testable import StupidWalletCore

private struct FakeTokenResolver: ClearSigningResolving {
  let symbol: String?
  let decimals: Int?
  func tokenMetadata(chainID: String, tokenAddress: String) async -> ClearSigningTokenMetadata? {
    ClearSigningTokenMetadata(symbol: symbol, decimals: decimals)
  }
}

private func registrySeedIndex(in directory: URL, entries: [String: String]) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let object: JSONValue = .object(entries.mapValues(JSONValue.string))
  try JSONEncoder().encode(object).write(to: directory.appendingPathComponent("index.json"))
}

private func registrySeedDescriptor(in directory: URL, name: String, json: String) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data(json.utf8).write(to: directory.appendingPathComponent(name))
}

final class ClearSigningTests: XCTestCase {
  let usdtDescriptor = """
      {
        "$schema": "../../specs/erc7730-v2.schema.json",
        "context": {
          "$id": "Tether USD",
          "contract": {
            "deployments": [
              { "chainId": 1, "address": "0xdAC17F958D2ee523a2206206994597C13D831ec7" },
              { "chainId": 137, "address": "0xc2132D05D31c914a87C6611C10748AEb04B58e8F" }
            ]
          }
        },
        "metadata": {
          "owner": "Tether Limited",
          "contractName": "Tether USD",
          "token": { "ticker": "USDT", "name": "Tether USD", "decimals": 6 }
        },
        "display": {
          "formats": {
            "transfer(address to,uint256 value)": {
              "intent": "Send",
              "fields": [
                { "path": "value", "label": "Amount", "format": "tokenAmount", "params": { "tokenPath": "@.to" } },
                { "path": "to", "label": "To", "format": "addressName" }
              ]
            },
            "approve(address spender,uint256 value)": {
              "intent": "Approve",
              "fields": [
                { "path": "spender", "label": "Spender", "format": "addressName" },
                { "path": "value", "label": "Amount", "format": "tokenAmount", "params": { "tokenPath": "@.to", "threshold": "0x8000000000000000000000000000000000000000000000000000000000000000" } }
              ]
            }
          }
        }
      }
    """

  func testParseDescriptor() throws {
    let descriptor = try ClearSigningDescriptor.parse(data: Data(usdtDescriptor.utf8))
    XCTAssertEqual(descriptor.deployments.count, 2)
    XCTAssertEqual(descriptor.deployments[0].chainId, 1)
    XCTAssertEqual(descriptor.metadata.token?.ticker, "USDT")
    XCTAssertEqual(descriptor.metadata.token?.decimals, 6)
    XCTAssertEqual(descriptor.formats["transfer(address to,uint256 value)"]?.intent, "Send")
  }

  func testAppliesMatchingAndNonMatching() throws {
    let descriptor = try ClearSigningDescriptor.parse(data: Data(usdtDescriptor.utf8))
    XCTAssertTrue(
      descriptor.applies(chainId: "1", to: "0xdac17f958d2ee523a2206206994597c13d831ec7"))
    XCTAssertFalse(
      descriptor.applies(chainId: "1", to: "0x0000000000000000000000000000000000000000"))
    XCTAssertFalse(
      descriptor.applies(chainId: "10", to: "0xdac17f958d2ee523a2206206994597c13d831ec7"))
  }

  func testFormatterTransfer() async throws {
    let descriptor = try ClearSigningDescriptor.parse(data: Data(usdtDescriptor.utf8))
    let format = descriptor.formats["transfer(address to,uint256 value)"]!
    let parsed = try ABI.parse(signature: "transfer(address to,uint256 value)")
    // value = 1_000_000 (1 USDT at 6 decimals), to = recipient.
    let calldata =
      "0xa9059cbb"
      + "0000000000000000000000001111111111111111111111111111111111111111"
      + "00000000000000000000000000000000000000000000000000000000000f4240"
    let decoded = try! XCTUnwrap(ABI.decode(arguments: parsed.arguments, calldataHex: calldata))
    let container = ClearSigningFormatter.Container(
      chainId: "1", to: "0xdac17f958d2ee523a2206206994597c13d831ec7")
    let formatter = ClearSigningFormatter(
      format: format, decoded: decoded, container: container,
      resolver: FakeTokenResolver(symbol: "USDT", decimals: 6))
    let display = await formatter.display()
    XCTAssertEqual(display.intent, "Send")
    XCTAssertEqual(display.fields.first?.label, "Amount")
    XCTAssertEqual(display.fields.first?.value, "1 USDT")
    XCTAssertEqual(display.fields.last?.label, "To")
    XCTAssertEqual(display.fields.last?.value, "0x1111111111111111111111111111111111111111")
  }

  func testOfflineRegistryServiceDecodesTransfer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClearSigningTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let usdtLower = "0xdac17f958d2ee523a2206206994597c13d831ec7"
    let cacheDirectory = directory.appendingPathComponent("ClearSigning")
    let registry = ClearSigningRegistry(cacheDirectory: cacheDirectory)

    // Seed the cache: the registry index resolves the USDT contract, and the descriptor
    // exists. The base URL is never reached because the cache is warm.
    try registrySeedIndex(
      in: cacheDirectory, entries: ["eip155:1:\(usdtLower)": "tether/usdt.json"])
    try registrySeedDescriptor(in: cacheDirectory, name: "tether_usdt.json", json: usdtDescriptor)

    let service = ClearSigningService(
      registry: registry, tokenResolver: FakeTokenResolver(symbol: "USDT", decimals: 6))
    let calldata =
      "0xa9059cbb"
      + "0000000000000000000000001111111111111111111111111111111111111111"
      + "00000000000000000000000000000000000000000000000000000000000f4240"
    let display = await service.display(chainId: "1", to: usdtLower, data: calldata)
    let unwrapped = try XCTUnwrap(display)
    XCTAssertEqual(unwrapped.intent, "Send")
    XCTAssertEqual(unwrapped.fields.first?.label, "Amount")
    XCTAssertEqual(unwrapped.fields.first?.value, "1 USDT")
  }

  func testScaledDecimal() {
    let etherBytes: [UInt8] = [0x0d, 0xe0, 0xb6, 0xb3, 0xa7, 0x64, 0x00, 0x00]
    XCTAssertEqual(ABI.decimal(from: etherBytes), "1000000000000000000")
    XCTAssertEqual(ClearSigningFormatter.scaledDecimal(raw: etherBytes, decimals: 18), "1")
    XCTAssertEqual(
      ClearSigningFormatter.scaledDecimal(raw: [0x0f, 0x42, 0x40], decimals: 6), "1")
  }
}
