import Foundation

/// One authoritative classification of JSON-RPC methods shared by the extension.
public enum MethodClass: Sendable, Equatable {
  case connect  // eth_requestAccounts / wallet_connect
  case chain  // eth_chainId / net_version / wallet_switchEthereumChain / wallet_addEthereumChain
  case sign  // personal_sign / eth_signTypedData_v4 / eth_signTypedData_v3
  case send  // eth_sendTransaction
  case denied  // explicitly unsafe signing methods
  case passthrough  // everything else goes to the RPC endpoint
}

public enum MethodPolicy {
  private static let signMethods: Set<String> = ["personal_sign", "eth_signtypeddata_v4"]
  private static let deniedMethods: Set<String> = [
    "eth_sign", "eth_signtransaction", "eth_signtypeddata", "eth_signtypeddata_v1",
    "eth_signtypeddata_v3",
  ]
  private static let chainMethods: Set<String> = [
    "eth_chainid", "net_version", "wallet_switchethereumchain", "wallet_addethereumchain",
  ]
  private static let sendMethods: Set<String> = ["eth_sendtransaction", "wallet_sendcalls"]

  public static func classify(_ method: String) -> MethodClass {
    let method = method.lowercased()
    if deniedMethods.contains(method) { return .denied }
    if signMethods.contains(method) { return .sign }
    if sendMethods.contains(method) { return .send }
    if chainMethods.contains(method) { return .chain }
    if method == "eth_requestaccounts" || method == "wallet_connect" { return .connect }
    return .passthrough
  }

  /// Whether a method should present an approval surface for this prototype slice.
  public static func requiresApproval(_ kind: MethodClass) -> Bool {
    switch kind {
    case .connect, .sign, .send, .chain: return true
    case .denied, .passthrough: return false
    }
  }
}
