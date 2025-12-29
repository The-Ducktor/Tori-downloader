<script lang="ts">
import { onMount } from "svelte";

interface DownloadItem {
	id: string;
	fileName: string;
	progress: number;
	status: string;
	statusText: string;
	progressText: string;
	sizeText?: string;
	totalSizeText?: string;
	speed?: string;
	timeRemaining?: string;
}

interface Settings {
	interceptEnabled: boolean;
	minInterceptSize: number;
	bypassPlugins: boolean;
	savePath: string;
}

interface PluginActionResult {
	url: string;
	fileName?: string;
	iconURL?: string;
	size?: number;
	headers?: Record<string, string>;
}

// State using Svelte 5 runes
let downloads = $state<DownloadItem[]>([]);
let isConnected = $state(false);
let settings = $state<Settings>({
	interceptEnabled: true,
	minInterceptSize: 50,
	bypassPlugins: false,
	savePath: "",
});

let activePanel = $state<"settings" | "add" | null>(null);
let addState = $state<"input" | "processing" | "selection">("input");
let manualUrls = $state("");
const addBypassPlugins = $state(false);
let discoveredFiles = $state<PluginActionResult[]>([]);
let selectedFileUrls = $state<Set<string>>(new Set());

const refreshState = async () => {
	try {
		const response = await chrome.runtime.sendMessage({
			action: "getDownloads",
		});
		if (response && response.success) {
			isConnected = response.connected;
			downloads = response.downloads || [];
		} else {
			isConnected = false;
		}
	} catch (error) {
		isConnected = false;
	}
};

onMount(() => {
	refreshState();
	const interval = setInterval(refreshState, 1000);

	const messageListener = (message: any) => {
		if (message.action === "downloadsUpdated") {
			isConnected = message.connected !== undefined ? message.connected : true;
			downloads = message.downloads || [];
		}
	};
	chrome.runtime.onMessage.addListener(messageListener);

	chrome.storage.local.get(
		["interceptEnabled", "minInterceptSize", "bypassPlugins", "savePath"],
		(result) => {
			settings = {
				interceptEnabled: result.interceptEnabled !== false,
				minInterceptSize:
					result.minInterceptSize !== undefined ? result.minInterceptSize : 50,
				bypassPlugins: result.bypassPlugins === true,
				savePath: result.savePath || "",
			};
		},
	);

	return () => {
		clearInterval(interval);
		chrome.runtime.onMessage.removeListener(messageListener);
	};
});

const togglePanel = (panel: "settings" | "add") => {
	activePanel = activePanel === panel ? null : panel;
	if (activePanel === "add") {
		addState = "input";
		checkClipboard();
	}
};

const checkClipboard = async () => {
	try {
		if (manualUrls.trim()) return;
		const text = await navigator.clipboard.readText();
		if (text) {
			const lines = text
				.split(/\s+/)
				.filter((l) => l.startsWith("http://") || l.startsWith("https://"));
			if (lines.length > 0) {
				manualUrls = lines.join("\n");
			}
		}
	} catch (err) {
		// Clipboard access might be denied
	}
};

const updateSetting = (key: keyof Settings, value: any) => {
	settings = { ...settings, [key]: value };
	chrome.storage.local.set({ [key]: value });
};

const formatBytes = (bytes: number) => {
	if (!bytes || bytes === 0) return "";
	const k = 1024;
	const sizes = ["B", "KB", "MB", "GB", "TB"];
	const i = Math.floor(Math.log(bytes) / Math.log(k));
	return parseFloat((bytes / k ** i).toFixed(1)) + " " + sizes[i];
};

const handleManualAdd = async () => {
	const urls = manualUrls
		.split("\n")
		.map((u) => u.trim())
		.filter((u) => u.length > 0);
	if (urls.length === 0) return;

	if (addBypassPlugins) {
		let successCount = 0;
		for (const url of urls) {
			try {
				const response = await fetch("http://localhost:18121/add", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({
						url: url,
						destinationPath: settings.savePath || null,
						bypassPlugins: true,
					}),
				});
				if (response.ok) successCount++;
			} catch (err) {
				console.error("Failed to add download:", err);
			}
		}
		if (successCount > 0) {
			manualUrls = "";
			activePanel = null;
		}
		return;
	}

	addState = "processing";
	let allResults: PluginActionResult[] = [];

	for (const url of urls) {
		try {
			const response = await fetch("http://localhost:18121/resolve", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ url }),
			});
			if (response.ok) {
				const data = await response.json();
				if (data.results) {
					allResults = [...allResults, ...data.results];
				}
			}
		} catch (err) {
			console.error("Failed to resolve URL:", err);
		}
	}

	if (allResults.length > 1) {
		discoveredFiles = allResults;
		selectedFileUrls = new Set(allResults.map((r) => r.url));
		addState = "selection";
	} else if (allResults.length === 1) {
		const res = allResults[0];
		try {
			await fetch("http://localhost:18121/add", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					url: res.url,
					fileName: res.fileName,
					headers: res.headers,
					destinationPath: settings.savePath || null,
					bypassPlugins: true,
				}),
			});
			manualUrls = "";
			activePanel = null;
		} catch (err) {
			addState = "input";
		}
	} else {
		addState = "input";
	}
};

const handleAddSelected = async () => {
	let successCount = 0;
	for (const file of discoveredFiles) {
		if (selectedFileUrls.has(file.url)) {
			try {
				const response = await fetch("http://localhost:18121/add", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({
						url: file.url,
						fileName: file.fileName,
						headers: file.headers,
						destinationPath: settings.savePath || null,
						bypassPlugins: true,
					}),
				});
				if (response.ok) successCount++;
			} catch (err) {
				console.error("Failed to add selected file:", err);
			}
		}
	}
	if (successCount > 0) {
		manualUrls = "";
		activePanel = null;
		addState = "input";
	}
};

const toggleFileSelection = (url: string) => {
	const newSet = new Set(selectedFileUrls);
	if (newSet.has(url)) {
		newSet.delete(url);
	} else {
		newSet.add(url);
	}
	selectedFileUrls = newSet;
};

const handleAction = async (id: string, endpoint: string) => {
	try {
		await fetch(`http://localhost:18121${endpoint}`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ id }),
		});
	} catch (err) {
		console.error(`Failed to ${endpoint}:`, err);
	}
};
</script>

<div class="header">
    <h1>Tori</h1>
    <div class="header-actions">
        <div class="connection-status">
            <span class="status-dot" class:online={isConnected}></span>
            <span>{isConnected ? "Online" : "Offline"}</span>
        </div>
        <button
            class="icon-btn"
            onclick={() => togglePanel("add")}
            title="Add Download"
        >
            <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
            >
                <line x1="12" y1="5" x2="12" y2="19"></line>
                <line x1="5" y1="12" x2="19" y2="12"></line>
            </svg>
        </button>
        <button
            class="icon-btn"
            onclick={() => togglePanel("settings")}
            title="Settings"
        >
            <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
            >
                <circle cx="12" cy="12" r="3"></circle>
                <path
                    d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"
                ></path>
            </svg>
        </button>
    </div>
</div>

<div class="panel" class:open={activePanel === "add"}>
    <div class="panel-content">
        {#if addState === "input"}
            <div class="flex flex-col gap-2">
                <div class="flex justify-between items-center">
                    <span class="font-semibold text-[11px] text-text-primary"
                        >URLs (one per line)</span
                    >
                    {#if manualUrls.trim()}
                        <span class="text-[10px] opacity-60">
                            {manualUrls.split("\n").filter((u) => u.trim())
                                .length} detected
                        </span>
                    {/if}
                </div>
                <textarea
                    class="input-field h-24 resize-none p-2 font-mono text-[11px] leading-relaxed"
                    placeholder="https://example.com/file.zip&#10;https://another.com/video.mp4"
                    bind:value={manualUrls}
                    onkeydown={(e) =>
                        e.key === "Enter" &&
                        (e.metaKey || e.ctrlKey) &&
                        handleManualAdd()}
                ></textarea>
            </div>
            <div class="row mt-1">
                <div class="flex items-center gap-2 cursor-pointer select-none">
                    <label class="switch">
                        <input
                            type="checkbox"
                            bind:checked={addBypassPlugins}
                        />
                        <span class="slider"></span>
                    </label>
                    <span class="text-[11px]">Bypass Plugins</span>
                </div>
                <button
                    class="btn-primary"
                    onclick={handleManualAdd}
                    disabled={!manualUrls.trim()}
                >
                    Add Downloads
                </button>
            </div>
        {:else if addState === "processing"}
            <div class="flex flex-col items-center py-8 gap-3">
                <div class="status-dot online w-3 h-3 animate-pulse"></div>
                <span class="text-xs font-medium text-text-primary"
                    >Resolving links...</span
                >
            </div>
        {:else if addState === "selection"}
            <div class="flex flex-col gap-2">
                <div class="flex justify-between items-center">
                    <div class="flex items-center gap-2">
                        <button
                            class="icon-btn p-1"
                            onclick={() => (addState = "input")}
                            title="Back"
                        >
                            <svg
                                width="14"
                                height="14"
                                viewBox="0 0 24 24"
                                fill="none"
                                stroke="currentColor"
                                stroke-width="2.5"
                                stroke-linecap="round"
                                stroke-linejoin="round"
                            >
                                <line x1="19" y1="12" x2="5" y2="12"></line>
                                <polyline points="12 19 5 12 12 5"></polyline>
                            </svg>
                        </button>
                        <span
                            class="font-semibold text-[11px] text-text-primary"
                        >
                            Select Files ({discoveredFiles.length})
                        </span>
                    </div>
                    <div class="flex gap-1">
                        <button
                            class="text-[9px] px-2 py-0.5 bg-white/5 hover:bg-white/10 rounded border border-border transition-colors"
                            onclick={() =>
                                (selectedFileUrls = new Set(
                                    discoveredFiles.map((f) => f.url),
                                ))}
                        >
                            All
                        </button>
                        <button
                            class="text-[9px] px-2 py-0.5 bg-white/5 hover:bg-white/10 rounded border border-border transition-colors"
                            onclick={() => (selectedFileUrls = new Set())}
                        >
                            None
                        </button>
                    </div>
                </div>
                <div
                    class="max-h-[140px] overflow-y-auto flex flex-col gap-1 border border-border rounded-md p-1 bg-bg/50"
                >
                    {#each discoveredFiles as file}
                        <div
                            class="flex items-start gap-2 p-2 bg-white/[0.02] hover:bg-white/[0.05] rounded transition-colors cursor-pointer"
                            onclick={() => toggleFileSelection(file.url)}
                            role="button"
                            tabindex="0"
                            onkeydown={(e) =>
                                e.key === "Enter" &&
                                toggleFileSelection(file.url)}
                        >
                            <input
                                type="checkbox"
                                class="mt-0.5"
                                checked={selectedFileUrls.has(file.url)}
                                onclick={(e) => e.stopPropagation()}
                                onchange={() => toggleFileSelection(file.url)}
                            />
                            <div class="flex flex-col overflow-hidden flex-1">
                                <div
                                    class="flex justify-between items-center gap-2"
                                >
                                    <span
                                        class="text-[11px] truncate text-text-primary font-medium"
                                    >
                                        {file.fileName ||
                                            file.url.split("/").pop()}
                                    </span>
                                    {#if file.size}
                                        <span
                                            class="text-[9px] opacity-60 shrink-0 tabular-nums"
                                        >
                                            {formatBytes(file.size)}
                                        </span>
                                    {/if}
                                </div>
                                <span
                                    class="text-[9px] truncate opacity-40 font-mono"
                                >
                                    {file.url}
                                </span>
                            </div>
                        </div>
                    {/each}
                </div>
                <div class="row mt-1">
                    <span class="text-[10px] opacity-60"
                        >{selectedFileUrls.size} selected</span
                    >
                    <button
                        class="btn-primary"
                        onclick={handleAddSelected}
                        disabled={selectedFileUrls.size === 0}
                    >
                        Add Selected
                    </button>
                </div>
            </div>
        {/if}
    </div>
</div>

<div class="panel" class:open={activePanel === "settings"}>
    <div class="panel-content">
        <div class="row">
            <span class="text-text-primary">Intercept Downloads</span>
            <label class="switch">
                <input
                    type="checkbox"
                    checked={settings.interceptEnabled}
                    onchange={(e) =>
                        updateSetting(
                            "interceptEnabled",
                            e.currentTarget.checked,
                        )}
                />
                <span class="slider"></span>
            </label>
        </div>
        <div class="row">
            <span class="text-text-primary">Min Intercept Size (MB)</span>
            <input
                type="number"
                class="input-field w-[64px] text-center"
                value={settings.minInterceptSize}
                oninput={(e) =>
                    updateSetting(
                        "minInterceptSize",
                        parseInt(e.currentTarget.value, 10) || 0,
                    )}
                min="0"
            />
        </div>
        <div class="row">
            <span class="text-text-primary">Bypass Plugins</span>
            <label class="switch">
                <input
                    type="checkbox"
                    checked={settings.bypassPlugins}
                    onchange={(e) =>
                        updateSetting("bypassPlugins", e.currentTarget.checked)}
                />
                <span class="slider"></span>
            </label>
        </div>
        <div class="flex flex-col gap-1.5">
            <span class="text-text-primary">Default Save Path</span>
            <input
                type="text"
                class="input-field"
                placeholder="/Users/name/Downloads"
                value={settings.savePath}
                oninput={(e) =>
                    updateSetting("savePath", e.currentTarget.value)}
            />
        </div>
    </div>
</div>

<div class="download-list">
    {#if downloads.length > 0}
        {#each downloads as item (item.id)}
            <div class="download-item group">
                <div class="file-name" title={item.fileName}>
                    {item.fileName}
                </div>
                <div class="progress-container bg-border/30">
                    <div
                        class="progress-bar shadow-[0_0_8px_rgba(10,132,255,0.3)]"
                        style:width="{(item.progress * 100).toFixed(1)}%"
                    ></div>
                </div>
                <div class="meta-info">
                    <span class="font-medium">{item.statusText}</span>
                    <span class="opacity-80">
                        {item.progressText}
                        {#if (item.status === "downloading" || item.status === "paused") && item.sizeText}
                            • {item.sizeText}
                        {/if}
                        {#if item.status !== "downloading" && item.status !== "paused" && item.totalSizeText}
                            • {item.totalSizeText}
                        {/if}
                    </span>
                </div>
                {#if item.status === "downloading"}
                    <div class="meta-info mt-1 opacity-50 font-mono">
                        <span>{item.speed}</span>
                        <span>{item.timeRemaining} left</span>
                    </div>
                {/if}
                <div
                    class="item-actions opacity-0 group-hover:opacity-100 transition-opacity duration-200"
                >
                    {#if item.status === "downloading" || item.status === "processing"}
                        <button
                            class="action-btn"
                            title="Pause"
                            onclick={() => handleAction(item.id, "/pause")}
                        >
                            <svg
                                width="12"
                                height="12"
                                viewBox="0 0 24 24"
                                fill="currentColor"
                            >
                                <rect x="6" y="4" width="4" height="16"></rect>
                                <rect x="14" y="4" width="4" height="16"></rect>
                            </svg>
                        </button>
                    {/if}
                    {#if item.status === "paused"}
                        <button
                            class="action-btn"
                            title="Resume"
                            onclick={() => handleAction(item.id, "/resume")}
                        >
                            <svg
                                width="12"
                                height="12"
                                viewBox="0 0 24 24"
                                fill="currentColor"
                            >
                                <polygon points="5 3 19 12 5 21 5 3"></polygon>
                            </svg>
                        </button>
                    {/if}
                    {#if !["completed", "failed", "canceled"].includes(item.status)}
                        <button
                            class="action-btn"
                            title="Cancel"
                            onclick={() => handleAction(item.id, "/cancel")}
                        >
                            <svg
                                width="12"
                                height="12"
                                viewBox="0 0 24 24"
                                fill="none"
                                stroke="currentColor"
                                stroke-width="3"
                                stroke-linecap="round"
                                stroke-linejoin="round"
                            >
                                <line x1="18" y1="6" x2="6" y2="18"></line>
                                <line x1="6" y1="6" x2="18" y2="18"></line>
                            </svg>
                        </button>
                    {/if}
                    <button
                        class="action-btn danger"
                        title="Remove"
                        onclick={() => handleAction(item.id, "/remove")}
                    >
                        <svg
                            width="12"
                            height="12"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="2.5"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                        >
                            <polyline points="3 6 5 6 21 6"></polyline>
                            <path
                                d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"
                            ></path>
                        </svg>
                    </button>
                </div>
            </div>
        {/each}
    {:else}
        <div class="empty-state">
            <div class="empty-icon grayscale opacity-50">🐦</div>
            <p class="font-medium">
                {isConnected ? "No active downloads" : "Connecting to Tori..."}
            </p>
        </div>
    {/if}
</div>

<div class="footer">Tori v1.0 ex ver 0.1</div>
