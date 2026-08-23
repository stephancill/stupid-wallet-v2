import Foundation
import StupidWalletCore

@MainActor
final class WalletViewModel: ObservableObject {
  private let balanceCache = BalanceCache()
  @Published var addressHex = ""
  @Published var balance: String?
  @Published var networkBalances: [NetworkBalanceItem] = []
  @Published var chainID = ChainStore.defaultChainID
  @Published var includedNetworkCount = 0
  @Published var isSaving = false
  @Published var errorMessage: String?

  var hasWallet: Bool { !addressHex.isEmpty }
  var chainName: String { NetworkInfo.name(for: chainID) }

  init() {
    if let address = WalletStore.activeAddress() {
      addressHex = address
    } else {
      let backend = SecurityWalletBackend()
      if backend.oldAddress() != nil {
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
    }
    if hasWallet {
      balance = try? balanceCache.balance(account: addressHex)
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
    try? balanceCache.remove(account: account)
    addressHex = ""
    balance = nil
    networkBalances = []
    errorMessage = nil
  }

  func refreshBalance() async {
    guard hasWallet else { return }
    let account = addressHex
    do {
      chainID = try ChainStore().currentChainID()
      let included = try NetworkStore().all().filter(\.includeInBalance)
      includedNetworkCount = included.count
      let results = await NativeBalanceService().balances(
        account: account, chainIDs: included.map(\.id))
      guard addressHex.caseInsensitiveCompare(account) == .orderedSame else { return }
      let resultsByChain = Dictionary(uniqueKeysWithValues: results.map { ($0.chainID, $0.wei) })
      networkBalances = included.compactMap { network in
        let wei = resultsByChain[network.id] ?? nil
        guard wei?.contains(where: { $0 != 0 }) == true else { return nil }
        return NetworkBalanceItem(
          id: network.id, name: network.name,
          balance: wei.map(NativeBalanceService.formatEther))
      }
      let successful = results.compactMap(\.wei)
      let refreshedBalance: String
      if included.isEmpty {
        refreshedBalance = NativeBalanceService.formatEther(bytes: [0])
      } else if successful.isEmpty {
        if balance == nil { balance = "Unavailable" }
        return
      } else {
        refreshedBalance = NativeBalanceService.formatEther(
          bytes: successful.reduce([0], NativeBalanceService.add))
      }
      balance = refreshedBalance
      try? balanceCache.save(balance: refreshedBalance, account: account)
    } catch {
      if balance == nil { balance = "Unavailable" }
    }
  }

  private func message(for error: Error) -> String {
    switch error {
    case WalletFactory.CreateError.invalidPrivateKey:
      return "Enter a valid 64-character private key."
    case WalletFactory.CreateError.walletAlreadyExists:
      return "A wallet already exists on this device."
    case WalletFactory.CreateError.saveFailed:
      return
        "The private key could not be saved securely. Check your device passcode and try again."
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

struct NetworkBalanceItem: Identifiable, Sendable {
  let id: String
  let name: String
  let balance: String?
}

struct NetworkInfo: Identifiable, Sendable {
  let id: String
  let name: String

  static let defaults = WalletNetwork.defaults.map { NetworkInfo(id: $0.id, name: $0.name) }

  static func name(for chainID: String) -> String {
    ((try? NetworkStore().all()) ?? []).first { $0.id == chainID }?.name
      ?? defaults.first { $0.id == chainID }?.name ?? "Chain \(chainID)"
  }
}
