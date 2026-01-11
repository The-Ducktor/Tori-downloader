# Tori 🐦

**Tori** is a lightweight, plugin-based download manager for macOS with browser extension support. The name is a play on the Japanese word for bird (**鳥**) and the root of the verb *toru* (**取り**), meaning "to take." True to its name, Tori sits in your menu bar, ready to fly out and grab the files you need.

## Core Concept

Tori is designed to be a minimal core that delegates site-specific logic to a modular plugin system. By using `JavaScriptCore`, Tori can resolve complex download links (like those requiring specific headers or multi-step redirects) using simple JavaScript files.

## Plugin Development

Creating a plugin for Tori is straightforward. Each plugin requires a folder containing a manifest and a script.

### 1. manifest.json
Define the name of your plugin and the URL patterns it should intercept.

```json
{
  "name": "ExampleService",
  "entryPoint": "index.js",
  "patterns": ["example\\.com/download/.*"]
}
```

### 2. index.js
The script must define a `plugin` object with a `handle` function. This function receives the input URL and returns the direct file link or a metadata object.

```javascript
const plugin = {
  handle: async (url) => {
    // Logic to extract the direct link
    return {
      url: "https://cdn.example.com/files/data.zip",
      fileName: "data.zip",
      headers: { "User-Agent": "Tori/1.0" }
    };
  }
};
```

## Features

- **Menu Bar First**: Optional menu-bar-only mode or full window interface with transparent title bars
- **Browser Integration**: Chrome/Firefox extension for automatic download interception
- **Extensible Architecture**: Add support for new hosting providers by simply adding a JavaScript plugin
- **Native Performance**: Built with SwiftUI for a fast, modern macOS experience
- **Smart Retries**: Built-in exponential backoff to handle flaky connections or temporary server errors
- **Real-time Updates**: WebSocket connection provides instant status updates to browser extension
- **Optimized**: Cached formatters, batched updates, and efficient memory management for minimal resource usage

## Architecture

### macOS App
- **SwiftUI** for modern, declarative UI
- **Network.framework** for HTTP server and WebSocket support
- **URLSession** for robust download handling
- **JavaScriptCore** for plugin execution

### Browser Extension
- **Svelte 5** for reactive UI
- **WebSocket** for real-time download status
- **Chrome Extension APIs** for download interception

## Getting Started

### macOS App
1. Open `Tori.xcodeproj` in Xcode 15+
2. Build and run the application
3. The app will start in menu-bar mode by default
4. Click the menu bar icon to access downloads, or click "Open Tori" for the full window

### Browser Extension
1. Navigate to `ToriExtension` directory
2. Run `bun install` to install dependencies
3. Run `bun run build` to build the extension
4. Load the `dist` folder as an unpacked extension in Chrome/Firefox
5. The extension will automatically intercept downloads and send them to Tori

## Performance Optimizations

Tori has been optimized for speed and memory efficiency:

- **Cached Formatters**: Static `ByteCountFormatter` and `DateComponentsFormatter` to avoid repeated allocations
- **Batched Updates**: Groups multiple state changes into single UI updates
- **WebSocket Frame Caching**: Pre-builds and reuses frames for multiple clients
- **Bounded Memory**: Limits tracked download IDs to prevent unbounded growth
- **Reduced Polling**: Browser extension uses 2-second intervals instead of 1-second
- **Efficient Rendering**: Memoized computations and minimal array allocations

## License

MIT License - see [LICENSE](LICENSE) for details

---
*Tori: Taking files under its wing.*