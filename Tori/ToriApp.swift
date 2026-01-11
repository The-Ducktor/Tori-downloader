import SwiftUI

@MainActor
class AppModel: ObservableObject {
    let downloadManager: DownloadManager
    let server: ToriServer

    init() {
        let manager = DownloadManager()
        self.downloadManager = manager
        self.server = ToriServer(downloadManager: manager)
        
        // Start server immediately upon AppModel creation (which happens once at app launch)
        self.server.start()
    }
}

@main
struct ToriApp: App {
    // StateObject ensures AppModel is created only once and persists for the app's lifetime
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        Window("Tori", id: "main") {
            DownloadManagerView()
                .environmentObject(appModel.downloadManager)
                .onOpenURL { url in
                    appModel.downloadManager.handleURL(url)
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
                .environmentObject(appModel.downloadManager)
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
            MenuBarExtraView(manager: appModel.downloadManager)
        } label: {
            let activeCount = appModel.downloadManager.downloads.filter { $0.status == .downloading || $0.status == .processing }.count
            Image(systemName: activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
