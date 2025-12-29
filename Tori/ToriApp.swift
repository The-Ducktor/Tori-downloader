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
        WindowGroup {
            DownloadManagerView()
                .environmentObject(downloadManager)
                .onOpenURL { url in
                    downloadManager.handleURL(url)
                }
        }

        MenuBarExtra {
            MenuBarExtraView(manager: downloadManager)
        } label: {
            let activeCount = downloadManager.downloads.filter { $0.status == .downloading || $0.status == .processing }.count
            Image(systemName: activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
