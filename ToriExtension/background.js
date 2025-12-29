/**
 * Tori Extension - Background Script
 *
 * Handles download interception, communication with the Tori macOS app,
 * and maintains a persistent WebSocket connection for real-time updates.
 */

const TORI_API_URL = "http://localhost:18121";
const TORI_WS_URL = "ws://localhost:18121";

let socket = null;
let currentDownloads = [];
let reconnectTimer = null;
let isConnecting = false;
const scriptStartTime = Date.now();
let socketConnectionTime = null;

console.log("[Tori] Background script initialized");

// Cache request headers for potential downloads
chrome.webRequest.onBeforeSendHeaders.addListener(
	(details) => {
		const headers = {};
		details.requestHeaders.forEach((h) => {
			headers[h.name] = h.value;
		});

		// Store in session storage to survive service worker termination
		const key = `headers_${details.url}`;
		chrome.storage.session.set({
			[key]: {
				headers,
				timestamp: Date.now(),
			},
		});

		// Periodically cleanup old entries
		if (Math.random() < 0.05) {
			chrome.storage.session.get(null, (items) => {
				const now = Date.now();
				const toRemove = Object.keys(items).filter(
					(k) => k.startsWith("headers_") && now - items[k].timestamp > 60000,
				);
				if (toRemove.length > 0) chrome.storage.session.remove(toRemove);
			});
		}
	},
	{ urls: ["<all_urls>"], types: ["main_frame", "sub_frame", "other"] },
	["requestHeaders"],
);

/**
 * Establishes and maintains a WebSocket connection to the Tori app.
 */
function connectWebSocket() {
	if (isConnecting || (socket && socket.readyState === WebSocket.OPEN)) return;

	isConnecting = true;
	console.log("[Tori] Attempting to connect to WebSocket...");

	if (socket) {
		socket.onopen = null;
		socket.onmessage = null;
		socket.onclose = null;
		socket.onerror = null;
		socket.close();
	}

	socket = new WebSocket(TORI_WS_URL);

	socket.onopen = () => {
		isConnecting = false;
		socketConnectionTime = Date.now();
		console.log("[Tori] WebSocket connected");
		if (reconnectTimer) {
			clearTimeout(reconnectTimer);
			reconnectTimer = null;
		}
	};

	socket.onmessage = (event) => {
		try {
			const data = JSON.parse(event.data);
			if (Array.isArray(data)) {
				// Filter out downloads that started before the socket connection
				// to prevent showing historical downloads from the server
				const filteredDownloads = socketConnectionTime
					? data.filter((download) => {
							const downloadStartTime = new Date(download.startTime).getTime();
							return downloadStartTime >= socketConnectionTime - 2000; // 2s buffer for clock skew
						})
					: data;

				currentDownloads = filteredDownloads;
				// Broadcast to popup if it's open
				chrome.runtime
					.sendMessage({
						action: "downloadsUpdated",
						downloads: currentDownloads,
					})
					.catch(() => {
						// Popup is likely closed, ignore
					});
			}
		} catch (err) {
			console.error("[Tori] Failed to parse WebSocket message:", err);
		}
	};

	socket.onclose = (event) => {
		isConnecting = false;
		socket = null;
		currentDownloads = [];
		console.log(
			`[Tori] WebSocket closed (code: ${event.code}). Retrying in 5s...`,
		);

		// Notify popup of disconnection
		chrome.runtime
			.sendMessage({
				action: "downloadsUpdated",
				downloads: [],
				connected: false,
			})
			.catch(() => {});

		if (!reconnectTimer) {
			reconnectTimer = setTimeout(connectWebSocket, 5000);
		}
	};

	socket.onerror = (error) => {
		console.error("[Tori] WebSocket error observed:", error);
		// onclose will handle the reconnection
	};
}

// Initial connection attempt
connectWebSocket();

/**
 * Intercepts browser downloads and redirects them to Tori.
 */
chrome.downloads.onCreated.addListener(async (downloadItem) => {
	// Ignore downloads that were created before the extension started
	// to prevent re-intercepting old downloads on browser restart.
	const downloadStartTime = new Date(downloadItem.startTime).getTime();
	if (downloadStartTime < scriptStartTime - 5000) {
		return;
	}

	// Check if interception is enabled and get settings
	const settings = await chrome.storage.local.get([
		"interceptEnabled",
		"minInterceptSize",
		"bypassPlugins",
		"savePath",
	]);

	if (settings.interceptEnabled === false) {
		console.log(
			"[Tori] Interception disabled, allowing browser to handle download",
		);
		return;
	}

	// Check file size if available (fileSize is -1 if unknown)
	const minSizeMB =
		settings.minInterceptSize !== undefined ? settings.minInterceptSize : 50;
	const minSizeBytes = minSizeMB * 1024 * 1024;

	if (
		downloadItem.fileSize > 0 &&
		downloadItem.fileSize < minSizeBytes &&
		minSizeMB > 0
	) {
		console.log(
			`[Tori] Skipping small download (${(
				downloadItem.fileSize / (1024 * 1024)
			).toFixed(2)}MB < ${minSizeMB}MB)`,
		);
		return;
	}

	// Only intercept HTTP/HTTPS downloads
	if (downloadItem.url.startsWith("http")) {
		console.log("[Tori] Intercepting download:", downloadItem.url);

		// Retrieve cached headers from session storage
		const key = `headers_${downloadItem.url}`;
		const storageResult = await chrome.storage.session.get([key]);
		const cached = storageResult[key] || { headers: {} };
		const headers = { ...cached.headers };

		// Ensure cookies are up to date
		const cookies = await chrome.cookies.getAll({ url: downloadItem.url });
		if (cookies.length > 0) {
			headers["Cookie"] = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
		}

		// Add basic metadata if missing
		if (!headers["User-Agent"]) headers["User-Agent"] = navigator.userAgent;
		if (!headers["Referer"] && downloadItem.referrer)
			headers["Referer"] = downloadItem.referrer;

		// Cancel the browser's internal download
		chrome.downloads.cancel(downloadItem.id, () => {
			if (chrome.runtime.lastError) {
				console.error(
					"[Tori] Error canceling browser download:",
					chrome.runtime.lastError,
				);
				return;
			}

			console.log(
				"[Tori] Browser download canceled, forwarding to Tori app...",
			);
			sendToTori(
				downloadItem.url,
				downloadItem.filename,
				headers,
				settings.bypassPlugins || false,
				settings.savePath || null,
			);
		});
	}
});

/**
 * Sends download metadata to the Tori local server.
 */
async function sendToTori(
	url,
	fileName,
	headers = {},
	bypassPlugins = false,
	destinationPath = null,
) {
	try {
		const response = await fetch(`${TORI_API_URL}/add`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({
				url: url,
				fileName: fileName ? fileName.split(/[\\/]/).pop() : null,
				headers: headers,
				bypassPlugins: bypassPlugins,
				destinationPath: destinationPath,
			}),
		});

		if (!response.ok) {
			throw new Error(`Server responded with ${response.status}`);
		}

		console.log("[Tori] Successfully sent download to app");

		chrome.notifications.create({
			type: "basic",
			iconUrl: "icons/icon128.png",
			title: "Tori Intercepted",
			message: `Started: ${fileName || url}`,
			priority: 1,
		});
	} catch (error) {
		console.error("[Tori] Failed to send download to app:", error);

		chrome.notifications.create({
			type: "basic",
			iconUrl: "icons/icon128.png",
			title: "Tori Connection Error",
			message: "Could not reach the Tori app. Is it running?",
			priority: 2,
		});
	}
}

/**
 * Handles messages from the popup UI.
 */
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
	if (request.action === "getDownloads") {
		const isConnected = socket && socket.readyState === WebSocket.OPEN;
		sendResponse({
			success: true,
			downloads: currentDownloads,
			connected: isConnected,
		});
	}
	return true; // Keep channel open for async response
});
