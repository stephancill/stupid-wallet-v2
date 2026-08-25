import StupidWalletCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

#if os(iOS)
  struct ActivityView: View {
    let account: String
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
      let service = makeWalletService(account: account)
      do {
        items = try await service.activities(account: account)
      } catch {
        errorMessage = "Activity could not be loaded."
      }
      isLoading = false

      guard !Task.isCancelled else { return }
      await service.refreshTransactionActivity(account: account)
      guard !Task.isCancelled else { return }
      if let refreshedItems = try? await service.activities(account: account) {
        items = refreshedItems
      }
    }
  }

  struct ActivityDetailView: View {
    let item: ActivityRecord
    @State private var connectedSite: ConnectedSite?
    @State private var connectionError = false

    init(item: ActivityRecord, connectedSite: ConnectedSite? = nil) {
      self.item = item
      _connectedSite = State(initialValue: connectedSite)
    }

    var body: some View {
      Form {
        Section("App") {
          if let connectedSite {
            NavigationLink(
              destination: ConnectedAppDetailView(site: connectedSite, account: item.account)
            ) {
              detailRow("App", connectedSite.domain)
            }
          } else {
            detailRow("App", appLabel(item.origin))
            if connectionError {
              Text("Connection state is unavailable.").foregroundStyle(.secondary)
            }
          }
        }
        if item.kind == .transaction {
          Section("Transaction") {
            if let hash = item.transactionHash {
              HStack {
                Text("Hash")
                CopyableText(value: hash)
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
          if let transactionData = item.transactionData {
            activityContentSection(title: "Data", content: transactionData)
          }
        } else {
          Section("Signature") {
            detailRow("Method", item.method)
            detailRow("Status", item.status.rawValue.capitalized)
            if let signature = item.signature, !signature.isEmpty {
              HStack {
                Text("Signature")
                CopyableText(value: signature)
                  .frame(maxWidth: .infinity)
              }
            }
            detailRow("From", item.account)
            detailRow("Network", NetworkInfo.name(for: normalizedChainID(item.chainID)))
            detailRow("Timestamp", item.createdAt.formatted(date: .abbreviated, time: .shortened))
          }
          if let signedMessage = item.signedMessage, !signedMessage.isEmpty {
            signedMessageSection(content: signedMessage, method: item.method)
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
      do {
        connectedSite = try await ConnectedSitesStore().grants(account: item.account).first {
          item.belongs(to: $0)
        }
      } catch {
        connectionError = true
      }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
      HStack {
        Text(label)
        Spacer()
        Text(value)
          .font(.body)
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

    private func activityContentSection(title: String, content: String) -> some View {
      Section(title) {
        Text(content)
          .font(.body)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    @ViewBuilder
    private func signedMessageSection(content: String, method: String) -> some View {
      if method.lowercased() == "eth_signtypeddata_v4",
        let typedData = typedDataDisplay(content)
      {
        Section("Message") {
          VStack(alignment: .leading, spacing: 16) {
            if !typedData.domain.isEmpty {
              typedDataGroup(title: "Domain", fields: typedData.domain)
            }
            if !typedData.message.isEmpty {
              typedDataGroup(title: "Message", fields: typedData.message)
            }
          }
          .overlay {
            CopyableContentOverlay(content: content)
          }
        }
      } else {
        activityContentSection(
          title: "Message", content: displaySignedMessage(content, method: method))
      }
    }

    private func typedDataGroup(title: String, fields: [TypedDataDisplayField]) -> some View {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(.subheadline)
          .fontWeight(.medium)
        ForEach(fields) { field in
          VStack(alignment: .leading, spacing: 4) {
            Text(field.label.uppercased())
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text(field.value)
              .font(.callout)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.vertical, 4)
    }

    private func typedDataDisplay(_ content: String) -> TypedDataDisplay? {
      guard let data = content.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        case .object(let root) = value
      else { return nil }

      let domainOrder = [
        ("name", "Name"),
        ("version", "Version"),
        ("chainId", "Chain"),
        ("verifyingContract", "Verifying Contract"),
      ]
      let domain: [TypedDataDisplayField]
      if case .object(let values)? = root["domain"] {
        domain = domainOrder.compactMap { key, label in
          values[key].map {
            TypedDataDisplayField(label: label, value: formattedJSONValue($0))
          }
        }
      } else {
        domain = []
      }
      let message: [TypedDataDisplayField]
      if case .object(let values)? = root["message"] {
        message = values.keys.sorted().compactMap { key in
          values[key].map {
            TypedDataDisplayField(label: key, value: formattedJSONValue($0))
          }
        }
      } else {
        message = []
      }
      guard !domain.isEmpty || !message.isEmpty else { return nil }
      return TypedDataDisplay(domain: domain, message: message)
    }

    private func formattedJSONValue(_ value: JSONValue) -> String {
      if let string = value.stringValue { return string }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
    }

    private func displaySignedMessage(_ value: String, method: String) -> String {
      guard method.lowercased() == "personal_sign", let bytes = Hex.data(value),
        let decoded = String(bytes: bytes, encoding: .utf8)
      else { return value }
      return decoded
    }
  }

  private struct TypedDataDisplay {
    let domain: [TypedDataDisplayField]
    let message: [TypedDataDisplayField]
  }

  private struct TypedDataDisplayField: Identifiable {
    let label: String
    let value: String
    var id: String { label }
  }

  private struct CopyableContentOverlay: UIViewRepresentable {
    let content: String

    func makeCoordinator() -> Coordinator {
      Coordinator(content: content)
    }

    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.backgroundColor = .clear
      let interaction = UIEditMenuInteraction(delegate: context.coordinator)
      view.addInteraction(interaction)
      let recognizer = UILongPressGestureRecognizer(
        target: context.coordinator,
        action: #selector(Coordinator.showCopyMenu(_:)))
      recognizer.cancelsTouchesInView = false
      view.addGestureRecognizer(recognizer)
      context.coordinator.view = view
      context.coordinator.interaction = interaction
      return view
    }

    func updateUIView(_ view: UIView, context: Context) {
      context.coordinator.content = content
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
      var content: String
      weak var view: UIView?
      var interaction: UIEditMenuInteraction?

      init(content: String) {
        self.content = content
      }

      @objc func showCopyMenu(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let view, let interaction else { return }
        interaction.presentEditMenu(
          with: UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: recognizer.location(in: view)))
      }

      func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
      ) -> UIMenu? {
        UIMenu(children: [
          UIAction(title: "Copy") { [content] _ in
            UIPasteboard.general.string = content
          }
        ])
      }

      func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
      ) -> CGRect {
        view?.bounds ?? .null
      }
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

  private struct CopyableText: UIViewRepresentable {
    let value: String

    func makeCoordinator() -> Coordinator {
      Coordinator(value: value)
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
      label.text = value
      context.coordinator.value = value
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
      var value: String
      weak var label: UILabel?
      var interaction: UIEditMenuInteraction?

      init(value: String) {
        self.value = value
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
          UIAction(title: "Copy") { [value] _ in
            UIPasteboard.general.string = value
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

  func makeWalletService(account: String) -> WalletService {
    let signing =
      (try? WalletAccountResolver().signer(address: account))
      ?? UnavailableSigner(account: account)
    return WalletService(
      signing: signing, resolver: .persisted(), registryStore: WalletRegistryStore())
  }

  private func appLabel(_ origin: String) -> String {
    if let host = URL(string: origin)?.host, !host.isEmpty { return host }
    return origin.isEmpty ? "Unknown App" : origin
  }

  private func normalizedChainID(_ value: String) -> String {
    ChainStore.normalize(value) ?? value
  }
#endif
