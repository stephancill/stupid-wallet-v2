import CryptoKit
import Foundation
import Security

public enum SeedPhraseError: Error, Sendable, Equatable {
  case invalidWordCount
  case invalidWord(String)
  case invalidChecksum
  case invalidEntropy
  case invalidDerivationIndex
  case derivationFailed
  case randomFailure
}

public enum EthereumSeedPhrase {
  private static let wordIndexes = Dictionary(
    uniqueKeysWithValues: String.englishMnemonics.enumerated().map { ($1, $0) })

  public static func generateEntropy(wordCount: Int = 12) throws -> [UInt8] {
    let byteCount: Int
    switch wordCount {
    case 12: byteCount = 16
    case 15: byteCount = 20
    case 18: byteCount = 24
    case 21: byteCount = 28
    case 24: byteCount = 32
    default: throw SeedPhraseError.invalidWordCount
    }
    var entropy = [UInt8](repeating: 0, count: byteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
      entropy = [UInt8](repeating: 0, count: entropy.count)
      throw SeedPhraseError.randomFailure
    }
    return entropy
  }

  /// Validates an English BIP-39 phrase and returns its canonical entropy.
  public static func entropy(mnemonic: String) throws -> [UInt8] {
    let normalized = mnemonic
      .decomposedStringWithCompatibilityMapping
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard [12, 15, 18, 21, 24].contains(normalized.count) else {
      throw SeedPhraseError.invalidWordCount
    }

    var bits: [UInt8] = []
    bits.reserveCapacity(normalized.count * 11)
    for word in normalized {
      guard let index = wordIndexes[word] else { throw SeedPhraseError.invalidWord(word) }
      for shift in stride(from: 10, through: 0, by: -1) {
        bits.append(UInt8((index >> shift) & 1))
      }
    }

    let checksumLength = normalized.count / 3
    let entropyBitCount = bits.count - checksumLength
    var entropy = [UInt8](repeating: 0, count: entropyBitCount / 8)
    for index in 0..<entropyBitCount where bits[index] == 1 {
      entropy[index / 8] |= UInt8(1 << (7 - index % 8))
    }
    let hash = Array(SHA256.hash(data: entropy))
    for index in 0..<checksumLength {
      let expected = (hash[0] >> (7 - index)) & 1
      guard bits[entropyBitCount + index] == expected else {
        throw SeedPhraseError.invalidChecksum
      }
    }

    return entropy
  }

  /// Encodes canonical BIP-39 entropy as an English mnemonic.
  public static func mnemonic(entropy: [UInt8]) throws -> String {
    guard [16, 20, 24, 28, 32].contains(entropy.count) else {
      throw SeedPhraseError.invalidEntropy
    }

    var bits: [UInt8] = []
    bits.reserveCapacity(entropy.count * 8 + entropy.count / 4)
    for byte in entropy {
      for shift in stride(from: 7, through: 0, by: -1) {
        bits.append((byte >> shift) & 1)
      }
    }
    let checksum = Array(SHA256.hash(data: entropy))
    for index in 0..<(entropy.count / 4) {
      bits.append((checksum[0] >> (7 - index)) & 1)
    }

    var words: [String] = []
    words.reserveCapacity(bits.count / 11)
    for offset in stride(from: 0, to: bits.count, by: 11) {
      var wordIndex = 0
      for bit in bits[offset..<(offset + 11)] {
        wordIndex = (wordIndex << 1) | Int(bit)
      }
      words.append(String.englishMnemonics[wordIndex])
    }
    return words.joined(separator: " ")
  }

  /// Validates an English BIP-39 phrase and derives `m/44'/60'/0'/0/0`.
  public static func privateKey(mnemonic: String) throws -> [UInt8] {
    let entropy = try entropy(mnemonic: mnemonic)
    return try privateKey(entropy: entropy, index: 0)
  }

  /// Derives the requested Ethereum account, skipping an invalid BIP-32 child if necessary.
  public static func derivePrivateKey(
    entropy: [UInt8], index: UInt32
  ) throws -> (privateKey: [UInt8], derivationIndex: UInt32) {
    guard index < 0x8000_0000 else { throw SeedPhraseError.invalidDerivationIndex }
    let phrase = try mnemonic(entropy: entropy)
    var password = Array(phrase.decomposedStringWithCompatibilityMapping.utf8)
    defer { password = [UInt8](repeating: 0, count: password.count) }

    var seed = pbkdf2SHA512(
      password: password,
      salt: Array("mnemonic".decomposedStringWithCompatibilityMapping.utf8),
      iterations: 2_048)
    defer { seed = [UInt8](repeating: 0, count: seed.count) }
    return try BIP32.ethereumAccount(seed: seed, index: index)
  }

  public static func privateKey(entropy: [UInt8], index: UInt32) throws -> [UInt8] {
    try derivePrivateKey(entropy: entropy, index: index).privateKey
  }

  private static func pbkdf2SHA512(
    password: [UInt8], salt: [UInt8], iterations: Int
  ) -> [UInt8] {
    let key = SymmetricKey(data: password)
    var input = salt
    input.append(contentsOf: [0, 0, 0, 1])
    var block = Array(HMAC<SHA512>.authenticationCode(for: input, using: key))
    var result = block
    for _ in 1..<iterations {
      block = Array(HMAC<SHA512>.authenticationCode(for: block, using: key))
      for index in result.indices { result[index] ^= block[index] }
    }
    block = [UInt8](repeating: 0, count: block.count)
    return result
  }
}

private enum BIP32 {
  static func ethereumAccount(
    seed: [UInt8], index requestedIndex: UInt32
  ) throws -> (privateKey: [UInt8], derivationIndex: UInt32) {
    let master = hmac(key: Array("Bitcoin seed".utf8), data: seed)
    var secret = Array(master.prefix(32))
    var chainCode = Array(master.suffix(32))
    guard Secp256k1.validateSecret(secret) else { throw SeedPhraseError.derivationFailed }

    let path: [(UInt32, Bool)] = [(44, true), (60, true), (0, true), (0, false)]
    for (index, hardened) in path {
      let child = try deriveChild(
        secret: secret, chainCode: chainCode, index: hardened ? index | 0x8000_0000 : index)
      secret = [UInt8](repeating: 0, count: secret.count)
      chainCode = [UInt8](repeating: 0, count: chainCode.count)
      secret = child.secret
      chainCode = child.chainCode
    }

    var index = requestedIndex
    while index < 0x8000_0000 {
      if let child = try? deriveChild(secret: secret, chainCode: chainCode, index: index) {
        secret = [UInt8](repeating: 0, count: secret.count)
        chainCode = [UInt8](repeating: 0, count: chainCode.count)
        chainCode = child.chainCode
        chainCode = [UInt8](repeating: 0, count: chainCode.count)
        return (child.secret, index)
      }
      guard index < 0x7fff_ffff else { break }
      index += 1
    }

    secret = [UInt8](repeating: 0, count: secret.count)
    chainCode = [UInt8](repeating: 0, count: chainCode.count)
    throw SeedPhraseError.derivationFailed
  }

  private static func deriveChild(
    secret: [UInt8], chainCode: [UInt8], index: UInt32
  ) throws -> (secret: [UInt8], chainCode: [UInt8]) {
    var data: [UInt8]
    if index & 0x8000_0000 != 0 {
      data = [0] + secret
    } else {
      data = try Secp256k1.publicKeyCompressed(secret: secret)
    }
    data.append(UInt8((index >> 24) & 0xff))
    data.append(UInt8((index >> 16) & 0xff))
    data.append(UInt8((index >> 8) & 0xff))
    data.append(UInt8(index & 0xff))
    var digest = hmac(key: chainCode, data: data)
    defer { digest = [UInt8](repeating: 0, count: digest.count) }
    let child = try Secp256k1.addTweak(secret: secret, tweak: Array(digest.prefix(32)))
    return (child, Array(digest.suffix(32)))
  }

  private static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
    Array(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }
}
