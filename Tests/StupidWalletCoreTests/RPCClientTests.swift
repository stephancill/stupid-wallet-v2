import Foundation
import Testing

@testable import StupidWalletCore

@Suite(.serialized)
struct RPCClientTests {
  private func stubValidation(returning chainID: String) -> RPCClient {
    StubURLProtocol.handler = { _ in
      (httpResponse(), jsonObject(["jsonrpc": "2.0", "id": 1, "result": chainID]))
    }
    return RPCClient(session: URLSession.stubSession)
  }

  @Test("valid chain-matching https override passes")
  func overrideValid() async {
    let result = await RPCOverrideValidator.validate(
      url: URL(string: "https://node.example.com")!, expectedChainID: "1",
      client: stubValidation(returning: "0x1"))
    guard case .success = result else {
      Issue.record("expected success, got \(result)")
      return
    }
  }

  @Test("wrong chain is rejected with chainMismatch")
  func overrideChainMismatch() async {
    let result = await RPCOverrideValidator.validate(
      url: URL(string: "https://api.example.com")!, expectedChainID: "1",
      client: stubValidation(returning: "0xa4b1"))
    guard case .failure(let error) = result else {
      Issue.record("expected chainMismatch")
      return
    }
    #expect(error == .chainMismatch(expected: "1", actual: "0xa4b1"))
  }

  @Test("non-loopback http is rejected")
  func overrideInsecureHttp() async {
    let result = await RPCOverrideValidator.validate(
      url: URL(string: "http://api.example.com")!, expectedChainID: "1",
      client: stubValidation(returning: "0x1"))
    guard case .failure(let error) = result else {
      Issue.record("expected insecure")
      return
    }
    #expect(error == .insecure)
  }

  @Test("loopback http is allowed")
  func overrideLoopback() async {
    let result = await RPCOverrideValidator.validate(
      url: URL(string: "http://127.0.0.1:8545")!, expectedChainID: "1",
      client: stubValidation(returning: "0x1"))
    guard case .success = result else {
      Issue.record("expected success on loopback")
      return
    }
  }

  @Test("URL without a host is invalid")
  func overrideNoHost() async {
    let result = await RPCOverrideValidator.validate(
      url: URL(string: "https://")!, expectedChainID: "1",
      client: stubValidation(returning: "0x1"))
    guard case .failure(let error) = result else {
      Issue.record("expected invalidURL")
      return
    }
    #expect(error == .invalidURL)
  }

  @Test("unreachable endpoint is rejected")
  func overrideUnreachable() async {
    StubURLProtocol.shouldFail = true
    defer { StubURLProtocol.shouldFail = false }
    let result = await RPCOverrideValidator.validate(
      url: URL(string: "https://api.example.com")!, expectedChainID: "1",
      client: RPCClient(session: URLSession.stubSession))
    guard case .failure(let error) = result else {
      Issue.record("expected unreachable")
      return
    }
    #expect(error == .unreachable)
  }
  @Test("a successful result is preserved")
  func resultPreserved() async throws {
    StubURLProtocol.shouldFail = false
    StubURLProtocol.handler = { _ in
      (httpResponse(), jsonObject(["jsonrpc": "2.0", "id": 1, "result": "0x1"]))
    }
    let client = RPCClient(session: URLSession.stubSession)
    let response = try await client.call(
      url: URL(string: "https://evm.example.com")!, method: "eth_chainId", params: .array([]))
    #expect(response == .result(.string("0x1")))
  }

  @Test("null result survives")
  func nullResultPreserved() async throws {
    StubURLProtocol.handler = { _ in
      (httpResponse(), jsonObject(["jsonrpc": "2.0", "id": 1, "result": NSNull()]))
    }
    let client = RPCClient(session: URLSession.stubSession)
    let response = try await client.call(
      url: URL(string: "https://example.com/rpc")!, method: "eth_x", params: .array([]))
    #expect(response == .result(.null))
  }

  @Test("node error object is preserved unmodified")
  func nodeErrorPreserved() async throws {
    let errorObject = JSONValue.object([
      "code": .number(-32000),
      "message": .string("insufficient funds"),
      "data": .object(["detail": .string("0x0")]),
    ])
    StubURLProtocol.handler = { _ in
      let data = try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"),
          "id": .number(1),
          "error": errorObject,
        ]))
      return (httpResponse(), data)
    }
    let client = RPCClient(session: URLSession.stubSession)
    let response = try await client.call(
      url: URL(string: "https://example.com/rpc")!, method: "eth_sendRawTransaction",
      params: .array([]))
    guard case .error(let value) = response else {
      Issue.record("expected an error response")
      return
    }
    #expect(value.nestedString(at: ["message"]) == "insufficient funds")
    #expect(value.nestedString(at: ["data", "detail"]) == "0x0")
  }

  @Test("transport failure is a distinct error")
  func transportFailure() async throws {
    StubURLProtocol.shouldFail = true
    defer { StubURLProtocol.shouldFail = false }
    let client = RPCClient(session: URLSession.stubSession)
    await #expect(throws: RPCClientError.transport) {
      _ = try await client.call(
        url: URL(string: "https://example.com/rpc")!, method: "eth_chainId",
        params: .array([]))
    }
  }

  @Test("unparseable body raises invalidResponse")
  func invalidResponse() async throws {
    StubURLProtocol.handler = { _ in (httpResponse(), Data("not json".utf8)) }
    let client = RPCClient(session: URLSession.stubSession)
    await #expect(throws: RPCClientError.invalidResponse) {
      _ = try await client.call(
        url: URL(string: "https://example.com/rpc")!, method: "eth_chainId",
        params: .array([]))
    }
  }

  @Test("preserves all JSON value types in a nested payload")
  func payloadBuildsWithoutLoss() throws {
    let params = JSONValue.object([
      "string": .string("s"),
      "number": .number(0.5),
      "integerAsDecimalString": .string("9007199254740993"),
      "bool": .bool(true),
      "null": .null,
      "array": .array([.string("a"), .null]),
    ])
    let data = try JSONEncoder().encode(params)
    let round = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(round == params)
  }
}

struct JSONValueTests {
  @Test("every JSON type round-trips")
  func roundTrip() throws {
    let value = JSONValue.object([
      "null": .null,
      "bool": .bool(true),
      "number": .number(3.25),
      "string": .string("text"),
      "array": .array([.object(["k": .string("v")]), .array([.null])]),
      "nestedNull": .object(["a": .null, "b": .array([.null, .string("x")])]),
    ])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  @Test("null is preserved inside arrays and objects")
  func preservesNull() throws {
    let data = Data(#"[null,{"a":null},0,false]"#.utf8)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .array(let items) = value else {
      Issue.record("expected array")
      return
    }
    #expect(items[0] == .null)
    #expect(items[1] == .object(["a": .null]))
    let roundTripped = try JSONEncoder().encode(value)
    let parsedAgain = try JSONValue.parse(roundTripped)
    #expect(parsedAgain == value)
  }

  @Test("number equality uses exact double comparison")
  func numberEquality() {
    #expect(JSONValue.number(0.5) == JSONValue.number(0.5))
    #expect(JSONValue.number(1.0) != JSONValue.number(2.0))
  }
}
