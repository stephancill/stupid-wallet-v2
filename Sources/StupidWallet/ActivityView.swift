import StupidWalletCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

#if os(iOS)
  struct ActivityView: View {
    @State private var items: [ActivityRecord] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
      List(items) { item in
        NavigationLink(destination: ActivityDetailView(item: item)) {
          ActivityRow(item: item)
        }
      }
      .overlay(alignment: .center) {
        if isLoading {
          ProgressView()
        } else if items.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "tray").foregroundStyle(.secondary)
            Text("No activity yet").foregroundStyle(.secondary).font(.footnote)
          }
        }
      }
      .overlay(alignment: .top) {
        if let errorMessage {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(errorMessage).foregroundStyle(.primary)
          }
          .padding(8)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .padding(.top, 8)
        }
      }
      .navigationTitle("Activity")
      .navigationBarTitleDisplayMode(.inline)
      .task { await load() }
      .refreshable { await load() }
    }

    private func load() async {
      isLoading = true
      errorMessage = nil
      let service = makeWalletService()
      await service.refreshTransactionActivity()
      do {
        items = try await service.activities()
      } catch {
        errorMessage = "Activity could not be loaded."
      }
      isLoading = false
    }
  }

  struct ActivityDetailView: View {
    let item: ActivityRecord
    @State private var connectedSite: ConnectedSite?

    init(item: ActivityRecord, connectedSite: ConnectedSite? = nil) {
      self.item = item
      _connectedSite = State(initialValue: connectedSite)
    }

    var body: some View {
      Form {
        Section("App") {
          if let connectedSite {
            NavigationLink(destination: ConnectedAppDetailView(site: connectedSite)) {
              detailRow("App", connectedSite.domain)
            }
          } else {
            detailRow("App", appLabel(item.origin))
          }
        }
        if item.kind == .transaction {
          Section("Transaction") {
            if let hash = item.transactionHash {
              HStack {
                Text("Hash")
                CopyableHashText(hash: hash)
                  .frame(maxWidth: .infinity)
              }
            }
            detailRow("Status", item.status.rawValue.capitalized)
            detailRow("Network", NetworkInfo.name(for: normalizedChainID(item.chainID)))
            detailRow("Timestamp", item.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let blockNumber = item.blockNumber {
              detailRow("Block", decimalBlockNumber(blockNumber))
            }
          }
        } else {
          Section("Signature") {
            detailRow("Method", item.method)
            detailRow("Status", item.status.rawValue.capitalized)
          }
          Section("Verification") {
            detailRow("From", item.account, monospaced: true)
            detailRow("Network", NetworkInfo.name(for: normalizedChainID(item.chainID)))
            detailRow("Timestamp", item.createdAt.formatted(date: .abbreviated, time: .shortened))
          }
        }
      }
      .navigationTitle("Details")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        if connectedSite == nil { await loadConnectedSite() }
      }
    }

    private func loadConnectedSite() async {
      connectedSite = await ConnectedSitesStore().all().first { item.belongs(to: $0) }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View
    {
      HStack {
        Text(label)
        Spacer()
        Text(value)
          .font(monospaced ? .system(.body, design: .monospaced) : .body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .multilineTextAlignment(.trailing)
      }
    }

    private func decimalBlockNumber(_ value: String) -> String {
      if value.lowercased().hasPrefix("0x"),
        let number = UInt64(value.dropFirst(2), radix: 16)
      {
        return String(number)
      }
      return UInt64(value).map(String.init) ?? value
    }
  }

  struct ActivityRow: View {
    let item: ActivityRecord

    var body: some View {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 4) {
          Text(appLabel(item.origin))
            .lineLimit(1)
            .truncationMode(.tail)
          HStack(spacing: 6) {
            if item.kind == .transaction, [.submitted, .pending].contains(item.status) {
              ProgressView().controlSize(.small).scaleEffect(0.7)
              Text("Pending")
            } else if item.kind == .transaction,
              [.reverted, .dropped, .replaced].contains(item.status)
            {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .imageScale(.small)
              Text("Failed")
            } else {
              Text(item.kind == .transaction ? "Transaction" : "Signature")
            }
            Text("•")
            Text(NetworkInfo.name(for: normalizedChainID(item.chainID)))
          }
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        }
        Spacer()
        Text(RelativeTime.abbreviated(from: item.createdAt))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }
      .padding(.vertical, 4)
    }
  }

  private struct CopyableHashText: UIViewRepresentable {
    let hash: String

    func makeCoordinator() -> Coordinator {
      Coordinator(transactionHash: hash)
    }

    func makeUIView(context: Context) -> UILabel {
      let label = UILabel()
      label.textColor = .secondaryLabel
      label.textAlignment = .right
      label.lineBreakMode = .byTruncatingMiddle
      label.numberOfLines = 1
      label.isUserInteractionEnabled = true
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

      let interaction = UIEditMenuInteraction(delegate: context.coordinator)
      label.addInteraction(interaction)
      label.addGestureRecognizer(
        UILongPressGestureRecognizer(
          target: context.coordinator,
          action: #selector(Coordinator.showCopyMenu(_:))))
      context.coordinator.label = label
      context.coordinator.interaction = interaction
      return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
      label.text = hash
      context.coordinator.transactionHash = hash
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
      var transactionHash: String
      weak var label: UILabel?
      var interaction: UIEditMenuInteraction?

      init(transactionHash: String) {
        self.transactionHash = transactionHash
      }

      @objc func showCopyMenu(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let label, let interaction else { return }
        interaction.presentEditMenu(
          with: UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: recognizer.location(in: label)))
      }

      func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
      ) -> UIMenu? {
        UIMenu(children: [
          UIAction(title: "Copy") { [transactionHash] _ in
            UIPasteboard.general.string = transactionHash
          }
        ])
      }

      func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
      ) -> CGRect {
        label?.bounds ?? .null
      }
    }
  }

  func makeWalletService() -> WalletService {
    let signing: any Signing
    if let address = WalletStore.activeAddress() {
      signing = KeychainSigner(account: address, store: KeychainKeyStore())
    } else {
      signing = UnavailableSigner()
    }
    return WalletService(signing: signing, resolver: .persisted())
  }

  private func appLabel(_ origin: String) -> String {
    if let host = URL(string: origin)?.host, !host.isEmpty { return host }
    return origin.isEmpty ? "Unknown App" : origin
  }

  private func normalizedChainID(_ value: String) -> String {
    ChainStore.normalize(value) ?? value
  }
#endif
