import StupidWalletCore
import SwiftUI

@main
struct StupidWalletApp: App {
  init() {
    WalletMetrics.configure(surface: .app)
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
