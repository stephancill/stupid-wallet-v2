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

  @Test("Hardhat mnemonic derives the standard second Ethereum account")
  func hardhatSecondAccountVector() throws {
    let phrase = "test test test test test test test test test test test junk"
    var entropy = try EthereumSeedPhrase.entropy(mnemonic: phrase)
    defer { entropy = [UInt8](repeating: 0, count: entropy.count) }
    var derived = try EthereumSeedPhrase.derivePrivateKey(entropy: entropy, index: 1)
    defer { derived.privateKey = [UInt8](repeating: 0, count: derived.privateKey.count) }

    #expect(derived.derivationIndex == 1)
    #expect(
      Hex.encode(derived.privateKey)
        == "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
    #expect(
      try EthereumKeypair.from(secret: derived.privateKey).address
        == "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
  }

  @Test("BIP-39 entropy and mnemonic round-trip for every supported size")
  func entropyRoundTrip() throws {
    for byteCount in [16, 20, 24, 28, 32] {
      var entropy = (0..<byteCount).map(UInt8.init)
      let mnemonic = try EthereumSeedPhrase.mnemonic(entropy: entropy)
      var recovered = try EthereumSeedPhrase.entropy(mnemonic: mnemonic)
      #expect(recovered == entropy)
      #expect(mnemonic.split(separator: " ").count == byteCount * 3 / 4)
      entropy = [UInt8](repeating: 0, count: entropy.count)
      recovered = [UInt8](repeating: 0, count: recovered.count)
    }
  }

  @Test("generated entropy has the requested BIP-39 size and valid mnemonic")
  func generatedEntropy() throws {
    for wordCount in [12, 15, 18, 21, 24] {
      var entropy = try EthereumSeedPhrase.generateEntropy(wordCount: wordCount)
      let mnemonic = try EthereumSeedPhrase.mnemonic(entropy: entropy)
      #expect(mnemonic.split(separator: " ").count == wordCount)
      #expect(try EthereumSeedPhrase.entropy(mnemonic: mnemonic) == entropy)
      entropy = [UInt8](repeating: 0, count: entropy.count)
    }
    #expect(throws: SeedPhraseError.invalidWordCount) {
      try EthereumSeedPhrase.generateEntropy(wordCount: 13)
    }
  }

  @Test("invalid entropy and hardened account indexes are rejected")
  func invalidInputs() throws {
    #expect(throws: SeedPhraseError.invalidEntropy) {
      try EthereumSeedPhrase.mnemonic(entropy: [UInt8](repeating: 0, count: 15))
    }
    let entropy = try EthereumSeedPhrase.entropy(
      mnemonic: "test test test test test test test test test test test junk")
    #expect(throws: SeedPhraseError.invalidDerivationIndex) {
      try EthereumSeedPhrase.derivePrivateKey(entropy: entropy, index: 0x8000_0000)
    }
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
