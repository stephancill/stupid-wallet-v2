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

    let json: JSONValue
    if let data = try? JSONSerialization.data(withJSONObject: message),
      let value = try? JSONValue.parse(data)
    {
      json = value
    } else {
      json = .null
    }
    let envelope = NativeWalletEnvelope(json)
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
    envelope: NativeWalletEnvelope, profileID: String?
  ) async -> JSONValue {
    let service: WalletService
    do {
      let adopted = try await WalletRegistryAdoption().ensureAdopted()
      guard let registry = adopted.registry else {
        return NativeWalletDispatcher.errorJSON(4900, "Wallet is not ready yet")
      }
      service = WalletService(
        signing: makeSigning(registry: registry), resolver: .persisted(),
        registryStore: WalletRegistryStore(), accountResolver: WalletAccountResolver())
    } catch {
      return NativeWalletDispatcher.errorJSON(4900, "Wallet is not ready yet")
    }
    return await NativeWalletDispatcher.dispatch(
      service: service, envelope: envelope, profileID: profileID)
  }
}

private struct ContextBox: @unchecked Sendable {
  let context: NSExtensionContext
  init(_ context: NSExtensionContext) { self.context = context }
}
