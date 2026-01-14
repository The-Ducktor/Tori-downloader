import Foundation
import Observation
import Combine

// DownloadManager handles the lifecycle of file downloads and plugin processing.

// MARK: - Shared Formatters (avoid repeated allocations)
@MainActor
private enum SharedFormatters {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    static let timeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
}

@MainActor
@Observable
class DownloadManager: NSObject {
    var downloads: [DownloadItem] = []

    // Batch update support
    @ObservationIgnored private var isBatchUpdating = false
    @ObservationIgnored private var needsNotify = false

    @ObservationIgnored var onUpdate: (() -> Void)?

    // Cached JSON for WebSocket broadcasts
    @ObservationIgnored private var cachedJSON: String?
    @ObservationIgnored private var jsonIsDirty = true

    private func notifyUpdate() {
        jsonIsDirty = true
        if isBatchUpdating {
            needsNotify = true
            return
        }
        onUpdate?()
    }

    /// Perform multiple updates without triggering observers until complete
    func batchUpdate(_ block: () -> Void) {
        isBatchUpdating = true
        needsNotify = false
        block()
        isBatchUpdating = false
        if needsNotify {
            onUpdate?()
        }
    }

    func appendDownload(_ item: DownloadItem) {
        downloads.append(item)
        notifyUpdate()
    }

    func removeDownloads(where predicate: (DownloadItem) -> Bool) {
        let countBefore = downloads.count
        downloads.removeAll(where: predicate)
        if downloads.count != countBefore {
            notifyUpdate()
        }
    }

    @ObservationIgnored private var session: URLSession!
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 2.0

    override init() {
        super.init()
        let config = URLSessionConfiguration.default

        // Configure session for better reliability
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 300.0
        config.networkServiceType = .default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // Add headers to prevent server-side connection issues
        config.httpAdditionalHeaders = [
            "User-Agent": "DownloadManager/1.0",
            "Connection": "keep-alive",
            "Accept": "*/*"
        ]

        // Allow multiple downloads to run at once. The default is 6 on macOS.
        config.httpMaximumConnectionsPerHost = 12

        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    /// Public entry point for adding downloads, suitable for extensions or URL schemes
    func handleURL(_ url: URL) {
        addDownload(url: url)
    }

    func addDownload(url: URL, fileName: String? = nil, headers: [String: String]? = nil, destinationPath: String? = nil, bypassPlugins: Bool = false) {
        // Create item immediately so it shows in the UI as "Processing"
        let item = DownloadItem(url: url)
        item.status = .processing
        item.suggestedFileName = fileName
        item.headers = headers

        // Set default favicon URL
        if let host = url.host {
            item.iconURL = URL(string: "https://icons.bitwarden.eu/\(host)/icon.png")
        }

        appendDownload(item)

        if bypassPlugins {
            startDownload(item: item)
            return
        }

        Task {
            // Process URL through plugins
            let results = await PluginManager.shared.processURL(url)

            guard !results.isEmpty else {
                removeDownloads { $0.id == item.id }
                return
            }

            if results.count == 1 {
                let result = results[0]
                // Update item with processed info
                item.url = result.url

                // Merge headers: plugin headers take precedence if they exist
                if let pHeaders = result.headers {
                    var merged = item.headers ?? [:]
                    for (key, value) in pHeaders {
                        merged[key] = value
                    }
                    item.headers = merged
                }

                if let pName = result.fileName {
                    item.suggestedFileName = pName
                }
                if let pIcon = result.iconURL {
                    item.iconURL = URL(string: pIcon)
                }

                // Set reprocessOnResume flag from plugin context
                item.reprocessOnResume = result.context?.reprocessOnResume ?? false

                // Prevent re-downloading if already completed or in progress (check other items)
                if downloads.contains(where: { $0.id != item.id && $0.url == item.url && ($0.status == .downloading || $0.status == .completed) }) {
                    removeDownloads { $0.id == item.id }
                    return
                }

                startDownload(item: item)
            } else {
                // Multiple files found - remove the placeholder and add all of them
                batchUpdate {
                    removeDownloads { $0.id == item.id }

                    for result in results {
                        let newItem = DownloadItem(url: result.url)
                        newItem.suggestedFileName = result.fileName
                        newItem.headers = result.headers
                        if let pIcon = result.iconURL {
                            newItem.iconURL = URL(string: pIcon)
                        }

                        // Set reprocessOnResume flag from plugin context
                        newItem.reprocessOnResume = result.context?.reprocessOnResume ?? false

                        // Prevent re-downloading
                        if !downloads.contains(where: { $0.url == newItem.url && ($0.status == .downloading || $0.status == .completed) }) {
                            downloads.append(newItem)
                            startDownload(item: newItem)
                        }
                    }
                }
            }
        }
    }

    func startDownload(item: DownloadItem) {
        item.status = .downloading
        item.retryCount = 0
        item.error = nil
        item.resetSpeedCalculation()
        performDownload(item: item)
        notifyUpdate()
    }

    func performDownload(item: DownloadItem) {
        var request = URLRequest(url: item.url)
        if let headers = item.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        let task = session.downloadTask(with: request)
        item.task = task
        task.resume()
    }

    func retryDownload(item: DownloadItem) {
        guard item.retryCount < maxRetries else {
            item.status = .failed
            print("Max retries reached for \(item.displayName)")
            notifyUpdate()
            return
        }

        item.retryCount += 1
        let delay = retryDelay * pow(2.0, Double(item.retryCount - 1)) // Exponential backoff

        print("Retrying download for \(item.displayName) (attempt \(item.retryCount + 1)/\(maxRetries + 1)) in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.performDownload(item: item)
            self.notifyUpdate()
        }
    }

    func cancelDownload(item: DownloadItem) {
        item.task?.cancel()
        item.status = .canceled
        onUpdate?()
    }

    func pauseDownload(item: DownloadItem) {
        guard item.status == .downloading, let task = item.task else { return }

        let itemID = item.id

        // For plugins that reprocess on resume, don't save resume data
        if item.reprocessOnResume {
            print("Pausing download for \(item.displayName) without resume data due to reprocessing requirement")
            DispatchQueue.main.async {
                guard let itemToPause = self.downloads.first(where: { $0.id == itemID }) else { return }
                itemToPause.status = .paused
                itemToPause.task = nil
                self.notifyUpdate()
            }
            task.cancel()
            return
        }

        task.cancel(byProducingResumeData: { resumeData in
            DispatchQueue.main.async {
                guard let itemToPause = self.downloads.first(where: { $0.id == itemID }) else { return }
                itemToPause.resumeData = resumeData
                itemToPause.status = .paused
                itemToPause.task = nil
                self.notifyUpdate()
            }
        })
    }

    func resumeDownload(item: DownloadItem) {
        guard item.status == .paused else { return }

        // If the plugin requires reprocessing, re-run the URL through the plugin
        if item.reprocessOnResume {
            item.status = .processing
            item.resumeData = nil
            notifyUpdate()

            Task {
                let results = await PluginManager.shared.processURL(item.originalURL)

                await MainActor.run {
                    if let result = results.first {
                        item.url = result.url
                        item.headers = result.headers
                        if let pName = result.fileName {
                            item.suggestedFileName = pName
                        }
                        if let pIcon = result.iconURL {
                            item.iconURL = URL(string: pIcon)
                        }
                    }

                    startDownload(item: item)
                }
            }
            return
        }

        // Otherwise, resume from the paused state
        guard let resumeData = item.resumeData else { return }

        item.status = .downloading
        item.resumeData = nil

        let task = session.downloadTask(withResumeData: resumeData)
        item.task = task
        task.resume()
        notifyUpdate()
    }

    func retryFailedDownload(item: DownloadItem) {
        guard item.status == .failed || item.status == .canceled else { return }
        startDownload(item: item)
    }

    func pauseDownload(id: UUID) {
        if let item = downloads.first(where: { $0.id == id }) {
            pauseDownload(item: item)
        }
    }

    func resumeDownload(id: UUID) {
        if let item = downloads.first(where: { $0.id == id }) {
            resumeDownload(item: item)
        }
    }

    func cancelDownload(id: UUID) {
        if let item = downloads.first(where: { $0.id == id }) {
            cancelDownload(item: item)
        }
    }

    func removeDownload(id: UUID) {
        if let item = downloads.first(where: { $0.id == id }) {
            item.task?.cancel()
            removeDownloads { $0.id == id }
        }
    }

    // MARK: - Global Actions

    func pauseAll() {
        for item in downloads where item.status == .downloading {
            pauseDownload(item: item)
        }
    }

    func resumeAll() {
        for item in downloads where item.status == .paused {
            resumeDownload(item: item)
        }
    }

    var totalSpeed: Double {
        downloads.reduce(0) { $0 + $1.speedBytesPerSecond }
    }

    var totalSpeedText: String {
        formatBytesPerSecond(totalSpeed)
    }

    private func formatBytesPerSecond(_ bytesPerSecond: Double) -> String {
        "\(SharedFormatters.byteFormatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    // MARK: - Helpers

    func item(for task: URLSessionTask) -> DownloadItem? {
        return downloads.first(where: { $0.task?.taskIdentifier == task.taskIdentifier })
    }

    func moveDownloadedFile(from location: URL, for item: DownloadItem) -> Bool {
        let fileManager = FileManager.default
        let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        var fileName = item.suggestedFileName ?? item.url.lastPathComponent
        if fileName.isEmpty { fileName = "download" }

        // Ensure file extension if missing and we can guess it
        if !fileName.contains(".") {
            let ext = item.url.pathExtension
            if !ext.isEmpty {
                fileName += ".\(ext)"
            }
        }

        var destinationURL = downloadsURL.appendingPathComponent(fileName)

        // Handle duplicates
        var counter = 1
        let baseName = (fileName as NSString).deletingPathExtension
        let pathExtension = (fileName as NSString).pathExtension

        while fileManager.fileExists(atPath: destinationURL.path) {
            let newName = pathExtension.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(pathExtension)"
            destinationURL = downloadsURL.appendingPathComponent(newName)
            counter += 1
        }

        do {
            try fileManager.moveItem(at: location, to: destinationURL)
            item.localURL = destinationURL
            return true
        } catch {
            print("Error moving file: \(error)")
            return false
        }
    }

    func downloadsAsJSON() -> String {
        let dicts = downloads.map { $0.toDictionary() }
        if let data = try? JSONSerialization.data(withJSONObject: dicts, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let item = item(for: downloadTask) else { return }

            // Update filename if we got it from the response headers
            if item.suggestedFileName == nil, let suggested = downloadTask.response?.suggestedFilename {
                item.suggestedFileName = suggested
            }

            let speedUpdated = item.updateSpeed(bytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite)
            item.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

            if speedUpdated {
                self.notifyUpdate()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let item = item(for: downloadTask) else { return }

            if moveDownloadedFile(from: location, for: item) {
                item.status = .completed
                item.progress = 1.0
                item.task = nil
                self.onUpdate?()
            } else {
                item.status = .failed
                item.error = NSError(domain: "DownloadManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to move file"])
                self.notifyUpdate()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let item = item(for: task) else { return }

            if let error = error as NSError? {
                if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                    if item.status != .paused {
                        item.status = .canceled
                    }
                } else {
                    item.error = error
                    self.retryDownload(item: item)
                }
            }
            self.notifyUpdate()
        }
    }
}

@MainActor
@Observable
class DownloadItem: Identifiable {
    enum Status: String, Codable {
        case pending, processing, downloading, paused, completed, failed, canceled
    }

    let id = UUID()
    let originalURL: URL
    var url: URL
    var destinationURL: URL?
    var suggestedFileName: String?
    var iconURL: URL?
    var headers: [String: String]?
    var reprocessOnResume: Bool = false
    let dateAdded = Date()

    private(set) var lastUpdate = Date()

    var status: Status = .pending { didSet { if status != oldValue { signalUpdate() } } }
    var progress: Double = 0
    var error: Error?
    var speed: String = "0 KB/s"
    var timeRemaining: String = ""
    var totalBytes: Int64 = 0
    var bytesWritten: Int64 = 0
    var currentSpeedBytesPerSecond: Double = 0

    private func signalUpdate() {
        lastUpdate = Date()
    }

    @ObservationIgnored var task: URLSessionDownloadTask?
    @ObservationIgnored var localURL: URL?
    @ObservationIgnored var resumeData: Data?
    @ObservationIgnored var retryCount = 0

    @ObservationIgnored var lastBytesWritten: Int64 = 0
    @ObservationIgnored var lastSpeedUpdateTime = Date()

    init(url: URL) {
        self.originalURL = url
        self.url = url
    }

    func resetSpeedCalculation() {
        lastBytesWritten = 0
        lastSpeedUpdateTime = Date()
        speed = "0 KB/s"
        timeRemaining = ""
        currentSpeedBytesPerSecond = 0
    }

    @discardableResult
    func updateSpeed(bytesWritten: Int64, totalBytesExpected: Int64) -> Bool {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytesExpected

        let now = Date()
        let timeInterval = now.timeIntervalSince(lastSpeedUpdateTime)

        // Only recalculate speed every 0.8 seconds to reduce CPU
        if timeInterval >= 0.8 {
            let bytesDownloaded = bytesWritten - lastBytesWritten
            let bytesPerSecond = Double(bytesDownloaded) / timeInterval
            currentSpeedBytesPerSecond = bytesPerSecond

            speed = formatBytesPerSecond(bytesPerSecond)

            if bytesPerSecond > 0 && totalBytesExpected > 0 {
                let remainingBytes = totalBytesExpected - bytesWritten
                if remainingBytes > 0 {
                    let remainingTime = Double(remainingBytes) / bytesPerSecond
                    timeRemaining = formatTimeInterval(remainingTime)
                } else {
                    timeRemaining = "Finalizing..."
                }
            } else if status == .downloading {
                timeRemaining = progress > 0 ? "Stalled" : "Calculating..."
            }

            lastBytesWritten = bytesWritten
            lastSpeedUpdateTime = now
            signalUpdate()
            return true
        }
        return false
    }

    func formatBytesPerSecond(_ bytesPerSecond: Double) -> String {
        "\(SharedFormatters.byteFormatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    func formatTimeInterval(_ interval: TimeInterval) -> String {
        if interval.isInfinite || interval.isNaN { return "" }
        return SharedFormatters.timeFormatter.string(from: interval) ?? ""
    }

    var displayName: String {
        suggestedFileName ?? url.lastPathComponent
    }

    var statusText: String {
        switch status {
        case .pending: return "Pending"
        case .processing: return "Processing"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    var progressText: String {
        let percent = Int(progress * 100)
        return "\(percent)%"
    }

    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let written = formatter.string(fromByteCount: bytesWritten)
        let total = formatter.string(fromByteCount: totalBytes)

        if totalBytes > 0 {
            return "\(written) of \(total)"
        } else {
            return written
        }
    }

    var totalSizeText: String {
        if totalBytes > 0 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: totalBytes)
        }
        return ""
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id.uuidString,
            "url": url.absoluteString,
            "originalURL": originalURL.absoluteString,
            "status": status.rawValue,
            "progress": progress,
            "speed": speed,
            "timeRemaining": timeRemaining,
            "totalBytes": totalBytes,
            "bytesWritten": bytesWritten,
            "displayName": displayName,
            "fileName": displayName,
            "statusText": statusText,
            "progressText": progressText,
            "sizeText": sizeText,
            "totalSizeText": totalSizeText,
            "dateAdded": dateAdded.timeIntervalSince1970 * 1000 // Queue in milliseconds for JS comparison
        ]
        if let error = error {
            dict["error"] = error.localizedDescription
        }
        if let iconURL = iconURL {
            dict["iconURL"] = iconURL.absoluteString
        }
        return dict
    }
}

extension DownloadItem {
    var speedBytesPerSecond: Double {
        guard status == .downloading else { return 0 }

        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastSpeedUpdateTime)

        // If no update for more than 2 seconds, speed is 0
        if timeSinceLastUpdate > 2.0 {
            return 0
        }

        return currentSpeedBytesPerSecond
    }

    var timeRemainingSeconds: Double {
        let speed = speedBytesPerSecond
        if speed > 0 && totalBytes > 0 {
            let remainingBytes = totalBytes - bytesWritten
            return Double(remainingBytes) / speed
        }
        return 0
    }
}
