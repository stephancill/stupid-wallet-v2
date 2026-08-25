import StupidWalletCore
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
    @State private var showAccountPicker = false

    var body: some View {
      NavigationView {
        Group {
          if vm.hasWallet {
            walletView
          } else {
            SetupView(vm: vm) { showAccountPicker = true }
          }
        }
        .background {
          NavigationLink(
            destination: ActivityView(account: vm.addressHex).id(vm.addressHex.lowercased()),
            isActive: $showActivity
          ) {
            EmptyView()
          }
          .hidden()
          NavigationLink(
            destination: ConnectedAppsView(address: vm.addressHex).id(vm.addressHex.lowercased()),
            isActive: $showConnectedApps
          ) {
            EmptyView()
          }
          .hidden()
        }
        .toolbar {
          if vm.hasWallet {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
              Button {
                UIPasteboard.general.string = vm.addressHex
              } label: {
                Image(systemName: "square.on.square")
              }
              .accessibilityLabel("Copy Address")

              AddressMenuButton(
                address: vm.addressHex,
                showAccounts: {
                  showAccountPicker = true
                },
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
        SettingsView(
          address: vm.addressHex,
          groupKind: vm.selectedGroup?.kind ?? .privateKey,
          accountCount: vm.selectedGroup?.accounts.count ?? 1
        ) {
          try await vm.forgetAccount()
        }
        .id(vm.addressHex.lowercased())
      }
      .sheet(isPresented: $showAccountPicker) {
        AccountPickerView(vm: vm)
      }
      .task {
        await vm.refreshBalance()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await vm.refreshBalance() } }
      }
      .onChange(of: vm.addressHex) { oldAddress, newAddress in
        guard oldAddress.caseInsensitiveCompare(newAddress) != .orderedSame else { return }
        showBalanceDetails = false
        showActivity = false
        showConnectedApps = false
        showSettingsSheet = false
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
                    VStack(alignment: .leading, spacing: 0) {
                      ForEach(vm.networkBalances) { network in
                        HStack(spacing: 6) {
                          Text(network.name)
                          Text(network.balance.map { "♦ \($0)" } ?? "Unavailable")
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    let showAccounts: () -> Void
    let showActivity: () -> Void
    let showConnectedApps: () -> Void
    let showSettings: () -> Void

    func makeUIView(context: Context) -> UIButton {
      let button = UIButton(type: .custom)
      button.showsMenuAsPrimaryAction = true
      button.imageView?.contentMode = .scaleAspectFit
      button.layer.cornerRadius = 8
      button.layer.cornerCurve = .continuous
      button.layer.masksToBounds = true
      button.accessibilityLabel = "Wallet address"
      button.accessibilityHint = "Shows account menu"
      return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
      let iconSize = CGSize(width: 28, height: 28)
      let icon = UIGraphicsImageRenderer(size: iconSize).image { _ in
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: iconSize), cornerRadius: 8).addClip()
        BlockieView.image(seed: address.lowercased()).draw(
          in: CGRect(origin: .zero, size: iconSize))
      }
      button.setImage(icon, for: .normal)

      let displayAddress =
        address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
      let accountAction = UIAction(title: displayAddress, image: icon) { _ in
        showAccounts()
      }
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
        children: [accountAction, activityAction, connectedAppsAction, settingsAction])
    }
  }
#else
  struct ContentView: View {
    var body: some View { Text("stupid wallet") }
  }
#endif
