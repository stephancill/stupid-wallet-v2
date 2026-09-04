import Foundation
@preconcurrency import Intents
import OSLog
import StupidWalletCore
@preconcurrency import UserNotifications

private let notificationLogger = Logger(
  subsystem: "co.za.stephancill.stupid-wallet.notification-service",
  category: "delivery")

/// The Notification Service Extension resolves local display state from the opaque,
/// installation-scoped registration id and renders a Communication Notification whose
/// left-side avatar is a locally generated blockie. It never receives or holds a private
/// key, an installation key, an APNs token, or any backend credential, and it never reads
/// the wallet registry beyond non-secret display state.
public class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
  private let deliveryLock = NSLock()
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNNotificationContent?

  public override init() {
    super.init()
  }

  public override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    notificationLogger.notice("Processing mutable notification")
    let userInfo = request.content.userInfo

    // Bounded, type-safe extraction. Anything malformed falls back to the base alert.
    let eventKind = parseKind(userInfo["eventKind"])
    let registrationID = stringValue(userInfo["addressRegistrationId"])
    let chainID = stringValue(userInfo["chainId"])

    // Resolve local display state (account label + address seed). Enrollment writes the
    // non-secret display map; its absence just means a generic fallback is rendered.
    let display = NotificationDisplayResolver.Display.resolve(
      registrationID: registrationID, chainID: chainID)
    let subject = notificationSubject(value: userInfo["subject"], fallback: eventKind.title)

    guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    let context = notificationContext(display: display, chainID: chainID)
    mutable.title = subject
    mutable.body = context
    mutable.subtitle = ""
    mutable.attachments = []

    deliveryLock.lock()
    self.contentHandler = contentHandler
    bestAttemptContent = mutable
    deliveryLock.unlock()

    guard
      let avatarData = NotificationBlockie.renderPNG(
        seed: display.addressSeed, pixelsPerCell: 16)
    else {
      finish(with: mutable)
      return
    }

    let handleValue = registrationID.isEmpty ? "wallet-\(chainID)" : registrationID
    let sender = INPerson(
      personHandle: INPersonHandle(value: handleValue, type: .unknown),
      nameComponents: nil,
      displayName: subject,
      image: INImage(imageData: avatarData),
      contactIdentifier: nil,
      customIdentifier: handleValue,
      isMe: false,
      suggestionType: .none)
    let intent = INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: context,
      speakableGroupName: nil,
      conversationIdentifier: "\(handleValue):\(chainID)",
      serviceName: "stupid wallet",
      sender: sender,
      attachments: nil)
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate { [self] error in
      if error != nil {
        notificationLogger.error("Communication interaction donation failed")
        finish(with: mutable)
        return
      }
      do {
        let updated = try mutable.updating(from: intent)
        notificationLogger.notice("Returning Communication Notification")
        finish(with: updated)
      } catch {
        notificationLogger.error("Communication notification update failed")
        finish(with: mutable)
      }
    }
  }

  public override func serviceExtensionTimeWillExpire() {
    if let bestAttemptContent {
      finish(with: bestAttemptContent)
    }
  }

  // MARK: - Parsing

  private func parseKind(_ value: Any?) -> NotificationEventKind {
    guard let raw = value as? String else { return .activityDetected }
    return NotificationEventKind(rawValue: raw) ?? .activityDetected
  }

  private func stringValue(_ value: Any?) -> String {
    (value as? String) ?? ""
  }

  private func notificationSubject(value: Any?, fallback: String) -> String {
    guard let raw = value as? String else { return fallback }
    let subject = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !subject.isEmpty, subject.count <= 120, !subject.contains(where: { $0.isNewline })
    else { return fallback }
    return subject
  }

  private func chainDisplayName(_ chainID: String) -> String {
    switch chainID {
    case "1": return "Ethereum"
    case "137": return "Polygon"
    case "8453": return "Base"
    default: return "Chain \(chainID)"
    }
  }

  private func notificationContext(
    display: NotificationDisplayResolver.Display, chainID: String
  ) -> String {
    let chain = chainDisplayName(chainID)
    return display.label.isEmpty ? chain : "\(display.label) • \(chain)"
  }

  private func finish(with content: UNNotificationContent) {
    deliveryLock.lock()
    let handler = contentHandler
    contentHandler = nil
    bestAttemptContent = nil
    deliveryLock.unlock()
    handler?(content)
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
      guard !registrationID.isEmpty else {
        return Display(label: "", addressSeed: "notification-\(chainID)")
      }
      if let alias = NotificationDisplayStore.read().aliases[registrationID] {
        return Display(label: alias.label, addressSeed: alias.address.lowercased())
      }
      return Display(label: "", addressSeed: "notification-\(chainID)")
    }
  }
}
