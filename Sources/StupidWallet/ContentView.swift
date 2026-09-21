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
    @State private var showCopyCheckmark = false
    @State private var showAddToken = false
    @State private var expandedSymbols: Set<String> = []

    var body: some View {
      NavigationView {
        Group {
          if vm.isLoadingInitialState {
            ProgressView()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .accessibilityLabel("Loading wallet")
          } else if vm.hasWallet {
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
          if !vm.isLoadingInitialState && vm.hasWallet {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
              Button {
                UIPasteboard.general.string = vm.addressHex
                showCopyCheckmark = true
                Task { @MainActor in
                  try? await Task.sleep(for: .seconds(1.5))
                  showCopyCheckmark = false
                }
              } label: {
                Image(systemName: showCopyCheckmark ? "checkmark" : "square.on.square")
                  .contentTransition(.identity)
              }
              .accessibilityLabel("Copy Address")

              AddressMenuButton(
                address: vm.addressHex,
                accountName: homeAccountName,
                isWatchOnly: vm.isWatchOnly,
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
          address: vm.addressHex, accountName: homeAccountName, isWatchOnly: vm.isWatchOnly,
          balances: vm.balances
        )
        .id(vm.addressHex.lowercased())
      }
      .sheet(isPresented: $showAccountPicker) {
        AccountPickerView(vm: vm)
      }
      .sheet(isPresented: $showAddToken) {
        NavigationView { AddTokenView(balances: vm.balances) }
      }
      .task(id: vm.addressHex) {
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
        showAddToken = false
      }
    }

    private static let portfolioAnchor = "portfolio"

    private var walletView: some View {
      ScrollViewReader { proxy in
        GeometryReader { geometry in
          ScrollView {
            VStack(spacing: 0) {
              VStack(spacing: 14) {
                Spacer(minLength: 0)
                balanceBlock
                if !vm.balances.portfolioHoldings.isEmpty {
                  Button {
                    withAnimation { proxy.scrollTo(Self.portfolioAnchor, anchor: .top) }
                  } label: {
                    Image(systemName: "chevron.down")
                      .font(.title3)
                      .foregroundStyle(.secondary)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Show token values")
                }
                Spacer(minLength: 0)
              }
              .frame(minHeight: heroHeight(geometry.size.height))

              portfolioSection

              VStack(spacing: 0) {
                if let error = vm.balances.error {
                  Text(error).font(.footnote).foregroundStyle(.red).padding(.vertical, 8)
                }
                Button("Add Token") { showAddToken = true }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 16)
              }
              .padding(.horizontal)
            }
          }
          .refreshable { await vm.refreshBalance() }
        }
      }
      .onChange(of: vm.networkBalances.isEmpty) { _, isEmpty in
        if isEmpty { showBalanceDetails = false }
      }
    }

    /// Leaves the portfolio section just below the fold so the caret has something to reveal.
    private func heroHeight(_ available: CGFloat) -> CGFloat {
      vm.balances.portfolioHoldings.isEmpty ? available : available * 0.8
    }

    private var balanceBlock: some View {
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
      .padding()
    }

    private var portfolioSection: some View {
      VStack(alignment: .leading, spacing: 0) {
        if let total = vm.balances.portfolioTotalDisplay {
          VStack(alignment: .leading, spacing: 2) {
            Text("Total value")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text(total)
              .font(.system(size: 30, weight: .semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.5)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, 12)
        }
        ForEach(vm.balances.portfolioGroups) { group in
          groupRow(group)
          Divider()
        }
      }
      .padding(.horizontal)
      .id(Self.portfolioAnchor)
    }

    @ViewBuilder
    private func groupRow(_ group: PortfolioGroup) -> some View {
      if group.isGrouped {
        Button {
          withAnimation {
            if expandedSymbols.contains(group.symbol) {
              expandedSymbols.remove(group.symbol)
            } else {
              expandedSymbols.insert(group.symbol)
            }
          }
        } label: {
          groupLabel(group, expandable: true)
        }
        .buttonStyle(.plain)
      } else if let tokenID = group.holdings.first.flatMap({ $0.address == nil ? nil : $0.id }) {
        NavigationLink(destination: TokenDetailView(tokenID: tokenID, balances: vm.balances)) {
          groupLabel(group, expandable: false)
        }
        .buttonStyle(.plain)
      } else {
        groupLabel(group, expandable: false)
      }

      if group.isGrouped, expandedSymbols.contains(group.symbol) {
        ForEach(group.holdings) { holding in
          HStack(spacing: 12) {
            Text(holding.networkName)
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(holding.valueDisplay ?? "—")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.leading, 40)
          .padding(.bottom, 10)
          .accessibilityElement(children: .combine)
        }
      }
    }

    private func groupLabel(_ group: PortfolioGroup, expandable: Bool) -> some View {
      HStack(spacing: 12) {
        TokenIconView(iconURL: group.iconURL, symbol: group.symbol)
        VStack(alignment: .leading, spacing: 3) {
          Text(group.symbol).foregroundStyle(.primary)
          Text(group.networkLabel).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Text(group.valueDisplay ?? "—")
          .foregroundStyle(group.valueDisplay == nil ? .secondary : .primary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        if expandable {
          Image(systemName: expandedSymbols.contains(group.symbol) ? "chevron.up" : "chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 12)
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }

    private var homeAccountName: String? {
      vm.selectedGroup?.accounts.first {
        $0.address.caseInsensitiveCompare(vm.addressHex) == .orderedSame
      }?.label
    }

  }

  private struct AddressMenuButton: View {
    let address: String
    let accountName: String?
    let isWatchOnly: Bool
    let showAccounts: () -> Void
    let showActivity: () -> Void
    let showConnectedApps: () -> Void
    let showSettings: () -> Void
    @State private var menuPresented = false

    var body: some View {
      Button {
        menuPresented = true
      } label: {
        BlockieView(seed: address.lowercased())
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Wallet address")
      .accessibilityHint("Shows account menu")
      .popover(isPresented: $menuPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
        VStack(spacing: 0) {
          accountMenuButton(action: showAccounts)
          menuButton("Activity", systemImage: "clock", action: showActivity)
          menuButton(
            "Connected Apps", systemImage: "puzzlepiece.extension", action: showConnectedApps)
          menuButton("Settings", systemImage: "gear", action: showSettings)
        }
        .frame(width: 280)
        .padding(.vertical, 6)
        .presentationCompactAdaptation(.popover)
      }
    }

    private var displayAddress: String {
      address.count > 12 ? "\(address.prefix(6))...\(address.suffix(4))" : address
    }

    private func accountMenuButton(action: @escaping () -> Void) -> some View {
      Button {
        menuPresented = false
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          action()
        }
      } label: {
        HStack(spacing: 12) {
          BlockieView(seed: address.lowercased())
            .frame(width: 28, height: 28)
          VStack(alignment: .leading, spacing: 2) {
            Text(accountName ?? displayAddress)
            HStack(spacing: 4) {
              Text(displayAddress)
              if isWatchOnly {
                Image(systemName: "eye").accessibilityLabel("Watch-only")
              }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          Image(systemName: "arrow.left.arrow.right")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 58)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }

    private func menuButton(
      _ title: String,
      systemImage: String? = nil,
      action: @escaping () -> Void
    ) -> some View {
      Button {
        menuPresented = false
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          action()
        }
      } label: {
        HStack(spacing: 12) {
          if let systemImage {
            Image(systemName: systemImage)
              .frame(width: 24)
          }
          Text(title)
          Spacer(minLength: 12)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 50)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }
#else
  struct ContentView: View {
    var body: some View { Text("stupid wallet") }
  }
#endif
