import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

#if os(iOS)
  struct ContentView: View {
    @StateObject private var vm = WalletViewModel()
    @State private var showBalanceDetails = false
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
            ToolbarItem(placement: .navigationBarLeading) {
              AddressMenuButton(address: vm.addressHex)
                .frame(width: 28, height: 28)
            }
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
        SettingsView(address: vm.addressHex) {
          try await vm.forgetAccount()
        }
      }
      .task {
        await vm.refreshBalance()
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
                  if let balance = vm.balance {
                    Text("\(vm.chainName) • \(balance)")
                  } else {
                    Text("Loading balances...")
                  }
                }
                .foregroundStyle(.secondary)
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
      button.menu = UIMenu(children: [copyAction])
    }
  }
#else
  struct ContentView: View {
    var body: some View { Text("Stupid Wallet") }
  }
#endif
