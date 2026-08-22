import Security
import StupidWalletCore
import SwiftUI

struct ContentView: View {
  @State private var phase: String = "Idle"
  @State private var log = ""

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "wallet.pass.fill")
        .font(.system(size: 40))
        .foregroundStyle(.tint)
      Text("Stupid Wallet")
        .font(.headline)
      Text("Signing happens in the Safari extension when you use a dapp.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Run keychain proof") {
        phase = "Running"
        log = ""
        Task { await runSelfTest() }
      }
      .buttonStyle(.borderedProminent)
      Button("Create a wallet") {
        phase = "Running"
        log = ""
        Task { @MainActor in
          do {
            let address = try WalletFactory.create()
            log = "Created wallet\naddress \(address)"
          } catch {
            log = "FAIL: \(error)"
          }
          phase = "Done"
        }
      }
      Button("Run 4-old→new migration") {
        phase = "Running"
        log = ""
        Task { @MainActor in
          let lines = Self.runMigration()
          log = lines.joined(separator: "\n")
          phase = "Done"
        }
      }
      Text(phase).font(.caption).foregroundStyle(.secondary)
      Text(log).font(.caption2).multilineTextAlignment(.leading).frame(
        maxWidth: .infinity, alignment: .leading)
    }
    .padding()
  }

  @MainActor
  private func runSelfTest() async {
    let lines = Self.performProof()
    log = lines.joined(separator: "\n")
    phase = "Done"
  }

  private static func runMigration() -> [String] {
    let backend = SecurityWalletBackend()
    guard let old = backend.oldAddress() else { return ["No old wallet address found."] }
    let result = WalletMigration.migrate(backend: backend)
    switch result {
    case .success(let outcome):
      switch outcome {
      case .noOldWallet:
        return ["No old wallet present."]
      case .alreadyMigrated:
        return ["Migration already complete (idempotent)."]
      case .skippedNewWalletExists:
        return ["Skipped: a new-format wallet already exists."]
      case .migrated(let address):
        return ["MIGRATED", "old address \(old)", "new address \(address)"]
      }
    case .failure(let error):
      return ["FAIL: \(error)"]
    }
  }

  /// Generates a random key, stores it under a `.userPresence` access control, reloads it
  /// (this is the system authentication prompt on a physical device), and verifies the
  /// address and an authenticated sign/recover round-trip.
  private static func performProof() -> [String] {
    var lines: [String] = []
    let store = KeychainKeyStore(
      service: "co.za.stephancill.stupid-wallet.self-test", accessGroup: nil)
    let account = "selftest-\(UUID().uuidString)"
    defer { store.delete(account: account) }

    guard let generated = Self.randomSecret() else { return ["FAIL: key generation"] }
    var secret = generated
    defer { secret = [UInt8](repeating: 0, count: secret.count) }

    let pair: EthereumKeypair
    do { pair = try EthereumKeypair.from(secret: secret) } catch {
      return ["FAIL: keypair derivation"]
    }
    lines.append("address \(pair.address)")

    do { try store.save(key: secret, account: account) } catch {
      return ["FAIL: keychain save (\(error))"]
    }
    lines.append("save ok")

    let loaded: [UInt8]
    do { loaded = try store.load(account: account) } catch {
      return ["FAIL: keychain load (\(error)) → user-presence not granted"]
    }
    guard loaded == secret else { return ["FAIL: round-trip mismatch"] }
    lines.append("load ok — Face ID/passcode released the key")

    do {
      let fromLoaded = try EthereumKeypair.from(secret: loaded)
      guard fromLoaded.address == pair.address else { return ["FAIL: address drifted"] }
      lines.append("re-derived address matches")
    } catch { return ["FAIL: reload re-derive"] }

    let digest = Keccak.keccak256(Array("keychain proof".utf8))
    if let signature = try? EthereumSigner.sign(digest: digest, keypair: pair),
      let recovered = try? EthereumSigner.recoverAddress(digest: digest, signature: signature),
      recovered == pair.address
    {
      lines.append("sign+recover verify OK")
    } else {
      return ["FAIL: sign/recover"]
    }

    lines.insert("PASS", at: 0)
    return lines
  }

  private static func randomSecret() -> [UInt8]? {
    for _ in 0..<8 {
      var bytes = [UInt8](repeating: 0, count: 32)
      let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      if status == errSecSuccess, (try? EthereumKeypair.from(secret: bytes)) != nil { return bytes }
    }
    return nil
  }
}
