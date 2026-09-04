import StupidWalletCore
import SwiftUI

#if os(iOS)
  struct NotificationsView: View {
    let address: String
    let accountName: String?
    @ObservedObject var coordinator: NotificationCoordinator

    var body: some View {
      List {
        Section {
          Toggle(
            "Account Activity",
            isOn: Binding(
              get: { coordinator.state.enrolledAddresses.contains(address.lowercased()) },
              set: { enabled in
                Task { await coordinator.setEnabled(enabled, address: address) }
              })
          )
          .disabled(coordinator.isWorking || !coordinator.isAvailable)
        } header: {
          Text(accountName ?? shortAddress)
        } footer: {
          Text(
            "Alerts cover this account on every network listed in Networks. New activity before enrollment is not backfilled."
          )
        }

        if !coordinator.state.chainStages.isEmpty {
          Section("Networks") {
            ForEach(coordinator.state.configuredChains.sorted(), id: \.self) { chainID in
              HStack {
                Text((try? NetworkStore().network(chainID: chainID)?.name) ?? "Chain \(chainID)")
                Spacer()
                Text(stageLabel(coordinator.state.chainStages[chainID]))
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        if coordinator.state.enrolledAddresses.contains(address.lowercased()) {
          Section {
            Button("Send Test Notification") {
              Task { await coordinator.sendTestNotification() }
            }
            .disabled(coordinator.isWorking || !coordinator.isAvailable)
          }
        }

        Section {
          Text(
            "Notifications use a separate device identity and never unlock or sign with your wallet key. The alert contains a general activity category; your account label and blockie are added locally on this device."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        if let error = coordinator.state.lastPublicError {
          Section { Text(error).foregroundStyle(.red) }
        }
      }
      .navigationTitle("Notifications")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        await coordinator.updateDisplayAlias(address: address, label: accountName)
        await coordinator.load()
      }
    }

    private var shortAddress: String {
      address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
    }

    private func stageLabel(_ stage: ChainRegistrationStage?) -> String {
      switch stage {
      case .active: "Active"
      case .enabling: "Enabling"
      case .unsupported: "Unsupported"
      case .error: "Error"
      case .operatorDisabled: "Disabled"
      default: "Staged"
      }
    }
  }
#endif
