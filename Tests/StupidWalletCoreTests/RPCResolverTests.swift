import Foundation
import Testing

@testable import StupidWalletCore

struct RPCRoutingTests {
  @Test("default routing covers multiple chain IDs")
  func defaultRouting() {
    for (id, expectedPath) in [
      ("1", "/v1/1"),
      ("42161", "/v1/42161"),
      ("8453", "/v1/8453"),
      ("137", "/v1/137"),
      ("10", "/v1/10"),
    ] {
      let url = RPCResolver.defaultURL(forChainID: id)
      #expect(url.absoluteString == "https://evm.stupidtech.net\(expectedPath)")
    }
  }

  @Test("a validated override replaces the default for that chain only")
  func overrideResolution() {
    let override = URL(string: "https://my-node.example.com")!
    let resolver = RPCResolver(overrides: ["42161": override])
    #expect(resolver.resolve(chainID: "42161") == override)
    #expect(resolver.resolve(chainID: "1") == RPCResolver.defaultURL(forChainID: "1"))
  }
}
