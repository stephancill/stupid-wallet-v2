import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

#if os(iOS)
  struct ContentView: View {
    @StateObject private var vm = WalletViewModel()
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
        .toolbar {
          if vm.hasWallet {
            ToolbarItem(placement: .navigationBarTrailing) {
              NavigationLink(destination: ActivityView()) {
                Image(systemName: "clock")
              }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
              Button {
                showSettingsSheet = true
              } label: {
                Image(systemName: "gear")
              }
            }
          }
        }
      }
      .sheet(isPresented: $showSettingsSheet) {
        SettingsView(address: vm.addressHex)
      }
      .task {
        await vm.refreshBalance()
      }
    }

    private var walletView: some View {
      ScrollView {
        VStack {
          Spacer()
          VStack(alignment: .center, spacing: 24) {
            HStack {
              Spacer()
              Menu {
                if let balance = vm.balance {
                  Text("\(vm.chainName) • \(balance)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .disabled(true)
                } else {
                  Text("Loading balances...").foregroundStyle(.secondary)
                }
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
                  Image(systemName: "chevron.down").foregroundStyle(.secondary)
                }
              }
              .menuStyle(.borderlessButton)
              Spacer()
            }

            Button {
              copyAddress()
            } label: {
              HStack(spacing: 6) {
                BlockieView(seed: vm.addressHex.lowercased())
                  .frame(width: 24, height: 24)
                Text(truncatedAddress(vm.addressHex))
                  .font(.system(.title3, design: .monospaced))
                  .frame(height: 24)
                Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                  .foregroundStyle(.secondary)
                  .frame(width: 20)
              }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
          }
          .padding()
          Spacer()
        }
        .frame(minHeight: contentHeight)
      }
      .refreshable { await vm.refreshBalance() }
    }

    @State private var didCopyAddress = false

    private func truncatedAddress(_ address: String) -> String {
      guard address.count > 12 else { return address }
      return "\(address.prefix(6))...\(address.suffix(4))"
    }

    private func copyAddress() {
      #if canImport(UIKit)
        UIPasteboard.general.string = vm.addressHex
      #endif
      didCopyAddress = true
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        didCopyAddress = false
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
#else
  struct ContentView: View {
    var body: some View { Text("Stupid Wallet") }
  }
#endif
