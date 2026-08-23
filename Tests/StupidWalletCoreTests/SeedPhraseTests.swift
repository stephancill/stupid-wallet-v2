import Testing

@testable import StupidWalletCore

struct SeedPhraseTests {
  @Test("Hardhat mnemonic derives the standard first Ethereum private key")
  func hardhatVector() throws {
    let phrase = "test test test test test test test test test test test junk"
    var key = try EthereumSeedPhrase.privateKey(mnemonic: phrase)
    defer { key = [UInt8](repeating: 0, count: key.count) }

    #expect(Hex.encode(key) == "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
    #expect(
      try EthereumKeypair.from(secret: key).address == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
  }

  @Test("BIP-39 checksum and vocabulary are enforced")
  func validation() {
    #expect(throws: SeedPhraseError.invalidChecksum) {
      try EthereumSeedPhrase.privateKey(
        mnemonic:
          "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
      )
    }
    #expect(throws: SeedPhraseError.invalidWord("notaword")) {
      try EthereumSeedPhrase.privateKey(
        mnemonic:
          "notaword abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
      )
    }
  }
}
