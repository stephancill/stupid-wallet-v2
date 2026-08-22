import Foundation
import Testing

@testable import StupidWalletCore

struct KeccakTests {
  @Test("keccak256 empty input")
  func empty() {
    #expect(
      Hex.encode(Keccak.keccak256([]))
        == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
  }

  @Test("keccak256 'abc'")
  func abc() {
    #expect(
      Hex.encode(Keccak.keccak256(Array("abc".utf8)))
        == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
  }

  @Test("keccak256 empty Data via Data overload")
  func emptyData() {
    #expect(
      Hex.encode(Array(Keccak.keccak256(Data())))
        == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
  }
}

struct Secp256k1Tests {
  @Test("private key 1 derives the generator public key and known address")
  func key1() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 1
    let pub = try Secp256k1.publicKeyUncompressed(secret: secret)
    #expect(pub.count == 65)
    // uncompressed y = generator point; verify known x coordinate prefix.
    #expect(
      Hex.encode(Array(pub[1...32]))
        == "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    let addressBytes = try Secp256k1.ethAddressFromPublicKey(pub)
    let address = EIP55.checksum(from: addressBytes)
    #expect(address == "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
  }

  @Test("from(secret:) yields a checksummed address")
  func address() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 1
    let pair = try EthereumKeypair.from(secret: secret)
    #expect(pair.address == "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
  }

  @Test("zero and out-of-range keys are rejected")
  func rejectsInvalid() {
    let zero = [UInt8](repeating: 0, count: 32)
    #expect(Secp256k1.validateSecret(zero) == false)
    var overflow = [UInt8](repeating: 0xFF, count: 32)
    #expect(Secp256k1.validateSecret(overflow) == false)
    overflow = [UInt8](repeating: 0, count: 32)
    overflow[0] = 0xFF  // near curve order n must fail
    // n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    let n: [UInt8] = Hex.data(
      "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!
    #expect(Secp256k1.validateSecret(n) == false)
    #expect(Secp256k1.validateSecret([0]) == false)
  }

  @Test("sign -> recover returns the original address")
  func signRecoverRoundtrip() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 0xAB
    let pair = try EthereumKeypair.from(secret: secret)
    let digest = Keccak.keccak256(Array("sign me".utf8))
    let signature = try EthereumSigner.sign(digest: digest, keypair: pair)
    #expect(signature.count == 65)
    let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: signature)
    #expect(recovered == pair.address)
  }
}

struct EIP55Tests {
  @Test("known EIP-55 vector")
  func vector() {
    let bytes = Hex.data("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed")!
    #expect(EIP55.checksum(from: bytes) == "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
  }

  @Test("EIP-191 digest includes the personal-sign prefix")
  func eip191Prefix() {
    // keccak256("\x19Ethereum Signed Message:\n0") cross-checked via `cast keccak`.
    #expect(
      Hex.encode(MessageHash.eip191(message: []))
        == "5f35dce98ba4fba25530a026ed80b2cecdaa31091ba4958b99b52ea1d068adad")
  }
}

struct RLPTests {
  @Test("empty string encodes to 0x80")
  func emptyString() {
    #expect(RLP.encode(.string([])) == [0x80])
  }

  @Test("single byte 0x00 stays 0x00, 'dog' gains 0x83 prefix")
  func primitives() {
    #expect(RLP.encode(.string([0x00])) == [0x00])
    #expect(RLP.encode(.string([0x0f])) == [0x0f])
    #expect(RLP.encode(.string([0x04, 0x00])) == [0x82, 0x04, 0x00])
    #expect(RLP.encode(.string(Array("dog".utf8))) == [0x83, 0x64, 0x6f, 0x67])
  }

  @Test("RLP spec example: list of dog and cat and dog")
  func specVectors() {
    let encoded = RLP.encode(
      .list([
        .string(Array("cat".utf8)),
        .string(Array("dog".utf8)),
      ]))
    #expect(encoded == [0xc8, 0x83, 0x63, 0x61, 0x74, 0x83, 0x64, 0x6f, 0x67])
  }
}

extension Hex {
  fileprivate static func decode(_ hex: String) -> [UInt8] { Hex.data(hex)! }
}
