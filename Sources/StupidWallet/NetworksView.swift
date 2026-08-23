import StupidWalletCore
import SwiftUI

#if os(iOS)
  struct NetworksView: View {
    var body: some View {
      List {
        Section("Default Networks") {
          ForEach(NetworkInfo.defaults) { network in
            NavigationLink(destination: NetworkDetailView(network: network)) {
              Text(network.name).font(.body)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Networks")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  struct NetworkDetailView: View {
    let network: NetworkInfo
    @State private var overrideURL: URL?
    @State private var showEditRPCSheet = false
    @State private var showChainIDAsHex = false

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
          Text(effectiveURL.absoluteString)
            .lineLimit(1)
            .truncationMode(.middle)

          Button {
            showEditRPCSheet = true
          } label: {
            Text("Change")
          }

          if overrideURL != nil {
            Button("Use Default RPC", role: .destructive) { removeOverride() }
          }
        } header: {
          Text("RPC URL")
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
    }

    private func load() {
      overrideURL = try? RPCOverrideStore().all()[network.id]
    }

    private func removeOverride() {
      try? RPCOverrideStore().remove(forChainID: network.id)
      overrideURL = nil
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
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
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
