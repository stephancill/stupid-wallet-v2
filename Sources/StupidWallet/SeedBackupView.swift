import SwiftUI

#if os(iOS)
  struct SeedBackupView: View {
    @ObservedObject var vm: WalletViewModel
    var onSuccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var mnemonic = ""
    @State private var groupName = ""
    @State private var didConfirmBackup = false
    @State private var generationError: String?

    var body: some View {
      List {
        Section("Wallet Name") {
          TextField("Wallet name", text: $groupName)
        }

        Section {
          Text(
            "Write these words down in order. Anyone with this phrase can control every account in this wallet."
          )
          .foregroundStyle(.secondary)
        }

        Section("Recovery Phrase") {
          if mnemonic.isEmpty && generationError == nil {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          } else {
            Text(mnemonic)
              .textSelection(.enabled)
              .privacySensitive()
              .accessibilityIdentifier("seed-backup-phrase")
          }
        }

        Section {
          Button {
            didConfirmBackup.toggle()
          } label: {
            Label(
              "I Saved This Recovery Phrase",
              systemImage: didConfirmBackup ? "checkmark.circle.fill" : "circle")
          }
          .accessibilityValue(didConfirmBackup ? "Confirmed" : "Not confirmed")
          Button("Create Wallet") {
            Task {
              if await vm.createSeedWallet(mnemonic: mnemonic, groupName: groupName) {
                clear()
                onSuccess()
                dismiss()
              }
            }
          }
          .disabled(
            !didConfirmBackup || mnemonic.isEmpty
              || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSaving)
        }

        if let error = generationError ?? vm.errorMessage {
          Section {
            Text(error).foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Back Up Wallet")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        vm.errorMessage = nil
        guard mnemonic.isEmpty else { return }
        do {
          mnemonic = try vm.generateSeedPhrase()
        } catch {
          generationError = "A recovery phrase could not be generated."
        }
      }
      .onDisappear(perform: clear)
      .onChange(of: scenePhase) { _, phase in
        guard phase == .background else { return }
        clear()
        dismiss()
      }
    }

    private func clear() {
      mnemonic = ""
      didConfirmBackup = false
    }
  }
#endif
