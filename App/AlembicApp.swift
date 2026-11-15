import SwiftUI

@main
struct AlembicApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.start() }
                .onOpenURL { store.open($0) }
        }
    }
}

enum AppTab: Hashable { case download, library, settings }

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var tab: AppTab = .download

    var body: some View {
        TabView(selection: $tab) {
            Tab("Download", systemImage: "arrow.down.circle", value: AppTab.download) {
                DownloadView()
            }
            Tab("Library", systemImage: "square.stack", value: AppTab.library) {
                LibraryView()
            }
            .badge(store.jobs.filter(\.isActive).count)
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(Color("AccentColor"))
        .onChange(of: store.pendingLink) { _, link in
            if link != nil { tab = .download }
        }
        #if DEBUG
        .onAppear {
            // Simulator screenshots only: `-AlembicTab library|settings`
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-AlembicTab"), i + 1 < args.count {
                tab = args[i + 1] == "library" ? .library : args[i + 1] == "settings" ? .settings : .download
            }
        }
        #endif
    }
}
