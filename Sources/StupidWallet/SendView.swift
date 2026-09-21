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
    }

    /// Exact available balance, trimmed of trailing zeros.
    var balanceDisplay: String {
      isNative
        ? NativeBalanceService.formatEther(bytes: raw)
        : ClearSigningFormatter.scaledDecimal(raw: raw, decimals: Int(decimals))
    }
  }

  struct SendView: View {
    @ObservedObject var vm: WalletViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var amount = ""
    @State private var recipient = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sentHash: String?

    private var assets: [SendAsset] {
      vm.balances.portfolioHoldings.map(SendAsset.init)
    }

    private var selected: SendAsset? {
      assets.first { $0.id == selectedID }
    }

    private var normalizedRecipient: String? {
      let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
      guard WalletToken.looksLikeAddress(trimmed),
        let bytes = Hex.data(trimmed), bytes.contains(where: { $0 != 0 })
      else { return nil }
      return "0x" + Hex.encode(bytes)
    }

    var body: some View {
      NavigationStack {
        Form {
          assetSection
          if let asset = selected {
            amountSection(asset)
          }
          recipientSection
          if vm.isWatchOnly {
            Section {
              Text("This account is watch-only and cannot sign or send.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
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
          if selectedID == nil { selectedID = assets.first?.id }
        }
        .onChange(of: selectedID) { _, _ in amount = "" }
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
          .accessibilityIdentifier("send.asset")
        }
      }
    }

    @ViewBuilder
    private func amountSection(_ asset: SendAsset) -> some View {
      Section("Amount") {
        HStack(spacing: 8) {
          TextField("0", text: $amount)
            .keyboardType(.decimalPad)
            .accessibilityIdentifier("send.amount")
          Text(asset.symbol).foregroundStyle(.secondary)
        }
        Text("Available \(asset.balanceDisplay) \(asset.symbol)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }

    @ViewBuilder
    private var recipientSection: some View {
      Section("To") {
        HStack(spacing: 12) {
          if let address = normalizedRecipient {
            BlockieView(seed: address.lowercased())
              .frame(width: 28, height: 28)
              .accessibilityHidden(true)
          }
          TextField("0x address", text: $recipient)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .accessibilityIdentifier("send.recipient")
        }
      }
    }

    private var canSend: Bool {
      guard !isSending, !vm.isWatchOnly, let asset = selected, normalizedRecipient != nil,
        let units = parsedAmount(for: asset), units.contains(where: { $0 != 0 })
      else { return false }
      return !NativeBalanceService.isGreater(units, than: asset.raw)
    }

    private func parsedAmount(for asset: SendAsset) -> [UInt8]? {
      let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return TokenTransfer.rawUnits(fromDecimal: trimmed, decimals: asset.decimals)
    }

    private func send() {
      guard let asset = selected, let to = normalizedRecipient,
        let units = parsedAmount(for: asset), units.contains(where: { $0 != 0 }),
        !NativeBalanceService.isGreater(units, than: asset.raw)
      else { return }
      errorMessage = nil
      isSending = true
      Task {
        defer { isSending = false }
        do {
          let value: String
          let data: String
          if asset.isNative {
            guard let quantity = Hex.quantity(units) else {
              throw TokenTransferError.amountTooLarge
            }
            value = quantity
            data = "0x"
          } else {
            value = "0x0"
            data = try TokenTransfer.transferCalldata(to: to, rawAmount: units)
          }
          let service = makeWalletService(account: vm.addressHex)
          let hash = try await service.sendTransaction(
            account: vm.addressHex, chainID: asset.chainID, to: to, value: value, data: data)
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
          Text(asset.networkName).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Text(asset.balanceDisplay)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
  }

  private struct SendAssetPickerView: View {
    let assets: [SendAsset]
    @Binding var selectedID: String?

    var body: some View {
      List(assets) { asset in
        Button {
          selectedID = asset.id
        } label: {
          HStack(spacing: 12) {
            SendAssetRow(asset: asset)
            if asset.id == selectedID {
              Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            }
          }
        }
        .buttonStyle(.plain)
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Asset")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
#endif
