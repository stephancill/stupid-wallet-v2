import Foundation

/// The signing capability the approval path needs. The wallet core treats this as an
/// abstraction so hermetic tests can inject a deterministic implementation, while the
/// production path uses `KeychainSigner` backed by the shared keychain + vendored
/// secp256k1. The signer never sees params; it signs a caller-supplied 32-byte digest.
public protocol Signing: Sendable {
  /// The EIP-55 account this signer controls.
  var account: String { get }

  /// Whether a key is actually present and reachable for this account.
  func hasKey() -> Bool

  /// Signs a 32-byte digest with the account key, returning a 65-byte
  /// `r ‖ s ‖ (recid + 27)` signature. Throws if the key is missing or authentication is
  /// required. Callers must present an authenticated `LAContext` before calling.
  func signDigest(_ digest: [UInt8]) throws -> [UInt8]
}

/// Real signing path: loads the account's secret from the shared keychain and signs
/// through the vendored secp256k1 target. The returned signature is verifiable against
/// `account` via `EthereumSigner.recoverAddress`.
public struct KeychainSigner: Signing {
  public let account: String
  private let store: KeychainKeyStore
  public let appGroup: String

  public init(
    account: String, store: KeychainKeyStore, appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    self.account = account
    self.store = store
    self.appGroup = appGroup
  }

  /// Whether this wallet account is the active, registered one. Reads only the non-secret
  /// App Group default (the address the factory/migration wrote) and NEVER touches the
  /// `.userPresence` keychain item, so it cannot present Face ID. The single device-owner
  /// prompt happens only inside `signDigest`, at actual signing.
  public func hasKey() -> Bool {
    hasActiveWallet()
  }

  public func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    guard digest.count == 32 else { throw SigningError.invalidDigest }
    let secret = try store.load(account: account)
    var secretBytes = secret
    defer {
      for index in secretBytes.indices { secretBytes[index] = 0 }
    }
    let keypair = try EthereumKeypair.from(secret: secretBytes)
    return try EthereumSigner.sign(digest: digest, keypair: keypair)
  }
}

public enum SigningError: Error, Sendable {
  case missingKey(account: String)
  case invalidDigest
  case authenticationRequired
}

extension Signing {
  /// Returns true when this signer actually validates the produced signature against its
  /// own account. Used only for on-device self-tests.
  public func verify(digest: [UInt8], signature: [UInt8]) -> Bool {
    let recovered = try? EthereumSigner.recoverAddress(
      digest: digest, signature: signature)
    return recovered?.lowercased() == account.lowercased()
  }
}

/// Signer used when no key exists in the shared group. Always reports not-ready so the
/// wallet fails loudly rather than pretending to sign.
public struct UnavailableSigner: Signing {
  public let account: String
  public init(account: String = "0x0000000000000000000000000000000000000000") {
    self.account = account
  }
  public func hasKey() -> Bool { false }
  public func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    throw SigningError.missingKey(account: account)
  }
}
