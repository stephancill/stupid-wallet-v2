import Foundation
import StupidWalletCore

@MainActor
final class WalletViewModel: ObservableObject {
  @Published var addressHex = ""
  @Published var balance: String?
  @Published var chainID = ChainStore.defaultChainID
  @Published var isSaving = false
  @Published var errorMessage: String?

  var hasWallet: Bool { !addressHex.isEmpty }
  var chainName: String { NetworkInfo.name(for: chainID) }

  init() {
    if let address = WalletStore.activeAddress() {
      addressHex = address
      return
    }
    let backend = SecurityWalletBackend()
    guard backend.oldAddress() != nil else { return }
    switch WalletMigration.migrate(backend: backend) {
    case .success(.migrated(let address)):
      addressHex = address
    case .success(.alreadyMigrated):
      addressHex = WalletStore.activeAddress() ?? ""
    case .success:
      break
    case .failure:
      errorMessage = "Your existing wallet could not be migrated. Please try again."
    }
  }

  func createNewWallet() {
    isSaving = true
    errorMessage = nil
    do {
      addressHex = try WalletFactory.create()
      Task { await refreshBalance() }
    } catch {
      errorMessage = message(for: error)
    }
    isSaving = false
  }

  func importWallet(input: String) {
    isSaving = true
    errorMessage = nil
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.split(whereSeparator: \.isWhitespace)
    do {
      if words.count == 1 {
        addressHex = try WalletFactory.importPrivateKey(trimmed)
      } else {
        addressHex = try WalletFactory.importSeedPhrase(trimmed)
      }
      Task { await refreshBalance() }
    } catch {
      errorMessage = message(for: error)
    }
    isSaving = false
  }

  func forgetAccount() async throws {
    let account = addressHex
    try WalletFactory.forget(account: account)
    await ConnectedSitesStore().disconnectAll(address: account)
    addressHex = ""
    balance = nil
    errorMessage = nil
  }

  func refreshBalance() async {
    guard hasWallet else { return }
    balance = nil
    do {
      chainID = try ChainStore().currentChainID()
      balance = try await NativeBalanceService().balance(account: addressHex, chainID: chainID)
    } catch {
      balance = "Unavailable"
    }
  }

  private func message(for error: Error) -> String {
    switch error {
    case WalletFactory.CreateError.invalidPrivateKey:
      return "Enter a valid 64-character private key."
    case WalletFactory.CreateError.walletAlreadyExists:
      return "A wallet already exists on this device."
    case WalletFactory.CreateError.verificationFailed:
      return "Wallet verification was cancelled or failed. No wallet was saved."
    case WalletFactory.CreateError.registrationFailed:
      return "The wallet could not be shared with the Safari extension. No wallet was saved."
    case SeedPhraseError.invalidWordCount:
      return "Enter a 12, 15, 18, 21, or 24 word seed phrase."
    case SeedPhraseError.invalidWord(let word):
      return "The seed phrase contains an unknown word: \(word)."
    case SeedPhraseError.invalidChecksum:
      return "The seed phrase checksum is invalid."
    case SeedPhraseError.derivationFailed:
      return "The seed phrase could not be derived."
    default:
      return "The wallet could not be saved. Please try again."
    }
  }
}

struct NetworkInfo: Identifiable, Sendable {
  let id: String
  let name: String

  static let defaults = [
    NetworkInfo(id: "1", name: "Ethereum"),
    NetworkInfo(id: "8453", name: "Base"),
    NetworkInfo(id: "42161", name: "Arbitrum One"),
    NetworkInfo(id: "10", name: "Optimism"),
  ]

  static func name(for chainID: String) -> String {
    defaults.first { $0.id == chainID }?.name ?? "Chain \(chainID)"
  }
}
