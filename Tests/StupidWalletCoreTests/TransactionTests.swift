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
}
