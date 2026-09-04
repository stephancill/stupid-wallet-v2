import SwiftUI

@main
struct StupidWalletApp: App {
  #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var appDelegate
  #endif

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
