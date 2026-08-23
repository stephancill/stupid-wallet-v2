import Foundation
import Testing

@testable import StupidWalletCore

struct MethodPolicyTests {
  @Test("explicitly handled methods classify as their wallet-owned class")
  func handled() {
    #expect(MethodPolicy.classify("eth_requestAccounts") == .connect)
    #expect(MethodPolicy.classify("wallet_connect") == .connect)
    #expect(MethodPolicy.classify("eth_chainId") == .chain)
    #expect(MethodPolicy.classify("net_version") == .chain)
    #expect(MethodPolicy.classify("wallet_switchEthereumChain") == .chain)
    #expect(MethodPolicy.classify("wallet_addEthereumChain") == .chain)
    #expect(MethodPolicy.classify("personal_sign") == .sign)
    #expect(MethodPolicy.classify("eth_signTypedData_v4") == .sign)
    #expect(MethodPolicy.classify("eth_sendTransaction") == .send)
  }

  @Test("unsafe signing methods are denied")
  func denied() {
    for method in [
      "eth_sign",
      "eth_signTransaction",
      "eth_signTypedData",
      "eth_signTypedData_v1",
      "eth_signTypedData_v3",
    ] {
      #expect(MethodPolicy.classify(method) == .denied, "expected \(method) to be denied")
    }
  }

  @Test(
    "every unhandled method passes through",
    arguments: [
      "eth_blockNumber",
      "eth_getBalance",
      "eth_call",
      "eth_getBlockByNumber",
      "net_peerCount",
      "web3_clientVersion",
      "any_custom_thing",
    ])
  func passthrough(_ method: String) {
    #expect(MethodPolicy.classify(method) == .passthrough)
  }

  @Test("classification is case-insensitive")
  func caseInsensitive() {
    #expect(MethodPolicy.classify("PERSONAL_SIGN") == .sign)
    #expect(MethodPolicy.classify("ETH_SIGN") == .denied)
  }

  @Test("approval surfaces guard the wallet-owned subsets")
  func approvalSurface() {
    #expect(MethodPolicy.requiresApproval("eth_requestAccounts"))
    #expect(MethodPolicy.requiresApproval("personal_sign"))
    #expect(MethodPolicy.requiresApproval("eth_sendTransaction"))
    #expect(MethodPolicy.requiresApproval("wallet_addEthereumChain"))
    #expect(!MethodPolicy.requiresApproval("wallet_switchEthereumChain"))
    #expect(!MethodPolicy.requiresApproval("eth_chainId"))
    #expect(!MethodPolicy.requiresApproval("eth_sign"))
    #expect(!MethodPolicy.requiresApproval("eth_blockNumber"))
  }
}

struct OriginTests {
  @Test("normalization binds scheme, host, and effective port")
  func normalize() {
    #expect(Origin.normalize("https://EXAMPLE.com") == "https://example.com")
    #expect(Origin.normalize("https://example.com:443") == "https://example.com")
    #expect(Origin.normalize("http://example.com:8080") == "http://example.com:8080")
    #expect(Origin.normalize("http://example.com:80") == "http://example.com")
    // HTTPS arbitrary port is distinct from the default.
    #expect(Origin.normalize("https://example.com:8443") == "https://example.com:8443")
    // Different schemes never collapse.
    #expect(Origin.normalize("http://example.com") != Origin.normalize("https://example.com"))
    #expect(Origin.normalize(nil) == "unknown")
  }

  @Test("displayHost returns the host for the review surface")
  func displayHost() {
    #expect(Origin.displayHost("https://example.com/path") == "example.com")
    #expect(Origin.displayHost("https://EXAMPLE.com:8443") == "example.com")
    #expect(Origin.displayHost(nil) == "unknown")
  }
}
