import Foundation
import SafariServices
import StupidWalletCore

/// Native bridge between the JavaScript extension scripts and the wallet core.
/// Each message is a JSON envelope under `SFExtensionMessageKey`. This handler is an
/// orchestrator only; it never reimplements policy, serialization, or signing.
public final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  private let service: WalletService

  public override init() {
    service = WalletService()
    super.init()
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
    let service = self.service
    let box = ContextBox(context)
    Task {
      let response = await Server.dispatch(service: service, envelope: envelope)
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
  static func dispatch(service: WalletService, envelope: Envelope) async -> JSONValue {
    switch envelope.action {
    case "me":
      return success(["account": .string(service.account.address)])

    case "list":
      do {
        let summaries = try await service.list()
        let items = summaries.map { summary -> JSONValue in
          var o: [String: JSONValue] = [
            "id": .string(summary.id),
            "method": .string(summary.method),
            "origin": .string(summary.origin),
            "chainId": .string(summary.chainId),
            "account": .string(summary.account),
          ]
          if let message = summary.message {
            o["message"] = .string(message)
          }
          return .object(o)
        }
        return success(["pending": .array(items)])
      } catch {
        return failure("list failed")
      }

    case "prepare":
      let method = envelope.method ?? ""
      guard !method.isEmpty else { return failure("missing method") }
      do {
        let id = try await service.prepare(
          method: method,
          params: envelope.params ?? .array([]),
          origin: envelope.origin ?? "unknown",
          chainId: envelope.chainId ?? "1"
        )
        return success(["requestId": .string(id.uuidString)])
      } catch {
        return failure("prepare failed")
      }

    case "summary":
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      do {
        let summary = try await service.summary(for: uuid)
        var object: [String: JSONValue] = [
          "id": .string(summary.id),
          "method": .string(summary.method),
          "origin": .string(summary.origin),
          "chainId": .string(summary.chainId),
          "account": .string(summary.account),
        ]
        if let message = summary.message {
          object["message"] = .string(message)
        }
        return success(object)
      } catch {
        return failure("summary failed")
      }

    case "approve":
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      do {
        let signature = try await service.approve(request: uuid)
        return success(["signature": signature])
      } catch {
        return failure("approve failed")
      }

    case "get":
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      if let status = await service.status(for: uuid) {
        var object: [String: JSONValue] = ["status": .string(status.status)]
        if let result = status.result {
          object["result"] = result
        }
        return success(object)
      }
      return failure("not found")

    case "reject":
      guard let uuid = envelope.requestID() else { return failure("invalid requestId") }
      do {
        try await service.reject(request: uuid)
        return success(["ok": .bool(true)])
      } catch {
        return failure("reject failed")
      }

    default:
      return failure("unsupported action")
    }
  }

  static func success(_ data: [String: JSONValue]) -> JSONValue {
    .object(["ok": .bool(true), "data": .object(data)])
  }

  static func failure(_ message: String) -> JSONValue {
    .object(["ok": .bool(false), "error": .string(message)])
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
