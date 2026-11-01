import Testing

@testable import StupidWalletCore

@Suite struct WalletMetricsTests {
  @Test func transactionsCarrySourceAndChain() {
    let dapp = WalletMetrics.event(
      for: .init(kind: .send, chainID: "8453", isWalletOriginated: false), outcome: "error")
    #expect(dapp.name == "transaction")
    #expect(dapp.props == ["kind": "send", "outcome": "error", "chain": "8453", "source": "dapp"])

    let app = WalletMetrics.event(
      for: .init(kind: .batch, chainID: "1", isWalletOriginated: true), outcome: "ok")
    #expect(app.name == "transaction")
    #expect(app.props["source"] == "app")
    #expect(app.props["kind"] == "batch")
  }

  @Test func signaturesAndConsentAreSeparateEvents() {
    let typed = WalletMetrics.event(
      for: .init(kind: .typedData, chainID: "1", isWalletOriginated: false), outcome: "cancelled")
    #expect(typed.name == "signature")
    #expect(typed.props == ["kind": "typed_data", "outcome": "cancelled"])

    let connect = WalletMetrics.event(
      for: .init(kind: .connect, chainID: "1", isWalletOriginated: false), outcome: "rejected")
    #expect(connect.name == "request")
    #expect(connect.props == ["kind": "connect", "outcome": "rejected"])

    let missing = WalletMetrics.event(for: nil, outcome: "error")
    #expect(missing.name == "request")
    #expect(missing.props == ["kind": "unknown", "outcome": "error"])
  }

  @Test func outcomeSeparatesCancelledAuthenticationFromFailures() {
    #expect(WalletMetrics.outcome(for: nil) == "ok")
    #expect(WalletMetrics.outcome(for: WalletError.authCancelled) == "cancelled")
    #expect(WalletMetrics.outcome(for: WalletError.queued) == "error")
    #expect(WalletMetrics.outcome(for: WalletError.rpc(.null)) == "error")
  }

  @Test func errorPropsKeepOnlyTheJSONRPCCode() {
    let nodeError = WalletError.rpc(
      .object(["code": .number(-32000), "message": .string("insufficient funds for 0xabc")]))
    #expect(WalletMetrics.errorProps(for: nodeError) == ["code": "-32000"])
    #expect(WalletMetrics.errorProps(for: WalletError.rpc(.string("x"))) == [:])
    #expect(WalletMetrics.errorProps(for: WalletError.expired) == [:])
  }
}
