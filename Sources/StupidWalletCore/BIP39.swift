import CryptoKit
import Foundation

public enum SeedPhraseError: Error, Sendable, Equatable {
  case invalidWordCount
  case invalidWord(String)
  case invalidChecksum
  case derivationFailed
}

public enum EthereumSeedPhrase {
  private static let wordIndexes = Dictionary(
    uniqueKeysWithValues: String.englishMnemonics.enumerated().map { ($1, $0) })

  /// Validates an English BIP-39 phrase and derives `m/44'/60'/0'/0/0`, matching the old app.
  public static func privateKey(mnemonic: String) throws -> [UInt8] {
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

    let phrase = normalized.joined(separator: " ")
    var seed = pbkdf2SHA512(
      password: Array(phrase.utf8),
      salt: Array("mnemonic".decomposedStringWithCompatibilityMapping.utf8),
      iterations: 2_048)
    defer { seed = [UInt8](repeating: 0, count: seed.count) }
    return try BIP32.ethereumFirstAccount(seed: seed)
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
  static func ethereumFirstAccount(seed: [UInt8]) throws -> [UInt8] {
    let master = hmac(key: Array("Bitcoin seed".utf8), data: seed)
    var secret = Array(master.prefix(32))
    var chainCode = Array(master.suffix(32))
    guard Secp256k1.validateSecret(secret) else { throw SeedPhraseError.derivationFailed }

    let path: [(UInt32, Bool)] = [
      (44, true), (60, true), (0, true), (0, false), (0, false),
    ]
    for (index, hardened) in path {
      var data: [UInt8]
      if hardened {
        data = [0] + secret
      } else {
        guard let compressed = try? Secp256k1.publicKeyCompressed(secret: secret) else {
          throw SeedPhraseError.derivationFailed
        }
        data = compressed
      }
      let childIndex = hardened ? index | 0x8000_0000 : index
      data.append(UInt8((childIndex >> 24) & 0xff))
      data.append(UInt8((childIndex >> 16) & 0xff))
      data.append(UInt8((childIndex >> 8) & 0xff))
      data.append(UInt8(childIndex & 0xff))
      let digest = hmac(key: chainCode, data: data)
      do {
        let child = try Secp256k1.addTweak(secret: secret, tweak: Array(digest.prefix(32)))
        secret = [UInt8](repeating: 0, count: secret.count)
        secret = child
        chainCode = Array(digest.suffix(32))
      } catch {
        throw SeedPhraseError.derivationFailed
      }
    }
    chainCode = [UInt8](repeating: 0, count: chainCode.count)
    return secret
  }

  private static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
    Array(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }
}
