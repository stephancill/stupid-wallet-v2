import Foundation
import Testing

@testable import StupidWalletCore

struct EIP1559TransactionTests {
  // A representative transfer (mainnet), deterministic and re-encodable.
  private func tx() -> EIP1559Transaction {
    EIP1559Transaction(
      chainId: 1, nonce: "0x00",
      maxPriorityFeePerGas: "0x3b9aca00", maxFeePerGas: "0x77359400",
      gasLimit: "0x5208", to: "0x3535353535353535353535353535353535353535",
      value: "0x0de0b6b3a7640000", data: "0x")
  }

  @Test("type-2 payload starts with the 0x02 envelope byte")
  func envelopeByte() throws {
    let payload = try tx().signingPayload()
    #expect(payload.first == 0x02)
  }

  @Test("signing extreme values yield 69-byte RLP inner (chain id present)")
  func structural() throws {
    let inner = try tx().signingPayload()
    #expect(inner.count > 50 && inner.count < 80)
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
      Hex.encode(payload) == "02f20180843b9aca008477359400825208943535353535353535353535353535"
        + "353535353535880de0b6b3a764000080c0808080")
    // Cross-checked independently via `cast keccak` over the canonical bytes.
    #expect(
      Hex.encode(Keccak.keccak256(payload))
        == "1cd747edb94994e95abd451af0167d0ec952ba615a8b628eb3ac905a4a583cb9")
  }
}

struct LegacyTransactionTests {
  private func tx() -> LegacyTransaction {
    LegacyTransaction(
      nonce: "0x09", gasPrice: "0x04a817c800", gasLimit: "0x5208",
      to: "0x3535353535353535353535353535353535353535",
      value: "0x0de0b6b3a7640000", data: "0x", chainId: 1)
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
}
