import Foundation

/// Persists the active new-format wallet address in the shared App Group container so both
/// the app and the Safari extension read/write the same value across processes. Unlike
/// `UserDefaults(suiteName:)`, `containerURL(forSecurityApplicationGroupIdentifier:)`
/// resolves to the same shared container for every process holding the App Group
/// entitlement, which the pending-request store already relies on. The file holds only a
/// public EIP-55 address (never a key), so it is not secret.
public enum WalletStore {
  public static func containerURL(appGroup: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  private static func addressFileURL(appGroup: String) -> URL? {
    containerURL(appGroup: appGroup)?
      .appendingPathComponent("wallet-address.conf", isDirectory: false)
  }

  /// The active EIP-55 address, or `nil` when no wallet exists yet.
  public static func activeAddress(
    appGroup: String = PendingRequestStore.defaultAppGroup
  ) -> String? {
    guard let url = addressFileURL(appGroup: appGroup),
      let data = try? Data(contentsOf: url)
    else { return nil }
    let value = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// Persists the active address. Atomic write so a partially-written file is never read.
  public static func setAddress(
    _ address: String, appGroup: String = PendingRequestStore.defaultAppGroup
  ) {
    guard let url = addressFileURL(appGroup: appGroup),
      let data = address.appending("\n").data(using: .utf8)
    else { return }
    try? data.write(to: url, options: [.atomic])
  }
}

extension KeychainSigner {
  /// Whether the signer's account is the currently registered active wallet, read from the
  /// shared App Group file (non-secret). Never touches the `.userPresence` keychain, so it
  /// presents no Face ID.
  public func hasActiveWallet() -> Bool {
    WalletStore.activeAddress(appGroup: appGroup)?.lowercased() == account.lowercased()
  }
}
