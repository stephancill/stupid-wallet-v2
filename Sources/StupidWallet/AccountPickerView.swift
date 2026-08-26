import StupidWalletCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

#if os(iOS)
  struct AccountPickerView: View {
    @ObservedObject var vm: WalletViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var groupLabels: [UUID: String] = [:]
    @State private var accountLabels: [String: String] = [:]
    @State private var pendingRemoval: PendingRemoval?
    @FocusState private var focusedLabel: LabelField?

    var body: some View {
      NavigationStack {
        List {
          ForEach(vm.walletGroups.filter { $0.lifecycle == .active }) { group in
            Section {
              let accounts = group.accounts.filter { $0.lifecycle == .active }
              ForEach(accounts) { account in
                if isEditing {
                  HStack(spacing: 12) {
                    BlockieView(seed: account.address.lowercased())
                      .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                      HStack(spacing: 6) {
                        TextField("Account name", text: accountLabelBinding(account))
                          .fixedSize(horizontal: true, vertical: false)
                          .focused($focusedLabel, equals: .account(account.id))
                          .underline(pattern: .dot, color: .secondary)
                        Spacer(minLength: 0)
                      }
                      Text(shortAddress(account.address))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                  }
                } else {
                  Button {
                    Task { _ = await vm.selectHomeAccount(address: account.address) }
                  } label: {
                    HStack(spacing: 12) {
                      BlockieView(seed: account.address.lowercased())
                        .frame(width: 28, height: 28)
                      VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
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
              }
              .onDelete { offsets in
                guard offsets.count == 1, let index = offsets.first else { return }
                pendingRemoval = PendingRemoval(group: group, account: accounts[index])
              }
              .deleteDisabled(vm.isSaving)

              if group.kind == .seed && !isEditing {
                AddAccountRow(vm: vm, groupID: group.id)
              }
            } header: {
              if isEditing {
                HStack(spacing: 6) {
                  TextField("Wallet name", text: groupLabelBinding(group))
                    .textInputAutocapitalization(.words)
                    .fixedSize(horizontal: true, vertical: false)
                    .focused($focusedLabel, equals: .group(group.id))
                    .underline(pattern: .dot, color: .secondary)
                  Spacer(minLength: 0)
                }
              } else {
                Text(group.label)
              }
            }
          }

          if !isEditing {
            Section("Add Wallet") {
              NavigationLink {
                SeedBackupView(vm: vm)
              } label: {
                Text("Create New Wallet")
                  .foregroundStyle(.tint)
              }
              NavigationLink {
                ImportWalletView(vm: vm)
              } label: {
                Text("Import Wallet")
                  .foregroundStyle(.tint)
              }
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
          if !isEditing {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") { dismiss() }
                .disabled(vm.isSaving)
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(isEditing ? "Done" : "Edit") {
              if isEditing {
                focusedLabel = nil
                Task {
                  await Task.yield()
                  if await vm.saveLabels(
                    groupLabels: groupLabels, accountLabels: accountLabels)
                  {
                    editMode = .inactive
                  }
                }
              } else {
                beginEditing()
              }
            }
            .disabled(vm.isSaving)
          }
        }
        .environment(\.editMode, $editMode)
      }
      .interactiveDismissDisabled(vm.isSaving)
      .alert(
        pendingRemoval?.removesGroup == true ? "Remove Wallet?" : "Remove Account?",
        isPresented: Binding(
          get: { pendingRemoval != nil },
          set: { if !$0 { pendingRemoval = nil } })
      ) {
        Button("Cancel", role: .cancel) { pendingRemoval = nil }
        Button(
          pendingRemoval?.removesGroup == true ? "Remove Wallet" : "Remove Account",
          role: .destructive
        ) {
          guard let removal = pendingRemoval else { return }
          pendingRemoval = nil
          Task {
            let removed =
              removal.removesGroup
              ? await vm.removeGroup(groupID: removal.group.id)
              : await vm.removeAccount(
                groupID: removal.group.id, address: removal.account.address)
            if removed {
              if removal.removesGroup {
                groupLabels.removeValue(forKey: removal.group.id)
                for account in removal.group.accounts {
                  accountLabels.removeValue(forKey: account.address.lowercased())
                }
              } else {
                accountLabels.removeValue(forKey: removal.account.address.lowercased())
              }
            }
          }
        }
      } message: {
        if let removal = pendingRemoval {
          Text(removalMessage(removal))
        }
      }
    }

    private func beginEditing() {
      groupLabels = Dictionary(uniqueKeysWithValues: vm.walletGroups.map { ($0.id, $0.label) })
      accountLabels = Dictionary(
        uniqueKeysWithValues: vm.walletGroups.flatMap(\.accounts).map {
          ($0.address.lowercased(), $0.label)
        })
      editMode = .active
    }

    private var isEditing: Bool { editMode == .active }

    private func groupLabelBinding(_ group: WalletGroup) -> Binding<String> {
      Binding(
        get: { groupLabels[group.id] ?? group.label },
        set: { groupLabels[group.id] = $0 })
    }

    private func accountLabelBinding(_ account: WalletAccount) -> Binding<String> {
      let key = account.address.lowercased()
      return Binding(
        get: { accountLabels[key] ?? account.label },
        set: { accountLabels[key] = $0 })
    }

    private func shortAddress(_ address: String) -> String {
      address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
    }

    private func removalMessage(_ removal: PendingRemoval) -> String {
      let groupLabel = groupLabels[removal.group.id] ?? removal.group.label
      let accountLabel =
        accountLabels[removal.account.address.lowercased()] ?? removal.account.label
      let address = shortAddress(removal.account.address)
      if removal.group.kind == .seed && removal.removesGroup {
        return
          "This is the last account in \(groupLabel) (\(address)). Its recovery phrase and wallet will be removed."
      }
      if removal.removesGroup {
        return "\(accountLabel) (\(address)) and its private key will be removed from this device."
      }
      return
        "\(accountLabel) (\(address)) will be removed. Other accounts in \(groupLabel) will remain available."
    }

    private struct PendingRemoval: Identifiable {
      let group: WalletGroup
      let account: WalletAccount

      var id: String { account.id }
      var removesGroup: Bool {
        group.kind == .privateKey || group.accounts.filter { $0.lifecycle == .active }.count == 1
      }
    }

    private enum LabelField: Hashable {
      case group(UUID)
      case account(String)
    }
  }

  private struct AddAccountRow: View {
    @ObservedObject var vm: WalletViewModel
    let groupID: UUID
    @State private var showsAccountBrowser = false

    var body: some View {
      HStack {
        Label("Add Account", systemImage: "plus")
          .foregroundStyle(vm.isSaving ? Color.secondary : Color.accentColor)
        Spacer()
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .gesture(
        LongPressGesture(minimumDuration: 0.5)
          .exclusively(before: TapGesture())
          .onEnded { value in
            guard !vm.isSaving else { return }
            switch value {
            case .first(true):
              addNextAccount()
            case .second:
              showsAccountBrowser = true
            default:
              break
            }
          }
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Add Account")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { showsAccountBrowser = true }
      .accessibilityAction(named: "Add Next Account") { addNextAccount() }
      .navigationDestination(isPresented: $showsAccountBrowser) {
        AccountDiscoveryView(vm: vm, groupID: groupID)
      }
    }

    private func addNextAccount() {
      Task { _ = await vm.deriveAccount(groupID: groupID) }
    }
  }

  struct AccountDiscoveryView: View {
    @ObservedObject var vm: WalletViewModel
    let groupID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var previews: [DerivedAccountPreview] = []
    @State private var selectedIndexes = Set<UInt32>()
    @State private var isLoading = false

    var body: some View {
      List {
        Section {
          ForEach(previews) { preview in
            Button {
              if selectedIndexes.contains(preview.derivationIndex) {
                selectedIndexes.remove(preview.derivationIndex)
              } else {
                selectedIndexes.insert(preview.derivationIndex)
              }
            } label: {
              HStack(spacing: 12) {
                Image(uiImage: BlockieView.image(seed: preview.address.lowercased()))
                  .resizable()
                  .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                  .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                  Text("Account \(preview.derivationIndex + 1)")
                    .foregroundStyle(.primary)
                  Text(shortAddress(preview.address))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedIndexes.contains(preview.derivationIndex) {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                } else {
                  Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.isSaving)
            .accessibilityLabel(
              "Account \(preview.derivationIndex + 1), \(preview.address)"
            )
            .accessibilityValue(
              selectedIndexes.contains(preview.derivationIndex) ? "Selected" : "Not selected")
          }
        } footer: {
          VStack(spacing: 8) {
            if skipsAccounts {
              Text("Unselected accounts below the highest selection will be skipped.")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isLoading {
              ProgressView()
                .frame(maxWidth: .infinity)
            } else {
              Button("Load More") {
                loadMore()
              }
              .buttonStyle(.plain)
              .font(.body)
              .foregroundStyle(.tint)
              .frame(maxWidth: .infinity)
              .disabled(vm.isSaving)
            }
          }
          .padding(.top, 6)
          .textCase(nil)
        }

        if let error = vm.errorMessage {
          Section {
            Text(error).foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Add Accounts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(selectedIndexes.count > 1 ? "Add \(selectedIndexes.count)" : "Add") {
            let indexes = selectedIndexes.sorted()
            Task {
              if await vm.deriveAccounts(groupID: groupID, derivationIndexes: indexes) {
                dismiss()
              }
            }
          }
          .disabled(selectedIndexes.isEmpty || vm.isSaving)
        }
      }
      .task {
        if previews.isEmpty { loadMore() }
      }
    }

    private func loadMore() {
      isLoading = true
      Task {
        defer { isLoading = false }
        guard
          let values = await vm.previewNextAccounts(
            groupID: groupID, count: previews.count + 10)
        else { return }
        previews = values
      }
    }

    private var skipsAccounts: Bool {
      guard let firstIndex = previews.first?.derivationIndex,
        let lastSelectedIndex = selectedIndexes.max()
      else { return false }
      return previews.contains {
        $0.derivationIndex >= firstIndex && $0.derivationIndex < lastSelectedIndex
          && !selectedIndexes.contains($0.derivationIndex)
      }
    }

    private func shortAddress(_ address: String) -> String {
      address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
    }
  }
#endif
