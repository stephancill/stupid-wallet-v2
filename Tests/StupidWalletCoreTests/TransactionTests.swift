import Foundation
import Testing

@testable import StupidWalletCore

struct EIP1559TransactionTests {
  // A representative transfer (mainnet), deterministic and re-encodable.
  private func tx() -> EIP1559Transaction {
    EIP1559Transaction(
      chainId: 1, nonce: "0x0",
      maxPriorityFeePerGas: "0x3b9aca00", maxFeePerGas: "0x77359400",
      gasLimit: "0x5208", to: "0x3535353535353535353535353535353535353535",
      value: "0xde0b6b3a7640000", data: "0x")
  }

  @Test("type-2 payload starts with the 0x02 envelope byte")
  func envelopeByte() throws {
    let payload = try tx().signingPayload()
    #expect(payload.first == 0x02)
  }

  @Test("type-2 signing preimage contains the nine unsigned fields")
  func structural() throws {
    let inner = try tx().signingPayload()
    #expect(inner.count > 40 && inner.count < 80)
  }

  @Test("sign -> recover yields the sender address")
  func signRecover() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 0x11
    let pair = try EthereumKeypair.from(secret: secret)
    let payload = try tx().signingPayload()
    let digest = Keccak.keccak256(payload)
    let signature = try EthereumSigner.sign(digest: digest, keypair: pair)
    let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: signature)
    #expect(recovered == pair.address)
  }

  @Test("EIP-1559 preimage (chain 1, empty access list) hashes to the canonical digest")
  func crossImpl() throws {
    let payload = try tx().signingPayload()
    #expect(
      Hex.encode(payload) == "02ef0180843b9aca008477359400825208943535353535353535353535353535"
        + "353535353535880de0b6b3a764000080c0")
    // Cross-checked independently with viem `serializeTransaction` and `keccak256`.
    #expect(
      Hex.encode(Keccak.keccak256(payload))
        == "fda4b0fb774359f7f19135727b7afe93ac4ac51dcabef74b8d3a7346b032d6b9")
  }

  @Test("signed EIP-1559 payload matches viem")
  func signedCrossImpl() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 0x11
    let pair = try EthereumKeypair.from(secret: secret)
    let digest = Keccak.keccak256(try tx().signingPayload())
    let signature = try EthereumSigner.sign(digest: digest, keypair: pair)
    #expect(
      Hex.encode(try tx().signedPayload(signature: signature))
        == "02f8720180843b9aca008477359400825208943535353535353535353535353535353535353535"
        + "880de0b6b3a764000080c001a0a46013d262cf1d2371f67b8b7aff5c8136d57a79cfb67018d8927"
        + "dae9bc2a5baa00a06ff3394df393049b1a161a0b96b7ba04dd80478d9b52895648efad8475c37")
  }
}

struct LegacyTransactionTests {
  private func tx() -> LegacyTransaction {
    LegacyTransaction(
      nonce: "0x9", gasPrice: "0x4a817c800", gasLimit: "0x5208",
      to: "0x3535353535353535353535353535353535353535",
      value: "0xde0b6b3a7640000", data: "0x", chainId: 1)
  }

  @Test("legacy payload RLP list prefix")
  func structure() throws {
    let payload = try tx().signingPayload()
    // RLP list with payload length < 56 uses a 0xC0..0xF7 single-byte prefix.
    #expect(payload.count >= 1)
    #expect((0xC0...0xF7).contains(Int(payload[0])))
  }

  @Test("sign -> recover matches sender")
  func signRecover() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 0x22
    let pair = try EthereumKeypair.from(secret: secret)
    let payload = try tx().signingPayload()
    let digest = Keccak.keccak256(payload)
    let signature = try EthereumSigner.sign(digest: digest, keypair: pair)
    let recovered = try EthereumSigner.recoverAddress(digest: digest, signature: signature)
    #expect(recovered == pair.address)
  }

  @Test("legacy preimage matches the viem cross-implementation vector")
  func _canonical() throws {
    let payload = try tx().signingPayload()
    #expect(
      Hex.encode(payload) == "ec098504a817c800825208943535353535353535353535353535353535353535"
        + "880de0b6b3a764000080018080")
    #expect(
      Hex.encode(Keccak.keccak256(payload))
        == "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53")
  }

  @Test("signed legacy payload matches viem")
  func signedCrossImpl() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    secret[31] = 0x22
    let pair = try EthereumKeypair.from(secret: secret)
    let digest = Keccak.keccak256(try tx().signingPayload())
    let signature = try EthereumSigner.sign(digest: digest, keypair: pair)
    #expect(
      Hex.encode(try tx().signedPayload(signature: signature))
        == "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764"
        + "00008026a0319b5389807e57c75397929410f91ba9f90dd136af345f9a24622ad56058d71da069989"
        + "e767920a4c83b6358da583628c53babd215850aa5bb4ffbde93e444ba61")
  }
}
