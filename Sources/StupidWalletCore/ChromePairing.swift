import CryptoKit
import Foundation
import Security

/// Browser-authentication keys are unrelated to Ethereum wallet keys.
public enum ChromePairing {
  public static func transcript(profile: String, nonce: String, publicKey: String) -> Data {
    Data("stupid-wallet-pair-v1\n\(profile)\n\(nonce)\n\(publicKey)".utf8)
  }
  public static func approval(
    profile: String, nonce: String, request: String, revision: UInt64, digest: String
  ) -> Data {
    Data("stupid-wallet-approve-v1\n\(profile)\n\(nonce)\n\(request)\n\(revision)\n\(digest)".utf8)
  }
  public static func code(transcript: Data) -> String {
    SHA256.hash(data: transcript).prefix(6).map { String(format: "%02X", $0) }.joined()
  }
  public static func verify(publicKey: String, signature: String, message: Data) -> Bool {
    guard let keyData = Data(base64Encoded: publicKey),
      let signatureData = Data(base64Encoded: signature),
      let key = try? P256.Signing.PublicKey(x963Representation: keyData),
      let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData)
    else { return false }
    return key.isValidSignature(signature, for: message)
  }
  public static func validKey(_ value: String) -> Bool {
    guard let data = Data(base64Encoded: value), data.count == 65 else { return false }
    return (try? P256.Signing.PublicKey(x963Representation: data)) != nil
  }
}

/// Integrity-protected public pairing records in the helper's entitled keychain domain.
public struct ChromePairingStore: Sendable {
  public init() {}
  private func query(profile: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "net.stupidtech.wallet.chrome-pairing-v1",
      kSecAttrAccount as String: profile,
      kSecAttrAccessGroup as String: KeychainKeyStore.productionAccessGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
  public func load(profile: String) throws -> String? {
    var q = query(profile: profile)
    q[kSecReturnData as String] = true
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data,
      let key = String(data: data, encoding: .utf8), ChromePairing.validKey(key)
    else { throw PairingError.storage }
    return key
  }
  public func save(profile: String, publicKey: String) throws {
    guard ChromePairing.validKey(publicKey) else { throw PairingError.storage }
    let bytes = Data(publicKey.utf8)
    let q = query(profile: profile)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw PairingError.storage }
    var item = q
    item[kSecValueData as String] = bytes
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PairingError.storage }
  }
  public func revoke(profile: String) throws {
    let status = SecItemDelete(query(profile: profile) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PairingError.storage
    }
  }
  public enum PairingError: Error { case storage }
}

public struct ChromeApprovalChallenge: Sendable {
  private let publicKey: String
  private let message: Data
  private let expires: Date
  private var consumed = false
  public init(publicKey: String, message: Data, expires: Date) {
    self.publicKey = publicKey
    self.message = message
    self.expires = expires
  }
  public mutating func consume(signature: String, now: Date = Date()) -> Bool {
    guard !consumed else { return false }
    consumed = true
    return now < expires
      && ChromePairing.verify(publicKey: publicKey, signature: signature, message: message)
  }
}
