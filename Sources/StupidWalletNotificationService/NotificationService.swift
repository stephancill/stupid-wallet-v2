import Foundation
import StupidWalletCore
import UserNotifications

/// The Notification Service Extension resolves local display state from the opaque,
/// installation-scoped registration id and renders `<account label> • <chain>` with a
/// locally generated blockie. It never receives or holds a private key, an installation
/// key, an APNs token, or any backend credential, and it never reads the wallet registry
/// beyond non-secret display state.
public class NotificationService: UNNotificationServiceExtension {
  public override init() {
    super.init()
  }

  public override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let userInfo = request.content.userInfo

    // Bounded, type-safe extraction. Anything malformed falls back to the base alert.
    let eventKind = parseKind(userInfo["eventKind"])
    let registrationID = stringValue(userInfo["addressRegistrationId"])
    let chainID = stringValue(userInfo["chainId"])

    // Resolve local display state (account label + address seed). Enrollment writes the
    // non-secret display map; its absence just means a generic fallback is rendered.
    let display = NotificationDisplayResolver.Display.resolve(
      registrationID: registrationID, chainID: chainID)

    guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    mutable.title = eventKind.title
    mutable.subtitle =
      display.label.isEmpty
      ? chainDisplayName(chainID)
      : "\(display.label) • \(chainDisplayName(chainID))"

    // Locally generated blockie attachment from the address seed.
    if let png = NotificationBlockie.renderPNG(seed: display.addressSeed, pixelsPerCell: 16),
      let written = writeToTempFile(png),
      let attachment = try? UNNotificationAttachment(
        identifier: "blockie", url: written, options: nil)
    {
      mutable.attachments = [attachment]
    }

    contentHandler(mutable)
  }

  public override func serviceExtensionTimeWillExpire() {
    // iOS displays the generic fallback from the base payload.
  }

  // MARK: - Parsing

  private func parseKind(_ value: Any?) -> NotificationEventKind {
    guard let raw = value as? String else { return .activityDetected }
    return NotificationEventKind(rawValue: raw) ?? .activityDetected
  }

  private func stringValue(_ value: Any?) -> String {
    (value as? String) ?? ""
  }

  private func chainDisplayName(_ chainID: String) -> String {
    switch chainID {
    case "1": return "Ethereum"
    case "137": return "Polygon"
    case "8453": return "Base"
    default: return "Chain \(chainID)"
    }
  }

  private func writeToTempFile(_ data: Data) -> URL? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("blockie-\(UUID().uuidString).png")
    do {
      try data.write(to: url)
      return url
    } catch {
      return nil
    }
  }
}

/// Resolves the opaque registration id into display state to keep even the account
/// address off the APNs payload.
private struct NotificationDisplayResolver {
  struct Display {
    /// Human account label. Empty when the display map is unknown.
    let label: String
    /// The address-derived blockie seed (lowercased) or a stable fallback seed.
    let addressSeed: String

    static func resolve(registrationID: String, chainID: String) -> Display {
      guard !registrationID.isEmpty, let mappingURL = NotificationDisplayState.mappingURL else {
        return Display(label: "", addressSeed: "notification-\(chainID)")
      }
      let state = NotificationDisplayState.load(from: mappingURL)
      if let alias = state.alias(for: registrationID) {
        return Display(label: alias.label, addressSeed: alias.address.lowercased())
      }
      return Display(label: "", addressSeed: "notification-\(chainID)")
    }
  }
}

/// Shared non-secret mapping written by the containing app so the extension can resolve
/// opaque registration ids without holding any wallet authority.
private enum NotificationDisplayState {
  struct Alias: Codable {
    let label: String
    let address: String
  }

  struct State: Codable {
    var aliases: [String: Alias]

    func alias(for registrationID: String) -> Alias? {
      aliases[registrationID]
    }
  }

  static var mappingURL: URL? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.co.za.stephancill.stupid-wallet")
    else { return nil }
    return container.appendingPathComponent("notificationDisplay.json")
  }

  static func load(from url: URL) -> State {
    guard let data = try? Data(contentsOf: url),
      let state = try? JSONDecoder().decode(State.self, from: data)
    else {
      return State(aliases: [:])
    }
    return state
  }
}
