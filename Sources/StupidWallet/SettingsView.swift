import StupidWalletCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
  import UniformTypeIdentifiers
#endif

#if os(iOS)
  struct SettingsView: View {
    let address: String
    let accountName: String?

    var body: some View {
      NavigationView {
        List {
          Section {
            HStack(spacing: 14) {
              BlockieView(seed: address.lowercased())
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(width: 52, height: 52)
              VStack(alignment: .leading, spacing: 3) {
                Text(accountName ?? shortAddress)
                  .font(.headline)
                Text(shortAddress)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected account, \(accountName ?? shortAddress), \(address)")
          }

          Section {
            NavigationLink(destination: NetworksView()) {
              Text("Networks")
            }
            NavigationLink(destination: AuthorizationsView(address: address)) {
              Text("Authorizations")
            }
            NavigationLink(destination: PrivateKeyView(address: address)) {
              Text("Private Key")
            }
          }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
      }
    }

    private var shortAddress: String {
      address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
    }
  }

  struct PrivateKeyView: View {
    let address: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var privateKey = ""
    @State private var isRevealing = false
    @State private var didCopy = false
    @State private var errorMessage: String?
    @State private var clearTask: Task<Void, Never>?

    var body: some View {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Label {
              Text("Security Warning")
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.headline)
            Text(
              "Your private key gives full access to your wallet and funds. Never share it with anyone, and keep it secure."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
          }
        }

        Section("Private Key") {
          if !privateKey.isEmpty {
            Text(privateKey)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(nil)
              .padding(.vertical, 4)
              .privacySensitive()
            Button {
              copyPrivateKey()
            } label: {
              Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .frame(maxWidth: .infinity, alignment: .center)
          } else {
            Button {
              revealPrivateKey()
            } label: {
              if isRevealing { ProgressView() } else { Text("Reveal") }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .disabled(isRevealing)
          }
        }

        if let errorMessage {
          Section {
            Text("Error: \(errorMessage)")
              .foregroundStyle(.red)
              .font(.footnote)
          }
        }
      }
      .navigationTitle("Private Key")
      .navigationBarTitleDisplayMode(.inline)
      .onDisappear(perform: clear)
      .onChange(of: scenePhase) { _, phase in
        if phase == .background { clear() }
      }
    }

    private func revealPrivateKey() {
      isRevealing = true
      errorMessage = nil
      do {
        privateKey = try WalletAccountResolver().exportPrivateKey(address: address)
        scheduleClear()
      } catch {
        errorMessage = "The private key could not be unlocked."
      }
      isRevealing = false
    }

    private func copyPrivateKey() {
      #if canImport(UIKit)
        UIPasteboard.general.setItems(
          [[UTType.utf8PlainText.identifier: privateKey]],
          options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(60),
          ])
      #endif
      didCopy = true
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        didCopy = false
      }
    }

    private func scheduleClear() {
      clearTask?.cancel()
      clearTask = Task {
        try? await Task.sleep(for: .seconds(60))
        guard !Task.isCancelled else { return }
        clear()
      }
    }

    private func clear() {
      clearTask?.cancel()
      clearTask = nil
      privateKey = ""
      didCopy = false
    }
  }
#endif
