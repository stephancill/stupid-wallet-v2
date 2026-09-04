import CryptoKit
import Foundation

/// Base64URL helpers shared by the notification signing and storage code.
public enum NotificationBase64URL {
  public static func encode(_ data: Data) -> String {
    let base64 = data.base64EncodedString()
    let url =
      base64
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return url
  }

  public static func decode(_ input: String) -> Data? {
    var transformed =
      input
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while transformed.count % 4 != 0 {
      transformed += "="
    }
    guard let base64 = Data(base64Encoded: transformed) else { return nil }
    return base64
  }
}

/// Canonical inputs for the wallet backend's `v1` request signature.
public enum NotificationCanonicalRequest {
  /// The signed byte sequence the installation key authenticates.
  public static func canonical(
    method: String,
    pathAndQuery: String,
    timestamp: String,
    requestID: String,
    bodyDigestBase64URL: String
  ) -> Data {
    let header =
      "v1\n"
      + method.uppercased() + "\n"
      + pathAndQuery + "\n"
      + timestamp + "\n"
      + requestID + "\n"
      + bodyDigestBase64URL
    return Data(header.utf8)
  }

  /// Base64url SHA-256 of the exact request body bytes.
  public static func bodyDigest(of body: Data) -> String {
    let digest = SHA256.hash(data: body)
    return NotificationBase64URL.encode(Data(digest))
  }
}

/// P-256 verification over the canonical v1 sequence. Both Swift (CryptoKit) and
/// the backend (Web Crypto) can verify the same signature bytes.
public enum NotificationP256Verifier {
  /// Imports an SPKI (DER, base64url) P-256 public key.
  public static func importPublicKey(spkiBase64URL: String) throws -> P256.Signing.PublicKey {
    guard let der = NotificationBase64URL.decode(spkiBase64URL) else {
      throw NotificationCryptoError.invalidBase64
    }
    return try P256.Signing.PublicKey(derRepresentation: der)
  }

  /// Verifies a raw R||S signature (base64url) over a canonical message.
  public static func verify(
    spkiBase64URL: String,
    signatureBase64URL: String,
    canonical: Data
  ) throws -> Bool {
    guard let signatureBytes = NotificationBase64URL.decode(signatureBase64URL) else {
      throw NotificationCryptoError.invalidBase64
    }
    let key = try importPublicKey(spkiBase64URL: spkiBase64URL)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
    return key.isValidSignature(signature, for: canonical)
  }
}

/// Signing helper for generating test keypairs and signatures.
public enum NotificationP256Signer {
  /// Creates a fresh P-256 keypair and returns the SPKI (base64url) + a signer.
  public static func generateKeypair() -> (
    publicKeySpkiBase64URL: String, sign: (Data) throws -> String
  ) {
    let privateKey = P256.Signing.PrivateKey()
    let publicKey = privateKey.publicKey
    let spki = publicKey.derRepresentation
    return (
      publicKeySpkiBase64URL: NotificationBase64URL.encode(spki),
      sign: { data in
        let signatureData = try privateKey.signature(for: data)
        return NotificationBase64URL.encode(signatureData.rawRepresentation)
      }
    )
  }
}

public enum NotificationCryptoError: Error, Sendable {
  case invalidBase64
  case signingFailed
}
