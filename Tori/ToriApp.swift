import SwiftUI

@main
struct ToriApp: App {
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var server: ToriServer

    init() {
        let manager = DownloadManager()
        let server = ToriServer(downloadManager: manager)
        _downloadManager = StateObject(wrappedValue: manager)
        _server = StateObject(wrappedValue: server)
        server.start()
    }

    var body: some Scene {
        Window("Tori", id: "main") {
            DownloadManagerView()
                .environmentObject(downloadManager)
                .onOpenURL { url in
                    downloadManager.handleURL(url)
                }
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        .defaultLaunchBehavior(.suppressed)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)

        Window("Add Downloads", id: "add-download") {
            AddDownloadView()
                .environmentObject(downloadManager)
                .frame(minWidth: 500, minHeight: 400)
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .keyboardShortcut("n", modifiers: .command)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)

        Window("Plugins", id: "plugins") {
            PluginsListView()
                .frame(minWidth: 500, minHeight: 400)
        }
        .defaultSize(width: 600, height: 500)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarExtraView(manager: downloadManager)
        } label: {
            let activeCount = downloadManager.downloads.filter { $0.status == .downloading || $0.status == .processing }.count
            Image(systemName: activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
