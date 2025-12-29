import SwiftUI

struct MenuBarExtraView: View {
    @ObservedObject var manager: DownloadManager

    var body: some View {
        let activeItems = manager.downloads.filter { $0.status == .downloading || $0.status == .processing || $0.status == .paused }

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
                if !activeItems.isEmpty {
                    Text("\(activeItems.count) active")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.windowBackgroundColor))

            Divider()

            // Content
            if activeItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.secondary)

                    Text("No Active Downloads")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text("Downloads will appear here.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 32)
                .frame(minWidth: 280)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activeItems) { item in
                            MenuBarDownloadRow(item: item, manager: manager)

                            if item.id != activeItems.last?.id {
                                Divider()
                                    .padding(.leading, 64)
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .background(Color(.windowBackgroundColor))
        .frame(width: 300)
    }
}

struct MenuBarDownloadRow: View {
    @ObservedObject var item: DownloadItem
    @ObservedObject var manager: DownloadManager
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(statusColor.opacity(0.1))
                    .frame(width: 36, height: 36)

                if let iconURL = item.iconURL {
                    AsyncImage(url: iconURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Image(systemName: fileIcon)
                        .font(.system(size: 16))
                        .foregroundColor(statusColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: item.status == .downloading || item.status == .processing)
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Filename
                Text(item.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Progress info
                HStack(spacing: 4) {
                    if item.status == .processing {
                        Text("Resolving link...")
                    } else if item.status == .downloading {
                        Text(item.progressText)
                        Text("•")
                        Text(item.sizeText)
                        Text("•")
                        Text(item.speed)
                        Spacer()
                        Text("\(item.timeRemaining) left")
                    } else if item.status == .paused {
                        Text(item.statusText)
                        Text("•")
                        Text(item.sizeText)
                    } else {
                        Text(item.statusText)
                        if !item.totalSizeText.isEmpty {
                            Text("•")
                            Text(item.totalSizeText)
                        }
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)

                // Progress bar
                if item.status == .downloading {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .scaleEffect(y: 0.6)
                } else if item.status == .processing {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .scaleEffect(y: 0.6)
                }
            }

            // Action button (appears on hover)
            if isHovered {
                Button(action: {
                    // Handle pause/resume/cancel
                    if self.item.status == .downloading {
                        self.manager.pauseDownload(item: self.item)
                    } else if self.item.status == .paused {
                        self.manager.resumeDownload(item: self.item)
                    } else if self.item.status == .failed || self.item.status == .canceled {
                        self.manager.retryFailedDownload(item: self.item)
                    } else if self.item.status == .completed {
                        self.showInFinder()
                    }
                }) {
                    Image(systemName: actionButtonIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.accentColor.opacity(0.05) : Color.clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if item.status == .completed {
                Button("Show in Finder") { showInFinder() }
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
    }

    private var actionButtonIcon: String {
        switch self.item.status {
        case .downloading: return "pause.fill"
        case .paused: return "play.fill"
        case .completed: return "folder.fill"
        case .failed, .canceled: return "arrow.clockwise"
        default: return "xmark"
        }
    }

    private var fileIcon: String {
        let fileExtension = self.item.url.pathExtension.lowercased()
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

    private func showInFinder() {
        guard let url = self.item.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    private var statusColor: Color {
        switch item.status {
        case .pending, .processing: return .secondary
        case .downloading: return .accentColor
        case .paused: return .orange
        case .completed: return .green
        case .failed, .canceled: return .red
        }
    }
}
