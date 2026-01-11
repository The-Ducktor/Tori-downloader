/**
 * Tori Extension - Background Script (Optimized)
 *
 * Handles download interception, communication with the Tori macOS app,
 * and maintains a persistent WebSocket connection for real-time updates.
 */

const TORI_API_URL = "http://localhost:18121";
const TORI_WS_URL = "ws://localhost:18121";

// Connection state
let socket = null;
let isConnecting = false;
let reconnectTimer = null;
let socketConnectionTime = null;

// Download tracking with size limit
const MAX_TRACKED_IDS = 500;
let trackedDownloadIds = new Set();
let currentDownloads = [];

// Timing
const scriptStartTime = Date.now();
const RECONNECT_DELAY = 5000;
const HEADER_CACHE_TTL = 30000; // 30 seconds
const HEADER_CLEANUP_THRESHOLD = 100;

console.log("[Tori] Background script initialized");

// Header caching with automatic cleanup
let headerCacheSize = 0;

function cacheHeaders(url, headers) {
	const key = `headers_${url}`;
	chrome.storage.session.set({
		[key]: {
			headers,
			timestamp: Date.now(),
		},
	});
	headerCacheSize++;

	// Cleanup when cache gets large
	if (headerCacheSize >= HEADER_CLEANUP_THRESHOLD) {
		cleanupHeaderCache();
	}
}

function cleanupHeaderCache() {
	chrome.storage.session.get(null, (items) => {
		const now = Date.now();
		const toRemove = [];

		for (const key of Object.keys(items)) {
			if (
				key.startsWith("headers_") &&
				now - items[key].timestamp > HEADER_CACHE_TTL
			) {
				toRemove.push(key);
			}
		}

		if (toRemove.length > 0) {
			chrome.storage.session.remove(toRemove);
			headerCacheSize = Math.max(0, headerCacheSize - toRemove.length);
		}
	});
}

// Cache request headers for potential downloads
chrome.webRequest.onBeforeSendHeaders.addListener(
	(details) => {
		const headers = {};
		for (const h of details.requestHeaders) {
			headers[h.name] = h.value;
		}
		cacheHeaders(details.url, headers);
	},
	{ urls: ["<all_urls>"], types: ["main_frame", "sub_frame", "other"] },
	["requestHeaders"],
);

/**
 * Cleanup tracked IDs to prevent unbounded memory growth
 */
function pruneTrackedIds() {
	if (trackedDownloadIds.size > MAX_TRACKED_IDS) {
		// Keep only IDs that are in currentDownloads
		const activeIds = new Set(currentDownloads.map((d) => d.id));
		trackedDownloadIds = activeIds;
	}
}

/**
 * Notify popup of state changes (with error suppression for closed popup)
 */
function notifyPopup(data) {
	chrome.runtime.sendMessage(data).catch(() => {
		// Popup is closed, ignore
	});
}

/**
 * Establishes and maintains a WebSocket connection to the Tori app.
 */
function connectWebSocket() {
	if (isConnecting || (socket && socket.readyState === WebSocket.OPEN)) {
		return;
	}

	isConnecting = true;

	// Cleanup existing socket
	if (socket) {
		socket.onopen = null;
		socket.onmessage = null;
		socket.onclose = null;
		socket.onerror = null;
		try {
			socket.close();
		} catch (e) {
			// Ignore close errors
		}
		socket = null;
	}

	console.log("[Tori] Connecting to WebSocket...");

	try {
		socket = new WebSocket(TORI_WS_URL);
	} catch (e) {
		console.error("[Tori] Failed to create WebSocket:", e);
		isConnecting = false;
		scheduleReconnect();
		return;
	}

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
				// Filter to only show new downloads (added after extension started)
				// We use a small grace period (5s) for clock differences
				const threshold = scriptStartTime - 5000;

				const filteredDownloads = data.filter(d => {
					const dateAdded = d.dateAdded || 0;
					return dateAdded >= threshold;
				});

				currentDownloads = filteredDownloads;

				notifyPopup({
					action: "downloadsUpdated",
					downloads: currentDownloads,
					connected: true,
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
		console.log(`[Tori] WebSocket closed (code: ${event.code})`);

		notifyPopup({
			action: "downloadsUpdated",
			downloads: [],
			connected: false,
		});

		scheduleReconnect();
	};

	socket.onerror = () => {
		// onclose will handle reconnection
		isConnecting = false;
	};
}

function scheduleReconnect() {
	if (!reconnectTimer) {
		reconnectTimer = setTimeout(() => {
			reconnectTimer = null;
			connectWebSocket();
		}, RECONNECT_DELAY);
	}
}

// Initial connection
connectWebSocket();

/**
 * Intercepts browser downloads and redirects them to Tori.
 */
chrome.downloads.onCreated.addListener(async (downloadItem) => {
	// Ignore old downloads (from before extension started)
	const downloadStartTime = new Date(downloadItem.startTime).getTime();
	if (downloadStartTime < scriptStartTime - 5000) {
		return;
	}

	// Only intercept HTTP/HTTPS
	if (!downloadItem.url.startsWith("http")) {
		return;
	}

	// Get settings
	const settings = await chrome.storage.local.get([
		"interceptEnabled",
		"minInterceptSize",
		"bypassPlugins",
		"savePath",
	]);

	if (settings.interceptEnabled === false) {
		return;
	}

	// Check file size threshold
	const minSizeMB = settings.minInterceptSize ?? 50;
	const minSizeBytes = minSizeMB * 1024 * 1024;

	if (
		downloadItem.fileSize > 0 &&
		downloadItem.fileSize < minSizeBytes &&
		minSizeMB > 0
	) {
		console.log(
			`[Tori] Skipping small download (${(downloadItem.fileSize / (1024 * 1024)).toFixed(1)}MB)`,
		);
		return;
	}

	console.log("[Tori] Intercepting:", downloadItem.url);

	// Get cached headers
	const key = `headers_${downloadItem.url}`;
	const storageResult = await chrome.storage.session.get([key]);
	const cached = storageResult[key] || { headers: {} };
	const headers = { ...cached.headers };

	// Add cookies
	try {
		const cookies = await chrome.cookies.getAll({ url: downloadItem.url });
		if (cookies.length > 0) {
			headers["Cookie"] = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
		}
	} catch (e) {
		// Cookie access may fail, continue without
	}

	// Ensure basic headers
	if (!headers["User-Agent"]) {
		headers["User-Agent"] = navigator.userAgent;
	}
	if (!headers["Referer"] && downloadItem.referrer) {
		headers["Referer"] = downloadItem.referrer;
	}

	// Cancel browser download
	chrome.downloads.cancel(downloadItem.id, () => {
		if (chrome.runtime.lastError) {
			console.error("[Tori] Cancel error:", chrome.runtime.lastError);
			return;
		}

		sendToTori(
			downloadItem.url,
			downloadItem.filename,
			headers,
			settings.bypassPlugins || false,
			settings.savePath || null,
		);
	});
});

/**
 * Sends download to Tori app
 */
async function sendToTori(
	url,
	fileName,
	headers,
	bypassPlugins,
	destinationPath,
) {
	try {
		const response = await fetch(`${TORI_API_URL}/add`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({
				url,
				fileName: fileName ? fileName.split(/[\\/]/).pop() : null,
				headers,
				bypassPlugins,
				destinationPath,
			}),
		});

		if (!response.ok) {
			throw new Error(`Server responded with ${response.status}`);
		}

		console.log("[Tori] Download sent successfully");
		showNotification("Tori Intercepted", `Started: ${fileName || url}`);
	} catch (error) {
		console.error("[Tori] Failed to send download:", error);
		showNotification(
			"Tori Connection Error",
			"Could not reach the Tori app. Is it running?",
			2,
		);
	}
}

function showNotification(title, message, priority = 1) {
	if (!chrome.notifications) return;

	chrome.notifications
		.create({
			type: "basic",
			iconUrl: "icons/icon128.png",
			title,
			message,
			priority,
		})
		.catch(() => {
			// Notification may fail, ignore
		});
}

/**
 * Handle messages from popup
 */
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
	if (request.action === "getDownloads") {
		sendResponse({
			success: true,
			downloads: currentDownloads,
			connected: socket && socket.readyState === WebSocket.OPEN,
		});
	}
	return true;
});
