import Foundation
import StupidMetrics
import os

/// Every anonymous usage event and error the wallet reports to metrics.stupidtech.net, in one
/// place. Properties are request kinds, decimal chain IDs, outcomes and JSON-RPC error codes
/// only: never addresses, origins, hashes, payloads, amounts or node error messages. Errors are
/// sent as their type and case (`StupidMetrics.describe`), never `localizedDescription`.
public enum WalletMetrics {
  /// The process that recorded an event. The app, Safari extension and Chrome helper each keep
  /// their own anonymous install id and queue.
  public enum Surface: String, Sendable {
    case app
    case safari
    case chrome
  }

  /// Public client key for the wallet's metrics; it only allows sending events.
  private static let appKey = "smk_fozSVS8q0JKO81FL48K6gU3wmxd2myvd"
  /// Shared through the App Group so the app's Settings choice also governs the extension and
  /// helper processes, whose `UserDefaults.standard` is separate.
  private static let disabledKey = "metrics.disabled"
  private static let surface = OSAllocatedUnfairLock<Surface?>(initialState: nil)

  private static var sharedDefaults: UserDefaults {
    UserDefaults(suiteName: PendingRequestStore.defaultAppGroup) ?? .standard
  }

  /// Starts collection once per process; later calls only re-apply the shared opt-out.
  @MainActor
  public static func configure(surface: Surface) {
    StupidMetrics.isEnabled = isEnabled
    let isFirst = Self.surface.withLock { current in
      guard current == nil else { return false }
      current = surface
      return true
    }
    if isFirst { StupidMetrics.configure(appKey: appKey) }
  }

  /// Whether the user shares anonymous usage data (Settings → Share Usage Data).
  public static var isEnabled: Bool {
    get { !sharedDefaults.bool(forKey: disabledKey) }
    set {
      sharedDefaults.set(!newValue, forKey: disabledKey)
      StupidMetrics.isEnabled = newValue
    }
  }

  /// Sends everything queued now. Extension processes call this after a review outcome because
  /// they never see the app lifecycle notifications that otherwise trigger a send.
  public static func flush() async {
    await StupidMetrics.flush()
  }

  // MARK: Requests

  /// A reviewed request was approved (and, for signing kinds, signed or broadcast) or failed.
  static func requestApproved(_ request: RequestContext?, error: (any Error)?) {
    record(request, outcome: outcome(for: error), error: error)
  }

  /// A pending request was rejected from its review surface, including rejections the extension
  /// issues when the requesting tab closes or navigates.
  static func requestRejected(_ request: RequestContext?) {
    record(request, outcome: "rejected", error: nil)
  }

  /// A transaction's final onchain or mempool status was observed by activity refresh.
  static func transactionResolved(chainID: String, status: ActivityStatus) {
    track("transaction_result", ["chain": chainID, "status": status.rawValue])
    if status != .confirmed {
      reportError("transaction_not_confirmed", message: status.rawValue, ["chain": chainID])
    }
  }

  /// The metadata metrics may read from a request record.
  struct RequestContext: Sendable, Equatable {
    var kind: RequestKind
    var chainID: String
    var isWalletOriginated: Bool

    init(kind: RequestKind, chainID: String, isWalletOriginated: Bool) {
      self.kind = kind
      self.chainID = chainID
      self.isWalletOriginated = isWalletOriginated
    }

    init(_ record: WalletPendingRequest) {
      self.init(
        kind: record.kind, chainID: record.chainId,
        isWalletOriginated: record.origin == WalletService.walletOriginatedOrigin)
    }
  }

  /// Event name and props for a request outcome: transactions, signatures and the
  /// consent-only kinds (connect, chain) are separate events so each reads on its own.
  static func event(for request: RequestContext?, outcome: String) -> (
    name: String, props: [String: String]
  ) {
    guard let request else { return ("request", ["kind": "unknown", "outcome": outcome]) }
    var props = ["kind": kindName(request.kind), "outcome": outcome]
    switch request.kind {
    case .send, .batch:
      props["chain"] = request.chainID
      props["source"] = request.isWalletOriginated ? "app" : "dapp"
      return ("transaction", props)
    case .message, .typedData, .siwe:
      return ("signature", props)
    case .connect, .chain, .denied, .passthrough:
      return ("request", props)
    }
  }

  /// `ok`, `cancelled` when device-owner authentication was dismissed, otherwise `error`.
  static func outcome(for error: (any Error)?) -> String {
    switch error {
    case nil: "ok"
    case WalletError.authCancelled?: "cancelled"
    default: "error"
    }
  }

  /// Error props: the JSON-RPC code for node, policy and transport errors, never their message.
  static func errorProps(for error: any Error) -> [String: String] {
    guard case WalletError.rpc(let value) = error,
      case .object(let object) = value, case .number(let code)? = object["code"]
    else { return [:] }
    return ["code": String(Int(code))]
  }

  private static func record(_ request: RequestContext?, outcome: String, error: (any Error)?) {
    let event = event(for: request, outcome: outcome)
    track(event.name, event.props)
    // A dismissed Face ID prompt is a user choice, not an issue to triage.
    guard let error, outcome == "error" else { return }
    let props = event.props.filter { $0.key != "outcome" }.merging(errorProps(for: error)) { $1 }
    reportError("\(event.name)_failed", message: StupidMetrics.describe(error), props)
  }

  // Processes that never configure metrics (tests, proofs) record nothing.
  private static func track(_ name: String, _ props: [String: String]) {
    guard let surface = surface.withLock({ $0 }) else { return }
    StupidMetrics.track(name, properties: props.merging(["surface": surface.rawValue]) { $1 })
  }

  private static func reportError(_ name: String, message: String, _ props: [String: String]) {
    guard let surface = surface.withLock({ $0 }) else { return }
    StupidMetrics.error(
      name, message: message, properties: props.merging(["surface": surface.rawValue]) { $1 })
  }

  private static func kindName(_ kind: RequestKind) -> String {
    kind == .typedData ? "typed_data" : kind.rawValue
  }
}
