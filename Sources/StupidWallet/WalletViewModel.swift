import Foundation
import StupidWalletCore

@MainActor
final class WalletViewModel: ObservableObject {
  private let balanceCache = BalanceCache()
  private let groupManager = WalletGroupManager()
  private var stateGeneration = 0
  @Published var addressHex = ""
  @Published var walletGroups: [WalletGroup] = []
  @Published var balance: String?
  @Published var networkBalances: [NetworkBalanceItem] = []
  @Published var chainID = ChainStore.defaultChainID
  @Published var includedNetworkCount = 0
  @Published var isSaving = false
  @Published private(set) var isLoadingInitialState = true
  @Published var errorMessage: String?

  var hasWallet: Bool { !addressHex.isEmpty }
  var hasRegisteredAccounts: Bool { walletGroups.contains { $0.lifecycle == .active } }
  var chainName: String { NetworkInfo.name(for: chainID) }
  var selectedGroup: WalletGroup? {
    walletGroups.first { group in
      group.lifecycle == .active
        && group.accounts.contains {
          $0.lifecycle == .active
            && $0.address.caseInsensitiveCompare(addressHex) == .orderedSame
        }
    }
  }

  init() {
    Task { await adoptAndLoad() }
  }

  /// Idempotent Gate A barrier. The app runs `ensureAdopted()` at every entry so a
  /// `.migrating` registry cannot be skipped; the projection file the registry maintains
  /// continues to drive the visible account.
  @MainActor
  private func adoptAndLoad() async {
    defer { isLoadingInitialState = false }
    stateGeneration += 1
    do {
      let result = try await WalletRegistryAdoption().ensureAdopted()
      guard let registry = result.registry else {
        walletGroups = []
        addressHex = ""
        balance = nil
        return
      }
      walletGroups = registry.groups.filter { $0.lifecycle == .active }
      guard let address = registry.homeSelectedAddress else {
        addressHex = ""
        balance = nil
        networkBalances = []
        return
      }
      addressHex = address
      balance = try balanceCache.balance(account: address)
      errorMessage = nil
    } catch {
      addressHex = ""
      walletGroups = []
      balance = nil
      errorMessage = "Your existing wallet could not be loaded. Please try again."
      return
    }
  }

  func generateSeedPhrase() throws -> String {
    var entropy = try EthereumSeedPhrase.generateEntropy()
    defer { entropy.resetBytes(in: entropy.indices) }
    return try EthereumSeedPhrase.mnemonic(entropy: entropy)
  }

  @discardableResult
  func createSeedWallet(mnemonic: String, groupName: String) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    let shouldSelect = !hasWallet
    do {
      let group = try groupManager.importSeedGroup(mnemonic: mnemonic, label: groupName)
      if shouldSelect {
        _ = try groupManager.selectHomeAccount(address: group.accounts[0].address)
      }
      await adoptAndLoad()
      await refreshBalance()
      return true
    } catch {
      let errorMessage = message(for: error)
      await adoptAndLoad()
      self.errorMessage = errorMessage
      return false
    }
  }

  @discardableResult
  func importWallet(input: String, groupName: String) async -> WalletGroup? {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.split(whereSeparator: \.isWhitespace)
    let shouldSelect = !hasWallet
    do {
      let group: WalletGroup
      if words.count == 1 {
        group = try groupManager.importPrivateKey(privateKey: trimmed, label: groupName)
      } else {
        group = try groupManager.importSeedGroup(mnemonic: trimmed, label: groupName)
      }
      if shouldSelect {
        _ = try groupManager.selectHomeAccount(address: group.accounts[0].address)
      }
      if group.kind == .privateKey {
        await finishWalletImport()
      }
      return group
    } catch {
      let errorMessage = message(for: error)
      await adoptAndLoad()
      self.errorMessage = errorMessage
      return nil
    }
  }

  func finishWalletImport() async {
    await adoptAndLoad()
    await refreshBalance()
  }

  @discardableResult
  func deriveAccount(groupID: UUID, derivationIndex: UInt32? = nil) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    do {
      let account: WalletAccount
      if let derivationIndex {
        account = try groupManager.deriveAccount(
          groupID: groupID, derivationIndex: derivationIndex)
      } else {
        account = try groupManager.deriveAccount(groupID: groupID)
      }
      _ = account
      await adoptAndLoad()
      return true
    } catch {
      let errorMessage = message(for: error)
      await adoptAndLoad()
      self.errorMessage = errorMessage
      return false
    }
  }

  func previewNextAccounts(groupID: UUID, count: Int) async -> [DerivedAccountPreview]? {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    do {
      return try groupManager.previewNextAccounts(groupID: groupID, count: count)
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }

  @discardableResult
  func deriveAccounts(groupID: UUID, derivationIndexes: [UInt32]) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    do {
      _ = try groupManager.deriveAccounts(
        groupID: groupID, derivationIndexes: derivationIndexes)
      await adoptAndLoad()
      return true
    } catch {
      let errorMessage = message(for: error)
      await adoptAndLoad()
      self.errorMessage = errorMessage
      return false
    }
  }

  @discardableResult
  func saveLabels(
    groupLabels: [UUID: String],
    accountLabels: [String: String]
  ) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    do {
      _ = try groupManager.updateLabels(
        groupLabels: groupLabels, accountLabels: accountLabels)
      await adoptAndLoad()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  @discardableResult
  func removeAccount(groupID: UUID, address: String) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    do {
      try groupManager.deleteAccount(groupID: groupID, address: address)
      networkBalances = []
      await adoptAndLoad()
      await refreshBalance()
      return true
    } catch {
      let errorMessage = message(for: error)
      await adoptAndLoad()
      self.errorMessage = errorMessage
      return false
    }
  }

  @discardableResult
  func removeGroup(groupID: UUID) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    do {
      try groupManager.deleteGroup(groupID: groupID)
      networkBalances = []
      await adoptAndLoad()
      await refreshBalance()
      return true
    } catch {
      let errorMessage = message(for: error)
      await adoptAndLoad()
      self.errorMessage = errorMessage
      return false
    }
  }

  @discardableResult
  func selectHomeAccount(address: String) async -> Bool {
    isSaving = true
    defer { isSaving = false }
    errorMessage = nil
    do {
      _ = try groupManager.selectHomeAccount(address: address)
      networkBalances = []
      await adoptAndLoad()
      await refreshBalance()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  func forgetAccount() async throws {
    let account = addressHex
    guard
      let registry = try WalletRegistryStore().loadReady(),
      let group = registry.groups.first(where: { group in
        group.lifecycle == .active
          && group.accounts.contains {
            $0.lifecycle == .active
              && $0.address.caseInsensitiveCompare(account) == .orderedSame
          }
      })
    else { throw WalletGroupManagerError.groupNotFound }
    try WalletGroupManager().deleteGroup(groupID: group.id)
    networkBalances = []
    await adoptAndLoad()
  }

  func refreshBalance() async {
    guard hasWallet else { return }
    let account = addressHex
    let generation = stateGeneration
    do {
      chainID = try ChainStore().currentChainID()
      let included = try NetworkStore().all().filter(\.includeInBalance)
      includedNetworkCount = included.count
      let results = await NativeBalanceService().balances(
        account: account, chainIDs: included.map(\.id))
      guard generation == stateGeneration,
        addressHex.caseInsensitiveCompare(account) == .orderedSame
      else { return }
      let resultsByChain = Dictionary(uniqueKeysWithValues: results.map { ($0.chainID, $0.wei) })
      networkBalances = included.compactMap { network in
        let wei = resultsByChain[network.id] ?? nil
        guard wei?.contains(where: { $0 != 0 }) == true else { return nil }
        return NetworkBalanceItem(
          id: network.id, name: network.name,
          balance: wei.map(NativeBalanceService.formatEther), wei: wei ?? [])
      }
      .sorted {
        if $0.wei == $1.wei {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return NativeBalanceService.isGreater($0.wei, than: $1.wei)
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
    case WalletGroupManagerError.duplicateAccount:
      return "That wallet already exists on this device."
    case WalletGroupManagerError.verificationFailed:
      return "Wallet verification was cancelled or failed. No wallet was added."
    case WalletGroupManagerError.secureStorage:
      return "The wallet could not be unlocked or saved securely."
    case WalletGroupManagerError.wrongGroupKind:
      return "Only seed wallets can add another account."
    case WalletGroupManagerError.registryChanged:
      return "Wallet state changed. Please try again."
    case WalletGroupManagerError.derivationIndexUnavailable:
      return "That derivation index is no longer available. Choose a current index and try again."
    case WalletGroupManagerError.invalidLabel:
      return "Enter a name for every wallet and account."
    case WalletGroupManagerError.lastSeedAccount:
      return "Remove the wallet to delete its final account."
    case WalletGroupManagerError.accountNotFound:
      return "That account is no longer available."
    default:
      return "The wallet could not be saved. Please try again."
    }
  }
}

struct NetworkBalanceItem: Identifiable, Sendable {
  let id: String
  let name: String
  let balance: String?
  let wei: [UInt8]
}

struct NetworkInfo: Identifiable, Sendable {
  let id: String
  let name: String

  static let initial = NetworkStore.initialNetworks.map { NetworkInfo(id: $0.id, name: $0.name) }

  static func name(for chainID: String) -> String {
    ((try? NetworkStore().all()) ?? []).first { $0.id == chainID }?.name
      ?? initial.first { $0.id == chainID }?.name ?? "Chain \(chainID)"
  }
}
