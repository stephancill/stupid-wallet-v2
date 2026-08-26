import StupidWalletCore
import SwiftUI

#if os(iOS)
  struct ImportWalletView: View {
    @ObservedObject var vm: WalletViewModel
    var onSuccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var groupName = ""
    @State private var importedSeedGroupID: UUID?

    private var isValid: Bool {
      let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
      let hex = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
      let words = trimmed.split(whereSeparator: \.isWhitespace)
      let hasName = !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return hasName
        && ((hex.count == 64 && hex.allSatisfy(\.isHexDigit))
          || [12, 15, 18, 21, 24].contains(words.count))
    }

    var body: some View {
      List {
        Section {
          TextField("Wallet group label", text: $groupName)
            .textInputAutocapitalization(.words)
        } header: {
          Text("Wallet Group Label")
        } footer: {
          Text("Use a label that helps you recognize this wallet group.")
        }

        Section {
          TextField("Enter recovery phrase or private key", text: $inputText, axis: .vertical)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .lineLimit(4...8)
            .frame(minHeight: 96, alignment: .topLeading)
            .privacySensitive()
        } header: {
          Text("Recovery Phrase or Private Key")
        } footer: {
          Text(
            "Enter a 12, 15, 18, 21, or 24-word recovery phrase, or a 64-character private key."
          )
        }

        Section {
          Button {
            Task {
              guard let group = await vm.importWallet(input: inputText, groupName: groupName) else {
                return
              }
              inputText = ""
              groupName = ""
              if group.kind == .seed {
                importedSeedGroupID = group.id
              } else {
                onSuccess()
                dismiss()
              }
            }
          } label: {
            HStack(spacing: 8) {
              if vm.isSaving {
                ProgressView()
              }
              Text(vm.isSaving ? "Importing…" : "Import Wallet")
            }
            .frame(maxWidth: .infinity)
          }
          .disabled(!isValid || vm.isSaving)
        }

        if let error = vm.errorMessage, !error.isEmpty {
          Section {
            Text(error)
              .foregroundStyle(.red)
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Import Wallet")
      .navigationBarTitleDisplayMode(.inline)
      .scrollDismissesKeyboard(.interactively)
      .onAppear { vm.errorMessage = nil }
      .navigationDestination(
        isPresented: Binding(
          get: { importedSeedGroupID != nil },
          set: { isPresented in
            guard !isPresented, importedSeedGroupID != nil else { return }
            importedSeedGroupID = nil
            Task {
              await vm.finishWalletImport()
              onSuccess()
              dismiss()
            }
          })
      ) {
        if let groupID = importedSeedGroupID {
          AccountDiscoveryView(vm: vm, groupID: groupID)
        }
      }
    }
  }
#endif
