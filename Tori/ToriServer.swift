import Foundation
import Network
import CryptoKit

/// A lightweight HTTP and WebSocket server to allow the Chrome extension to communicate with Tori efficiently.
/// We mark the class as @unchecked Sendable because it is isolated to the MainActor, and all callbacks
/// are explicitly jumped back to the MainActor using assumeIsolated.
@MainActor
final class ToriServer: ObservableObject, @unchecked Sendable {
    private var listener: NWListener?
    private let port: NWEndpoint.Port
    private let downloadManager: DownloadManager

    // WebSocket management
    private var connections: [UUID: NWConnection] = [:]
    private var lastUpdateSent: Date = .distantPast
    private let minUpdateInterval: TimeInterval = 0.5 // Max 2 updates per second to save battery
    private var pendingUpdate = false

    // Cached JSON and WebSocket frame to avoid repeated serialization
    private var cachedJSON: String?
    private var cachedFrame: Data?
    private var jsonIsDirty = true

    // Pre-allocated response templates
    private static let okResponse = "{\"status\": \"ok\"}"
    private static let corsHeaders = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n"

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
        // Tori's default API port
        self.port = NWEndpoint.Port(rawValue: 18121)!

        // Set up the update hook from DownloadManager
        self.downloadManager.onUpdate = { [weak self] in
            MainActor.assumeIsolated {
                self?.jsonIsDirty = true
                self?.cachedFrame = nil
                self?.scheduleUpdate()
            }
        }
    }

    private func getCachedJSON() -> String {
        if jsonIsDirty || cachedJSON == nil {
            cachedJSON = downloadManager.downloadsAsJSON()
            cachedFrame = nil // Invalidate frame cache too
            jsonIsDirty = false
        }
        return cachedJSON!
    }

    private func getCachedFrame() -> Data {
        if cachedFrame == nil {
            let json = getCachedJSON()
            let data = Data(json.utf8)

            // Construct WebSocket Text Frame (Server to Client, no masking)
            // 0x81 = Fin bit set, Opcode 1 (Text)
            var frame = Data([0x81])
            let length = data.count
            if length <= 125 {
                frame.append(UInt8(length))
            } else if length <= 65535 {
                frame.append(126)
                var len = UInt16(length).bigEndian
                frame.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
            } else {
                frame.append(127)
                var len = UInt64(length).bigEndian
                frame.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
            }
            frame.append(data)
            cachedFrame = frame
        }
        return cachedFrame!
    }

    func start() {
        let parameters = NWParameters.tcp

        guard let listener = try? NWListener(using: parameters, on: port) else {
            print("ToriServer: [Error] Failed to create listener on port \(port)")
            return
        }

        self.listener = listener

        // NWListener callbacks are executed on the provided queue.
        // We use .main to stay on the MainActor's thread.
        listener.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    print("ToriServer: [Status] Ready on port 18121 (HTTP + WS)")
                case .failed(let error):
                    print("ToriServer: [Error] Listener failed: \(error)")
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                print("ToriServer: [Network] New incoming connection")
                self?.handleNewConnection(connection)
            }
        }

        listener.start(queue: .main)
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        connection.start(queue: .main)
        receiveData(id: id, connection: connection)
    }

    private func receiveData(id: UUID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self = self else { return }

                if let data = data, !data.isEmpty {
                    let requestString = String(data: data, encoding: .utf8) ?? ""

                    // Check if this is a WebSocket upgrade request
                    if requestString.contains("Upgrade: websocket") {
                        print("ToriServer: [WS] Upgrade request received")
                        self.handleWebSocketUpgrade(id: id, request: requestString, connection: connection)
                    } else {
                        self.processHttpRequest(requestString, connection: connection)
                    }
                }

                if error != nil || isComplete {
                    if self.connections[id] == nil {
                        connection.cancel()
                    }
                }
            }
        }
    }

    // MARK: - HTTP Handling

    private func processHttpRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        let method = parts[0]
        let path = parts[1]

        print("ToriServer: [HTTP] \(method) \(path)")

        // Handle CORS preflight
        if method == "OPTIONS" {
            sendCORSResponse(connection: connection)
            return
        }

        if method == "GET" && path == "/downloads" {
            sendHttpResponse(json: getCachedJSON(), connection: connection)
        } else if method == "POST" && path == "/resolve" {
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let body = String(request[bodyRange.upperBound...])
                if let jsonData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let urlString = json["url"] as? String,
                   let url = URL(string: urlString) {

                    Task {
                        let results = await PluginManager.shared.processURL(url)
                        let resultsArray = results.map { result -> [String: Any] in
                            var dict: [String: Any] = ["url": result.url.absoluteString]
                            if let fileName = result.fileName { dict["fileName"] = fileName }
                            if let iconURL = result.iconURL { dict["iconURL"] = iconURL }
                            if let headers = result.headers { dict["headers"] = headers }
                            return dict
                        }

                        let responseData = try? JSONSerialization.data(withJSONObject: ["results": resultsArray])
                        let responseJson = String(data: responseData ?? Data(), encoding: .utf8) ?? "{}"

                        await MainActor.run {
                            self.sendHttpResponse(json: responseJson, connection: connection)
                        }
                    }
                } else {
                    sendHttpResponse(status: "400 Bad Request", json: "{\"error\": \"Invalid URL\"}", connection: connection)
                }
            } else {
                sendHttpResponse(status: "400 Bad Request", json: "{\"error\": \"No body found\"}", connection: connection)
            }
        } else if method == "POST" && path == "/add" {
            // Basic body extraction (find double CRLF)
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let body = String(request[bodyRange.upperBound...])
                if let jsonData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let urlString = json["url"] as? String,
                   let url = URL(string: urlString) {

                    let fileName = json["fileName"] as? String
                    let headers = json["headers"] as? [String: String]
                    let destinationPath = json["destinationPath"] as? String
                    let bypassPlugins = json["bypassPlugins"] as? Bool ?? false

                    print("ToriServer: [Action] Adding download from extension: \(urlString)")
                    downloadManager.addDownload(url: url, fileName: fileName, headers: headers, destinationPath: destinationPath, bypassPlugins: bypassPlugins)
                    sendHttpResponse(json: Self.okResponse, connection: connection)
                } else {
                    print("ToriServer: [Error] Failed to parse /add request body")
                    sendHttpResponse(status: "400 Bad Request", json: "{\"error\": \"Invalid JSON\"}", connection: connection)
                }
            } else {
                sendHttpResponse(status: "400 Bad Request", json: "{\"error\": \"No body found\"}", connection: connection)
            }
        } else if method == "POST" && ["/pause", "/resume", "/cancel", "/remove"].contains(path) {
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let body = String(request[bodyRange.upperBound...])
                if let jsonData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let idString = json["id"] as? String,
                   let id = UUID(uuidString: idString) {

                    switch path {
                    case "/pause": downloadManager.pauseDownload(id: id)
                    case "/resume": downloadManager.resumeDownload(id: id)
                    case "/cancel": downloadManager.cancelDownload(id: id)
                    case "/remove": downloadManager.removeDownload(id: id)
                    default: break
                    }
                    sendHttpResponse(json: Self.okResponse, connection: connection)
                } else {
                    sendHttpResponse(status: "400 Bad Request", json: "{\"error\": \"Invalid ID\"}", connection: connection)
                }
            } else {
                sendHttpResponse(status: "400 Bad Request", json: "{\"error\": \"No body found\"}", connection: connection)
            }
        } else {
            sendHttpResponse(status: "404 Not Found", json: "{\"error\": \"Not Found\"}", connection: connection)
        }
    }

    private func sendHttpResponse(status: String = "200 OK", json: String, connection: NWConnection) {
        // Use string interpolation with pre-computed parts
        let contentLength = json.utf8.count
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(contentLength)\r\n\(Self.corsHeaders)Connection: close\r\n\r\n\(json)"

        connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private static let corsResponse = Data("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Max-Age: 86400\r\nConnection: close\r\n\r\n".utf8)

    private func sendCORSResponse(connection: NWConnection) {
        connection.send(content: Self.corsResponse, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    // MARK: - WebSocket Handling

    private func handleWebSocketUpgrade(id: UUID, request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let keyLine = lines.first(where: { $0.lowercased().contains("sec-websocket-key") }),
              let key = keyLine.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) else {
            print("ToriServer: [WS Error] Missing Sec-WebSocket-Key")
            connection.cancel()
            return
        }

        // Generate Accept Key using CryptoKit (Modern SHA1)
        let combined = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let sha1 = Insecure.SHA1.hash(data: Data(combined.utf8))
        let acceptKey = Data(sha1).base64EncodedString()

        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(acceptKey)\r\n" +
                       "\r\n"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ [weak self] error in
            MainActor.assumeIsolated {
                guard let self = self, error == nil else { return }

                // Track this connection for broadcasting updates
                self.connections[id] = connection
                print("ToriServer: [WS] Client connected. Total active: \(self.connections.count)")

                connection.stateUpdateHandler = { state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .cancelled, .failed:
                            if self.connections.removeValue(forKey: id) != nil {
                                print("ToriServer: [WS] Client disconnected. Total active: \(self.connections.count)")
                            }
                        default:
                            break
                        }
                    }
                }

                // Listen for closure or messages (though we only push)
                self.listenForWebSocketMessages(id: id, connection: connection)

                // Send initial state immediately
                self.broadcastUpdate()
            }
        }))
    }

    private func listenForWebSocketMessages(id: UUID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if error != nil || isComplete {
                    if self.connections.removeValue(forKey: id) != nil {
                        print("ToriServer: [WS] Client connection closed. Total active: \(self.connections.count)")
                    }
                    connection.cancel()
                } else {
                    self.listenForWebSocketMessages(id: id, connection: connection)
                }
            }
        }
    }

    private func scheduleUpdate() {
        guard !pendingUpdate else { return }

        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastUpdateSent)

        if timeSinceLast >= minUpdateInterval {
            broadcastUpdate()
        } else {
            pendingUpdate = true
            let delay = minUpdateInterval - timeSinceLast
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pendingUpdate = false
                    self?.broadcastUpdate()
                }
            }
        }
    }

    private func broadcastUpdate() {
        guard !connections.isEmpty else { return }

        // Use cached frame to avoid repeated serialization and frame construction
        let frame = getCachedFrame()

        for (id, connection) in connections {
            connection.send(content: frame, completion: .contentProcessed({ [weak self] error in
                MainActor.assumeIsolated {
                    if error != nil {
                        print("ToriServer: [WS Error] Failed to send update to client \(id)")
                        connection.cancel()
                        self?.connections.removeValue(forKey: id)
                    }
                }
            }))
        }

        lastUpdateSent = Date()
    }
}
