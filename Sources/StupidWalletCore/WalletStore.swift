import Foundation

/// Persists the active new-format wallet address in the shared App Group container so both
/// the app and the Safari extension read/write the same value across processes. Unlike
/// `UserDefaults(suiteName:)`, `containerURL(forSecurityApplicationGroupIdentifier:)`
/// resolves to the same shared container for every process holding the App Group
/// entitlement, which the pending-request store already relies on. The file holds only a
/// public EIP-55 address (never a key), so it is not secret.
public enum WalletStore {
  public enum StoreError: Error, Sendable, Equatable {
    case unavailable
    case accountMismatch
  }

  public static func containerURL(appGroup: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  private static func addressFileURL(appGroup: String, directory: URL? = nil) -> URL? {
    (directory ?? containerURL(appGroup: appGroup))?
      .appendingPathComponent("wallet-address.conf", isDirectory: false)
  }

  /// The active EIP-55 address, or `nil` when no wallet exists yet.
  public static func activeAddress(
    appGroup: String = PendingRequestStore.defaultAppGroup,
    directory: URL? = nil
  ) -> String? {
    guard let url = addressFileURL(appGroup: appGroup, directory: directory),
      let data = try? Data(contentsOf: url)
    else { return nil }
    let value = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// Persists the active address. Atomic write so a partially-written file is never read.
  public static func setAddress(
    _ address: String,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    directory: URL? = nil
  ) throws {
    guard let url = addressFileURL(appGroup: appGroup, directory: directory),
      let data = address.appending("\n").data(using: .utf8)
    else { throw StoreError.unavailable }
    do {
      try data.write(to: url, options: [.atomic])
    } catch {
      throw StoreError.unavailable
    }
  }

  /// Removes only the expected active address so a stale caller cannot forget a replacement
  /// account that became active in the meantime.
  public static func removeAddress(
    _ address: String,
    appGroup: String = PendingRequestStore.defaultAppGroup,
    directory: URL? = nil
  ) throws {
    guard let active = activeAddress(appGroup: appGroup, directory: directory),
      active.caseInsensitiveCompare(address) == .orderedSame
    else { throw StoreError.accountMismatch }
    guard let url = addressFileURL(appGroup: appGroup, directory: directory) else {
      throw StoreError.unavailable
    }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw StoreError.unavailable
    }
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
