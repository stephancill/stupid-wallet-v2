import CryptoKit
import StupidWalletCore
import SwiftUI
import UserNotifications

#if canImport(UIKit)
  import UIKit

  @MainActor
  final class NotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate
  {
    static let shared = NotificationCoordinator()

    @Published private(set) var state = NotificationRegistrationState()
    @Published private(set) var isWorking = false
    @Published private(set) var isAvailable = true

    private let store = NotificationRegistrationStore()
    private let displayStore = NotificationDisplayStore()
    private let keyStore = NotificationInstallationKeyStore()
    private let popupKeyStore = NotificationInstallationKeyStore(
      service: "co.za.stephancill.stupid-wallet.notifications.popup",
      accessGroup: KeychainKeyStore.defaultAccessGroup)
    private let client = NotificationInstallationClient()
    private var apnsToken: String?
    private var reconciliationTask: Task<Void, Never>?
    private var didLoadPersistedState = false

    override private init() {
      super.init()
      #if targetEnvironment(macCatalyst)
        isAvailable = false
      #else
        if ProcessInfo.processInfo.isiOSAppOnMac { isAvailable = false }
      #endif
      UNUserNotificationCenter.current().delegate = self
    }

    func load() async {
      guard isAvailable else { return }
      await loadPersistedStateIfNeeded()
      await refreshSettings()
      if !state.enrolledAddresses.isEmpty { UIApplication.shared.registerForRemoteNotifications() }
    }

    func setEnabled(_ enabled: Bool, address: String) async {
      guard isAvailable, !isWorking else { return }
      isWorking = true
      defer { isWorking = false }
      let normalized = address.lowercased()
      do {
        if enabled {
          let allowed = try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound])
          guard allowed else {
            await refreshSettings()
            state.lastPublicError = "Notifications are disabled in Settings."
            try await store.write(state)
            return
          }
          state.enrolledAddresses.insert(normalized)
          try await store.write(state)
          await refreshSettings()
          UIApplication.shared.registerForRemoteNotifications()
          if apnsToken != nil { await reconcile() }
        } else {
          state.enrolledAddresses.remove(normalized)
          state.displayLabelsByAddress.removeValue(forKey: normalized)
          if state.enrolledAddresses.isEmpty {
            await deleteInstallation()
          } else {
            await reconcile()
          }
          try await store.write(state)
        }
      } catch {
        state.lastPublicError = "Notification settings could not be updated."
        try? await store.write(state)
      }
    }

    func updateDisplayAlias(address: String, label: String?) async {
      guard isAvailable, !address.isEmpty else { return }
      await loadPersistedStateIfNeeded()
      let normalized = address.lowercased()
      if let label {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { state.displayLabelsByAddress[normalized] = trimmed }
      }
      if let identity = try? keyStore.loadOrCreate() {
        synchronizeInstallationMetadata(from: identity)
      }
      try? await store.write(state)
      try? await writeDisplayState()
    }

    func foreground() async {
      guard isAvailable else { return }
      await refreshSettings()
      if !state.enrolledAddresses.isEmpty {
        UIApplication.shared.registerForRemoteNotifications()
        if apnsToken != nil { await reconcile() }
      }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
      apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
      await reconcile()
    }

    func didFailToRegisterForRemoteNotifications() async {
      state.lastPublicError = "This device could not register with Apple Push Notification service."
      try? await store.write(state)
    }

    func sendTestNotification() async {
      guard isAvailable, !isWorking, !state.enrolledAddresses.isEmpty else { return }
      isWorking = true
      defer { isWorking = false }
      await reconcile()
      guard state.lastPublicError == nil else { return }
      do {
        try await client.sendTestNotification(identity: keyStore.loadOrCreate())
      } catch {
        state.lastPublicError = "A test notification could not be sent."
        try? await store.write(state)
      }
    }

    nonisolated func userNotificationCenter(
      _: UNUserNotificationCenter,
      willPresent _: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      completionHandler([.banner, .list, .sound])
    }

    private func refreshSettings() async {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      let observation = NotificationSettingsObservation(
        authorization: authorization(settings.authorizationStatus),
        alertSetting: alertSetting(settings.alertSetting),
        observedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1000))
      state.settings = observation
      if observation.authorization == .denied || observation.alertSetting == .disabled {
        if !state.enrolledAddresses.isEmpty {
          await deleteInstallation()
          state.enrolledAddresses = []
        }
      }
      try? await store.write(state)
    }

    private func loadPersistedStateIfNeeded() async {
      guard !didLoadPersistedState else { return }
      defer { didLoadPersistedState = true }
      do {
        state = try await store.read()
      } catch {
        state.lastPublicError = "Notification state is unavailable."
      }
    }

    private func reconcile() async {
      if let reconciliationTask {
        await reconciliationTask.value
        return
      }
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        await self.performReconcile()
      }
      reconciliationTask = task
      await task.value
      reconciliationTask = nil
    }

    private func performReconcile() async {
      guard let apnsToken, !state.enrolledAddresses.isEmpty, let settings = state.settings else {
        return
      }
      guard
        NotificationReconciliationPolicy.isEligible(
          authorization: settings.authorization,
          alertSetting: settings.alertSetting,
          apnsTokenHash: tokenHash(apnsToken))
      else { return }
      do {
        var identity = try keyStore.loadOrCreate()
        if identity.installationID == nil {
          let popupIdentity = try popupKeyStore.loadOrCreate()
          let installationID = try await client.create(
            identity: identity,
            popupPublicKey: popupIdentity.publicKeySPKIBase64URL,
            apnsToken: apnsToken,
            environment: apnsEnvironment,
            settings: settings,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
              as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
          try keyStore.saveInstallationID(installationID)
          identity = try keyStore.loadOrCreate()
        }
        guard identity.installationID != nil else {
          throw NotificationInstallationClientError.invalidResponse
        }
        synchronizeInstallationMetadata(from: identity)
        try await store.write(state)
        try await writeDisplayState()
        let chains = Set(try NetworkStore().all().map(\.id))
        if chains != state.configuredChains {
          state.configuredChains = chains
          state.chainInventoryRevision += 1
        }
        let snapshot = try await client.reconcile(
          identity: identity,
          token: apnsToken,
          environment: apnsEnvironment,
          settings: settings,
          addresses: state.enrolledAddresses,
          chains: chains,
          revision: state.chainInventoryRevision)
        state.chainStages = snapshot.chainStages
        state.acknowledgedChainRevision = state.chainInventoryRevision
        state.apnsTokenHash = tokenHash(apnsToken)
        state.lastSuccessfulReconciliationUnixMs = Int(Date().timeIntervalSince1970 * 1000)
        state.pendingCleanup = false
        state.lastPublicError = nil
        try await store.write(state)
        try await writeDisplayState()
      } catch {
        state.lastPublicError = "Notification enrollment will retry when the service is available."
        try? await store.write(state)
      }
    }

    private func deleteInstallation() async {
      if let reconciliationTask { await reconciliationTask.value }
      do {
        let identity = try keyStore.loadOrCreate()
        try await client.delete(identity: identity)
        try keyStore.delete()
        try popupKeyStore.delete()
        state.installationId = nil
        state.installationPublicKeyHash = nil
        state.apnsTokenHash = nil
        state.chainStages = [:]
        state.pendingCleanup = false
        state.lastPublicError = nil
        try await displayStore.write(NotificationDisplayState())
      } catch {
        state.pendingCleanup = true
        state.lastPublicError = "Notification cleanup will retry when the service is available."
      }
    }

    private func writeDisplayState() async throws {
      guard let installationID = state.installationId else { return }
      var aliases: [String: NotificationDisplayAlias] = [:]
      for address in state.enrolledAddresses {
        let registrationID = NotificationRegistrationID.opaque(
          installationID: installationID, address: address)
        let label = state.displayLabelsByAddress[address].flatMap { $0.isEmpty ? nil : $0 }
          ?? shortAddress(address)
        aliases[registrationID] = NotificationDisplayAlias(label: label, address: address)
      }
      try await displayStore.write(NotificationDisplayState(aliases: aliases))
    }

    private func synchronizeInstallationMetadata(from identity: NotificationInstallationIdentity) {
      guard let installationID = identity.installationID else { return }
      state.synchronizeInstallationMetadata(
        installationID: installationID,
        publicKeyHash: identity.publicKeySPKIBase64URL.map(publicKeyHash))
    }

    private func shortAddress(_ address: String) -> String {
      address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
    }

    private var apnsEnvironment: String {
      #if DEBUG
        "development"
      #else
        "production"
      #endif
    }

    private func tokenHash(_ token: String) -> String {
      NotificationBase64URL.encode(Data(SHA256.hash(data: Data(token.utf8))))
    }

    private func publicKeyHash(_ key: String) -> String {
      NotificationBase64URL.encode(Data(SHA256.hash(data: Data(key.utf8))))
    }

    private func authorization(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
      switch status {
      case .authorized: .authorized
      case .denied: .denied
      case .provisional: .provisional
      case .ephemeral: .ephemeral
      default: .notDetermined
      }
    }

    private func alertSetting(_ setting: UNNotificationSetting) -> NotificationAlertSetting {
      switch setting {
      case .enabled: .enabled
      case .disabled: .disabled
      default: .unsupported
      }
    }
  }

  final class NotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(
      _: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      Task { @MainActor in
        await NotificationCoordinator.shared.didRegisterForRemoteNotifications(
          deviceToken: deviceToken)
      }
    }

    func application(
      _: UIApplication,
      didFailToRegisterForRemoteNotificationsWithError _: Error
    ) {
      Task { @MainActor in
        await NotificationCoordinator.shared.didFailToRegisterForRemoteNotifications()
      }
    }
  }
#endif
