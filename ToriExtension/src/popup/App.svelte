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
    let addBypassPlugins = $state(false);
    let discoveredFiles = $state<PluginActionResult[]>([]);
    let selectedFileUrls = $state<Set<string>>(new Set());
    let showAllDownloads = $state(false);

    const activeDownloads = $derived(
        downloads.filter(
            (d) =>
                d.status === "downloading" ||
                d.status === "processing" ||
                d.status === "paused",
        ),
    );

    const displayedDownloads = $derived(
        showAllDownloads ? downloads : activeDownloads,
    );

    // Avoid unnecessary array allocations
    const emptyArray: DownloadItem[] = [];

    const refreshState = async () => {
        try {
            const response = await chrome.runtime.sendMessage({
                action: "getDownloads",
            });
            if (response?.success) {
                isConnected = response.connected ?? false;
                // Only update if data actually changed
                const newDownloads = response.downloads || emptyArray;
                if (
                    JSON.stringify(newDownloads) !== JSON.stringify(downloads)
                ) {
                    downloads = newDownloads;
                }
            } else {
                isConnected = false;
            }
        } catch {
            isConnected = false;
        }
    };

    onMount(() => {
        refreshState();
        // Reduced polling interval - WebSocket handles real-time updates
        const interval = setInterval(refreshState, 2000);

        const messageListener = (message: {
            action: string;
            connected?: boolean;
            downloads?: DownloadItem[];
        }) => {
            if (message.action === "downloadsUpdated") {
                isConnected = message.connected ?? true;
                downloads = message.downloads || emptyArray;
            }
        };
        chrome.runtime.onMessage.addListener(messageListener);

        chrome.storage.local.get(
            [
                "interceptEnabled",
                "minInterceptSize",
                "bypassPlugins",
                "savePath",
            ],
            (result) => {
                settings = {
                    interceptEnabled: result.interceptEnabled !== false,
                    minInterceptSize:
                        result.minInterceptSize !== undefined
                            ? result.minInterceptSize
                            : 50,
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
                    .filter(
                        (l) =>
                            l.startsWith("http://") || l.startsWith("https://"),
                    );
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

    // Pre-compute constants for formatBytes
    const BYTE_UNITS = ["B", "KB", "MB", "GB", "TB"] as const;
    const LOG_1024 = Math.log(1024);

    const formatBytes = (bytes: number): string => {
        if (!bytes) return "";
        const i = Math.floor(Math.log(bytes) / LOG_1024);
        return `${(bytes / 1024 ** i).toFixed(1)} ${BYTE_UNITS[i]}`;
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

    const clearCompleted = async () => {
        const completedIds = downloads
            .filter((d) => d.status === "completed")
            .map((d) => d.id);
        for (const id of completedIds) {
            await handleAction(id, "/remove");
        }
    };
</script>

<!-- Toolbar -->
<div class="toolbar">
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

    {#if activeDownloads.length > 0}
        <span class="active-badge">{activeDownloads.length} active</span>
    {/if}

    <div
        class="status-indicator"
        class:online={isConnected}
        title={isConnected ? "Connected" : "Disconnected"}
    ></div>

    <div class="spacer"></div>

    <div class="toggle-group">
        <button
            class="toggle-btn"
            class:active={!showAllDownloads}
            onclick={() => (showAllDownloads = false)}
        >
            Active
        </button>
        <button
            class="toggle-btn"
            class:active={showAllDownloads}
            onclick={() => (showAllDownloads = true)}
        >
            All
        </button>
    </div>
</div>

<!-- Add Panel -->
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
                    Add
                </button>
            </div>
        {:else if addState === "processing"}
            <div class="flex flex-col items-center py-6 gap-3">
                <div
                    class="status-indicator online w-3 h-3 animate-pulse"
                ></div>
                <span class="text-xs font-medium text-text-primary"
                    >Resolving...</span
                >
            </div>
        {:else if addState === "selection"}
            <div class="flex flex-col gap-2">
                <div class="flex justify-between items-center">
                    <div class="flex items-center gap-2">
                        <button
                            class="icon-btn small"
                            onclick={() => (addState = "input")}
                            title="Back"
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
                            class="mini-btn"
                            onclick={() =>
                                (selectedFileUrls = new Set(
                                    discoveredFiles.map((f) => f.url),
                                ))}
                        >
                            All
                        </button>
                        <button
                            class="mini-btn"
                            onclick={() => (selectedFileUrls = new Set())}
                        >
                            None
                        </button>
                    </div>
                </div>
                <div class="file-selection-list">
                    {#each discoveredFiles as file}
                        <div
                            class="file-selection-item"
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

<!-- Settings Panel -->
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
            <span class="text-text-primary">Min Size (MB)</span>
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
            <span class="text-text-primary">Save Path</span>
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

<!-- Download List -->
<div class="download-list">
    {#if displayedDownloads.length > 0}
        {#each displayedDownloads.toReversed() as item (item.id)}
            <div
                class="download-item group"
                class:completed={item.status === "completed"}
            >
                <div class="file-name" title={item.fileName}>
                    {item.fileName}
                </div>
                <div class="progress-container">
                    <div
                        class="progress-bar"
                        style:width="{(item.progress * 100).toFixed(1)}%"
                    ></div>
                </div>
                <div class="meta-info">
                    <span class="font-medium">{item.statusText}</span>
                    <span class="opacity-80 tabular-nums">
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
                    <div class="meta-info mt-1 opacity-50 tabular-nums">
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
            <div class="empty-icon">🐦</div>
            <p>{showAllDownloads ? "No downloads" : "No active downloads"}</p>
        </div>
    {/if}
</div>

<!-- Footer -->
<div class="footer">
    <button
        class="footer-btn"
        onclick={() => togglePanel("settings")}
        title="Settings"
    >
        <svg
            width="13"
            height="13"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
        >
            <circle cx="12" cy="12" r="3"></circle>
            <path
                d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"
            ></path>
        </svg>
    </button>

    {#if downloads.some((d) => d.status === "completed")}
        <button
            class="footer-btn"
            onclick={clearCompleted}
            title="Clear Completed"
        >
            <svg
                width="13"
                height="13"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
            >
                <polyline points="3 6 5 6 21 6"></polyline>
                <path
                    d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"
                ></path>
            </svg>
        </button>
    {/if}

    <div class="spacer"></div>

    <span class="footer-version">Tori</span>
</div>

<style>
    .toolbar {
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 8px 12px;
        background: var(--color-bg);
        border-bottom: 1px solid var(--color-border-subtle);
    }

    .icon-btn {
        display: flex;
        align-items: center;
        justify-content: center;
        width: 28px;
        height: 28px;
        background: transparent;
        border: none;
        cursor: pointer;
        color: var(--color-text-secondary);
        border-radius: 6px;
        transition: var(--transition-fast);
    }

    .icon-btn:hover {
        color: var(--color-text-primary);
        background: rgba(255, 255, 255, 0.08);
    }

    .icon-btn.small {
        width: 24px;
        height: 24px;
    }

    .active-badge {
        font-size: 10px;
        font-weight: 600;
        color: var(--color-accent);
        background: rgba(10, 132, 255, 0.15);
        padding: 2px 8px;
        border-radius: 10px;
    }

    .status-indicator {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        background: var(--color-error);
        transition: var(--transition-smooth);
    }

    .status-indicator.online {
        background: var(--color-success);
        box-shadow: 0 0 8px rgba(52, 199, 89, 0.5);
    }

    .spacer {
        flex: 1;
    }

    .toggle-group {
        display: flex;
        background: var(--color-border-subtle);
        border-radius: 6px;
        padding: 2px;
    }

    .toggle-btn {
        font-size: 10px;
        font-weight: 500;
        padding: 4px 10px;
        border: none;
        background: transparent;
        color: var(--color-text-secondary);
        cursor: pointer;
        border-radius: 4px;
        transition: var(--transition-fast);
    }

    .toggle-btn.active {
        background: var(--color-card-bg);
        color: var(--color-text-primary);
    }

    .toggle-btn:hover:not(.active) {
        color: var(--color-text-primary);
    }

    .panel {
        max-height: 0;
        overflow: hidden;
        background: var(--color-card-bg);
        border-bottom: 1px solid var(--color-border-subtle);
        transition:
            max-height 0.3s ease-out,
            opacity 0.3s ease-out;
        opacity: 0;
    }

    .panel.open {
        max-height: 280px;
        opacity: 1;
    }

    .panel-content {
        padding: 12px;
        display: flex;
        flex-direction: column;
        gap: 12px;
        font-size: 12px;
        color: var(--color-text-secondary);
    }

    .row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
    }

    .mini-btn {
        font-size: 9px;
        padding: 2px 8px;
        background: rgba(255, 255, 255, 0.05);
        border: 1px solid var(--color-border);
        border-radius: 4px;
        color: var(--color-text-secondary);
        cursor: pointer;
        transition: var(--transition-fast);
    }

    .mini-btn:hover {
        background: rgba(255, 255, 255, 0.1);
    }

    .file-selection-list {
        max-height: 120px;
        overflow-y: auto;
        display: flex;
        flex-direction: column;
        gap: 4px;
        border: 1px solid var(--color-border);
        border-radius: 6px;
        padding: 4px;
        background: rgba(0, 0, 0, 0.2);
    }

    .file-selection-item {
        display: flex;
        align-items: flex-start;
        gap: 8px;
        padding: 8px;
        background: rgba(255, 255, 255, 0.02);
        border-radius: 4px;
        cursor: pointer;
        transition: var(--transition-fast);
    }

    .file-selection-item:hover {
        background: rgba(255, 255, 255, 0.05);
    }

    .download-list {
        flex: 1;
        max-height: 380px;
        overflow-y: auto;
        padding: 8px;
        display: flex;
        flex-direction: column;
        gap: 8px;
    }

    .download-item {
        background: rgba(255, 255, 255, 0.04);
        border-radius: 10px;
        padding: 12px;
        border: 1px solid rgba(66, 66, 69, 0.5);
        transition: var(--transition-smooth);
    }

    .download-item:hover {
        background: rgba(255, 255, 255, 0.06);
        border-color: var(--color-border-subtle);
    }

    .download-item.completed {
        opacity: 0.6;
    }

    .file-name {
        font-size: 12px;
        font-weight: 600;
        color: var(--color-text-primary);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
        margin-bottom: 8px;
    }

    .progress-container {
        height: 4px;
        background: rgba(66, 66, 69, 0.3);
        border-radius: 2px;
        overflow: hidden;
        margin-bottom: 8px;
    }

    .progress-bar {
        height: 100%;
        background: linear-gradient(
            to right,
            var(--color-accent),
            rgba(10, 132, 255, 0.8)
        );
        border-radius: 2px;
        transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1);
    }

    .meta-info {
        display: flex;
        justify-content: space-between;
        font-size: 10px;
        color: rgba(161, 161, 166, 0.8);
    }

    .item-actions {
        display: flex;
        gap: 8px;
        margin-top: 10px;
        padding-top: 8px;
        border-top: 1px solid rgba(255, 255, 255, 0.05);
    }

    .action-btn {
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 6px;
        background: transparent;
        border: none;
        cursor: pointer;
        color: var(--color-text-secondary);
        border-radius: 6px;
        transition: var(--transition-smooth);
    }

    .action-btn:hover {
        color: var(--color-text-primary);
        background: rgba(255, 255, 255, 0.1);
    }

    .action-btn.danger:hover {
        color: var(--color-error);
        background: rgba(255, 59, 48, 0.15);
    }

    .empty-state {
        padding: 48px 20px;
        text-align: center;
        color: rgba(161, 161, 166, 0.6);
    }

    .empty-icon {
        font-size: 32px;
        margin-bottom: 8px;
        opacity: 0.4;
        filter: grayscale(1);
    }

    .empty-state p {
        margin: 0;
        font-size: 12px;
        font-weight: 500;
    }

    .footer {
        display: flex;
        align-items: center;
        gap: 12px;
        padding: 8px 12px;
        border-top: 1px solid var(--color-border-subtle);
        background: var(--color-bg);
    }

    .footer-btn {
        display: flex;
        align-items: center;
        justify-content: center;
        width: 26px;
        height: 26px;
        background: transparent;
        border: none;
        cursor: pointer;
        color: var(--color-text-secondary);
        border-radius: 6px;
        transition: var(--transition-fast);
    }

    .footer-btn:hover {
        color: var(--color-text-primary);
        background: rgba(255, 255, 255, 0.08);
    }

    .footer-version {
        font-size: 11px;
        color: rgba(161, 161, 166, 0.4);
    }
</style>
