import SwiftUI

struct DownloadManagerView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var isShowingAddDownloadSheet = false
    @State private var isShowingPluginsSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if manager.downloads.isEmpty {
                    emptyStateView
                } else {
                    downloadsListView
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button("Clear Completed") {
                        clearCompleted()
                    }
                    .disabled(!manager.downloads.contains { $0.status == .completed })

                    Button(action: { isShowingPluginsSheet = true }) {
                        Image(systemName: "puzzlepiece")
                    }
                    .help("Plugins")

                    Button(action: { isShowingAddDownloadSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .help("Add Download")
                }
            }
            .sheet(isPresented: $isShowingAddDownloadSheet) {
                AddDownloadView()
                    .environmentObject(manager)
            }
            .sheet(isPresented: $isShowingPluginsSheet) {
                PluginsListView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(spacing: 4) {
                Text("No Downloads")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Click the + button to add a new download.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: { isShowingAddDownloadSheet = true }) {
                Label("Add Download", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var downloadsListView: some View {
        List {
            ForEach(manager.downloads) { item in
                DownloadRow(item: item, manager: manager)
            }
            .onDelete(perform: deleteDownloads)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .background(Color(NSColor.controlBackgroundColor))
        .contextMenu {
            backgroundContextMenu
        }
    }

    @ViewBuilder
    private var backgroundContextMenu: some View {
        Button("New Download") {
            isShowingAddDownloadSheet = true
        }

        Divider()

        Button("Clear Completed") {
            clearCompleted()
        }
        .disabled(!manager.downloads.contains { $0.status == .completed })

        Button("Clear All") {
            clearAll()
        }
        .disabled(manager.downloads.isEmpty)
    }

    // MARK: - Actions

    private func deleteDownloads(at offsets: IndexSet) {
        for index in offsets {
            let item = manager.downloads[index]
            if item.status == .downloading {
                manager.cancelDownload(item: item)
            }
        }
        manager.downloads.remove(atOffsets: offsets)
    }

    private func clearCompleted() {
        manager.downloads.removeAll { $0.status == .completed }
    }

    private func clearAll() {
        for item in manager.downloads {
            if item.status == .downloading {
                manager.cancelDownload(item: item)
            }
        }
        manager.downloads.removeAll()
    }
}

// MARK: - AddDownloadView (Sheet)

struct AddDownloadView: View {
    enum ViewState {
        case input
        case processing
        case selection([PluginActionResult])
    }

    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput = ""
    @State private var bypassPlugins = false
    @State private var showingInvalidURL = false
    @State private var viewState: ViewState = .input
    @State private var selectedUrls: Set<URL> = []
    @FocusState private var isUrlInputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch viewState {
                    case .input:
                        inputView
                    case .processing:
                        processingView
                    case .selection(let results):
                        selectionView(results: results)
                    }
                }
                .padding()
            }
            .navigationTitle("Add Downloads")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isUrlInputFocused = true
            checkClipboard()
        }
        .alert("No Valid URLs", isPresented: $showingInvalidURL) {
            Button("OK") { }
        } message: {
            Text("Please enter at least one valid URL starting with http or https.")
        }
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 20) {

            VStack(alignment: .leading, spacing: 8) {
                Text("URLs")
                    .font(.headline)

                TextField("Paste links here (one per line)...", text: $urlInput, axis: .vertical)
                    .lineLimit(5...10)
                    .textFieldStyle(.roundedBorder)
                    .focused($isUrlInputFocused)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.headline)

                Toggle(isOn: $bypassPlugins) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bypass Plugins")
                            .font(.body)
                        Text("Skip plugin processing and download directly from the source URL.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(.top, 4)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: addDownloadsFromInput) {
                    Text(urlCount > 1 ? "Add \(urlCount) Downloads" : "Add Download")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Processing URLs...")
                .font(.headline)
            Text("Checking for plugins and direct links")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(24)
    }

    private func selectionView(results: [PluginActionResult]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Select Files")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("\(results.count) files discovered. Choose which ones to download.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        // Show plugin info if available
                        if let context = results.first?.context {
                            HStack(spacing: 6) {
                                Image(systemName: "puzzlepiece.fill")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                                Text("Via: \(context.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if let capabilities = context.capabilities, !capabilities.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(capabilities, id: \.self) { capability in
                                            Text(capability)
                                                .font(.system(size: 9, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.1))
                                                .foregroundColor(.accentColor)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Button("Select All") {
                            selectedUrls = Set(results.map { $0.url })
                        }
                        .buttonStyle(.link)

                        Button("Select None") {
                            selectedUrls.removeAll()
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)

            Divider()

            List {
                ForEach(results, id: \.url) { result in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { selectedUrls.contains(result.url) },
                            set: { isSelected in
                                if isSelected {
                                    selectedUrls.insert(result.url)
                                } else {
                                    selectedUrls.remove(result.url)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)

                        if let iconURLString = result.iconURL, let iconURL = URL(string: iconURLString) {
                            AsyncImage(url: iconURL) { image in
                                image.resizable().aspectRatio(contentMode: .fit)
                            } placeholder: {
                                ProgressView().controlSize(.small)
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: "doc.fill")
                                .font(.title3)
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(result.fileName ?? result.url.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                                if let size = result.size {
                                    Text(formatBytes(size))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(result.url.absoluteString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .frame(height: 300)

            Divider()

            HStack {
                Button("Back") {
                    viewState = .input
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(selectedUrls.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Add Selected") {
                    for result in results where selectedUrls.contains(result.url) {
                        manager.addDownload(
                            url: result.url,
                            fileName: result.fileName,
                            headers: result.headers,
                            bypassPlugins: true
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedUrls.isEmpty)
            }
            .padding(24)
        }
    }

    private var urlCount: Int {
        let urls = urlInput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return urls.count
    }

    private func checkClipboard() {
        if let content = NSPasteboard.general.string(forType: .string) {
            let lines = content.components(separatedBy: .newlines)
            var validUrls: [String] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    validUrls.append(trimmed)
                }
            }

            if !validUrls.isEmpty {
                urlInput = validUrls.joined(separator: "\n")
            }
        }
    }

    private func addDownloadsFromInput() {
        let lines = urlInput.components(separatedBy: .newlines)
        let urls = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }

        guard !urls.isEmpty else {
            showingInvalidURL = true
            return
        }

        if bypassPlugins {
            for url in urls {
                manager.addDownload(url: url, bypassPlugins: true)
            }
            dismiss()
            return
        }

        viewState = .processing

        Task {
            var allResults: [PluginActionResult] = []
            for url in urls {
                let results = await PluginManager.shared.processURL(url)
                allResults.append(contentsOf: results)
            }

            await MainActor.run {
                if allResults.count > 1 {
                    selectedUrls = Set(allResults.map { $0.url })
                    viewState = .selection(allResults)
                } else if let first = allResults.first {
                    manager.addDownload(
                        url: first.url,
                        fileName: first.fileName,
                        headers: first.headers,
                        bypassPlugins: true
                    )
                    dismiss()
                } else {
                    viewState = .input
                    showingInvalidURL = true
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - DownloadRow

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let manager: DownloadManager

    var body: some View {
        HStack(spacing: 16) {
            // File type icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(statusColor.opacity(0.1))
                    .frame(width: 40, height: 40)

                if let iconURL = item.iconURL {
                    AsyncImage(url: iconURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Image(systemName: fileIcon)
                        .font(.title3)
                        .foregroundColor(statusColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: item.status == .downloading || item.status == .processing)
                }
            }

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.status == .downloading || item.status == .paused {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(statusColor)
                        .animation(.spring(), value: item.progress)
                } else if item.status == .processing {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(statusColor)
                        .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Text(item.statusText)
                        .fontWeight(.semibold)
                        .foregroundColor(statusColor)

                    if let error = item.error, (item.status == .failed || item.status == .canceled) {
                        Text("•")
                        Text(error.localizedDescription)
                            .lineLimit(1)
                    }

                    if item.status == .downloading || item.status == .paused {
                        Group {
                            Text("•")
                            Text(item.progressText)
                            Text("•")
                            Text(item.sizeText)
                            if item.status == .downloading {
                                Text("•")
                                Text(item.speed)
                                Text("•")
                                Text("\(item.timeRemaining) left")
                            }
                        }
                        .foregroundColor(.secondary)
                    } else if !item.totalSizeText.isEmpty {
                        Group {
                            Text("•")
                            Text(item.totalSizeText)
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .font(.caption)
            }

            Spacer()

            // Action buttons
            actionButtons
        }
        .padding(.vertical, 8)
        .contextMenu {
            contextMenuItems
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            switch item.status {
            case .completed:
                Button(action: showInFinder) {
                    Label("Show", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button(action: removeItem) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Remove from list")

            case .downloading:
                Button(action: { manager.pauseDownload(item: item) }) {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.bordered)
                .help("Pause")

                Button(action: { manager.cancelDownload(item: item) }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .help("Cancel")

            case .paused:
                Button(action: { manager.resumeDownload(item: item) }) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)

            case .failed, .canceled:
                Button(action: { manager.retryFailedDownload(item: item) }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(action: removeItem) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Remove from list")

            case .pending, .processing:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if item.status == .completed {
            Button("Show in Finder") { showInFinder() }
            Button("Copy Path") { copyPath() }
            Divider()
        }

        Menu("Copy URL") {
            Button("Copy Original URL") {
                copyURL(item.originalURL)
            }
            Button("Copy Download URL") {
                copyURL(item.url)
            }
        }

        if item.status != .downloading && item.status != .processing {
            Divider()
            Button("Remove from List", role: .destructive) {
                removeItem()
            }
        }
    }

    // MARK: - Computed Properties

    private var fileIcon: String {
        let fileExtension = item.url.pathExtension.lowercased()
        switch fileExtension {
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "pdf": return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo.fill"
        case "mp3", "wav", "aac", "flac": return "music.note"
        case "mp4", "mov", "avi", "mkv": return "play.rectangle.fill"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "txt": return "doc.plaintext"
        case "dmg", "iso": return "opticaldisc.fill"
        default: return "doc.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .pending, .processing: return .secondary
        case .downloading: return .accentColor
        case .paused: return .orange
        case .completed: return .green
        case .failed, .canceled: return .red
        }
    }

    // MARK: - Helper Functions

    private func showInFinder() {
        guard let url = item.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath() {
        guard let url = item.localURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func removeItem() {
        if let index = manager.downloads.firstIndex(where: { $0.id == item.id }) {
            manager.downloads.remove(at: index)
        }
    }
}

// MARK: - PluginsListView

struct PluginsListView: View {
    @StateObject private var pluginManager = PluginManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if pluginManager.loadedPlugins.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "puzzlepiece")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Plugins Loaded")
                            .font(.title3)
                        Text("Add plugin folders with a manifest.json to extend Tori.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(pluginManager.loadedPlugins) { plugin in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: plugin.isEnabled ? "puzzlepiece.fill" : "puzzlepiece")
                            .font(.title2)
                            .foregroundColor(plugin.isEnabled ? .accentColor : .secondary)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(plugin.manifest.name)
                                    .font(.headline)
                                    .foregroundColor(plugin.isEnabled ? .primary : .secondary)

                                Button(action: { pluginManager.togglePlugin(plugin) }) {
                                    Text(plugin.isEnabled ? "Active" : "Disabled")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(plugin.isEnabled ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
                                        .foregroundColor(plugin.isEnabled ? .green : .secondary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                // Show capabilities next to button
                                if let capabilities = plugin.manifest.capabilities, !capabilities.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(capabilities, id: \.self) { capability in
                                            Text(capability)
                                                .font(.system(size: 8, weight: .semibold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.accentColor.opacity(0.15))
                                                .foregroundColor(.accentColor)
                                                .opacity(plugin.isEnabled ? 1.0 : 0.6)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }

                            if let description = plugin.manifest.description {
                                Text(description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .opacity(plugin.isEnabled ? 1.0 : 0.6)
                                    .lineLimit(2)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(plugin.manifest.patterns, id: \.self) { pattern in
                                        Text(cleanPattern(pattern))
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.1))
                                            .foregroundColor(.secondary)
                                            .opacity(plugin.isEnabled ? 1.0 : 0.5)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 8)
                    }
                }

                Divider()

                HStack {
                    Button("Open Plugins Folder") {
                        openPluginsFolder()
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("Reload Plugins") {
                        pluginManager.loadPlugins()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding()
            }
            .navigationTitle("Plugins")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cleanPattern(_ pattern: String) -> String {
        pattern.replacingOccurrences(of: "\\.", with: ".")
            .replacingOccurrences(of: ".*", with: "*")
            .replacingOccurrences(of: "\\", with: "")
    }

    private func openPluginsFolder() {
        let fileManager = FileManager.default
        if let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let pluginsDir = appSupportDir.appendingPathComponent("Tori/Plugins")
            if !fileManager.fileExists(atPath: pluginsDir.path) {
                try? fileManager.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: pluginsDir.path)
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @StateObject var manager = DownloadManager()

    DownloadManagerView()
        .environmentObject(manager)
}
