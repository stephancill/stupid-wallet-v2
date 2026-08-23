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
  private static func makeSigning() -> any Signing {
    let store = KeychainKeyStore()
    // The active address is read from the shared App Group file first (works reliably
    // across app and extension processes), with a UserDefaults fallback for pre-existing
    // wallets written before the file store existed.
    let address =
      WalletStore.activeAddress()
      ?? UserDefaults(suiteName: PendingRequestStore.defaultAppGroup)?
      .string(forKey: WalletFactory.walletAddressKey)
    if let address {
      return KeychainSigner(account: address, store: store)
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
    // A fresh service per native message resolves the current wallet account lazily.
    let service = WalletService(signing: Self.makeSigning(), resolver: .persisted())
    let box = ContextBox(context)
    Task {
      let response = await Server.dispatch(
        service: service, envelope: envelope, profileID: profileID)
      let responseItem = NSExtensionItem()
      responseItem.userInfo = [SFExtensionMessageKey: response.unwrapped]
      box.context.completeRequest(returningItems: [responseItem], completionHandler: nil)
    }
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
    case "me":
      return success(["account": .string(service.account)])

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
      return success([
        "connected": .bool(await service.isConnected(origin: origin, profileID: profileID))
      ])

    case "listSites":
      let sites = await service.connectedSitesList()
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
      await service.disconnect(origin: origin, profileID: profileID)
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

    case "list":
      do {
        let summaries = try await service.list(profileID: profileID)
        return success(["pending": .array(summaries.map(summaryJSON))])
      } catch {
        return failure("list failed")
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
          profileID: profileID
        )
        return success(["requestId": .string(id.uuidString)])
      } catch WalletError.methodNotApproved {
        return errorJSON(4200, "Method not approved")
      } catch WalletError.notReady {
        return errorJSON(4900, "No wallet key is available yet")
      } catch WalletError.invalidParams {
        return errorJSON(-32602, "Invalid transaction parameters")
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
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      do {
        let result = try await service.approve(request: uuid, profileID: profileID)
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
        return errorJSON(-32602, "Request payload changed")
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
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      do {
        try await service.reject(request: uuid, profileID: profileID)
        return success(["ok": .bool(true)])
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
      "title": .string(summary.title),
      "queued": .bool(summary.queued),
      "rows": .array(
        summary.rows.map {
          .object(["label": .string($0.label), "value": .string($0.value)])
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
  let params: JSONValue?
  let payload: JSONValue?

  static func parse(_ message: Any) -> Envelope {
    guard let dict = message as? [String: Any],
      let data = try? JSONSerialization.data(withJSONObject: dict),
      let json = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let object) = json
    else {
      return Envelope(
        action: "unknown", method: nil, origin: nil, chainId: nil, params: nil, payload: nil)
    }

    return Envelope(
      action: object["action"]?.stringValue ?? "unknown",
      method: object["method"]?.stringValue,
      origin: object["origin"]?.stringValue,
      chainId: object["chainId"]?.stringValue,
      params: object["params"],
      payload: object["payload"]
    )
  }

  func requestID() -> UUID? {
    guard case .object(let object) = payload else { return nil }
    return object["requestId"]?.stringValue.flatMap(UUID.init(uuidString:))
  }
}

extension JSONValue {
  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}
