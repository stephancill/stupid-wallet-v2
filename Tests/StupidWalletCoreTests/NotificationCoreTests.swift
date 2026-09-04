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
    state.configuredChains = ["1", "8453"]
    state.chainInventoryRevision = 2
    state.acknowledgedChainRevision = 2
    try await store.write(state)

    let loaded = try await store.read()
    XCTAssertEqual(loaded.enrolledAddresses.count, 1)
    XCTAssertEqual(loaded.configuredChains, ["1", "8453"])
    XCTAssertEqual(loaded.chainInventoryRevision, 2)
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
}
