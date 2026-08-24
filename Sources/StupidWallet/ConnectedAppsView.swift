import StupidWalletCore
import SwiftUI

#if os(iOS)
  struct ConnectedAppsView: View {
    let address: String
    @State private var sites: [ConnectedSite] = []

    var body: some View {
      List {
        if sites.isEmpty {
          Section {
            HStack {
              Spacer()
              VStack(spacing: 8) {
                Image(systemName: "app.badge")
                  .font(.system(size: 28))
                  .foregroundStyle(.secondary)
                Text("No connected apps yet").foregroundStyle(.secondary)
              }
              Spacer()
            }
            .padding(.vertical, 16)
          }
        } else {
          Section {
            ForEach(sites) { site in
              NavigationLink(destination: ConnectedAppDetailView(site: site)) {
                HStack {
                  Text(site.domain)
                  Spacer()
                  Text(RelativeTime.abbreviated(from: site.connectedAt))
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Connected Apps")
      .navigationBarTitleDisplayMode(.inline)
      .task { await load() }
      .refreshable { await load() }
    }

    private func load() async {
      sites = await ConnectedSitesStore().all().filter {
        $0.address.caseInsensitiveCompare(address) == .orderedSame
      }
    }
  }

  struct ConnectedAppDetailView: View {
    let site: ConnectedSite
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var activity: [ActivityRecord] = []
    @State private var isLoadingActivity = false
    @State private var activityError: String?

    var body: some View {
      Form {
        Section("App") {
          HStack {
            Text("Domain")
            Spacer()
            Text(site.domain).foregroundStyle(.secondary)
          }
          HStack {
            Text("Connected")
            Spacer()
            Text(site.connectedAt.formatted(date: .abbreviated, time: .standard))
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
          }
        }
        Section {
          Button {
            if let url = URL(string: "https://\(site.domain)") { openURL(url) }
          } label: {
            Text("Open App")
          }
        }
        Section("Activity") {
          if isLoadingActivity {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          } else if let activityError {
            Text(activityError).foregroundStyle(.secondary)
          } else if activity.isEmpty {
            Text("No activity yet").foregroundStyle(.secondary)
          } else {
            ForEach(activity) { item in
              NavigationLink(destination: ActivityDetailView(item: item, connectedSite: site)) {
                ActivityRow(item: item)
              }
            }
          }
        }
        Section {
          Button("Disconnect", role: .destructive) {
            Task {
              await ConnectedSitesStore().disconnect(
                origin: site.origin ?? "https://\(site.domain)", profileID: site.profileID)
              dismiss()
            }
          }
        }
      }
      .navigationTitle(site.domain)
      .navigationBarTitleDisplayMode(.inline)
      .task { await loadActivity() }
      .refreshable { await loadActivity() }
    }

    private func loadActivity() async {
      isLoadingActivity = true
      activityError = nil
      let service = makeWalletService()
      await service.refreshTransactionActivity()
      do {
        activity = try await service.activities(for: site)
      } catch {
        activityError = "Activity could not be loaded."
      }
      isLoadingActivity = false
    }
  }

  enum RelativeTime {
    static func abbreviated(from date: Date) -> String {
      let seconds = max(0, Int(Date().timeIntervalSince(date)))
      if seconds < 60 { return "now" }
      if seconds < 3_600 { return "\(seconds / 60)m" }
      if seconds < 86_400 { return "\(seconds / 3_600)h" }
      if seconds < 604_800 { return "\(seconds / 86_400)d" }
      return date.formatted(date: .abbreviated, time: .omitted)
    }
  }
#endif
