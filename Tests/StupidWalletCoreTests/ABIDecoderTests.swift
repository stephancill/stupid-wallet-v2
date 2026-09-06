import XCTest

@testable import StupidWalletCore

final class ABIDecoderTests: XCTestCase {
  func testParseTransferSignature() throws {
    let parsed = try ABI.parse(signature: "transfer(address to,uint256 value)")
    XCTAssertEqual(parsed.name, "transfer")
    XCTAssertEqual(parsed.arguments.count, 2)
    XCTAssertEqual(parsed.arguments[0].name, "to")
    XCTAssertEqual(parsed.arguments[0].type, .address)
    XCTAssertEqual(parsed.arguments[1].name, "value")
    XCTAssertEqual(parsed.arguments[1].type, .uint(256))
  }

  func testParseTypeOnlySignature() throws {
    let parsed = try ABI.parse(signature: "transfer(address,uint256)")
    XCTAssertEqual(parsed.name, "transfer")
    XCTAssertEqual(parsed.arguments.map(\.name), ["", ""])
    XCTAssertEqual(parsed.arguments.map(\.type), [.address, .uint(256)])
  }

  func testParseNestedTuple() throws {
    let parsed = try ABI.parse(
      signature: "submitOrder((address token,uint256 amount,uint256 price) order,bytes32 salt)")
    XCTAssertEqual(parsed.name, "submitOrder")
    let order = parsed.arguments[0].type
    guard case .tuple(let components) = order else {
      return XCTFail("expected tuple")
    }
    XCTAssertEqual(components.map(\.name), ["token", "amount", "price"])
    XCTAssertEqual(components.map(\.type), [.address, .uint(256), .uint(256)])
    XCTAssertEqual(parsed.arguments[1].type, .fixedBytes(32))
  }

  func testParseArrayTypes() throws {
    let parsed = try ABI.parse(signature: "airdrop(address[] recipients,uint256[3] values)")
    guard case .array(.address) = parsed.arguments[0].type else {
      return XCTFail("expected address[]")
    }
    guard case .fixedArray(.uint(256), 3) = parsed.arguments[1].type else {
      return XCTFail("expected uint256[3]")
    }
  }

  func testTransferSelector() throws {
    let parsed = try ABI.parse(signature: "transfer(address to,uint256 value)")
    XCTAssertEqual(ABI.selector(name: parsed.name, arguments: parsed.arguments), "0xa9059cbb")
  }

  func testApproveSelector() throws {
    let parsed = try ABI.parse(signature: "approve(address spender,uint256 amount)")
    XCTAssertEqual(ABI.selector(name: parsed.name, arguments: parsed.arguments), "0x095ea7b3")
  }

  func testDecodeTransfer() throws {
    let parsed = try ABI.parse(signature: "transfer(address to,uint256 value)")
    let to = String(repeating: "11", count: 20)
    let calldata =
      "0xa9059cbb000000000000000000000000" + to
      + "00000000000000000000000000000000000000000000000000000000000003e8"
    guard let decoded = ABI.decode(arguments: parsed.arguments, calldataHex: calldata) else {
      return XCTFail("decode failed")
    }
    XCTAssertEqual(decoded["to"]?.hexDisplay.lowercased(), "0x" + to)
    XCTAssertEqual(decoded["value"]?.decimalString, "1000")
  }

  func testDecodeNestedDynamicTuple() throws {
    let parsed = try ABI.parse(
      signature: "swap((uint256 a,string b) w,address to)")
    XCTAssertTrue(parsed.arguments[0].type.isDynamic)
    // w = (a: 1, b: "hi"), to = 0x1111...1111
    let calldata =
      "0x"
      + "0000000000000000000000000000000000000000000000000000000000000040"  // w -> 0x40
      + "0000000000000000000000001111111111111111111111111111111111111111"  // to
      + "0000000000000000000000000000000000000000000000000000000000000001"  // w.a
      + "0000000000000000000000000000000000000000000000000000000000000040"  // w.b -> rel 0x40
      + "0000000000000000000000000000000000000000000000000000000000000002"  // string len
      + "6869000000000000000000000000000000000000000000000000000000000000"  // "hi"
    guard let raw = Hex.data(calldata),
      let decoded = ABI.decode(arguments: parsed.arguments, data: raw)
    else { return XCTFail("decode failed") }
    guard case .object(let w)? = decoded["w"] else {
      return XCTFail("expected object")
    }
    XCTAssertEqual(w["a"]?.decimalString, "1")
    XCTAssertEqual(w["b"]?.displayString, "hi")
    XCTAssertEqual(
      decoded["to"]?.hexDisplay.lowercased(), "0x" + String(repeating: "11", count: 20))
  }

  func testDecodeDocExample() throws {
    let parsed = try ABI.parse(signature: "max(uint256 a,uint256[] b,bytes10 c,bytes d)")
    let calldata =
      "0x12345678"
      + "0000000000000000000000000000000000000000000000000000000000000123"
      + "0000000000000000000000000000000000000000000000000000000000000080"
      + "3132333435363738393000000000000000000000000000000000000000000000"
      + "00000000000000000000000000000000000000000000000000000000000000e0"
      + "0000000000000000000000000000000000000000000000000000000000000002"
      + "0000000000000000000000000000000000000000000000000000000000000456"
      + "0000000000000000000000000000000000000000000000000000000000000789"
      + "0000000000000000000000000000000000000000000000000000000000000000"
    guard let decoded = ABI.decode(arguments: parsed.arguments, calldataHex: calldata) else {
      return XCTFail("decode failed")
    }
    XCTAssertEqual(decoded["a"]?.decimalString, "291")
    if case .array(let values)? = decoded["b"] {
      XCTAssertEqual(values.map(\.decimalString), ["1110", "1929"])
    } else {
      XCTFail()
    }
    if case .bytes(let raw)? = decoded["c"] {
      XCTAssertEqual(Hex.encode(raw), "31323334353637383930")
    } else {
      XCTFail()
    }
    XCTAssertEqual(decoded["d"]?.hexDisplay, "0x")
  }
}
