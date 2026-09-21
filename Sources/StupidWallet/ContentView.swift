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
    @State private var showSendSheet = false
    @State private var showCopyCheckmark = false
    @State private var expandedSymbols: Set<String> = []
    @State private var currentPage: String? = ContentView.balancePage

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
      .sheet(isPresented: $showSendSheet) {
        SendView(vm: vm)
          .id(vm.addressHex.lowercased())
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
        showSendSheet = false
      }
    }

    private static let balancePage = "balancePage"
    private static let tokenPage = "tokenPage"
    /// Lifts the centred balance so it lands slightly above the page's midpoint.
    private static let balanceVerticalBias: CGFloat = 0.053

    private var hasHoldings: Bool { !vm.balances.portfolioHoldings.isEmpty }

    private var walletView: some View {
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          VStack(spacing: 0) {
            balanceScreen
              .containerRelativeFrame(.vertical)
              .id(Self.balancePage)

            tokenScreen
              .containerRelativeFrame(.vertical)
              .anchorPreference(key: TokenPageBoundsKey.self, value: .bounds) { $0 }
              .id(Self.tokenPage)
          }
          .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentPage)
        .ignoresSafeArea(.container, edges: .bottom)
        .overlayPreferenceValue(TokenPageBoundsKey.self) { anchor in
          GeometryReader { geometry in
            if let anchor {
              let bounds = geometry[anchor]
              let progress = min(max(1 - bounds.minY / max(bounds.height, 1), 0), 1)
              let onTokenPage = progress >= 0.5
              // Resolve the moving seam here, without publishing per-frame state to the holdings list.
              pageCaret(
                progress: progress,
                label: onTokenPage ? "Hide token values" : "Show token values"
              ) {
                let target = onTokenPage ? Self.balancePage : Self.tokenPage
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                  currentPage = target
                  proxy.scrollTo(target, anchor: .top)
                }
              }
              .position(
                x: geometry.size.width / 2,
                y: max(22, min(bounds.minY, geometry.size.height - 30))
              )
            }
          }
        }
      }
      .onChange(of: vm.networkRows.isEmpty) { _, isEmpty in
        if isEmpty { showBalanceDetails = false }
      }
      .onChange(of: hasHoldings) { _, hasHoldings in
        if !hasHoldings { currentPage = Self.balancePage }
      }
    }

    private func pageCaret(progress: CGFloat, label: String, action: @escaping () -> Void)
      -> some View
    {
      Button(action: action) {
        Image(systemName: "chevron.down")
          .font(.title3)
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(180 * progress))
          .frame(width: 120, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .accessibilityIdentifier("home.pageCaret")
    }

    private var balanceScreen: some View {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          balanceBlock
          Spacer(minLength: 0)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        // Sit above the true vertical centre; the page caret keeps the seam it already owns.
        .offset(y: -geometry.size.height * Self.balanceVerticalBias)
      }
      .background(Color(.systemBackground))
    }

    /// Revealed screen: total value over the value-ordered holdings.
    private var tokenScreen: some View {
      VStack(spacing: 0) {
        // Reserve the page caret's touch area so it never overlaps the total.
        Color.clear.frame(height: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text(vm.balances.portfolioTotalDisplay ?? "—")
            .font(.system(size: 30, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel("Portfolio value")
            .accessibilityValue(vm.balances.portfolioTotalDisplay ?? "Unavailable")
          if let change = vm.balances.portfolioChangeDisplay {
            Text(change)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(changeColor(change))
              .accessibilityLabel("24 hour change")
              .accessibilityValue(change)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .opacity(vm.balances.isRefreshing ? 0.6 : 1)

        List {
          ForEach(vm.balances.portfolioGroups) { group in
            groupRow(group)
              .opacity(vm.balances.isRefreshing ? 0.6 : 1)
          }
          if let error = vm.balances.error {
            Text(error).foregroundStyle(.red)
          }
        }
        .listStyle(.plain)
        .refreshable { await vm.refreshBalance() }
      }
      .frame(maxWidth: .infinity)
      .background(Color(.systemBackground))
      .safeAreaInset(edge: .bottom, spacing: 0) { sendToolbar }
    }

    /// Floating wallet-owned actions for the token screen. Swap joins the same group when
    /// implemented.
    private var sendToolbar: some View {
      HStack(spacing: 10) {
        Spacer(minLength: 0)
        Button {
          showSendSheet = true
        } label: {
          Label("Send", systemImage: "arrow.up")
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .floatingGlassButtonStyle()
        .accessibilityIdentifier("home.send")
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 20)
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
            Image(systemName: showBalanceDetails ? "chevron.up" : "chevron.down")
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
        .popover(
          isPresented: $showBalanceDetails,
          attachmentAnchor: .rect(.bounds),
          arrowEdge: .top
        ) {
          Group {
            if !vm.networkRows.isEmpty {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(vm.networkRows) { network in
                  HStack(spacing: 6) {
                    Text(network.name)
                    Spacer(minLength: 12)
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
          .accessibilityElement(children: .combine)
        }
      }
    }

    private func groupLabel(_ group: PortfolioGroup, expandable: Bool) -> some View {
      HStack(spacing: 12) {
        TokenIconView(iconURL: group.iconURL, symbol: group.symbol)
        VStack(alignment: .leading, spacing: 3) {
          Text(group.symbol).foregroundStyle(.primary)
          HStack(spacing: 4) {
            Text(group.networkLabel).font(.subheadline).foregroundStyle(.secondary)
            if expandable {
              Image(
                systemName: expandedSymbols.contains(group.symbol) ? "chevron.up" : "chevron.down"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
          }
        }
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 3) {
          Text(group.valueDisplay ?? "—")
            .foregroundStyle(group.valueDisplay == nil ? .secondary : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          if let change = group.changeDisplay {
            Text(change)
              .font(.subheadline)
              .foregroundStyle(changeColor(change))
          }
        }
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }

    private func changeColor(_ display: String) -> Color {
      display.hasPrefix("+") ? .green : .secondary
    }

    private var homeAccountName: String? {
      vm.selectedGroup?.accounts.first {
        $0.address.caseInsensitiveCompare(vm.addressHex) == .orderedSame
      }?.label
    }

  }

  private struct TokenPageBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
      value = nextValue() ?? value
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
                Image(systemName: "eye").font(.system(size: 10)).accessibilityLabel("Watch-only")
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

  extension View {
    /// Liquid Glass on iOS 26, with a bordered capsule on earlier supported systems.
    @ViewBuilder
    fileprivate func floatingGlassButtonStyle() -> some View {
      if #available(iOS 26.0, *) {
        buttonStyle(.glass).buttonBorderShape(.capsule)
      } else {
        buttonStyle(.bordered).buttonBorderShape(.capsule)
      }
    }
  }
#else
  struct ContentView: View {
    var body: some View { Text("stupid wallet") }
  }
#endif
