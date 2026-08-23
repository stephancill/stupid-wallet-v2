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
    @State private var didCopyHash = false

    var body: some View {
      Form {
        if item.kind == .transaction {
          Section("Transaction") {
            if let hash = item.transactionHash {
              Button {
                copy(hash)
              } label: {
                HStack {
                  Text("Hash")
                  Spacer()
                  HStack(spacing: 6) {
                    Text(hash)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                      .truncationMode(.middle)
                    Image(systemName: didCopyHash ? "checkmark" : "doc.on.doc")
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .buttonStyle(.plain)
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

    private func copy(_ hash: String) {
      #if canImport(UIKit)
        UIPasteboard.general.string = hash
      #endif
      didCopyHash = true
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        didCopyHash = false
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

  private func makeWalletService() -> WalletService {
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
