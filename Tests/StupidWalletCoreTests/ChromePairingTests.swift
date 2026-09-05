import CryptoKit
import Foundation
import Testing

@testable import StupidWalletCore

@Suite struct ChromePairingTests {
  // Public-only vector generated independently with Node Web Crypto ECDSA/P-256/SHA-256.
  let key =
    "BD2I/rnoJG8ueXLG11vMlo4tcmUJzbsFu131ugQAkHIbiQDifev9n8LXHGD2vhU7QcurGxa1CppHgZQghxjuAWs="
  let signature =
    "dp4Y17nQJWdXyYH/l8cqts7J+r1hNymIz97R/Lfh1uicZTnPZrN9yigNp79VCkKQDDj9ZTJbIo6fAABzOvjWwg=="
  let profile = "chrome:11111111-1111-4111-8111-111111111111"
  let nonce = "22222222-2222-4222-8222-222222222222"
  let request = "33333333-3333-4333-8333-333333333333"
  var message: Data {
    ChromePairing.approval(
      profile: profile, nonce: nonce,
      request: request, revision: 7, digest: "digest")
  }

  @Test func webCryptoVectorAndBindings() {
    #expect(ChromePairing.verify(publicKey: key, signature: signature, message: message))
    for changed in [
      ChromePairing.approval(
        profile: profile + "x", nonce: nonce, request: request, revision: 7, digest: "digest"),
      ChromePairing.approval(
        profile: profile, nonce: UUID().uuidString, request: request, revision: 7, digest: "digest"),
      ChromePairing.approval(
        profile: profile, nonce: nonce, request: UUID().uuidString, revision: 7, digest: "digest"),
      ChromePairing.approval(
        profile: profile, nonce: nonce, request: request, revision: 8, digest: "digest"),
      ChromePairing.approval(
        profile: profile, nonce: nonce, request: request, revision: 7, digest: "changed"),
    ] { #expect(!ChromePairing.verify(publicKey: key, signature: signature, message: changed)) }
    #expect(!ChromePairing.verify(publicKey: key, signature: "", message: message))
    #expect(!ChromePairing.validKey("invalid"))
  }
  @Test func replayExpiryAndWrongKeyFailClosed() {
    let now = Date()
    var challenge = ChromeApprovalChallenge(
      publicKey: key, message: message, expires: now.addingTimeInterval(10))
    let first = challenge.consume(signature: signature, now: now)
    #expect(first)
    let replay = challenge.consume(signature: signature, now: now)
    #expect(!replay)
    var expired = ChromeApprovalChallenge(publicKey: key, message: message, expires: now)
    let late = expired.consume(signature: signature, now: now)
    #expect(!late)
    let other = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
    var wrong = ChromeApprovalChallenge(
      publicKey: other, message: message, expires: now.addingTimeInterval(10))
    let mismatch = wrong.consume(signature: signature, now: now)
    #expect(!mismatch)
  }
  @Test func pairingRequiresProofOfPossession() throws {
    let privateKey = P256.Signing.PrivateKey()
    let publicKey = privateKey.publicKey.x963Representation.base64EncodedString()
    let transcript = ChromePairing.transcript(profile: profile, nonce: nonce, publicKey: publicKey)
    let proof = try privateKey.signature(for: transcript).rawRepresentation.base64EncodedString()
    #expect(ChromePairing.verify(publicKey: publicKey, signature: proof, message: transcript))
    #expect(
      !ChromePairing.verify(
        publicKey: publicKey, signature: proof,
        message: ChromePairing.transcript(
          profile: profile, nonce: UUID().uuidString, publicKey: publicKey)))
    #expect(ChromePairing.code(transcript: transcript).count == 12)
  }
}
