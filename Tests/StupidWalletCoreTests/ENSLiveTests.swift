import Foundation
import Testing

@testable import StupidWalletCore

struct ENSLiveTests {
  @Test(
    "public ENS integration fixtures resolve through the production RPC and verified CCIP reads",
    .enabled(if: ProcessInfo.processInfo.environment["ENS_LIVE_TESTS"] == "1"),
    arguments: [
      ("ur.integration-tests.eth", "1", "0x2222222222222222222222222222222222222222"),
      ("test.offchaindemo.eth", "1", "0x779981590e7ccc0cfae8040ce7151324747cdb97"),
      ("test.ses.eth", "8453", "0x7d3a48269416507e6d207a9449e7800971823ffa"),
      ("ensfairy.xyz", "1", "0x481f50a5bdccc0bc4322c4dca04301433ded50f0"),
    ])
  func publicFixtures(name: String, chainID: String, expected: String) async throws {
    // Public fixtures cross-checked with viem 2.55.19; not wallet-owned accounts.
    let result = try await ENSResolver(rpcResolver: RPCResolver()).resolve(
      name: name, chainID: chainID)
    #expect(result.name == name)
    #expect(result.chainID == chainID)
    #expect(result.address.lowercased() == expected)
  }
}
