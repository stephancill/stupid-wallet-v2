import StupidWalletCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
  import UniformTypeIdentifiers
#endif

#if os(iOS)
  struct SettingsView: View {
    let address: String
    let groupKind: WalletGroupKind
    let accountCount: Int
    let forgetAccount: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingForget = false
    @State private var forgetError: String?

    var body: some View {
      NavigationView {
        List {
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
          Section {
            Button(forgetLabel, role: .destructive) {
              isConfirmingForget = true
            }
          }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
          forgetTitle,
          isPresented: $isConfirmingForget
        ) {
          Button(forgetLabel, role: .destructive) {
            Task {
              do {
                try await forgetAccount()
                dismiss()
              } catch {
                forgetError = "The account could not be forgotten. Please try again."
              }
            }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(forgetMessage)
        }
        .alert("Could Not Forget Account", isPresented: errorIsPresented) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(forgetError ?? "")
        }
      }
    }

    private var errorIsPresented: Binding<Bool> {
      Binding(
        get: { forgetError != nil },
        set: { if !$0 { forgetError = nil } }
      )
    }

    private var forgetLabel: String { groupKind == .seed ? "Forget Wallet" : "Forget Account" }

    private var forgetTitle: String {
      groupKind == .seed ? "Forget this wallet?" : "Forget this account?"
    }

    private var forgetMessage: String {
      if groupKind == .seed {
        return
          "This removes the seed and all \(accountCount) derived accounts from this device. Make sure you have a backup."
      }
      return "This removes the private key from this device. Make sure you have a backup."
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
