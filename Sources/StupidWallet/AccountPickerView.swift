import StupidWalletCore
import SwiftUI

#if os(iOS)
  struct AccountPickerView: View {
    @ObservedObject var vm: WalletViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        List {
          ForEach(vm.walletGroups.filter { $0.lifecycle == .active }) { group in
            Section {
              ForEach(group.accounts) { account in
                Button {
                  Task {
                    if await vm.selectHomeAccount(address: account.address) { dismiss() }
                  }
                } label: {
                  HStack(spacing: 12) {
                    BlockieView(seed: account.address.lowercased())
                      .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                      if let index = account.derivationIndex {
                        Text("Account \(index + 1)")
                      } else {
                        Text("Private Key Account")
                      }
                      Text(shortAddress(account.address))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.address.caseInsensitiveCompare(vm.addressHex) == .orderedSame {
                      Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isSaving)
              }

              if group.kind == .seed {
                Button("Add Account", systemImage: "plus") {
                  Task {
                    if await vm.deriveAccount(groupID: group.id) { dismiss() }
                  }
                }
                .disabled(vm.isSaving)
              }
            } header: {
              Text(group.kind == .seed ? "Seed Wallet" : "Private Key Wallet")
            }
          }

          Section("Add Wallet") {
            NavigationLink("Create New Wallet") {
              SeedBackupView(vm: vm) { dismiss() }
            }
            NavigationLink("Import Wallet") {
              ImportWalletView(vm: vm) { dismiss() }
            }
          }

          if let error = vm.errorMessage {
            Section {
              Text(error).foregroundStyle(.red)
            }
          }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
      .interactiveDismissDisabled(vm.isSaving)
    }

    private func shortAddress(_ address: String) -> String {
      address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
    }
  }
#endif
