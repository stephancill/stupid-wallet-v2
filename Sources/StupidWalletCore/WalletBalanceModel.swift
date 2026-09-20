import Combine
import Foundation

public struct TokenBalanceRow: Identifiable, Sendable, Equatable {
  public let token: WalletToken
  public let networkName: String
  /// Catalog display icon, resolved asynchronously; never persisted.
  public var iconURL: URL?
  public var entry: TokenBalanceEntry?
  public var isCached = true
  public var isLoading = false
  public var error: String?
  public var id: String { token.id }
}

public struct NativeBalanceRow: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let balance: String?
  public let wei: [UInt8]
}

/// One instance is shared by Home and Settings. Cached rows are published before any network wait.
@MainActor
public final class WalletBalanceModel: ObservableObject {
  @Published public private(set) var account = ""
  @Published public private(set) var nativeTotal: String?
  @Published public private(set) var nativeRows: [NativeBalanceRow] = []
  @Published public private(set) var rows: [TokenBalanceRow] = []
  @Published public private(set) var includedNetworkCount = 0
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var error: String?
  public let service: WalletBalanceService

  private var active: (id: UUID, context: BalanceContext, task: Task<Void, Never>)?
  private var nativeResults: [String: NativeNetworkBalance] = [:]
  private var iconCache: [String: URL?] = [:]
  private var iconRequests: Set<String> = []

  public init(service: WalletBalanceService = WalletBalanceService()) { self.service = service }

  public func selectAccount(_ address: String) {
    let normalized = address.lowercased()
    guard account != normalized else { return }
    active?.task.cancel()
    active = nil
    account = normalized
    nativeTotal = nil
    nativeRows = []
    nativeResults = [:]
    rows = []
    error = nil
    isRefreshing = false
    includedNetworkCount = 0
    guard !account.isEmpty else { return }
    do {
      nativeTotal = try service.cachedNative(account: account)
      try hydrate(context: service.context(account: account))
    } catch { self.error = error.localizedDescription }
  }

  public func refresh() async {
    guard !account.isEmpty else { return }
    let context: BalanceContext
    do { context = try service.context(account: account) } catch {
      active?.task.cancel()
      active = nil
      isRefreshing = false
      for index in rows.indices { rows[index].isLoading = false }
      self.error = error.localizedDescription
      if nativeTotal == nil { nativeTotal = "Unavailable" }
      return
    }
    if let active, active.context == context {
      await active.task.value
      return
    }
    active?.task.cancel()
    do {
      try hydrate(context: context)
      let refreshID = try service.begin(context: context)
      error = nil
      isRefreshing = true
      nativeResults = [:]
      for index in rows.indices { rows[index].isLoading = true }
      let task = Task { [weak self, service] in
        await service.fetch(context: context) { [weak self] result in
          await self?.receive(result: result, context: context, refreshID: refreshID)
        }
        self?.finish(context: context, refreshID: refreshID)
      }
      active = (refreshID, context, task)
      await task.value
    } catch {
      active = nil
      isRefreshing = false
      self.error = error.localizedDescription
      if nativeTotal == nil { nativeTotal = "Unavailable" }
    }
  }

  public func remove(tokenID: String) async {
    do {
      try service.tokens.remove(tokenID: tokenID)
      active?.task.cancel()
      active = nil
      isRefreshing = false
      rows.removeAll { $0.id == tokenID }
      error = nil
      Task { await refresh() }
    } catch { self.error = error.localizedDescription }
  }

  private func hydrate(context: BalanceContext) throws {
    let snapshot = try service.tokens.load()
    let names = Dictionary(uniqueKeysWithValues: context.networks.map { ($0.id, $0.name) })
    rows = context.tokens.compactMap { token in
      guard let name = names[token.chainID] else { return nil }
      return TokenBalanceRow(
        token: token, networkName: name, iconURL: iconCache[token.id] ?? nil,
        entry: snapshot.balance(account: account, tokenID: token.id))
    }.sorted {
      if $0.token.symbol != $1.token.symbol {
        return $0.token.symbol.localizedStandardCompare($1.token.symbol) == .orderedAscending
      }
      if $0.networkName != $1.networkName {
        return $0.networkName.localizedStandardCompare($1.networkName) == .orderedAscending
      }
      return $0.id < $1.id
    }
    includedNetworkCount = context.networks.filter(\.includeInBalance).count
    resolveIcons(for: context.tokens)
  }

  /// Resolves catalog icons once per session for rows that do not have one yet.
  private func resolveIcons(for tokens: [WalletToken]) {
    for token in tokens where !iconRequests.contains(token.id) {
      iconRequests.insert(token.id)
      Task { [weak self, service] in
        let iconURL = await service.tokenIcon(chainID: token.chainID, address: token.address)
        guard let self else { return }
        iconCache[token.id] = iconURL
        if let index = rows.firstIndex(where: { $0.id == token.id }) {
          rows[index].iconURL = iconURL
        }
      }
    }
  }

  private func receive(result: NetworkBalanceResult, context: BalanceContext, refreshID: UUID) {
    guard active?.id == refreshID, account == context.account, !Task.isCancelled else { return }
    do {
      try service.commit(context: context, refreshID: refreshID, result: result)
      if let native = result.native { nativeResults[native.chainID] = native }
      for read in result.tokens {
        guard let index = rows.firstIndex(where: { $0.id == read.tokenID }) else { continue }
        rows[index].isLoading = false
        switch read.result {
        case .success(let entry):
          rows[index].entry = entry
          rows[index].isCached = false
          rows[index].error = nil
        case .failure(let error):
          rows[index].isCached = true
          rows[index].error = error.localizedDescription
        }
      }
    } catch {
      self.error = error.localizedDescription
      active?.task.cancel()
    }
  }

  private func finish(context: BalanceContext, refreshID: UUID) {
    guard active?.id == refreshID, account == context.account else { return }
    defer {
      active = nil
      isRefreshing = false
      for index in rows.indices { rows[index].isLoading = false }
    }
    guard !Task.isCancelled else { return }
    do {
      // Only native successes decide whether the native aggregate can be replaced.
      let successful = nativeResults.values.compactMap(\.wei)
      if includedNetworkCount == 0 || !successful.isEmpty {
        let total = NativeBalanceService.formatEther(
          bytes: successful.reduce([0], NativeBalanceService.add))
        try service.saveNative(context: context, refreshID: refreshID, balance: total)
        nativeTotal = total
        nativeRows = context.networks.compactMap { network in
          guard let wei = nativeResults[network.id]?.wei, wei.contains(where: { $0 != 0 }) else {
            return nil
          }
          return NativeBalanceRow(
            id: network.id, name: network.name,
            balance: NativeBalanceService.formatEther(bytes: wei), wei: wei)
        }.sorted {
          if $0.wei == $1.wei { return $0.name < $1.name }
          return NativeBalanceService.isGreater($0.wei, than: $1.wei)
        }
      } else if nativeTotal == nil {
        nativeTotal = "Unavailable"
      }
    } catch { self.error = error.localizedDescription }
  }
}
