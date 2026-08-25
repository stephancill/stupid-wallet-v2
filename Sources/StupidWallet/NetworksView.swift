import StupidWalletCore
import SwiftUI

#if os(iOS)
  struct NetworksView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var networks: [WalletNetwork] = []
    @State private var showAddSheet = false

    var body: some View {
      List {
        Section {
          ForEach(networks) { networkRow($0) }
        }

        Section {
          Button("Add...") { showAddSheet = true }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Networks")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear(perform: load)
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { load() }
      }
      .sheet(isPresented: $showAddSheet, onDismiss: load) {
        NavigationView { AddNetworkView() }
      }
    }

    private func networkRow(_ network: WalletNetwork) -> some View {
      NavigationLink(destination: NetworkDetailView(network: network, onChange: load)) {
        HStack {
          Text(network.name).font(.body)
          Spacer()
          if !network.includeInBalance {
            Image(systemName: "eye.slash").foregroundStyle(.secondary).font(.caption)
          }
        }
      }
    }

    private func load() {
      networks = (try? NetworkStore().all()) ?? []
    }
  }

  struct NetworkDetailView: View {
    let network: WalletNetwork
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var overrideURL: URL?
    @State private var includeInBalance: Bool
    @State private var showEditRPCSheet = false
    @State private var showChainIDAsHex = false
    @State private var showDeleteConfirmation = false
    @State private var deleteError: String?

    init(network: WalletNetwork, onChange: @escaping () -> Void = {}) {
      self.network = network
      self.onChange = onChange
      _includeInBalance = State(initialValue: network.includeInBalance)
    }

    private var effectiveURL: URL {
      overrideURL ?? RPCResolver.defaultURL(forChainID: network.id)
    }

    var body: some View {
      Form {
        Section("Network Information") {
          HStack {
            Text("Name")
            Spacer()
            Text(network.name).foregroundStyle(.secondary)
          }
          Button {
            showChainIDAsHex.toggle()
          } label: {
            HStack {
              Text("Chain ID").foregroundStyle(.primary)
              Spacer()
              Text(showChainIDAsHex ? ChainStore.hexChainID(network.id) ?? network.id : network.id)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
            }
          }
          .buttonStyle(.plain)
        }

        Section {
          Toggle("Include in Total Balance", isOn: $includeInBalance)
            .onChange(of: includeInBalance) { _, included in
              try? NetworkStore().setIncluded(included, chainID: network.id)
              onChange()
            }
        } footer: {
          Text("Balances on included networks are added to the total on the home screen.")
        }

        Section {
          Text(effectiveURL.absoluteString)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Button("Change") { showEditRPCSheet = true }
        } header: {
          Text("RPC URL")
        }

        Section {
          Button("Delete Network", role: .destructive) { showDeleteConfirmation = true }
        }
      }
      .navigationTitle(network.name)
      .navigationBarTitleDisplayMode(.inline)
      .onAppear(perform: load)
      .sheet(isPresented: $showEditRPCSheet) {
        NavigationView {
          EditRPCURLView(chainID: network.id, currentURL: effectiveURL) { url in
            overrideURL = url
            showEditRPCSheet = false
          }
        }
      }
      .confirmationDialog(
        "Delete \(network.name)?", isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete Network", role: .destructive, action: deleteNetwork)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes the network and its custom RPC URL from your wallet.")
      }
      .alert("Network Not Deleted", isPresented: deleteErrorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(deleteError ?? "The network could not be deleted.")
      }
    }

    private func load() {
      overrideURL = try? RPCOverrideStore().all()[network.id]
      includeInBalance =
        (try? NetworkStore().network(chainID: network.id))??.includeInBalance
        ?? network.includeInBalance
    }

    private func deleteNetwork() {
      do {
        let chainStore = ChainStore()
        let wasSelected = try? chainStore.currentChainID() == network.id
        let networkStore = NetworkStore()
        try networkStore.remove(chainID: network.id)
        try? RPCOverrideStore().remove(forChainID: network.id)
        if wasSelected == true, let replacement = try networkStore.all().first {
          try? chainStore.setChainID(replacement.id)
        }
        onChange()
        dismiss()
      } catch {
        deleteError = "The network could not be deleted."
      }
    }

    private var deleteErrorIsPresented: Binding<Bool> {
      Binding(
        get: { deleteError != nil },
        set: { if !$0 { deleteError = nil } })
    }
  }

  struct AddNetworkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chainID = ""
    @State private var rpcURL = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
      Form {
        Section("Network Information") {
          TextField("Name", text: $name).autocorrectionDisabled()
          TextField("Chain ID (decimal or 0x)", text: $chainID).keyboardType(.asciiCapable)
        }
        Section("RPC URL") {
          TextField("https://", text: $rpcURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        }
        if let errorMessage {
          Section { Text(errorMessage).foregroundStyle(.red) }
        }
      }
      .navigationTitle("Add Network")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Checking..." : "Add") { add() }
            .disabled(isSaving || name.isEmpty || chainID.isEmpty || rpcURL.isEmpty)
        }
      }
    }

    private func add() {
      guard let normalized = ChainStore.normalize(chainID), let url = URL(string: rpcURL) else {
        errorMessage = "Enter a valid chain ID and RPC URL."
        return
      }
      isSaving = true
      errorMessage = nil
      Task {
        switch await RPCOverrideValidator.validate(url: url, expectedChainID: normalized) {
        case .success:
          do {
            let networkStore = NetworkStore()
            guard try networkStore.network(chainID: normalized) == nil else {
              throw NetworkStoreError.alreadyExists
            }
            try RPCOverrideStore().set(url, forChainID: normalized)
            do {
              try networkStore.add(name: name, chainID: normalized)
              dismiss()
            } catch {
              try? RPCOverrideStore().remove(forChainID: normalized)
              throw error
            }
          } catch NetworkStoreError.alreadyExists {
            errorMessage = "That network is already in your wallet."
          } catch {
            errorMessage = "The network could not be saved."
          }
        case .failure(.chainMismatch):
          errorMessage = "This RPC URL is for a different network."
        case .failure(.insecure):
          errorMessage = "Use an HTTPS RPC URL."
        default:
          errorMessage = "The RPC URL could not be reached."
        }
        isSaving = false
      }
    }
  }

  struct EditRPCURLView: View {
    let chainID: String
    let currentURL: URL
    let onSave: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rpcURL: String
    @State private var isValidating = false
    @State private var errorMessage: String?

    init(chainID: String, currentURL: URL, onSave: @escaping (URL) -> Void) {
      self.chainID = chainID
      self.currentURL = currentURL
      self.onSave = onSave
      _rpcURL = State(initialValue: currentURL.absoluteString)
    }

    var body: some View {
      Form {
        Section {
          TextField("https://", text: $rpcURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        } header: {
          Text("RPC URL")
        } footer: {
          if let errorMessage {
            Text(errorMessage).foregroundStyle(.red)
          } else {
            Text("Enter the full RPC URL including https://")
          }
        }
      }
      .navigationTitle("Change RPC URL")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(isValidating ? "Checking..." : "Save") { validateAndSave() }
            .disabled(isValidating || rpcURL.isEmpty)
        }
      }
    }

    private func validateAndSave() {
      guard let url = URL(string: rpcURL) else {
        errorMessage = "Enter a valid URL."
        return
      }
      isValidating = true
      errorMessage = nil
      Task {
        switch await RPCOverrideValidator.validate(url: url, expectedChainID: chainID) {
        case .success:
          do {
            try RPCOverrideStore().set(url, forChainID: chainID)
            onSave(url)
          } catch {
            errorMessage = "The RPC URL could not be saved."
          }
        case .failure(.chainMismatch):
          errorMessage = "This RPC URL is for a different network."
        case .failure(.insecure):
          errorMessage = "Use an HTTPS RPC URL."
        default:
          errorMessage = "The RPC URL could not be reached."
        }
        isValidating = false
      }
    }
  }
#endif
