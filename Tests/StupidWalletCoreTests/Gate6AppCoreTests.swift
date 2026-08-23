import Foundation
import Testing

@testable import StupidWalletCore

struct Gate6AppCoreTests {
  @Test("RPC overrides persist by normalized decimal chain ID")
  func rpcOverridesPersist() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RPCOverrideStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = RPCOverrideStore(directory: directory)
    let url = try #require(URL(string: "https://rpc.example.test"))
    try store.set(url, forChainID: "0x2105")

    #expect(try store.all() == ["8453": url])
    #expect(RPCResolver.persisted(store: store).resolve(chainID: "8453") == url)

    try store.remove(forChainID: "8453")
    #expect(try store.all().isEmpty)
  }

  @Test("native balance formatting supports full-width Ethereum quantities")
  func nativeBalanceFormatting() {
    #expect(NativeBalanceService.formatEther(bytes: [0]) == "0.000000")
    #expect(
      NativeBalanceService.formatEther(bytes: Hex.quantityData(hex: "0xde0b6b3a7640000")!)
        == "1.000000")
    #expect(
      NativeBalanceService.formatEther(bytes: [UInt8](repeating: 0xff, count: 32))
        == "115792089237316195423570985008687907853269984665640564039457.584007")
  }
}
