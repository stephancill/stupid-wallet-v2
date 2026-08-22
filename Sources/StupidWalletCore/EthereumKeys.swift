import CSecp256k1
import Foundation

/// Hex byte helpers shared across the core.
public enum Hex {
  public static func encode(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public static func data(_ hex: String) -> [UInt8]? {
    var cleaned = hex.lowercased()
    if cleaned.hasPrefix("0x") { cleaned.removeFirst(2) }
    guard cleaned.count.isMultiple(of: 2), cleaned.allSatisfy({ $0.isHexDigit }) else {
      return nil
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
      let next = cleaned.index(index, offsetBy: 2)
      guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  public static func quantityData(hex: String) -> [UInt8]? {
    var cleaned = hex.lowercased()
    if cleaned.hasPrefix("0x") { cleaned.removeFirst(2) }
    guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
    if !cleaned.count.isMultiple(of: 2) { cleaned.insert("0", at: cleaned.startIndex) }
    return data(cleaned)
  }
}

/// Ethereum account keys derived through the vendored secp256k1 target.
public struct EthereumKeypair: Sendable {
  public let secret: [UInt8]  // 32 bytes
  public let address: String  // EIP-55 checksummed

  public init(secret: [UInt8]) throws {
    guard Secp256k1.validateSecret(secret) else { throw KeyError.invalidSecret }
    let pub = try Secp256k1.publicKeyUncompressed(secret: secret)
    let addressBytes = try Secp256k1.ethAddressFromPublicKey(pub)
    self.secret = secret
    self.address = EIP55.checksum(from: addressBytes)
  }

  /// Builds a keypair from an existing 32-byte secret, validating range/scalar.
  public static func from(secret: [UInt8]) throws -> EthereumKeypair {
    try EthereumKeypair(secret: secret)
  }
}

public enum KeyError: Error, Sendable {
  case invalidSecret
  case randomFailure
}

/// EIP-55 mixed-case checksummed address.
public enum EIP55 {
  public static func checksum(from addressBytes: [UInt8]) -> String {
    let lowercase = Hex.encode(addressBytes)
    let hash = Hex.encode(Keccak.keccak256(Array(lowercase.utf8)))
    var result = "0x"
    for (index, char) in lowercase.enumerated() {
      let hashChar = hash[hash.index(hash.startIndex, offsetBy: index)]
      if hashChar >= "8" {
        result += String(char).uppercased()
      } else {
        result.append(char)
      }
    }
    return result
  }
}

/// Signer for raw message hashes and EIP-191/712 digests. Returns a compact signature
/// (r || s || v) padded to 65 bytes, matching Ethereum's `personal_sign` output.
public enum EthereumSigner {
  /// Signs a 32-byte digest; returns r || s || (recovery + 27) (65 bytes).
  public static func sign(digest: [UInt8], keypair: EthereumKeypair) throws -> [UInt8] {
    let (compact, recid) = try Secp256k1.signRecoverable(
      messageHash: digest, secret: keypair.secret)
    var signature = compact
    signature.append(UInt8(recid + 27))
    return signature
  }

  /// Recovers the EIP-55 address from a message digest and a 65-byte signature (r||s||v).
  public static func recoverAddress(digest: [UInt8], signature: [UInt8]) throws -> String? {
    guard signature.count == 65, digest.count == 32 else { return nil }
    let recovery = Int(signature[64]) - 27
    guard (0...3).contains(recovery) else { return nil }
    let pub = try Secp256k1.recover(
      messageHash: digest, signature: Array(signature[0..<64]), recovery: recovery)
    let addressBytes = try Secp256k1.ethAddressFromPublicKey(pub)
    return EIP55.checksum(from: addressBytes)
  }
}
