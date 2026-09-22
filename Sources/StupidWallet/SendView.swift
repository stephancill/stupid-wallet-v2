import StupidWalletCore
import SwiftUI

#if os(iOS)
  /// One concrete send target: a native currency on a chain, or a tracked ERC-20 token.
  struct SendAsset: Identifiable, Equatable {
    let chainID: String
    let symbol: String
    let networkName: String
    let iconURL: URL?
    let address: String?  // nil for the native currency
    let decimals: UInt8
    let raw: [UInt8]
    let priceUSD: String?
    let valueDisplay: String?

    var id: String { "\(chainID):\(address ?? "native")" }
    var isNative: Bool { address == nil }

    init(holding: PortfolioHolding) {
      chainID = holding.chainID
      symbol = holding.symbol
      networkName = holding.networkName
      iconURL = holding.iconURL
      address = holding.address
      decimals = holding.decimals
      raw = holding.raw
      priceUSD = holding.priceUSD
      valueDisplay = holding.valueDisplay
    }

    var balanceDisplay: String {
      DecimalValue.rounded(
        ClearSigningFormatter.scaledDecimal(raw: raw, decimals: Int(decimals)), significantDigits: 6
      ) ?? "—"
    }
  }

  struct SendView: View {
    @ObservedObject var vm: WalletViewModel
    private let initialAssetSearch: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectedID: String?
    @State private var showInitialAssetPicker: Bool
    @State private var amountInput = SendAmountInput()
    @State private var selectedAmountUnit: SendAmountInput.Unit = .token
    @FocusState private var focusedAmount: SendAmountInput.Unit?
    @State private var recipient = ""
    @State private var recipientResolution: ENSResolution?
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sentHash: String?
    @State private var maximumRequest: SendMaximumRequest?
    @State private var maximumAmount: String?

    init(vm: WalletViewModel, initialAssetID: String? = nil, initialAssetSearch: String? = nil) {
      self.vm = vm
      self.initialAssetSearch = initialAssetSearch
      _selectedID = State(initialValue: initialAssetID)
      _showInitialAssetPicker = State(initialValue: initialAssetSearch != nil)
    }

    private var assets: [SendAsset] {
      vm.balances.portfolioHoldings.map(SendAsset.init)
    }

    private var selected: SendAsset? {
      assets.first { $0.id == selectedID }
    }

    private var amount: String { amountInput.token }
    private var decimalSeparator: String { locale.decimalSeparator ?? "." }

    private var normalizedRecipient: String? {
      if let resolution = recipientResolution {
        guard resolution.chainID == selected?.chainID,
          resolution.address.caseInsensitiveCompare(recipient) == .orderedSame
        else { return nil }
      }
      return recipientAddress(from: recipient)
    }

    private var recipientAccount: WalletAccount? {
      vm.walletGroups.filter { $0.lifecycle == .active }.flatMap(\.accounts).first {
        $0.lifecycle == .active && $0.address.caseInsensitiveCompare(recipient) == .orderedSame
      }
    }

    var body: some View {
      NavigationStack {
        Form {
          recipientSection
          assetSection
          if let asset = selected {
            amountSection(asset)
          }
          if let errorMessage {
            Section { Text(errorMessage).foregroundStyle(.red) }
          }
          Section {
            Button(action: send) {
              HStack {
                Spacer()
                if isSending {
                  ProgressView().accessibilityLabel("Sending")
                } else {
                  Text("Send").fontWeight(.semibold)
                }
                Spacer()
              }
            }
            .disabled(!canSend)
            .accessibilityIdentifier("send.submit")
          } footer: {
            if vm.isWatchOnly {
              Text("This account is watch-only and cannot sign or send.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
              .disabled(isSending)
          }
        }
        .onAppear {
          if selectedID == nil, initialAssetSearch == nil { selectedID = assets.first?.id }
        }
        .navigationDestination(isPresented: $showInitialAssetPicker) {
          SendAssetPickerView(
            assets: assets, selectedID: $selectedID, initialSearch: initialAssetSearch ?? "")
        }
        .onChange(of: selectedID) { _, _ in
          amountInput = SendAmountInput()
          selectedAmountUnit = .token
          focusedAmount = nil
          maximumRequest = nil
          maximumAmount = nil
        }
        .onChange(of: focusedAmount) { _, unit in
          if let unit { selectedAmountUnit = unit }
        }
        .onChange(of: selected?.priceUSD) { _, _ in
          if let asset = selected {
            amountInput.refreshUSD(
              decimals: asset.decimals, priceUSD: asset.priceUSD, decimalSeparator: decimalSeparator
            )
          }
        }
        .onChange(of: normalizedRecipient) { _, _ in
          maximumRequest = nil
          if maximumAmount != nil {
            amountInput = SendAmountInput()
            maximumAmount = nil
          }
        }
        .onChange(of: selected?.raw) { _, _ in
          maximumRequest = nil
          if maximumAmount != nil {
            amountInput = SendAmountInput()
            maximumAmount = nil
          }
        }
        .onChange(of: selected?.chainID) { _, _ in
          if recipientResolution != nil {
            recipient = ""
            recipientResolution = nil
          }
        }
        .alert(
          "Sent",
          isPresented: Binding(
            get: { sentHash != nil },
            set: { if !$0 { sentHash = nil } })
        ) {
          Button("Done") { dismiss() }
        } message: {
          Text(sentHash ?? "")
        }
      }
      .task(id: maximumRequest) {
        guard let request = maximumRequest else { return }
        do {
          let service = NativeSendMaximum(
            resolver: RPCResolver(overrides: try RPCOverrideStore().all()))
          let raw = try await service.amount(
            account: request.account, chainID: request.chainID, to: request.recipient,
            balanceCap: request.balance)
          try Task.checkCancellation()
          guard maximumRequest == request, selected?.id == request.assetID,
            vm.addressHex == request.account, normalizedRecipient == request.recipient,
            amount == request.priorAmount
          else { return }
          let value = ClearSigningFormatter.scaledDecimal(raw: raw, decimals: Int(request.decimals))
          editAmount(
            value: value.replacingOccurrences(of: ".", with: decimalSeparator), unit: .token)
          maximumAmount = amount
        } catch {
          guard !Task.isCancelled, maximumRequest == request else { return }
          maximumRequest = nil
          errorMessage =
            (error as? NativeSendMaximumError)?.errorDescription
            ?? "The network fee could not be estimated. Check your connection and try again."
        }
      }
    }

    @ViewBuilder
    private var assetSection: some View {
      Section("Asset") {
        if assets.isEmpty {
          Text("Add a token or include a network before sending.").foregroundStyle(.secondary)
        } else {
          NavigationLink {
            SendAssetPickerView(assets: assets, selectedID: $selectedID)
          } label: {
            if let asset = selected {
              SendAssetRow(asset: asset)
            } else {
              Text("Select an asset").foregroundStyle(.secondary)
            }
          }
          .disabled(isSending)
          .accessibilityIdentifier("send.asset")
        }
      }
    }

    @ViewBuilder
    private func amountSection(_ asset: SendAsset) -> some View {
      Section("Amount") {
        HStack(spacing: 8) {
          TextField(
            "0",
            text: Binding(
              get: { amountInput.token },
              set: { if $0 != amountInput.token { editAmount(value: $0, unit: .token) } })
          )
          .keyboardType(.decimalPad)
          .focused($focusedAmount, equals: .token)
          .disabled(isSending)
          .accessibilityLabel("Token amount")
          .accessibilityIdentifier("send.amount")
          if !amountInput.token.isEmpty { amountClearButton(unit: .token) }
          Button {
            selectMaximum(asset: asset)
          } label: {
            Text("Max")
              .opacity(maximumRequest == nil ? 1 : 0)
              .overlay {
                if maximumRequest != nil { ProgressView().controlSize(.mini) }
              }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .fixedSize()
          .disabled(isSending)
          .accessibilityLabel("Max")
          .accessibilityIdentifier("send.amount.max")
          Text(asset.symbol).foregroundStyle(.secondary).fixedSize()
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        HStack(spacing: 8) {
          TextField(
            SendAmountInput.canConvert(priceUSD: asset.priceUSD) ? "0" : "Price unavailable",
            text: Binding(
              get: { amountInput.usd },
              set: { if $0 != amountInput.usd { editAmount(value: $0, unit: .usd) } })
          )
          .keyboardType(.decimalPad)
          .focused($focusedAmount, equals: .usd)
          .disabled(isSending || !SendAmountInput.canConvert(priceUSD: asset.priceUSD))
          .accessibilityLabel("USD amount")
          .accessibilityIdentifier("send.amount.usd")
          if !amountInput.usd.isEmpty { amountClearButton(unit: .usd) }
          Text("USD").foregroundStyle(.secondary)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        Text(
          selectedAmountUnit == .usd
            ? "Available \(asset.valueDisplay ?? "—")"
            : "Available \(asset.balanceDisplay) \(asset.symbol)"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityIdentifier("send.amount.available")
      }
    }

    private func amountClearButton(unit: SendAmountInput.Unit) -> some View {
      Button {
        editAmount(value: "", unit: unit)
        selectedAmountUnit = unit
        focusedAmount = unit
      } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .disabled(isSending)
      .accessibilityLabel(unit == .token ? "Clear token amount" : "Clear USD amount")
      .accessibilityIdentifier(unit == .token ? "send.amount.clear" : "send.amount.usd.clear")
    }

    private func editAmount(value: String, unit: SendAmountInput.Unit) {
      guard let asset = selected, !isSending else { return }
      maximumRequest = nil
      maximumAmount = nil
      errorMessage = nil
      amountInput.edit(
        value: value, unit: unit, decimals: asset.decimals, priceUSD: asset.priceUSD,
        decimalSeparator: decimalSeparator)
    }

    private func selectMaximum(asset: SendAsset) {
      errorMessage = nil
      maximumRequest = nil
      maximumAmount = nil
      if asset.isNative {
        guard let recipient = normalizedRecipient else {
          errorMessage = "Select a recipient to calculate Max after reserving the network fee."
          return
        }
        maximumRequest = SendMaximumRequest(
          account: vm.addressHex, assetID: asset.id, chainID: asset.chainID, recipient: recipient,
          balance: asset.raw, decimals: asset.decimals, priorAmount: amount)
      } else {
        let value = ClearSigningFormatter.scaledDecimal(
          raw: asset.raw, decimals: Int(asset.decimals))
        editAmount(value: value.replacingOccurrences(of: ".", with: decimalSeparator), unit: .token)
      }
    }

    @ViewBuilder
    private var recipientSection: some View {
      Section("To") {
        NavigationLink {
          SendRecipientPickerView(
            groups: vm.walletGroups, chainID: selected?.chainID ?? vm.chainID,
            networkName: selected?.networkName ?? vm.chainName,
            recipient: $recipient, recipientResolution: $recipientResolution)
        } label: {
          if let address = normalizedRecipient {
            SendRecipientRow(
              address: address,
              label: recipientResolution?.name ?? recipientAccount?.label ?? "Address")
          } else {
            Text("Select a recipient").foregroundStyle(.secondary)
          }
        }
        .disabled(isSending)
        .accessibilityIdentifier("send.recipient")
      }
    }

    private var canSend: Bool {
      guard !isSending, maximumRequest == nil, !vm.isWatchOnly, let asset = selected,
        normalizedRecipient != nil,
        let units = parsedAmount(for: asset), units.contains(where: { $0 != 0 })
      else { return false }
      return !NativeBalanceService.isGreater(units, than: asset.raw)
    }

    private func parsedAmount(for asset: SendAsset) -> [UInt8]? {
      amountInput.rawUnits(decimals: asset.decimals, decimalSeparator: decimalSeparator)
    }

    private func send() {
      guard canSend, let asset = selected, let to = normalizedRecipient,
        let units = parsedAmount(for: asset), units.contains(where: { $0 != 0 }),
        !NativeBalanceService.isGreater(units, than: asset.raw)
      else { return }
      errorMessage = nil
      isSending = true
      Task {
        defer { isSending = false }
        do {
          // Native sends target the recipient; ERC-20 sends target the token contract with the
          // recipient encoded in the transfer calldata.
          let transfer: SendTransfer
          if asset.isNative {
            transfer = try SendTransfer.native(recipient: to, rawAmount: units)
          } else {
            guard let token = asset.address else { throw WalletError.invalidParams }
            transfer = try SendTransfer.erc20(token: token, recipient: to, rawAmount: units)
          }
          let service = makeWalletService(account: vm.addressHex)
          let hash = try await service.sendTransaction(
            account: vm.addressHex, chainID: asset.chainID, to: transfer.to,
            value: transfer.value, data: transfer.data)
          await vm.refreshBalance()
          sentHash = hash
        } catch {
          errorMessage = sendMessage(for: error)
        }
      }
    }

    private func sendMessage(for error: Error) -> String {
      switch error {
      case WalletError.notReady:
        return "This account cannot sign. Add a key-backed account to send."
      case WalletError.authCancelled:
        return "Authentication was cancelled. Nothing was sent."
      case WalletError.queued:
        return "Another transaction is already in progress on this network."
      case TokenTransferError.amountTooLarge:
        return "That amount is too large."
      case WalletError.invalidParams:
        return "Enter a valid recipient and amount."
      case WalletError.rpc(let value):
        return value.nestedString(at: ["message"]) ?? "The network rejected the transaction."
      default:
        return "The transaction could not be sent. Please try again."
      }
    }
  }

  private struct SendAssetRow: View {
    let asset: SendAsset

    var body: some View {
      HStack(spacing: 12) {
        TokenIconView(iconURL: asset.iconURL, symbol: asset.symbol)
        VStack(alignment: .leading, spacing: 3) {
          Text(asset.symbol).foregroundStyle(.primary)
          Text("\(asset.networkName) • \(asset.balanceDisplay) \(asset.symbol)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        Spacer(minLength: 12)
        Text(asset.valueDisplay ?? "—")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
  }

  private struct SendAssetPickerView: View {
    let assets: [SendAsset]
    @Binding var selectedID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    init(assets: [SendAsset], selectedID: Binding<String?>, initialSearch: String = "") {
      self.assets = assets
      _selectedID = selectedID
      _searchText = State(initialValue: initialSearch)
    }

    private var filteredAssets: [SendAsset] {
      let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !query.isEmpty else { return assets }
      return assets.filter {
        $0.symbol.localizedCaseInsensitiveContains(query)
          || $0.networkName.localizedCaseInsensitiveContains(query)
          || ($0.address?.localizedCaseInsensitiveContains(query) ?? false)
      }
    }

    var body: some View {
      List(filteredAssets) { asset in
        Button {
          selectedID = asset.id
          dismiss()
        } label: {
          SendAssetRow(asset: asset)
        }
        .buttonStyle(.plain)
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Asset")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Search assets"
      )
      .overlay {
        if filteredAssets.isEmpty {
          ContentUnavailableView.search(text: searchText)
        }
      }
    }
  }

  private struct SendRecipientRow: View {
    let address: String
    let label: String

    var body: some View {
      HStack(spacing: 12) {
        BlockieView(seed: address.lowercased())
          .frame(width: 28, height: 28)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(label).foregroundStyle(.primary)
          CopyableText(value: address, textStyle: .subheadline, alignment: .left)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
  }

  private struct SendRecipientPickerView: View {
    let groups: [WalletGroup]
    let chainID: String
    let networkName: String
    @Binding var recipient: String
    @Binding var recipientResolution: ENSResolution?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var lookup: RecipientLookup?
    @FocusState private var addressIsFocused: Bool

    private var query: RecipientQuery {
      RecipientQuery(
        input: address.trimmingCharacters(in: .whitespacesAndNewlines), chainID: chainID)
    }

    private var currentLookup: RecipientLookup? {
      lookup?.query == query ? lookup : nil
    }

    private var activeGroups: [WalletGroup] {
      groups.filter { $0.lifecycle == .active && $0.accounts.contains { $0.lifecycle == .active } }
    }

    var body: some View {
      List {
        Section("Address") {
          HStack {
            TextField("Address or ENS name", text: $address)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.URL)
              .submitLabel(.done)
              .focused($addressIsFocused)
              .onSubmit {
                if let resolution = currentLookup?.resolution {
                  selectRecipient(address: resolution.address, resolution: resolution)
                } else {
                  selectRecipient(address: address)
                }
              }
              .accessibilityIdentifier("send.recipient.address")
            if query.input.contains("."), currentLookup == nil {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Resolving for \(networkName)…")
                .accessibilityIdentifier("send.recipient.resolving")
            }
            if !address.isEmpty {
              Button {
                address = ""
                addressIsFocused = true
              } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear address")
              .accessibilityIdentifier("send.recipient.clear")
            }
          }
          if let normalized = recipientAddress(from: address) {
            Button {
              selectRecipient(address: normalized)
            } label: {
              SendRecipientRow(address: normalized, label: "Use address")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("send.recipient.useAddress")
          } else if let resolution = currentLookup?.resolution {
            Button {
              selectRecipient(address: resolution.address, resolution: resolution)
            } label: {
              SendRecipientRow(address: resolution.address, label: resolution.name)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("send.recipient.useENS")
          }
        }
        ForEach(activeGroups) { group in
          Section(group.label) {
            ForEach(group.accounts.filter { $0.lifecycle == .active }) { account in
              Button {
                selectRecipient(address: account.address)
              } label: {
                SendRecipientRow(address: account.address, label: account.label)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("send.recipient.account.\(account.id)")
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Recipient")
      .navigationBarTitleDisplayMode(.inline)
      .task(id: query) {
        let request = query
        lookup = nil
        guard recipientAddress(from: request.input) == nil, request.input.contains(".") else {
          return
        }
        do {
          try await Task.sleep(for: .milliseconds(350))
          let resolver = ENSResolver(
            rpcResolver: RPCResolver(overrides: try RPCOverrideStore().all()))
          let resolution = try await resolver.resolve(name: request.input, chainID: request.chainID)
          try Task.checkCancellation()
          lookup = RecipientLookup(query: request, resolution: resolution)
        } catch {
          guard !Task.isCancelled else { return }
          lookup = RecipientLookup(query: request)
        }
      }
    }

    private func selectRecipient(address: String, resolution: ENSResolution? = nil) {
      guard let normalized = recipientAddress(from: address) else { return }
      recipient = normalized
      recipientResolution = resolution
      addressIsFocused = false
      dismiss()
    }
  }

  private struct RecipientQuery: Hashable {
    let input: String
    let chainID: String
  }

  private struct SendMaximumRequest: Hashable {
    let id = UUID()
    let account: String
    let assetID: String
    let chainID: String
    let recipient: String
    let balance: [UInt8]
    let decimals: UInt8
    let priorAmount: String
  }

  private struct RecipientLookup {
    let query: RecipientQuery
    var resolution: ENSResolution?
  }

  private func recipientAddress(from input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard WalletToken.looksLikeAddress(trimmed),
      let bytes = Hex.data(trimmed), bytes.contains(where: { $0 != 0 })
    else { return nil }
    return EIP55.checksum(from: bytes)
  }
#endif
