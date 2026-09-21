import Combine
import Foundation
import StupidWalletCore

@MainActor
final class WalletViewModel: ObservableObject {
  let balances = WalletBalanceModel()
  private var balanceObservation: AnyCancellable?
  private let groupManager = WalletGroupManager()
  private var registryUnavailableMessage: String?
  @Published var addressHex = ""
  @Published var walletGroups: [WalletGroup] = []
  var balance: String? { balances.nativeTotal }
  var networkRows: [NativeBalanceRow] { balances.nativeRows }
  @Published var chainID = ChainStore.defaultChainID
  var includedNetworkCount: Int { balances.includedNetworkCount }
  @Published var isSaving = false
  @Published private(set) var isLoadingInitialState = true
  @Published var errorMessage: String?

  var hasWallet: Bool { !addressHex.isEmpty }
  var isWatchOnly: Bool { selectedGroup?.kind == .watchOnly }
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
    balanceObservation = balances.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    Task { await adoptAndLoad() }
  }

  /// Idempotent Gate A barrier. The app runs `ensureAdopted()` at every entry so a
  /// `.migrating` registry cannot be skipped; the projection file the registry maintains
  /// continues to drive the visible account.
  @MainActor
  private func adoptAndLoad() async {
    defer { isLoadingInitialState = false }
    do {
      let result = try await WalletRegistryAdoption().ensureAdopted()
      guard let registry = result.registry else {
        walletGroups = []
        addressHex = ""
        balances.selectAccount("")
        return
      }
      walletGroups = registry.groups.filter { $0.lifecycle == .active }
      guard let address = registry.homeSelectedAddress else {
        addressHex = ""
        balances.selectAccount("")
        return
      }
      addressHex = address
      balances.selectAccount(address)
      registryUnavailableMessage = nil
      errorMessage = nil
    } catch {
      addressHex = ""
      walletGroups = []
      balances.selectAccount("")
      let message = adoptionMessage(for: error)
      registryUnavailableMessage = message
      errorMessage = message
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
      if let address = WalletGroupManager.canonicalWatchOnlyAddress(input: trimmed) {
        group = try groupManager.importWatchOnly(address: address, label: groupName)
      } else if words.count == 1 {
        group = try groupManager.importPrivateKey(privateKey: trimmed, label: groupName)
      } else {
        group = try groupManager.importSeedGroup(mnemonic: trimmed, label: groupName)
      }
      if shouldSelect {
        _ = try groupManager.selectHomeAccount(address: group.accounts[0].address)
      }
      if group.kind != .seed {
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
    await adoptAndLoad()
  }

  func refreshBalance() async {
    guard hasWallet else { return }
    do {
      chainID = try ChainStore().currentChainID()
    } catch {
      errorMessage = "The selected network could not be loaded."
    }
    await balances.refresh()
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
    case WalletGroupManagerError.registryNotReady:
      return registryUnavailableMessage
        ?? "Your existing wallet could not be loaded. Please close and reopen the app to try again."
    case WalletGroupManagerError.verificationFailed:
      return "Wallet verification was cancelled or failed. No wallet was added."
    case WalletGroupManagerError.secureStorage:
      return
        "The wallet could not be unlocked or saved securely. Make sure a device passcode is enabled."
    case WalletGroupManagerError.wrongGroupKind:
      return "Only seed wallets can add another account."
    case WalletGroupManagerError.registryChanged:
      return "Wallet state changed. Please try again."
    case WalletGroupManagerError.derivationIndexUnavailable:
      return "That derivation index is no longer available. Choose a current index and try again."
    case WalletGroupManagerError.invalidLabel:
      return "Enter a name for every wallet and account."
    case WalletGroupManagerError.invalidAddress:
      return "Enter a valid 0x-prefixed, 40-character account address."
    case WalletGroupManagerError.lastSeedAccount:
      return "Remove the wallet to delete its final account."
    case WalletGroupManagerError.accountNotFound:
      return "That account is no longer available."
    default:
      return "The wallet could not be saved. Please try again."
    }
  }

  private func adoptionMessage(for error: Error) -> String {
    if case WalletRegistryAdoptionError.migrationFailed(.cancelled) = error {
      return
        "Wallet recovery authentication was cancelled or unavailable. Make sure a device passcode is enabled, then close and reopen the app to try again."
    }
    return "Your existing wallet could not be loaded. Please try again."
  }
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
