import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

#if os(iOS)
  struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = WalletViewModel()
    @State private var showBalanceDetails = false
    @State private var showActivity = false
    @State private var showConnectedApps = false
    @State private var showSettingsSheet = false

    var body: some View {
      NavigationView {
        Group {
          if vm.hasWallet {
            walletView
          } else {
            SetupView(vm: vm)
          }
        }
        .background {
          NavigationLink(destination: ActivityView(), isActive: $showActivity) {
            EmptyView()
          }
          .hidden()
          NavigationLink(
            destination: ConnectedAppsView(address: vm.addressHex),
            isActive: $showConnectedApps
          ) {
            EmptyView()
          }
          .hidden()
        }
        .toolbar {
          if vm.hasWallet {
            ToolbarItem(placement: .navigationBarTrailing) {
              AddressMenuButton(
                address: vm.addressHex,
                showActivity: {
                  showActivity = true
                },
                showConnectedApps: {
                  showConnectedApps = true
                },
                showSettings: {
                  showSettingsSheet = true
                }
              )
              .frame(width: 28, height: 28)
            }
          }
        }
      }
      .sheet(
        isPresented: $showSettingsSheet,
        onDismiss: {
          Task { await vm.refreshBalance() }
        }
      ) {
        SettingsView(address: vm.addressHex) {
          try await vm.forgetAccount()
        }
      }
      .task {
        await vm.refreshBalance()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await vm.refreshBalance() } }
      }
    }

    private var walletView: some View {
      ScrollView {
        VStack {
          Spacer()
          VStack(alignment: .center) {
            HStack {
              Spacer()
              Button {
                showBalanceDetails = true
              } label: {
                HStack(alignment: .center, spacing: 8) {
                  if let balance = vm.balance {
                    Text("♦ \(balance)")
                      .font(.system(size: 48, weight: .bold))
                      .foregroundStyle(.primary)
                      .lineLimit(1)
                      .minimumScaleFactor(0.4)
                      .allowsTightening(true)
                  } else {
                    ProgressView()
                  }
                  if !vm.networkBalances.isEmpty {
                    Image(systemName: showBalanceDetails ? "chevron.up" : "chevron.down")
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .buttonStyle(.plain)
              .disabled(vm.networkBalances.isEmpty)
              .popover(
                isPresented: $showBalanceDetails,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
              ) {
                Group {
                  if !vm.networkBalances.isEmpty {
                    VStack(spacing: 0) {
                      ForEach(vm.networkBalances) { network in
                        HStack(spacing: 16) {
                          Text(network.name)
                          Spacer()
                          Text(network.balance.map { "♦ \($0)" } ?? "Unavailable")
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                      }
                    }
                    .frame(minWidth: 280)
                  } else if vm.balance == nil {
                    Text("Loading balances...")
                  } else if vm.includedNetworkCount == 0 {
                    Text("No networks included")
                  } else {
                    Text("Balances unavailable")
                  }
                }
                .padding()
                .presentationCompactAdaptation(.popover)
              }
              Spacer()
            }
          }
          .padding()
          Spacer()
        }
        .frame(minHeight: contentHeight)
      }
      .refreshable { await vm.refreshBalance() }
      .onChange(of: vm.networkBalances.isEmpty) { _, isEmpty in
        if isEmpty { showBalanceDetails = false }
      }
    }

    private var contentHeight: CGFloat {
      #if canImport(UIKit)
        UIScreen.main.bounds.height - 200
      #else
        600
      #endif
    }
  }

  private struct AddressMenuButton: UIViewRepresentable {
    let address: String
    let showActivity: () -> Void
    let showConnectedApps: () -> Void
    let showSettings: () -> Void

    func makeUIView(context: Context) -> UIButton {
      let button = UIButton(type: .custom)
      button.showsMenuAsPrimaryAction = true
      button.imageView?.contentMode = .scaleAspectFit
      button.layer.cornerRadius = 14
      button.layer.masksToBounds = true
      button.accessibilityLabel = "Wallet address"
      button.accessibilityHint = "Shows address actions"
      return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
      let iconSize = CGSize(width: 28, height: 28)
      let icon = UIGraphicsImageRenderer(size: iconSize).image { _ in
        BlockieView.image(seed: address.lowercased()).draw(
          in: CGRect(origin: .zero, size: iconSize))
      }
      button.setImage(icon, for: .normal)

      let copyAction = UIAction(
        title: "Copy Address",
        image: UIImage(systemName: "doc.on.doc")
      ) { _ in
        UIPasteboard.general.string = address
      }
      copyAction.subtitle =
        address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
      let activityAction = UIAction(
        title: "Activity",
        image: UIImage(systemName: "clock")
      ) { _ in
        showActivity()
      }
      let connectedAppsAction = UIAction(
        title: "Connected Apps",
        image: UIImage(systemName: "puzzlepiece.extension")
      ) { _ in
        showConnectedApps()
      }
      let settingsAction = UIAction(
        title: "Settings",
        image: UIImage(systemName: "gear")
      ) { _ in
        showSettings()
      }
      button.menu = UIMenu(
        children: [copyAction, activityAction, connectedAppsAction, settingsAction])
    }
  }
#else
  struct ContentView: View {
    var body: some View { Text("stupid wallet") }
  }
#endif
