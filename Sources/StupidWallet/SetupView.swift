import SwiftUI

#if os(iOS)
  struct SetupView: View {
    @ObservedObject var vm: WalletViewModel
    let showAccounts: () -> Void

    var body: some View {
      VStack(spacing: 24) {
        Spacer()
        VStack(spacing: 16) {
          Image(systemName: "wallet.pass")
            .font(.system(size: 60))
            .foregroundStyle(.tint)
          Text("welcome")
            .font(.largeTitle)
            .fontWeight(.bold)
          Text("get started by creating a new wallet or importing an existing one")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
        }
        Spacer()
        VStack(spacing: 16) {
          NavigationLink(destination: ImportWalletView(vm: vm)) {
            HStack {
              Image(systemName: "arrow.down.circle.fill").font(.title2)
              Text("Import Wallet").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
          }
          .buttonStyle(.borderedProminent)

          NavigationLink(destination: SeedBackupView(vm: vm)) {
            HStack {
              Image(systemName: "plus.circle.fill").font(.title2)
              Text("Create New Wallet").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
          }
          .buttonStyle(.bordered)
          .disabled(vm.isSaving)

          if vm.hasRegisteredAccounts {
            Button("Choose Existing Account", action: showAccounts)
              .disabled(vm.isSaving)
          }
        }
        .padding(.horizontal, 32)
        Spacer()
        if let error = vm.errorMessage, !error.isEmpty {
          Text(error)
            .foregroundStyle(.red)
            .font(.footnote)
            .padding(.horizontal, 32)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.vertical, 40)
    }
  }
#endif
