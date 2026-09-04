import Foundation
import XCTest

@testable import StupidWalletCore

/// Cross-language gate: this suite loads the exact shared vector that the TypeScript
/// backend verifies (server/test/fixtures/p256-vector.json) and re-verifies it via
/// CryptoKit, so Swift and TypeScript prove the same bytes.
final class NotificationCoreTests: XCTestCase {
  private struct Vector {
    let spki: String
    let signature: String
    let message: String
  }

  private var vector: Vector!

  override func setUp() {
    super.setUp()
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
    let fixtureURL = repoRoot.appendingPathComponent("server/test/fixtures/p256-vector.json")
    let data = try? Data(contentsOf: fixtureURL)
    let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
    vector = Vector(
      spki: object?["spkiBase64Url"] as? String ?? "",
      signature: object?["signatureBase64Url"] as? String ?? "",
      message: object?["message"] as? String ?? ""
    )
  }

  func testSharedVectorVerifiesInCryptoKit() throws {
    let valid = try NotificationP256Verifier.verify(
      spkiBase64URL: vector.spki,
      signatureBase64URL: vector.signature,
      canonical: Data(vector.message.utf8)
    )
    XCTAssertTrue(valid, "the shared P-256 vector must verify in CryptoKit")
  }

  func testTamperedMessageFails() throws {
    let valid = try NotificationP256Verifier.verify(
      spkiBase64URL: vector.spki,
      signatureBase64URL: vector.signature,
      canonical: Data("tampered".utf8)
    )
    XCTAssertFalse(valid)
  }

  func testCanonicalRequestShape() {
    let digest = NotificationCanonicalRequest.bodyDigest(of: Data("{}".utf8))
    let canonical = NotificationCanonicalRequest.canonical(
      method: "PUT",
      pathAndQuery: "/v1/installations/inst_1/push-token",
      timestamp: "1720000000000",
      requestID: "req-1",
      bodyDigestBase64URL: digest
    )
    let text = String(data: canonical, encoding: .utf8)!
    XCTAssertTrue(text.hasPrefix("v1\nPUT\n/v1/installations/inst_1/push-token\n"))
    XCTAssertTrue(text.hasSuffix("\n" + digest))
  }

  func testGeneratedKeypairSignsAndVerifies() throws {
    let (generatedSPKI, sign) = NotificationP256Signer.generateKeypair()
    let messageData = Data("hello v1 canonical".utf8)
    let signatureValue = try sign(messageData)
    let valid = try NotificationP256Verifier.verify(
      spkiBase64URL: generatedSPKI,
      signatureBase64URL: signatureValue,
      canonical: messageData
    )
    XCTAssertTrue(valid)
  }

  func testRegistrationStoreRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NotificationRegistrationStore(fileURL: directory.appendingPathComponent("reg.json"))

    var state = try await store.read()
    XCTAssertTrue(state.enrolledAddresses.isEmpty)
    state.enrolledAddresses.insert("0x1111111111111111111111111111111111111111")
    state.displayLabelsByAddress["0x1111111111111111111111111111111111111111"] = "Account 1"
    state.configuredChains = ["1", "8453"]
    state.chainInventoryRevision = 2
    state.acknowledgedChainRevision = 2
    try await store.write(state)

    let loaded = try await store.read()
    XCTAssertEqual(loaded.enrolledAddresses.count, 1)
    XCTAssertEqual(
      loaded.displayLabelsByAddress["0x1111111111111111111111111111111111111111"],
      "Account 1")
    XCTAssertEqual(loaded.configuredChains, ["1", "8453"])
    XCTAssertEqual(loaded.chainInventoryRevision, 2)
  }

  func testNotificationDisplayStoreAndOpaqueRegistrationID() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NotificationDisplayStore(fileURL: directory.appendingPathComponent("display.json"))
    let address = "0x1111111111111111111111111111111111111111"
    let registrationID = NotificationRegistrationID.opaque(
      installationID: "inst_test", address: address)
    XCTAssertEqual(registrationID, "ar_zaam156GtU9__kJu_5xDs8Jp")

    let alias = NotificationDisplayAlias(label: "Account 1", address: address)
    try await store.write(NotificationDisplayState(aliases: [registrationID: alias]))
    let loaded = await store.read()
    XCTAssertEqual(loaded.aliases[registrationID], alias)
  }

  func testRegistrationStateWithoutDisplayLabelsRemainsBackwardCompatible() throws {
    let legacy = Data(
      """
      {"version":1,"enrolledAddresses":[],"configuredChains":[],"chainInventoryRevision":0,"acknowledgedChainRevision":0,"pendingCleanup":false}
      """.utf8)
    let state = try JSONDecoder().decode(NotificationRegistrationState.self, from: legacy)
    XCTAssertTrue(state.displayLabelsByAddress.isEmpty)
  }

  func testExistingIdentityRepairsMissingInstallationMetadata() throws {
    let legacy = Data(
      """
      {"version":1,"enrolledAddresses":["0x1111111111111111111111111111111111111111"],"displayLabelsByAddress":{"0x1111111111111111111111111111111111111111":"Account 1"},"configuredChains":["1"],"chainInventoryRevision":1,"acknowledgedChainRevision":1,"pendingCleanup":false}
      """.utf8)
    var state = try JSONDecoder().decode(NotificationRegistrationState.self, from: legacy)
    XCTAssertNil(state.installationId)

    state.synchronizeInstallationMetadata(
      installationID: "inst_existing", publicKeyHash: "pk_hash")

    XCTAssertEqual(state.installationId, "inst_existing")
    XCTAssertEqual(state.installationPublicKeyHash, "pk_hash")
    let registrationID = NotificationRegistrationID.opaque(
      installationID: try XCTUnwrap(state.installationId),
      address: try XCTUnwrap(state.enrolledAddresses.first))
    XCTAssertFalse(registrationID.isEmpty)
  }

  func testNotificationServiceExtensionUsesAppleExtensionPoint() throws {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
    let plistURL = repoRoot.appendingPathComponent("NotificationServiceExtension/Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let extensionInfo = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
    XCTAssertEqual(
      extensionInfo["NSExtensionPointIdentifier"] as? String,
      "com.apple.usernotifications.service")
  }

  func testCommunicationNotificationConfiguration() throws {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()

    let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("Info.plist"))
    let info = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any])
    XCTAssertEqual(info["NSUserActivityTypes"] as? [String], ["INSendMessageIntent"])

    let entitlementData = try Data(
      contentsOf: repoRoot.appendingPathComponent("App.entitlements"))
    let entitlements = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: entitlementData, format: nil)
        as? [String: Any])
    XCTAssertEqual(entitlements["com.apple.developer.siri"] as? Bool, true)
    XCTAssertEqual(
      entitlements["com.apple.developer.usernotifications.communication"] as? Bool,
      true)

    let serviceSource = try String(
      contentsOf: repoRoot.appendingPathComponent(
        "Sources/StupidWalletNotificationService/NotificationService.swift"),
      encoding: .utf8)
    XCTAssertTrue(serviceSource.contains("mutable.body = context"))
    XCTAssertFalse(serviceSource.contains("mutable.body = \"\""))
  }

  func testInstallationIdentityPersistsWithoutWalletAuthentication() throws {
    let store = NotificationInstallationKeyStore(
      service: "notification-tests-\(UUID().uuidString)", accessGroup: nil)
    defer { try? store.delete() }

    let created = try store.loadOrCreate()
    XCTAssertNil(created.installationID)
    XCTAssertNotNil(created.publicKeySPKIBase64URL)
    try store.saveInstallationID("inst_test")

    let recovered = try store.loadOrCreate()
    XCTAssertEqual(recovered.privateKey, created.privateKey)
    XCTAssertEqual(recovered.installationID, "inst_test")
    let canonical = Data("notification-only".utf8)
    let signature = try recovered.sign(canonical)
    XCTAssertTrue(
      try NotificationP256Verifier.verify(
        spkiBase64URL: recovered.publicKeySPKIBase64URL ?? "",
        signatureBase64URL: signature,
        canonical: canonical))
  }

  func testEventKindTitles() {
    XCTAssertEqual(NotificationEventKind.nativeReceived.title, "Received funds")
    XCTAssertEqual(NotificationEventKind.activityReverted.title, "Activity reverted")
    XCTAssertEqual(NotificationEventKind.allCases.count, 10)
  }

  func testBlockieRendersDeterministicPNG() throws {
    let seed = "0x1111111111111111111111111111111111111111"
    let first = try XCTUnwrap(NotificationBlockie.renderPNG(seed: seed, pixelsPerCell: 12))
    let second = try XCTUnwrap(NotificationBlockie.renderPNG(seed: seed, pixelsPerCell: 12))
    XCTAssertEqual(first, second, "the blockie render must be deterministic for a given seed")
    XCTAssertGreaterThan(first.count, 100, "a rendered PNG must carry image bytes")
    XCTAssertEqual(NotificationBlockie.pixels(for: seed).count, 64)
    let different = try XCTUnwrap(
      NotificationBlockie.renderPNG(seed: "0x2222222222222222222222222222222222222222"))
    XCTAssertNotEqual(first, different, "different seeds must produce different renders")
  }

  func testDesiredStateOnlyPairsActiveChains() {
    let desired = NotificationDesiredState.desired(
      activeWalletAddresses: ["0xAaAa", "0xBbBb"],
      configuredChains: ["1", "8453", "137"],
      activeGlobalChains: ["1", "8453"]
    )
    XCTAssertEqual(desired.addresses, ["0xaaaa", "0xbbbb"])
    XCTAssertEqual(desired.configuredChains, ["1", "8453", "137"])
    XCTAssertEqual(desired.addressChainPairs.count, 4)
    XCTAssertTrue(desired.addressChainPairs.contains("1:0xaaaa"))
    XCTAssertTrue(desired.addressChainPairs.contains("8453:0xbbbb"))
  }

  func testEligibilityRequiresAuthorizationAlertAndToken() {
    XCTAssertTrue(
      NotificationReconciliationPolicy.isEligible(
        authorization: .authorized, alertSetting: .enabled, apnsTokenHash: "token"))
    XCTAssertFalse(
      NotificationReconciliationPolicy.isEligible(
        authorization: .denied, alertSetting: .enabled, apnsTokenHash: "token"))
    XCTAssertFalse(
      NotificationReconciliationPolicy.isEligible(
        authorization: .authorized, alertSetting: .enabled, apnsTokenHash: nil))
  }

  func testLivenessSettingsAndPopupCadence() {
    let semester = 90 * 24 * 60 * 60 * 1000
    let now = Int64(semester)
    XCTAssertTrue(
      NotificationReconciliationPolicy.isLivenessRenewalDue(
        livenessExpiresAtMs: now + 10 * 24 * 60 * 60 * 1000, nowMs: now))
    XCTAssertFalse(
      NotificationReconciliationPolicy.isLivenessRenewalDue(
        livenessExpiresAtMs: now + 20 * 24 * 60 * 60 * 1000, nowMs: now))
    XCTAssertTrue(
      NotificationReconciliationPolicy.isSettingsRefreshDue(
        settingsValidUntilMs: now + 20 * 24 * 60 * 60 * 1000, nowMs: now))
    XCTAssertTrue(
      NotificationReconciliationPolicy.isPopupRenewalDue(lastPopupRenewalMs: nil, nowMs: now))
    XCTAssertFalse(
      NotificationReconciliationPolicy.isPopupRenewalDue(
        lastPopupRenewalMs: now - 1 * 60 * 60 * 1000, nowMs: now))
    XCTAssertTrue(
      NotificationReconciliationPolicy.isPopupRenewalDue(
        lastPopupRenewalMs: now - 25 * 60 * 60 * 1000, nowMs: now))
  }
}
