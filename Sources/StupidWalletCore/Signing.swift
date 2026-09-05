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

public enum SigningError: Error, Sendable, Equatable {
  case missingKey(account: String)
  case invalidDigest
  case authenticationRequired
  case accountUnavailable
  case accountMismatch
}

public protocol AccountResolving: Sendable {
  func signer(address: String) throws -> any Signing
  func exportPrivateKey(address: String) throws -> String
}

/// Adapts the historical injected signer to account resolution for hermetic callers. It
/// deliberately resolves only that exact account and cannot substitute another signer.
struct InjectedAccountResolver: AccountResolving {
  let signing: any Signing

  func signer(address: String) throws -> any Signing {
    guard signing.account.caseInsensitiveCompare(address) == .orderedSame else {
      throw SigningError.accountUnavailable
    }
    return signing
  }

  func exportPrivateKey(address _: String) throws -> String {
    throw SigningError.accountUnavailable
  }
}

/// Resolves a registered account to its protected source. Seed children are derived only
/// inside the group lifecycle claim and are never persisted as address-keyed keychain items.
public struct WalletAccountResolver: AccountResolving, Sendable {
  private let registryStore: WalletRegistryStore
  private let keyStore: any WalletKeyStoring
  private let seedStore: any WalletSeedStoring
  private let lifecycle: WalletGroupLifecycleCoordinator
  private let cancellation: ProtectedOperationCancellation?

  public init(
    directory: URL? = nil,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    keyStore: KeychainKeyStore = KeychainKeyStore(),
    seedStore: KeychainSeedStore = KeychainSeedStore(),
    cancellation: ProtectedOperationCancellation? = nil
  ) {
    registryStore = WalletRegistryStore(directory: directory, appGroup: appGroup)
    self.keyStore = keyStore
    self.seedStore = seedStore
    self.cancellation = cancellation
    lifecycle = WalletGroupLifecycleCoordinator(directory: directory, appGroup: appGroup)
  }

  init(
    registryStore: WalletRegistryStore,
    keyStore: any WalletKeyStoring,
    seedStore: any WalletSeedStoring,
    lifecycle: WalletGroupLifecycleCoordinator,
    cancellation: ProtectedOperationCancellation? = nil
  ) {
    self.registryStore = registryStore
    self.keyStore = keyStore
    self.seedStore = seedStore
    self.lifecycle = lifecycle
    self.cancellation = cancellation
  }

  public func signer(address: String) throws -> any Signing {
    let context = try resolve(address: address)
    return RegistryAccountSigner(account: context.account.address, resolver: self)
  }

  public func exportPrivateKey(address: String) throws -> String {
    var secret = try withPrivateKey(
      address: address, reason: "Unlock your wallet to reveal your private key"
    ) { $0 }
    defer { secret.resetBytes(in: secret.indices) }
    return "0x" + Hex.encode(secret)
  }

  fileprivate func hasKey(address: String) -> Bool {
    guard let context = try? resolve(address: address) else { return false }
    switch context.group.kind {
    case .privateKey: return keyStore.contains(account: context.account.address)
    case .seed: return seedStore.contains(groupID: context.group.id)
    }
  }

  fileprivate func sign(address: String, digest: [UInt8]) throws -> [UInt8] {
    guard digest.count == 32 else { throw SigningError.invalidDigest }
    return try withPrivateKey(address: address, reason: "Unlock your wallet to sign") { secret in
      try EthereumSigner.sign(digest: digest, keypair: EthereumKeypair.from(secret: secret))
    }
  }

  private struct Context {
    let group: WalletGroup
    let account: WalletAccount
  }

  private func resolve(address: String) throws -> Context {
    guard let registry = try registryStore.loadReady() else {
      throw SigningError.accountUnavailable
    }
    for group in registry.groups where group.lifecycle == .active {
      if let account = group.accounts.first(where: {
        $0.lifecycle == .active && $0.address.caseInsensitiveCompare(address) == .orderedSame
      }) {
        return Context(group: group, account: account)
      }
    }
    throw SigningError.accountUnavailable
  }

  private func withPrivateKey<T>(
    address: String,
    reason: String,
    operation: ([UInt8]) throws -> T
  ) throws -> T {
    guard cancellation?.isCancelled != true else { throw SigningError.authenticationRequired }
    let initial = try resolve(address: address)
    return try lifecycle.withClaim(groupID: initial.group.id) {
      let current = try resolve(address: address)
      guard current.group.id == initial.group.id else { throw SigningError.accountUnavailable }

      var secret: [UInt8]
      switch current.group.kind {
      case .privateKey:
        secret = try keyStore.load(account: current.account.address, reason: reason)
      case .seed:
        guard let index = current.account.derivationIndex else {
          throw SigningError.accountUnavailable
        }
        var entropy = try seedStore.load(groupID: current.group.id, reason: reason)
        defer { entropy.resetBytes(in: entropy.indices) }
        secret = try EthereumSeedPhrase.privateKey(entropy: entropy, index: index)
      }
      defer { secret.resetBytes(in: secret.indices) }
      let derived = try EthereumKeypair.from(secret: secret).address
      guard derived.caseInsensitiveCompare(current.account.address) == .orderedSame else {
        throw SigningError.accountMismatch
      }
      guard cancellation?.isCancelled != true else { throw SigningError.authenticationRequired }
      let result = try operation(secret)
      guard cancellation?.isCancelled != true else { throw SigningError.authenticationRequired }
      return result
    }
  }
}

private struct RegistryAccountSigner: Signing {
  let account: String
  let resolver: WalletAccountResolver

  func hasKey() -> Bool { resolver.hasKey(address: account) }

  func signDigest(_ digest: [UInt8]) throws -> [UInt8] {
    try resolver.sign(address: account, digest: digest)
  }
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
