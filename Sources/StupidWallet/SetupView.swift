import SwiftUI

#if os(iOS)
  struct SetupView: View {
    @ObservedObject var vm: WalletViewModel
    let showAccounts: () -> Void

    var body: some View {
      VStack(spacing: 24) {
        Spacer()
        Image(uiImage: UIImage(named: "AppIcon") ?? UIImage())
          .resizable()
          .scaledToFit()
          .frame(width: 168, height: 168)
          .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
          .accessibilityLabel("stupid wallet logo")
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
