import SwiftUI

struct ContentView: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "wallet.pass.fill")
        .font(.system(size: 40))
        .foregroundStyle(.tint)
      Text("Stupid Wallet")
        .font(.headline)
      Text("Signing happens in the Safari extension when you use a dapp.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
  }
}
