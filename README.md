# Tori 🐦

**Tori** is a lightweight, plugin-based download manager for macOS. The name is a play on the Japanese word for bird (**鳥**) and the root of the verb *toru* (**取り**), meaning "to take." True to its name, Tori sits in your menu bar, ready to fly out and grab the files you need.

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

- **Menu Bar Resident**: Stays tucked away in the system tray until a download is active.
- **Extensible Architecture**: Add support for new hosting providers by simply adding a JavaScript plugin.
- **Native Performance**: Built with SwiftUI for a fast, modern macOS experience.
- **Smart Retries**: Built-in exponential backoff to handle flaky connections or temporary server errors.

## Getting Started

1. Open `Tori.xcodeproj` in Xcode 15+.
2. Build and run the application.
3. Use the menu bar icon to add URLs or monitor active transfers.

---
*Tori: Taking files under its wing.*