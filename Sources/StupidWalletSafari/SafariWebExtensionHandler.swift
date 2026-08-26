import Foundation
import SafariServices
import StupidWalletCore

/// Native bridge between the JavaScript extension scripts and the wallet core.
/// Each message is a JSON envelope under `SFExtensionMessageKey`. This handler is an
/// orchestrator only; it never reimplements policy, serialization, or signing.
public final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  public override init() {
    super.init()
  }

  /// Builds the `Signing` capability from the wallet state at the moment of the request.
  /// The active account is resolved lazily from the App Group default so a wallet created
  /// (or migrated) after the extension process was launched is picked up, and so the
  /// `.keychain` `.usePresence` item is never touched for an existence probe.
  private static func makeSigning(registry: WalletRegistry) -> any Signing {
    let address = registry.homeSelectedAddress
    if let address, let signer = try? WalletAccountResolver().signer(address: address) {
      return signer
    }
    return UnavailableSigner()
  }

  public func beginRequest(with context: NSExtensionContext) {
    guard let item = context.inputItems.first as? NSExtensionItem,
      let userInfo = item.userInfo,
      let message = userInfo[SFExtensionMessageKey]
    else {
      context.completeRequest(returningItems: [], completionHandler: nil)
      return
    }

    let envelope = Envelope.parse(message)
    let profileID: String?
    if let profile = userInfo[SFExtensionProfileKey] as? UUID {
      profileID = profile.uuidString.lowercased()
    } else if let profile = userInfo[SFExtensionProfileKey] as? NSUUID {
      profileID = profile.uuidString.lowercased()
    } else {
      profileID = userInfo[SFExtensionProfileKey] as? String
    }
    let box = ContextBox(context)
    Task { @Sendable in
      let response = await Self.dispatchAdoptedIfReady(
        envelope: envelope, profileID: profileID)
      let responseItem = NSExtensionItem()
      responseItem.userInfo = [SFExtensionMessageKey: response.unwrapped]
      box.context.completeRequest(returningItems: [responseItem], completionHandler: nil)
    }
  }

  /// Runs the idempotent adoption barrier; a throwing barrier fails closed with a
  /// structured not-ready response, otherwise request handling proceeds through a
  /// registry-gated service.
  private static nonisolated func dispatchAdoptedIfReady(
    envelope: Envelope, profileID: String?
  ) async -> JSONValue {
    let service: WalletService
    do {
      let adopted = try await WalletRegistryAdoption().ensureAdopted()
      guard let registry = adopted.registry else {
        return Server.errorJSON(4900, "Wallet is not ready yet")
      }
      service = WalletService(
        signing: makeSigning(registry: registry), resolver: .persisted(),
        registryStore: WalletRegistryStore(), accountResolver: WalletAccountResolver())
    } catch {
      return Server.errorJSON(4900, "Wallet is not ready yet")
    }
    return await Server.dispatch(service: service, envelope: envelope, profileID: profileID)
  }
}

private struct ContextBox: @unchecked Sendable {
  let context: NSExtensionContext
  init(_ context: NSExtensionContext) { self.context = context }
}

private enum Server {
  static func dispatch(
    service: WalletService, envelope: Envelope, profileID: String?
  ) async -> JSONValue {
    switch envelope.action {
    case "visibleAccounts":
      do {
        let accounts = try await service.visibleAccounts(
          origin: envelope.origin ?? "unknown", profileID: profileID)
        return success(["accounts": .array(accounts.map(JSONValue.string))])
      } catch {
        return errorJSON(4900, "Connection state is unavailable")
      }

    case "chain":
      guard let state = try? await service.activeChainState(),
        let hex = ChainStore.hexChainID(state.chainID)
      else {
        return errorJSON(-32603, "Invalid active chain")
      }
      return success([
        "chainId": .string(state.chainID),
        "chainIdHex": .string(hex),
        "recoveredSwitch": .bool(state.recoveredSwitch),
      ])

    case "isConnected":
      let origin = envelope.origin ?? "unknown"
      guard let connected = try? await service.isConnected(origin: origin, profileID: profileID)
      else { return errorJSON(4900, "Connection state is unavailable") }
      return success([
        "connected": .bool(connected)
      ])

    case "listSites":
      guard let sites = try? await service.connectedSitesList() else {
        return errorJSON(4900, "Connection state is unavailable")
      }
      return success([
        "sites": .array(
          sites.map {
            .object([
              "domain": .string($0.domain),
              "address": .string($0.address),
            ])
          })
      ])

    case "disconnectSite":
      let origin = envelope.origin ?? "unknown"
      do {
        try await service.disconnect(origin: origin, profileID: profileID)
      } catch {
        return errorJSON(4900, "Connection state is unavailable")
      }
      return success(["ok": .bool(true)])

    case "passthrough":
      let method = envelope.method ?? ""
      guard !method.isEmpty else { return failure("missing method") }
      guard let activeChainID = try? await service.activeChainID() else {
        return errorJSON(4900, "Active chain is unavailable")
      }
      let outcome = await service.passthrough(
        method: method,
        params: envelope.params ?? .array([]),
        chainID: activeChainID
      )
      switch outcome {
      case .result(let value):
        return success(["result": value])
      case .nodeError(let nodeError):
        // Preserve the structured node error object; it has no "data" envelope.
        return .object(["ok": .bool(false), "error": nodeError])
      }

    case "switchChain":
      do {
        let result = try await service.switchChain(
          params: envelope.params ?? .array([]),
          origin: envelope.origin ?? "unknown",
          profileID: profileID)
        return success(["result": result])
      } catch WalletError.invalidParams {
        return errorJSON(-32602, "Invalid chain parameters")
      } catch WalletError.unauthorized {
        return errorJSON(4100, "Origin is not connected")
      } catch WalletError.notReady {
        return errorJSON(4900, "No wallet key is available yet")
      } catch WalletError.queued {
        return errorJSON(-32000, "Another chain switch is in progress")
      } catch {
        return errorJSON(4900, "Active chain is unavailable")
      }

    case "getCapabilities":
      do {
        let result = try await service.getCapabilities(
          params: envelope.params ?? .array([]), origin: envelope.origin ?? "unknown",
          profileID: profileID)
        return success(["result": result])
      } catch WalletError.invalidParams {
        return errorJSON(-32602, "Invalid capabilities parameters")
      } catch WalletError.unauthorized {
        return errorJSON(4100, "Unauthorized")
      } catch WalletError.notReady {
        return errorJSON(4900, "No wallet key is available yet")
      } catch WalletError.rpc(let error) {
        return .object(["ok": .bool(false), "error": error])
      } catch {
        return failure("capabilities failed")
      }

    case "getCallsStatus":
      do {
        let result = try await service.getCallsStatus(
          params: envelope.params ?? .array([]), origin: envelope.origin ?? "unknown",
          profileID: profileID)
        return success(["result": result])
      } catch WalletError.invalidParams {
        return errorJSON(-32602, "Invalid calls status parameters")
      } catch WalletError.unauthorized {
        return errorJSON(4100, "Unauthorized")
      } catch WalletError.notReady {
        return errorJSON(4900, "No wallet key is available yet")
      } catch WalletError.rpc(let error) {
        return .object(["ok": .bool(false), "error": error])
      } catch {
        return failure("calls status failed")
      }

    case "list":
      do {
        let summaries = try await service.list(profileID: profileID)
        return success(["pending": .array(summaries.map(summaryJSON))])
      } catch {
        return failure("list failed")
      }

    case "connectAccounts":
      guard let uuid = envelope.requestID(), let revision = envelope.reviewedRevision() else {
        return errorJSON(-32602, "Invalid account-list request")
      }
      do {
        guard let summary = try await service.summarize(request: uuid, profileID: profileID),
          summary.kind == RequestKind.connect.rawValue, !summary.queued,
          summary.revision == revision
        else {
          return errorJSON(-32602, "Connect review changed; reload the request")
        }
        let groups = try await service.availableAccountGroups()
        return success([
          "groups": .array(groups.map(accountGroupJSON))
        ])
      } catch {
        return errorJSON(4900, "Wallet accounts are unavailable")
      }

    case "rebindConnect":
      guard let uuid = envelope.requestID(), let revision = envelope.reviewedRevision(),
        let account = envelope.selectedAccount()
      else {
        return errorJSON(-32602, "Invalid account selection")
      }
      do {
        try await service.rebindConnect(
          request: uuid, account: account, reviewedRevision: revision, profileID: profileID)
        guard let summary = try await service.summarize(request: uuid, profileID: profileID) else {
          return errorJSON(4100, "Request no longer exists")
        }
        return success(["summary": summaryJSON(summary)])
      } catch WalletError.queued {
        return errorJSON(-32000, "An earlier request must be handled first")
      } catch WalletError.alreadyConsumed {
        return errorJSON(4001, "Request already handled")
      } catch WalletError.bindingMismatch {
        return errorJSON(-32602, "Connect review changed; reload the request")
      } catch {
        return errorJSON(4900, "Account selection failed")
      }

    case "prepare":
      let method = envelope.method ?? ""
      guard !method.isEmpty else { return failure("missing method") }
      guard let activeChainID = try? await service.activeChainID() else {
        return errorJSON(4900, "Active chain is unavailable")
      }
      do {
        let id = try await service.prepare(
          method: method,
          params: envelope.params ?? .array([]),
          origin: envelope.origin ?? "unknown",
          chainId: activeChainID,
          profileID: profileID,
          requestKey: envelope.requestKey
        )
        return success(["requestId": .string(id.uuidString)])
      } catch WalletError.methodNotApproved {
        return errorJSON(4200, "Method not approved")
      } catch WalletError.notReady {
        return errorJSON(4900, "No wallet key is available yet")
      } catch WalletError.invalidParams {
        return errorJSON(-32602, "Invalid request parameters")
      } catch WalletError.unauthorized {
        return errorJSON(4100, "Origin is not connected")
      } catch WalletError.rpc(let error) {
        return .object(["ok": .bool(false), "error": error])
      } catch {
        return failure("prepare failed")
      }

    case "summary":
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      guard let summary = try? await service.summarize(request: uuid, profileID: profileID) else {
        return failure("not found")
      }
      return successObject(summaryJSON(summary))

    case "approve":
      guard let uuid = envelope.requestID(), let revision = envelope.reviewedRevision() else {
        return errorJSON(-32602, "Invalid reviewed request")
      }
      do {
        let result = try await service.approve(
          request: uuid, profileID: profileID, reviewedRevision: revision)
        return success(["result": result])
      } catch WalletError.notFound {
        return errorJSON(4100, "Request no longer exists")
      } catch WalletError.alreadyConsumed {
        return errorJSON(4001, "Request already handled")
      } catch WalletError.expired {
        return errorJSON(4001, "Request expired")
      } catch WalletError.queued {
        return errorJSON(-32000, "An earlier request must be handled first")
      } catch WalletError.bindingMismatch {
        return errorJSON(-32602, "Request review changed; reload the request")
      } catch WalletError.authCancelled {
        return errorJSON(4001, "User rejected")
      } catch WalletError.rpc(let error) {
        return .object(["ok": .bool(false), "error": error])
      } catch {
        return failure("approve failed")
      }

    case "get":
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      if let status = await service.status(for: uuid, profileID: profileID) {
        var object: [String: JSONValue] = ["status": .string(status.status)]
        if let result = status.result {
          object["result"] = result
        }
        if let error = status.error {
          object["error"] = error
        }
        return success(object)
      }
      return failure("not found")

    case "reject":
      guard let uuid = envelope.requestID(), let revision = envelope.reviewedRevision() else {
        return errorJSON(-32602, "Invalid reviewed request")
      }
      do {
        try await service.reject(
          request: uuid, profileID: profileID, reviewedRevision: revision)
        return success(["ok": .bool(true)])
      } catch WalletError.bindingMismatch {
        return errorJSON(-32602, "Request review changed; reload the request")
      } catch WalletError.alreadyConsumed {
        return errorJSON(4001, "Request already handled")
      } catch WalletError.queued {
        return errorJSON(-32000, "An earlier request must be handled first")
      } catch {
        return failure("reject failed")
      }

    default:
      return failure("unsupported action")
    }
  }

  private static func summaryJSON(_ summary: WalletService.Summary) -> JSONValue {
    .object([
      "id": .string(summary.id),
      "kind": .string(summary.kind),
      "method": .string(summary.method),
      "origin": .string(summary.origin),
      "chainId": .string(summary.chainId),
      "account": .string(summary.account),
      "accountLabel": summary.accountLabel.map(JSONValue.string) ?? .null,
      "title": .string(summary.title),
      "queued": .bool(summary.queued),
      "revision": .number(Double(summary.revision)),
      "rows": .array(
        summary.rows.map {
          .object(["label": .string($0.label), "value": .string($0.value)])
        }),
    ])
  }

  private static func accountGroupJSON(_ group: WalletService.AvailableAccountGroup) -> JSONValue {
    .object([
      "id": .string(group.id.uuidString.lowercased()),
      "kind": .string(group.kind.rawValue),
      "accounts": .array(
        group.accounts.map { account in
          var value: [String: JSONValue] = ["address": .string(account.address)]
          if let index = account.derivationIndex {
            value["derivationIndex"] = .number(Double(index))
          }
          return .object(value)
        }),
    ])
  }

  static func success(_ data: [String: JSONValue]) -> JSONValue {
    .object(["ok": .bool(true), "data": .object(data)])
  }

  static func successObject(_ object: JSONValue) -> JSONValue {
    .object(["ok": .bool(true), "data": object])
  }

  static func failure(_ message: String) -> JSONValue {
    .object(["ok": .bool(false), "error": .string(message)])
  }

  static func errorJSON(_ code: Int, _ message: String) -> JSONValue {
    .object([
      "ok": .bool(false),
      "error": .object([
        "code": .number(Double(code)),
        "message": .string(message),
      ]),
    ])
  }
}

private struct Envelope {
  let action: String
  let method: String?
  let origin: String?
  let chainId: String?
  let requestKey: String?
  let params: JSONValue?
  let payload: JSONValue?

  static func parse(_ message: Any) -> Envelope {
    guard let dict = message as? [String: Any],
      let data = try? JSONSerialization.data(withJSONObject: dict),
      let json = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let object) = json
    else {
      return Envelope(
        action: "unknown", method: nil, origin: nil, chainId: nil, requestKey: nil, params: nil,
        payload: nil)
    }

    return Envelope(
      action: object["action"]?.stringValue ?? "unknown",
      method: object["method"]?.stringValue,
      origin: object["origin"]?.stringValue,
      chainId: object["chainId"]?.stringValue,
      requestKey: object["requestKey"]?.stringValue,
      params: object["params"],
      payload: object["payload"]
    )
  }

  func requestID() -> UUID? {
    guard case .object(let object) = payload else { return nil }
    return object["requestId"]?.stringValue.flatMap(UUID.init(uuidString:))
  }

  func reviewedRevision() -> UInt64? {
    guard case .object(let object) = payload, case .number(let value)? = object["revision"],
      value.isFinite, value >= 0, value.rounded(.towardZero) == value,
      value <= 9_007_199_254_740_991
    else { return nil }
    return UInt64(value)
  }

  func selectedAccount() -> String? {
    guard case .object(let object) = payload else { return nil }
    return object["account"]?.stringValue
  }
}

extension JSONValue {
  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}
