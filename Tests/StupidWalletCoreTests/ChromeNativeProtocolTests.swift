import Foundation
import Testing

@testable import StupidWalletCore

@Suite("Chrome native protocol")
struct ChromeNativeProtocolTests {
  let id = UUID().uuidString
  let profile = "chrome:" + UUID().uuidString.lowercased()

  func frame(_ message: JSONValue, version: Int = 3, profile: String? = nil) -> JSONValue {
    .object([
      "version": .number(Double(version)), "id": .string(id),
      "profileId": .string(profile ?? self.profile), "message": message,
    ])
  }
  var hello: JSONValue { frame(.object(["action": .string("hello")])) }

  @Test func handshakeAndProfileBinding() throws {
    var session = ChromeNativeSession()
    #expect(throws: ChromeNativeSession.Failure.self) {
      try session.accept(frame(.object(["action": .string("list")])))
    }
    let accepted = try session.accept(hello)
    #expect(accepted.profileID == profile)
    #expect(try session.accept(frame(.object(["action": .string("list")]))).action == "list")
    #expect(throws: ChromeNativeSession.Failure.self) { try session.accept(hello) }
    #expect(throws: ChromeNativeSession.Failure.self) {
      try session.accept(
        frame(.object(["action": .string("list")]), profile: "chrome:" + UUID().uuidString))
    }
  }

  @Test func rejectsVersionAndUnknownAuthority() throws {
    var session = ChromeNativeSession()
    #expect(throws: ChromeNativeSession.Failure.self) {
      try session.accept(frame(.object(["action": .string("hello")]), version: 2))
    }
    _ = try session.accept(hello)
    for action in ["approve", "reject", "connectAccounts"] {
      var fields: [String: JSONValue] = ["requestId": .string(id), "revision": .number(1)]
      if action == "approve" { fields["bindingDigest"] = .string("digest") }
      let payload: JSONValue = .object(fields)
      _ = try session.accept(frame(.object(["action": .string(action), "payload": payload])))
      #expect(throws: ChromeNativeSession.Failure.self) {
        try session.accept(
          frame(.object(["action": .string(action), "payload": payload, "params": .array([])])))
      }
      #expect(throws: ChromeNativeSession.Failure.self) {
        try session.accept(
          frame(
            .object([
              "action": .string(action),
              "payload": .object([
                "requestId": .string(id), "revision": .number(1), "params": .array([]),
              ]),
            ])))
      }
    }
    #expect(throws: ChromeNativeSession.Failure.self) {
      try session.accept(frame(.object(["action": .string("listSites")])))
    }
  }

  @Test func malformedOriginAndRevisionFailClosed() throws {
    var session = ChromeNativeSession()
    _ = try session.accept(hello)
    for origin in [
      "null", "file:///tmp/a", "https://example.com/path", "https://user@example.com",
      "https://example.com?x=1",
    ] {
      #expect(throws: ChromeNativeSession.Failure.self) {
        try session.accept(
          frame(.object(["action": .string("visibleAccounts"), "origin": .string(origin)])))
      }
    }
    for revision in [
      JSONValue.number(-1), .number(0.5), .number(9_007_199_254_740_992), .string("1"), .bool(true),
    ] {
      #expect(throws: ChromeNativeSession.Failure.self) {
        try session.accept(
          frame(
            .object([
              "action": .string("approve"),
              "payload": .object([
                "requestId": .string(id), "revision": revision,
              ]),
            ])))
      }
    }
  }

  @Test func contextControlsRejectExtraAuthority() throws {
    var session = ChromeNativeSession()
    _ = try session.accept(hello)
    for action in ["invalidate", "contextResult"] {
      var payload: [String: JSONValue] = ["requestId": .string(id)]
      if action == "contextResult" {
        payload["nonce"] = .string(UUID().uuidString)
        payload["valid"] = .bool(true)
        payload["signature"] = .string("")
      }
      _ = try session.accept(
        frame(.object(["action": .string(action), "payload": .object(payload)])))
      payload["params"] = .array([])
      #expect(throws: ChromeNativeSession.Failure.self) {
        try session.accept(
          frame(.object(["action": .string(action), "payload": .object(payload)])))
      }
    }
  }

  @Test func framesPreserveJSONAndMultipleMessages() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
    let output = try FileHandle(forWritingTo: file)
    let value: JSONValue = .object([
      "unicode": .string("👋"), "nested": .array([.null, .bool(false), .number(1.5)]),
    ])
    try ChromeNativeFrames.write(value, to: output)
    try ChromeNativeFrames.write(.null, to: output)
    try output.close()
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    let first = try #require(try ChromeNativeFrames.read(from: input))
    #expect(try JSONValue.parse(first) == value)
    let second = try #require(try ChromeNativeFrames.read(from: input))
    #expect(try JSONValue.parse(second) == .null)
    #expect(try ChromeNativeFrames.read(from: input) == nil)
  }

  @Test func rejectsOversizeAndTruncatedFramesBeforeDecode() throws {
    for bytes in [
      Data([1, 0]), Data([4, 0, 0, 0, 123]), Data([0, 0, 0, 0]), Data([1, 0, 4, 0]),
    ] {
      let pipe = Pipe()
      try pipe.fileHandleForWriting.write(contentsOf: bytes)
      try pipe.fileHandleForWriting.close()
      defer { try? pipe.fileHandleForReading.close() }
      #expect(throws: ChromeNativeFrames.Failure.self) {
        try ChromeNativeFrames.read(from: pipe.fileHandleForReading)
      }
    }
  }
}
