import StupidWalletCore
import SwiftUI

#if os(iOS)
  struct AuthorizationsView: View {
    private enum Action: Equatable {
      case deploy
      case enable
      case replace(delegate: String)
      case revoke
    }

    private struct Confirmation: Identifiable {
      let chainID: String
      let networkName: String
      let action: Action
      var id: String { "\(chainID)-\(String(describing: action))" }
    }

    private let service: AuthorizationService
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [AuthorizationStatus] = []
    @State private var implementationStates: [String: Simple7702AccountImplementationState] = [:]
    @State private var isLoading = true
    @State private var operationChainID: String?
    @State private var submittedChains: Set<String> = []
    @State private var confirmation: Confirmation?
    @State private var errorMessage: String?
    @State private var showingInfo = false
    @State private var refreshGeneration = 0

    init(address: String) {
      service = AuthorizationService(
        account: address,
        signing: KeychainSigner(account: address, store: KeychainKeyStore()),
        networkStore: NetworkStore(),
        resolver: .persisted(),
        rpcClient: RPCClient())
    }

    var body: some View {
      List {
        Section {
          if isLoading && statuses.isEmpty {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          } else {
            ForEach(statuses) { status in
              authorizationRow(status)
            }
          }
        } header: {
          Text("Networks")
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Authorizations")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            showingInfo = true
          } label: {
            Image(systemName: "info.circle")
          }
          .accessibilityLabel("About Authorizations")
        }
      }
      .task { await refresh() }
      .refreshable { await refresh() }
      .alert(item: $confirmation) { confirmation in
        confirmationAlert(confirmation)
      }
      .alert("Authorization Failed", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
      .sheet(isPresented: $showingInfo) {
        NavigationView {
          List {
            Section("Account Authorizations") {
              Text(
                "An EIP-7702 authorization persistently delegates this account on one network. Other networks are unaffected."
              )
              Text(
                "stupid wallet uses delegation for atomic batched calls. If needed, an approved batch first deploys the reviewed implementation, then upgrades the account and executes the batch."
              )
              Text(
                "Enabling or revoking signs both an authorization and its transaction. Each signature uses fresh device-owner authentication, so two Face ID or passcode prompts are expected."
              )
            }
            Section("Canonical Delegate") {
              Text(EIP5792.simple7702Account)
                .textSelection(.enabled)
              Text("Simple7702Account used by the wallet's reviewed EIP-5792 batching flow.")
              Link(
                "View deployed code",
                destination: URL(
                  string: "https://basescan.org/address/\(EIP5792.simple7702Account)#code")!)
            }
          }
          .navigationTitle("About Authorizations")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showingInfo = false }
            }
          }
        }
      }
    }

    @ViewBuilder
    private func authorizationRow(_ status: AuthorizationStatus) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(status.network.name)
          Spacer()
          if operationChainID == status.id {
            ProgressView()
          } else {
            stateControl(status)
          }
        }

        switch status.state {
        case .authorized(let delegate)
        where delegate.caseInsensitiveCompare(EIP5792.simple7702Account) != .orderedSame:
          Label("Delegated to a different implementation", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.footnote)
          Text(delegate)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Button("Replace with Simple7702Account") {
            confirmation = Confirmation(
              chainID: status.id, networkName: status.network.name,
              action: .replace(delegate: delegate))
          }
          .disabled(operationChainID != nil)
        case .malformed(let code):
          Label(
            "Unrecognized account code will not be overwritten",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange)
          .font(.footnote)
          Text(code).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        case .unavailable:
          Text("Authorization status unavailable")
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .notAuthorized, .authorized:
          EmptyView()
        }

        implementationControl(status)

        if submittedChains.contains(status.id) {
          Text("Transaction submitted. Pull to refresh if confirmation is still pending.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateControl(_ status: AuthorizationStatus) -> some View {
      switch status.state {
      case .notAuthorized:
        if implementationStates[status.id] == .verified {
          Toggle(
            "", isOn: toggleBinding(status: status, isOn: false, enableAction: .enable)
          )
          .labelsHidden()
          .disabled(operationChainID != nil)
        } else {
          Text("Not Ready").foregroundStyle(.secondary)
        }
      case .authorized(let delegate):
        Toggle(
          "",
          isOn: toggleBinding(
            status: status, isOn: true, enableAction: .replace(delegate: delegate))
        )
        .labelsHidden()
        .disabled(operationChainID != nil)
      case .malformed:
        Text("Unrecognized").foregroundStyle(.secondary)
      case .unavailable:
        Text("Unavailable").foregroundStyle(.secondary)
      }
    }

    @ViewBuilder
    private func implementationControl(_ status: AuthorizationStatus) -> some View {
      switch implementationStates[status.id] {
      case .missing:
        Text("Simple7702Account is not deployed on this network.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Deploy Simple7702Account") {
          confirmation = Confirmation(
            chainID: status.id, networkName: status.network.name, action: .deploy)
        }
        .disabled(operationChainID != nil)
      case .unsafe:
        Label(
          "Simple7702Account address contains unrecognized code",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
        .font(.footnote)
      case .unavailable:
        Text("Implementation status unavailable")
          .font(.footnote)
          .foregroundStyle(.secondary)
      case .verified, nil:
        EmptyView()
      }
    }

    private func toggleBinding(
      status: AuthorizationStatus, isOn: Bool, enableAction: Action
    ) -> Binding<Bool> {
      Binding(
        get: { isOn },
        set: { newValue in
          guard newValue != isOn else { return }
          confirmation = Confirmation(
            chainID: status.id, networkName: status.network.name,
            action: newValue ? enableAction : .revoke)
        })
    }

    private func confirmationAlert(_ confirmation: Confirmation) -> Alert {
      let title: String
      let message: String
      let button: String
      let role: ButtonRole?
      switch confirmation.action {
      case .deploy:
        title = "Deploy Simple7702Account?"
        message =
          "This deploys the wallet's reviewed batching implementation on \(confirmation.networkName). A network transaction and one authentication prompt are required."
        button = "Deploy"
        role = nil
      case .enable:
        title = "Upgrade Account?"
        message =
          "This persistently delegates your account on \(confirmation.networkName) to Simple7702Account. A network transaction and two authentication prompts are required."
        button = "Upgrade"
        role = nil
      case .replace(let delegate):
        title = "Replace Authorization?"
        message =
          "This replaces the existing delegate \(delegate) on \(confirmation.networkName) with Simple7702Account. Review the address carefully. A network transaction and two authentication prompts are required."
        button = "Replace"
        role = .destructive
      case .revoke:
        title = "Revoke Authorization?"
        message =
          "This removes smart account delegation on \(confirmation.networkName). A network transaction and two authentication prompts are required."
        button = "Revoke"
        role = .destructive
      }
      return Alert(
        title: Text(title), message: Text(message),
        primaryButton: .default(Text("Cancel")),
        secondaryButton: role == .destructive
          ? .destructive(Text(button)) { run(confirmation) }
          : .default(Text(button)) { run(confirmation) })
    }

    private func run(_ confirmation: Confirmation) {
      Task {
        operationChainID = confirmation.chainID
        submittedChains.remove(confirmation.chainID)
        defer { operationChainID = nil }
        do {
          let hash: String
          switch confirmation.action {
          case .deploy:
            hash = try await service.deployImplementation(chainID: confirmation.chainID)
          case .enable:
            hash = try await service.enable(chainID: confirmation.chainID)
          case .replace:
            hash = try await service.enable(
              chainID: confirmation.chainID, replacingForeignAuthorization: true)
          case .revoke:
            hash = try await service.revoke(chainID: confirmation.chainID)
          }
          submittedChains.insert(confirmation.chainID)
          try await pollReceipt(transactionHash: hash, chainID: confirmation.chainID)
          await refresh()
        } catch {
          errorMessage = message(for: error)
        }
      }
    }

    private func pollReceipt(transactionHash: String, chainID: String) async throws {
      for _ in 0..<12 {
        switch try await service.receiptStatus(
          transactionHash: transactionHash, chainID: chainID)
        {
        case .pending:
          try await Task.sleep(for: .seconds(2))
        case .confirmed:
          submittedChains.remove(chainID)
          return
        case .reverted:
          submittedChains.remove(chainID)
          throw AuthorizationOperationError.rpc(
            .invalidResponse("The authorization transaction reverted"))
        }
      }
    }

    private func refresh() async {
      refreshGeneration += 1
      let generation = refreshGeneration
      isLoading = true
      async let refreshedStatuses = service.statuses()
      async let implementations = service.implementationStatuses()
      let nextStatuses = await refreshedStatuses
      let nextImplementations = Dictionary(
        uniqueKeysWithValues: await implementations.map { ($0.id, $0.state) })
      guard generation == refreshGeneration else { return }
      statuses = nextStatuses
      implementationStates = nextImplementations
      isLoading = false
    }

    private func message(for error: Error) -> String {
      guard let error = error as? AuthorizationOperationError else {
        if let deployment = error as? Simple7702AccountDeploymentError {
          switch deployment {
          case .alreadyDeployed: return "Simple7702Account is already deployed on this network."
          case .unsafeImplementation:
            return "The Simple7702Account address contains unrecognized code."
          case .missingCanonicalFactory:
            return "The canonical CREATE2 factory is not deployed on this network."
          case .unsafeCanonicalFactory:
            return "The canonical CREATE2 factory contains unrecognized code."
          case .invalidPrimitive:
            return "The reviewed deployment data failed its integrity check."
          }
        }
        return "The authorization could not be updated."
      }
      switch error {
      case .unsupportedChain: return "This network does not support wallet authorizations."
      case .operationInProgress:
        return "Another transaction for this account and network is still being submitted."
      case .missingImplementation:
        return "Simple7702Account is not deployed on this network."
      case .alreadyEnabled: return "This account is already upgraded on this network."
      case .notAuthorized: return "This account is not delegated on this network."
      case .replacementConfirmationRequired:
        return "Replacing a different delegate requires explicit confirmation."
      case .unsafeAccountCode:
        return "Unrecognized account code was not overwritten."
      case .nonceOverflow: return "The account nonce is too large for an EIP-7702 authorization."
      case .signerMismatch: return "The signatures did not match this wallet account."
      case .rpc(.node(let value)):
        return value.nestedString(at: ["message"]) ?? "The network rejected the transaction."
      case .rpc(.transport): return "The network could not be reached."
      case .rpc(.invalidResponse(let message)): return message
      }
    }

    private var errorIsPresented: Binding<Bool> {
      Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } })
    }
  }
#endif
