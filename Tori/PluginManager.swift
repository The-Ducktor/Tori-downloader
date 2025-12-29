import Foundation
@preconcurrency import JavaScriptCore

struct PluginManifest: Codable, Sendable {
    let name: String
    let description: String?
    let entryPoint: String
    let patterns: [String]
    let capabilities: [String]?
}

struct PluginActionResult: Sendable {
    let url: URL
    let fileName: String?
    let iconURL: String?
    let size: Int64?
    let headers: [String: String]?
    let pluginName: String?
    let pluginCapabilities: [String]?
}

struct LoadedPlugin: Identifiable {
    let id = UUID()
    let manifest: PluginManifest
    let jsValue: JSValue
    var isEnabled: Bool
}

@MainActor
class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published var loadedPlugins: [LoadedPlugin] = []
    private let context: JSContext

    var loadedPluginNames: [String] {
        loadedPlugins.map { $0.manifest.name }
    }

    init() {
        guard let context = JSContext() else {
            fatalError("Failed to create JSContext")
        }
        self.context = context
        setupContext()
        loadPlugins()
    }

    private func setupContext() {
        // Add console.log support
        let log: @convention(block) (String) -> Void = { message in
            print("🔌 [Plugin Log]: \(message)")
        }
        context.setObject(log, forKeyedSubscript: "print" as NSString)
        context.evaluateScript("var console = { log: print };")
        context.evaluateScript("var globalThis = this;")

        // Add setTimeout polyfill
        let setTimeout: @convention(block) (JSValue, Double) -> JSValue? = { [weak self] callback, ms in
            guard let self = self else { return nil }
            let timer = Timer.scheduledTimer(withTimeInterval: ms / 1000.0, repeats: false) { _ in
                DispatchQueue.main.async {
                    callback.call(withArguments: [])
                }
            }
            return JSValue(object: timer, in: self.context)
        }
        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)

        let clearTimeout: @convention(block) (JSValue) -> Void = { timerValue in
            if let timer = timerValue.toObject() as? Timer {
                timer.invalidate()
            }
        }
        context.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)

        // Add fetch support (Basic implementation for plugins)
        let fetch: @convention(block) (String, [String: Any]?) -> JSValue? = { [weak self] urlString, options in
            guard let self = self else { return nil }

            return JSValue(newPromiseIn: self.context) { [weak self] resolve, reject in
                guard let self = self, let url = URL(string: urlString) else {
                    reject?.call(withArguments: ["Invalid URL"])
                    return
                }

                var request = URLRequest(url: url)
                if let options = options {
                    if let method = options["method"] as? String {
                        request.httpMethod = method
                    }
                    if let headers = options["headers"] as? [String: String] {
                        for (key, value) in headers {
                            request.setValue(value, forHTTPHeaderField: key)
                        }
                    }
                }

                URLSession.shared.dataTask(with: request) { data, response, error in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }

                        if let error = error {
                            reject?.call(withArguments: [error.localizedDescription])
                            return
                        }

                        let httpResponse = response as? HTTPURLResponse
                        let responseObj = JSValue(newObjectIn: self.context)

                        // Add text() method
                        let textFn: @convention(block) () -> JSValue? = { [weak self] in
                            guard let self = self else { return nil }
                            return JSValue(newPromiseIn: self.context) { tResolve, _ in
                                if let data = data, let text = String(data: data, encoding: .utf8) {
                                    tResolve?.call(withArguments: [text])
                                } else {
                                    tResolve?.call(withArguments: [""])
                                }
                            }
                        }
                        responseObj?.setObject(textFn, forKeyedSubscript: "text" as NSString)

                        // Add headers.get() method
                        let headersObj = JSValue(newObjectIn: self.context)
                        let getHeaderFn: @convention(block) (String) -> String? = { key in
                            return httpResponse?.value(forHTTPHeaderField: key)
                        }
                        headersObj?.setObject(getHeaderFn, forKeyedSubscript: "get" as NSString)
                        responseObj?.setObject(headersObj, forKeyedSubscript: "headers" as NSString)

                        responseObj?.setObject(httpResponse?.statusCode ?? 0, forKeyedSubscript: "status" as NSString)
                        responseObj?.setObject((200...299).contains(httpResponse?.statusCode ?? 0), forKeyedSubscript: "ok" as NSString)

                        resolve?.call(withArguments: [responseObj as Any])
                    }
                }.resume()
            }
        }
        context.setObject(fetch, forKeyedSubscript: "fetch" as NSString)

        // Error handling for JS
        context.exceptionHandler = { _, exception in
            print("❌ [JS Error]: \(exception?.toString() ?? "Unknown error")")
        }
    }

    func loadPlugins() {
        let fileManager = FileManager.default
        loadedPlugins = []

        // 1. Load from Application Support (User plugins)
        if let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let pluginsDir = appSupportDir.appendingPathComponent("Tori/Plugins")
            loadPluginsFromRoot(pluginsDir)
        }

        // 2. Load from Bundle (Built-in plugins)
        if let bundlePluginsDir = Bundle.main.resourceURL?.appendingPathComponent("Plugins") {
            loadPluginsFromRoot(bundlePluginsDir)
        }
    }

    private func loadPluginsFromRoot(_ root: URL) {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return
        }

        // Search recursively for any .json files that might be manifests
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == "json" {
                loadPlugin(at: fileURL)
            }
        }
    }

    private func loadPlugin(at manifestURL: URL) {
        let fileManager = FileManager.default
        let folderURL = manifestURL.deletingLastPathComponent()

        do {
            let data = try Data(contentsOf: manifestURL)
            // Check if it's actually a manifest by trying to decode it
            guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else { return }

            let entryPointURL = folderURL.appendingPathComponent(manifest.entryPoint)

            guard fileManager.fileExists(atPath: entryPointURL.path) else {
                print("⚠️ Entry point \(manifest.entryPoint) not found for plugin \(manifest.name) at \(folderURL.path)")
                return
            }

            let script = try String(contentsOf: entryPointURL, encoding: .utf8)
            let wrappedScript = "(function() { \(script)\n return plugin; })()"

            if let pluginValue = context.evaluateScript(wrappedScript), !pluginValue.isUndefined {
                let isEnabled = UserDefaults.standard.object(forKey: "plugin_enabled_\(manifest.name)") as? Bool ?? true
                let loadedPlugin = LoadedPlugin(manifest: manifest, jsValue: pluginValue, isEnabled: isEnabled)
                loadedPlugins.append(loadedPlugin)
                print("✅ Loaded plugin: \(manifest.name) (Enabled: \(isEnabled))")
            }
        } catch {
            // Silently fail for non-manifest JSONs
        }
    }

    func togglePlugin(_ plugin: LoadedPlugin) {
        if let index = loadedPlugins.firstIndex(where: { $0.id == plugin.id }) {
            loadedPlugins[index].isEnabled.toggle()
            UserDefaults.standard.set(loadedPlugins[index].isEnabled, forKey: "plugin_enabled_\(loadedPlugins[index].manifest.name)")
        }
    }

    func findPlugin(for url: URL) -> LoadedPlugin? {
        let urlString = url.absoluteString
        for plugin in loadedPlugins where plugin.isEnabled {
            for pattern in plugin.manifest.patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)) != nil {
                    return plugin
                }
            }
        }
        return nil
    }

    /// Processes a URL through a plugin asynchronously with retry logic
    func processURL(_ url: URL) async -> [PluginActionResult] {
        guard let plugin = findPlugin(for: url) else {
            return [PluginActionResult(url: url, fileName: nil, iconURL: nil, size: nil, headers: nil, pluginName: nil, pluginCapabilities: nil)]
        }

        let maxRetries = 3
        var attempt = 0

        while attempt < maxRetries {
            let handleFn = plugin.jsValue.objectForKeyedSubscript("handle")
            let resultValue = handleFn?.call(withArguments: [url.absoluteString])

            // Handle Promise if returned
            let finalResult: JSValue?
            if let resultValue = resultValue, resultValue.hasProperty("then") {
                // Use a wrapper to pass non-Sendable JSValue through continuation
                struct UncheckedJSValue: @unchecked Sendable {
                    let value: JSValue?
                }

                let wrappedResult = await withCheckedContinuation { continuation in
                    let onResolve: @convention(block) (JSValue) -> Void = { val in
                        continuation.resume(returning: UncheckedJSValue(value: val))
                    }
                    let onReject: @convention(block) (JSValue) -> Void = { err in
                        print("❌ [Plugin Async Error]: \(err.toString() ?? "Unknown")")
                        continuation.resume(returning: UncheckedJSValue(value: nil))
                    }

                    resultValue.invokeMethod("then", withArguments: [
                        JSValue(object: onResolve, in: self.context) as Any
                    ])
                    resultValue.invokeMethod("catch", withArguments: [
                        JSValue(object: onReject, in: self.context) as Any
                    ])
                }
                finalResult = wrappedResult.value
            } else {
                finalResult = resultValue
            }

            if let result = finalResult, !result.isUndefined {
                // Check for error response from plugin
                if result.isObject && result.hasProperty("error") {
                    let errorMsg = result.objectForKeyedSubscript("error")?.toString() ?? "Unknown error"
                    let isRetryable = result.objectForKeyedSubscript("retryable")?.toBool() ?? false

                    print("⚠️ Plugin '\(plugin.manifest.name)' reported error: \(errorMsg)")

                    if isRetryable && attempt < maxRetries - 1 {
                        attempt += 1
                        let delay = pow(2.0, Double(attempt)) // Exponential backoff
                        print("🔄 Retrying plugin in \(delay)s...")
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                }

                if result.isArray {
                    var results: [PluginActionResult] = []
                    let length = result.objectForKeyedSubscript("length")?.toInt32() ?? 0
                    for i in 0..<length {
                        if let item = result.objectAtIndexedSubscript(Int(i)),
                           let actionResult = parsePluginResult(item, pluginName: plugin.manifest.name, pluginCapabilities: plugin.manifest.capabilities) {
                            results.append(actionResult)
                        }
                    }
                    if !results.isEmpty { return results }
                } else if result.isObject {
                    if result.hasProperty("url") {
                        if let actionResult = parsePluginResult(result, pluginName: plugin.manifest.name, pluginCapabilities: plugin.manifest.capabilities) {
                            return [actionResult]
                        }
                    } else if result.hasProperty("files") {
                        let filesVal = result.objectForKeyedSubscript("files")
                        if filesVal?.isArray == true {
                            var results: [PluginActionResult] = []
                            let length = filesVal?.objectForKeyedSubscript("length")?.toInt32() ?? 0
                            for i in 0..<length {
                                if let item = filesVal?.objectAtIndexedSubscript(Int(i)),
                                   let actionResult = parsePluginResult(item, pluginName: plugin.manifest.name, pluginCapabilities: plugin.manifest.capabilities) {
                                    results.append(actionResult)
                                }
                            }
                            if !results.isEmpty { return results }
                        }
                    }
                } else if result.isString {
                    if let newURLString = result.toString(), let newURL = URL(string: newURLString) {
                        return [PluginActionResult(url: newURL, fileName: nil, iconURL: nil, size: nil, headers: nil, pluginName: plugin.manifest.name, pluginCapabilities: plugin.manifest.capabilities)]
                    }
                }
            }
            break // Exit loop if no retryable error
        }

        return [PluginActionResult(url: url, fileName: nil, iconURL: nil, size: nil, headers: nil, pluginName: nil, pluginCapabilities: nil)]
    }

    private func parsePluginResult(_ result: JSValue, pluginName: String? = nil, pluginCapabilities: [String]? = nil) -> PluginActionResult? {
        if result.isString {
            if let urlString = result.toString(), let url = URL(string: urlString) {
                return PluginActionResult(url: url, fileName: nil, iconURL: nil, size: nil, headers: nil, pluginName: pluginName, pluginCapabilities: pluginCapabilities)
            }
        } else if result.isObject {
            let urlVal = result.objectForKeyedSubscript("url")
            let nameVal = result.objectForKeyedSubscript("fileName")
            let iconVal = result.objectForKeyedSubscript("iconURL")
            let sizeVal = result.objectForKeyedSubscript("size")
            let headersVal = result.objectForKeyedSubscript("headers")

            let urlString = (urlVal?.isUndefined == false && urlVal?.isNull == false) ? urlVal?.toString() : nil
            let fileName = (nameVal?.isUndefined == false && nameVal?.isNull == false) ? nameVal?.toString() : nil
            let iconURL = (iconVal?.isUndefined == false && iconVal?.isNull == false) ? iconVal?.toString() : nil
            let size = (sizeVal?.isUndefined == false && sizeVal?.isNull == false) ? Int64(sizeVal?.toNumber()?.doubleValue ?? 0) : nil

            var headers: [String: String]? = nil
            if let headersVal = headersVal, headersVal.isObject {
                headers = headersVal.toDictionary() as? [String: String]
            }

            if let urlString = urlString, let url = URL(string: urlString) {
                return PluginActionResult(url: url, fileName: fileName, iconURL: iconURL, size: size, headers: headers, pluginName: pluginName, pluginCapabilities: pluginCapabilities)
            }
        }
        return nil
    }
}
