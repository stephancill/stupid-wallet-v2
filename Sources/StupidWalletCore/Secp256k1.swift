import CSecp256k1
import Foundation

/// Wrap of the vendored libsecp256k1 for Ethereum key operations.
/// Internal-by-default; only the Ethereum-facing helpers are public.
enum Secp256k1 {
  enum Error: Swift.Error {
    case invalidSecretKey
    case pubkeyFailure
    case signingFailed
    case recoverFailed
  }

  /// Parses a heap-allocated signing context (initialized once per process).
  nonisolated(unsafe) private static let context: OpaquePointer? =
    secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY))

  /// Serializes an uncompressed 64-byte public key (x || y).
  static func publicKeyUncompressed(secret: [UInt8]) throws -> [UInt8] {
    guard secret.count == 32, let context else { throw Error.invalidSecretKey }
    var key = secret
    defer { key = [UInt8](repeating: 0, count: key.count) }
    guard secp256k1_ec_seckey_verify(context, &key) == 1 else {
      throw Error.invalidSecretKey
    }
    var pub = secp256k1_pubkey()
    guard secp256k1_ec_pubkey_create(context, &pub, &key) == 1 else {
      throw Error.pubkeyFailure
    }
    var output = [UInt8](repeating: 0, count: 65)
    var len = output.count
    guard
      secp256k1_ec_pubkey_serialize(context, &output, &len, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED))
        == 1
    else {
      throw Error.pubkeyFailure
    }
    return output
  }

  /// Ethereum address = last 20 bytes of Keccak-256(uncompressed pubkey minus 0x04).
  static func ethAddressFromPublicKey(_ uncompressed: [UInt8]) throws -> [UInt8] {
    guard uncompressed.count == 65 else { throw Error.invalidSecretKey }
    let hash = Keccak.keccak256(Array(uncompressed.dropFirst()))
    return Array(hash.suffix(20))
  }

  /// Signs a 32-byte message hash with a recoverable signature (r || s, recovery id).
  static func signRecoverable(messageHash: [UInt8], secret: [UInt8]) throws -> (
    signature: [UInt8], recovery: Int
  ) {
    guard messageHash.count == 32, secret.count == 32, let context else {
      throw Error.signingFailed
    }
    var msg = messageHash
    var key = secret
    var sig = secp256k1_ecdsa_recoverable_signature()
    guard secp256k1_ecdsa_sign_recoverable(context, &sig, &msg, &key, nil, nil) == 1 else {
      throw Error.signingFailed
    }
    var compact = [UInt8](repeating: 0, count: 64)
    var recid: Int32 = 0
    secp256k1_ecdsa_recoverable_signature_serialize_compact(context, &compact, &recid, &sig)
    // Overwrite secrets in place.
    msg = [UInt8](repeating: 0, count: msg.count)
    key = [UInt8](repeating: 0, count: key.count)
    return (compact, Int(recid))
  }

  /// Recovers the uncompressed public key from a message hash and (r || s || recovery).
  static func recover(messageHash: [UInt8], signature: [UInt8], recovery: Int) throws -> [UInt8] {
    guard messageHash.count == 32, signature.count == 64, let context else {
      throw Error.recoverFailed
    }
    var msg = messageHash
    var compact = signature
    var sig = secp256k1_ecdsa_recoverable_signature()
    guard
      secp256k1_ecdsa_recoverable_signature_parse_compact(context, &sig, &compact, Int32(recovery))
        == 1
    else {
      throw Error.recoverFailed
    }
    var pub = secp256k1_pubkey()
    guard secp256k1_ecdsa_recover(context, &pub, &sig, &msg) == 1 else {
      throw Error.recoverFailed
    }
    var output = [UInt8](repeating: 0, count: 65)
    var len = output.count
    guard
      secp256k1_ec_pubkey_serialize(context, &output, &len, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED))
        == 1
    else {
      throw Error.recoverFailed
    }
    return output
  }

  /// Ensures a 32-byte key is a valid secp256k1 scalar.
  static func validateSecret(_ secret: [UInt8]) -> Bool {
    guard secret.count == 32, let context else { return false }
    var key = secret
    defer { key = [UInt8](repeating: 0, count: key.count) }
    return secp256k1_ec_seckey_verify(context, &key) == 1
  }
}
