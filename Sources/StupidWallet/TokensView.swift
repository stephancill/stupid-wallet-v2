import StupidWalletCore
import SwiftUI

#if os(iOS)
  /// Catalog icon when the token has one, otherwise a letter placeholder.
  struct TokenIconView: View {
    let iconURL: URL?
    let symbol: String

    var body: some View {
      Group {
        if let iconURL {
          AsyncImage(url: iconURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            placeholder
          }
        } else {
          placeholder
        }
      }
      .frame(width: 28, height: 28)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .accessibilityHidden(true)
    }

    private var placeholder: some View {
      ZStack {
        Color.secondary.opacity(0.15)
        Text(initial)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }

    private var initial: String {
      symbol.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
        ?? "?"
    }
  }

  struct TokenRowView: View {
    let row: TokenBalanceRow
    var showsBalance = true

    var body: some View {
      HStack(alignment: .center, spacing: 12) {
        TokenIconView(iconURL: row.iconURL, symbol: row.token.symbol)
        VStack(alignment: .leading, spacing: 3) {
          Text(row.token.symbol).foregroundStyle(.primary)
          Text(row.networkName).font(.subheadline).foregroundStyle(.secondary)
        }
        if showsBalance {
          Spacer(minLength: 12)
          VStack(alignment: .trailing, spacing: 3) {
            if let entry = row.entry {
              Text(row.token.displayBalance(raw: entry.raw))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else if row.isLoading {
              ProgressView().accessibilityLabel("Loading balance")
            } else {
              Text("Unavailable").foregroundStyle(.secondary)
            }
          }
        }
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
  }

  struct TokensView: View {
    @ObservedObject var balances: WalletBalanceModel
    @State private var showAdd = false

    var body: some View {
      List {
        Section {
          if balances.rows.isEmpty { Text("No tokens added").foregroundStyle(.secondary) }
          ForEach(balances.rows) { row in
            NavigationLink(destination: TokenDetailView(tokenID: row.id, balances: balances)) {
              TokenRowView(row: row, showsBalance: false)
            }
          }
        }
        Section { Button("Add Token") { showAdd = true } }
        if let error = balances.error { Section { Text(error).foregroundStyle(.red) } }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Tokens")
      .navigationBarTitleDisplayMode(.inline)
      .task { await balances.refresh() }
      .refreshable { await balances.refresh() }
      .sheet(isPresented: $showAdd) { NavigationView { AddTokenView(balances: balances) } }
    }
  }

  struct TokenDetailView: View {
    let tokenID: String
    @ObservedObject var balances: WalletBalanceModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRemoveConfirmation = false

    private var row: TokenBalanceRow? { balances.rows.first { $0.id == tokenID } }

    var body: some View {
      Form {
        if let row {
          Section("Details") {
            LabeledContent("Symbol", value: row.token.symbol)
            LabeledContent("Network", value: row.networkName)
            LabeledContent("Decimals", value: String(row.token.decimals))
            HStack {
              Text("Contract")
              CopyableText(value: row.token.address)
                .frame(maxWidth: .infinity)
            }
          }
          Section {
            Button("Remove Token", role: .destructive) { showRemoveConfirmation = true }
          }
          if let error = balances.error { Section { Text(error).foregroundStyle(.red) } }
        } else {
          Text("This token is no longer tracked.").foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Token")
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { await balances.refresh() }
      .alert(
        "Remove \(row?.token.symbol ?? "Token")?", isPresented: $showRemoveConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Remove Token", role: .destructive, action: remove)
      } message: {
        Text("This removes the token from the tracked list for every account.")
      }
    }

    private func remove() {
      Task {
        await balances.remove(tokenID: tokenID)
        if !balances.rows.contains(where: { $0.id == tokenID }) { dismiss() }
      }
    }
  }

  struct AddTokenView: View {
    @ObservedObject var balances: WalletBalanceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [TokenCandidate] = []
    @State private var networks: [WalletNetwork] = []
    @State private var chainID = ""
    @State private var showNetworkSelector = false
    @State private var isSearching = false
    @State private var message: String?
    @State private var error: String?
    @State private var pendingCandidate: TokenCandidate?
    @State private var isAdding = false
    @State private var lookup: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var initialized = false

    var body: some View {
      List {
        Section {
          HStack(spacing: 8) {
            TextField("Search name, symbol, or address", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.asciiCapable)
              .accessibilityIdentifier("token-search")
            if isSearching {
              ProgressView().accessibilityLabel("Searching")
            }
            if !query.isEmpty {
              Button {
                query = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear search")
              .accessibilityIdentifier("token-search-clear")
            }
          }
        }
        if networks.isEmpty {
          Section {
            Text("Add a network in Settings → Networks first.").foregroundStyle(.secondary)
          }
        } else if showNetworkSelector {
          Section {
            Picker("Network", selection: $chainID) {
              ForEach(networks) { Text($0.name).tag($0.id) }
            }
          }
        }
        if !candidates.isEmpty {
          Section {
            ForEach(candidates) { candidate in
              Button {
                confirmAdd(candidate)
              } label: {
                candidateRow(candidate)
              }
              .buttonStyle(.plain)
              .disabled(candidate.isTracked)
            }
          }
        }
        if let message { Section { Text(message).foregroundStyle(.secondary) } }
        if let error { Section { Text(error).foregroundStyle(.red) } }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Add Token")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
      .onAppear {
        guard !initialized else { return }
        initialized = true
        do {
          networks = try balances.service.context(account: balances.account).networks
          chainID = networks.first?.id ?? ""
          if UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string,
            WalletToken.looksLikeAddress(text)
          {
            query = text.trimmingCharacters(in: .whitespacesAndNewlines)
          }
          search()
        } catch { self.error = error.localizedDescription }
      }
      .onChange(of: query) { _, _ in search() }
      .onChange(of: chainID) { _, _ in reloadAddressFallback() }
      .onChange(of: balances.account) { _, _ in search() }
      .onDisappear { lookup?.cancel() }
      .alert(
        "Add \(pendingCandidate?.symbol ?? "Token")?",
        isPresented: Binding(
          get: { pendingCandidate != nil },
          set: { if !$0 { pendingCandidate = nil } })
      ) {
        Button("Cancel", role: .cancel) { pendingCandidate = nil }
        Button("Add Token") {
          if let candidate = pendingCandidate { add(candidate) }
        }
      } message: {
        if let candidate = pendingCandidate {
          Text("Adds \(candidate.symbol) on \(candidate.networkName) to your tracked tokens.")
        }
      }
    }

    private func candidateRow(_ candidate: TokenCandidate) -> some View {
      HStack(alignment: .center, spacing: 12) {
        TokenIconView(iconURL: candidate.imageURL, symbol: candidate.symbol)
        VStack(alignment: .leading, spacing: 3) {
          Text(candidate.symbol).foregroundStyle(.primary)
          Text(subtitle(candidate)).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        if let marketCap = candidate.marketCapDisplay {
          Text(marketCap).foregroundStyle(.secondary)
        }
        if candidate.isTracked {
          Image(systemName: "checkmark")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Added")
        }
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }

    private func subtitle(_ candidate: TokenCandidate) -> String {
      guard let name = candidate.name else { return candidate.networkName }
      return "\(name) · \(candidate.networkName)"
    }

    /// A contract address loads on the selected network when the catalog does not know it;
    /// any other text searches the catalog.
    private func search() {
      lookup?.cancel()
      generation = UUID()
      let generation = generation
      let account = balances.account
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      candidates = []
      error = nil
      showNetworkSelector = false
      guard !trimmed.isEmpty, !networks.isEmpty else {
        isSearching = false
        message = nil
        return
      }
      isSearching = true
      message = nil
      let addressQuery = WalletToken.looksLikeAddress(trimmed)
      lookup = Task {
        do {
          try await Task.sleep(for: .milliseconds(350))
          try Task.checkCancellation()
          try await performSearch(
            generation: generation, account: account, query: trimmed, addressQuery: addressQuery)
        } catch {
          guard !Task.isCancelled, self.generation == generation else { return }
          isSearching = false
          self.error = error.localizedDescription
        }
      }
    }

    private func performSearch(
      generation: UUID, account: String, query: String, addressQuery: Bool
    ) async throws {
      let context = try balances.service.context(account: account)
      let outcome = try await balances.service.searchTokens(context: context, query: query)
      guard !Task.isCancelled, self.generation == generation else { return }
      guard outcome.candidates.isEmpty else {
        candidates = outcome.candidates
        isSearching = false
        return
      }
      guard addressQuery else {
        isSearching = false
        message = emptyMessage(outcome)
        return
      }
      // The catalog does not know this address on any configured network, so offer an
      // explicit network choice and validate the address on chain there.
      showNetworkSelector = true
      await loadAddress(generation: generation, account: account, address: query, context: context)
    }

    /// Re-runs only the on-chain fallback when the fallback network changes.
    private func reloadAddressFallback() {
      guard showNetworkSelector else { return }
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard WalletToken.looksLikeAddress(trimmed) else { return }
      lookup?.cancel()
      generation = UUID()
      let generation = generation
      let account = balances.account
      candidates = []
      error = nil
      isSearching = true
      message = nil
      lookup = Task {
        do {
          let context = try balances.service.context(account: account)
          await loadAddress(
            generation: generation, account: account, address: trimmed, context: context)
        } catch {
          guard !Task.isCancelled, self.generation == generation else { return }
          isSearching = false
          self.error = error.localizedDescription
        }
      }
    }

    private func loadAddress(
      generation: UUID, account: String, address: String, context: BalanceContext
    ) async {
      guard !chainID.isEmpty else {
        isSearching = false
        return
      }
      let outcome = await balances.service.addressCandidate(
        context: context, chainID: chainID, address: address)
      guard !Task.isCancelled, self.generation == generation else { return }
      isSearching = false
      switch outcome {
      case .success(let candidate):
        candidates = [candidate]
        message = nil
      case .failure(let error):
        message = addressMessage(error)
      }
    }

    private func addressMessage(_ error: TokenError) -> String {
      guard error == .notContract else { return error.localizedDescription }
      let network = networks.first { $0.id == chainID }?.name ?? "this network"
      return "No ERC-20 token found at this address on \(network)."
    }

    private func emptyMessage(_ outcome: TokenSearchOutcome) -> String {
      var text = "No tokens found."
      if outcome.failedNetworkCount > 0 { text += " Some networks could not be searched." }
      return text
    }

    private func confirmAdd(_ candidate: TokenCandidate) {
      guard !isAdding, !candidate.isTracked else { return }
      pendingCandidate = candidate
    }

    private func add(_ candidate: TokenCandidate) {
      pendingCandidate = nil
      isAdding = true
      error = nil
      Task {
        defer { isAdding = false }
        do {
          let context = try balances.service.context(account: balances.account)
          let imported = try await balances.service.inspect(
            context: context, chainID: candidate.chainID, address: candidate.address)
          try balances.service.add(imported: imported, context: context)
          if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index].isTracked = true
          }
          await balances.refresh()
        } catch {
          guard !Task.isCancelled else { return }
          self.error = error.localizedDescription
        }
      }
    }
  }
#endif
