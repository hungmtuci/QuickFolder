import Foundation
import AppKit
import ApplicationServices
import Combine

@MainActor
final class FolderManager: ObservableObject {
    static let shared = FolderManager()

    @Published private(set) var openFinderFolders: [FolderItem] = []
    @Published private(set) var recentFolders: [FolderItem] = []
    @Published private(set) var pinnedPaths: [String] = []
    @Published private(set) var finderAutomationStatus: PermissionStatus = .unknown

    enum PermissionStatus: Equatable {
        case unknown
        case granted
        case denied(String)
    }

    private let recentsKey = "QuickFolder.StoredRecents.v1"
    private let pinnedKey = "QuickFolder.PinnedFolders.v1"
    private let maxRecentCount = 25
    private var storedRecents: [StoredRecentFolder] = []
    private var pollTimer: Timer?
    private var isRefreshingFinder = false

    private init() {
        loadPersistedData()
        importFinderRecentBookmarks()
        rebuildPublishedLists(openPaths: [])
        startMonitoring()
    }

    func startMonitoring() {
        refreshNow()
        pollTimer?.invalidate()
        // Only poll Finder when the floating panel is actually visible on screen
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard FloatingPanelController.shared.isPanelVisible else { return }
                self?.refreshNow()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == "com.apple.finder" {
                Task { @MainActor in
                    self?.refreshNow()
                }
            }
        }
    }

    func refreshNow() {
        guard !isRefreshingFinder else { return }
        isRefreshingFinder = true
        let knownPaths = storedRecents.map(\.path) + pinnedPaths

        Task.detached(priority: .userInitiated) {
            let result = Self.fetchOpenFinderWindowPaths(knownRecentPaths: knownPaths)
            await MainActor.run {
                self.isRefreshingFinder = false
                switch result {
                case .success(let paths):
                    self.finderAutomationStatus = .granted
                    self.recordSeenPaths(paths)
                    self.rebuildPublishedLists(openPaths: paths)
                case .failure(let err):
                    self.finderAutomationStatus = .denied(err.message)
                    self.rebuildPublishedLists(openPaths: [])
                }
            }
        }
    }

    func recordFolderUsed(_ path: String) {
        let std = FolderItem.standardizePath(path)
        guard isDirectoryExists(std) else { return }
        let now = Date()
        if let idx = storedRecents.firstIndex(where: { $0.path == std }) {
            storedRecents[idx].lastUsed = now
        } else {
            storedRecents.insert(StoredRecentFolder(path: std, lastUsed: now), at: 0)
        }
        sortAndTrimRecents()
        savePersistedData()
        let currentOpenPaths = openFinderFolders.map(\.path)
        rebuildPublishedLists(openPaths: currentOpenPaths)
    }

    func isPinned(_ path: String) -> Bool {
        let std = FolderItem.standardizePath(path)
        return pinnedPaths.contains(std)
    }

    func togglePin(_ path: String) {
        let std = FolderItem.standardizePath(path)
        if let idx = pinnedPaths.firstIndex(of: std) {
            pinnedPaths.remove(at: idx)
        } else {
            pinnedPaths.insert(std, at: 0)
        }
        UserDefaults.standard.set(pinnedPaths, forKey: pinnedKey)
        let currentOpenPaths = openFinderFolders.map(\.path)
        rebuildPublishedLists(openPaths: currentOpenPaths)
    }

    func clearRecentHistory() {
        storedRecents.removeAll()
        UserDefaults.standard.removeObject(forKey: recentsKey)
        let currentOpenPaths = openFinderFolders.map(\.path)
        rebuildPublishedLists(openPaths: currentOpenPaths)
    }

    /// Returns a combined ordered list for quick keyboard shortcuts (Opt+1 .. Opt+9)
    func allQuickAccessFolders(searchQuery: String = "") -> [FolderItem] {
        let openList = filtered(openFinderFolders, query: searchQuery)
        let recentList = filtered(recentFolders, query: searchQuery)
        return openList + recentList
    }

    func filtered(_ items: [FolderItem], query: String) -> [FolderItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.name.lowercased().contains(trimmed) ||
            $0.displayPath.lowercased().contains(trimmed)
        }
    }

    // MARK: - Private Helpers

    private func recordSeenPaths(_ paths: [String]) {
        var changed = false
        let now = Date()
        for raw in paths.reversed() {
            let std = FolderItem.standardizePath(raw)
            guard isDirectoryExists(std) else { continue }
            if let idx = storedRecents.firstIndex(where: { $0.path == std }) {
                // Update timestamp if older than 30 seconds
                if now.timeIntervalSince(storedRecents[idx].lastUsed) > 30 {
                    storedRecents[idx].lastUsed = now
                    changed = true
                }
            } else {
                storedRecents.insert(StoredRecentFolder(path: std, lastUsed: now), at: 0)
                changed = true
            }
        }
        if changed {
            sortAndTrimRecents()
            savePersistedData()
        }
    }

    private func rebuildPublishedLists(openPaths: [String]) {
        // 1. Deduplicate open Finder windows while preserving front-to-back window order
        var seenOpen = Set<String>()
        var openItems: [FolderItem] = []
        for rawPath in openPaths {
            let std = FolderItem.standardizePath(rawPath)
            guard isDirectoryExists(std), !seenOpen.contains(std) else { continue }
            seenOpen.insert(std)
            openItems.append(
                FolderItem(
                    path: std,
                    source: .openFinderWindow(windowIndex: openItems.count + 1)
                )
            )
        }
        self.openFinderFolders = openItems

        // 2. Build Recent + Pinned list (excluding paths already open in Finder so there is no duplication)
        var recents: [FolderItem] = []
        var seenRecent = seenOpen

        for pinned in pinnedPaths {
            let std = FolderItem.standardizePath(pinned)
            guard isDirectoryExists(std), !seenRecent.contains(std) else { continue }
            seenRecent.insert(std)
            recents.append(FolderItem(path: std, source: .pinned))
        }

        for item in storedRecents {
            let std = FolderItem.standardizePath(item.path)
            guard isDirectoryExists(std), !seenRecent.contains(std) else { continue }
            seenRecent.insert(std)
            recents.append(FolderItem(path: std, source: .recent, lastUsed: item.lastUsed))
        }

        self.recentFolders = recents
    }

    private func loadPersistedData() {
        if let pinned = UserDefaults.standard.stringArray(forKey: pinnedKey) {
            self.pinnedPaths = pinned.map { FolderItem.standardizePath($0) }
        }
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let decoded = try? JSONDecoder().decode([StoredRecentFolder].self, from: data) {
            self.storedRecents = decoded.filter { isDirectoryExists($0.path) }
        }
    }

    private func savePersistedData() {
        if let data = try? JSONEncoder().encode(storedRecents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    private func sortAndTrimRecents() {
        storedRecents.sort { $0.lastUsed > $1.lastUsed }
        if storedRecents.count > maxRecentCount {
            storedRecents = Array(storedRecents.prefix(maxRecentCount))
        }
    }

    /// Reads macOS Finder's FXRecentFolders bookmark list so the user immediately has their recent folders on first launch.
    func importFinderRecentBookmarks() {
        let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
        if let rawEntries = finderDefaults?.array(forKey: "FXRecentFolders") as? [[String: Any]] {
            var importedCount = 0
            for (index, entry) in rawEntries.enumerated() {
                guard let bookmarkData = entry["file-bookmark"] as? Data else { continue }
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    let std = FolderItem.standardizePath(url.path)
                    guard isDirectoryExists(std) else { continue }
                    if !storedRecents.contains(where: { $0.path == std }) {
                        // Preserve relative order from Finder's list
                        let syntheticDate = Date().addingTimeInterval(-Double(index * 60))
                        storedRecents.append(StoredRecentFolder(path: std, lastUsed: syntheticDate))
                        importedCount += 1
                    }
                }
            }
            if importedCount > 0 {
                sortAndTrimRecents()
            }
        }

        // Also ensure common user folders exist as fallback if recents are sparse
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents"
        ]
        for (idx, path) in defaults.enumerated() {
            let std = FolderItem.standardizePath(path)
            if isDirectoryExists(std) && !storedRecents.contains(where: { $0.path == std }) {
                storedRecents.append(
                    StoredRecentFolder(
                        path: std,
                        lastUsed: Date().addingTimeInterval(-Double(86400 + idx * 60))
                    )
                )
            }
        }
        sortAndTrimRecents()
        savePersistedData()
    }

    private func isDirectoryExists(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix(".cannedsearch") ||
           lower.hasSuffix(".savedsearch") ||
           lower.hasSuffix(".app") ||
           lower.hasPrefix("/system/library/") {
            return false
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - Finder Window Query (Accessibility + AppleScript)

    struct FinderQueryError: Error {
        let message: String
    }

    nonisolated private static func fetchOpenFinderWindowPaths(knownRecentPaths: [String]) -> Result<[String], FinderQueryError> {
        // 1. Try Accessibility API on Finder first (fast, no -1743 AppleEvents prompt required)
        if AXIsProcessTrusted(),
           let axPaths = fetchFinderPathsViaAX(knownRecentPaths: knownRecentPaths) {
            return .success(axPaths)
        }

        // 2. Fallback to AppleScript via osascript
        let scriptSource = """
        tell application "Finder"
            if not running then return ""
            set outputText to ""
            repeat with w in Finder windows
                try
                    set p to POSIX path of (target of w as alias)
                    if outputText is "" then
                        set outputText to p
                    else
                        set outputText to outputText & linefeed & p
                    end if
                end try
            end repeat
            return outputText
        end tell
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", scriptSource]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return .failure(FinderQueryError(message: error.localizedDescription))
        }

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Lỗi osascript"
            if errStr.contains("-1743") {
                return .failure(FinderQueryError(message: "Chưa cấp quyền điều khiển Finder (Automation)"))
            }
            return .failure(FinderQueryError(message: errStr))
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let paths = outStr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return .success(paths)
    }

    nonisolated private static func fetchFinderPathsViaAX(knownRecentPaths: [String]) -> [String]? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return []
        }
        let axFinder = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(axFinder, 0.05)

        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axFinder, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else {
            return nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standardMap: [String: String] = [
            "desktop": "\(home)/Desktop",
            "documents": "\(home)/Documents",
            "downloads": "\(home)/Downloads",
            "applications": "/Applications",
            "pictures": "\(home)/Pictures",
            "music": "\(home)/Music",
            "movies": "\(home)/Movies",
            URL(fileURLWithPath: home).lastPathComponent.lowercased(): home
        ]

        var results: [String] = []
        for win in wins {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == "AXWindow" else { continue }

            // Check AXDocument or AXProxy URL first
            var docRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docRef) == .success,
               let docStr = docRef as? String,
               let url = URL(string: docStr), url.isFileURL {
                results.append(url.path)
                continue
            }

            var proxyRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXProxyAttribute as CFString, &proxyRef) == .success,
               let proxy = proxyRef {
                let proxyEl = proxy as! AXUIElement
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(proxyEl, kAXURLAttribute as CFString, &urlRef) == .success {
                    if let url = urlRef as? URL, url.isFileURL {
                        results.append(url.path)
                        continue
                    } else if let urlStr = urlRef as? String, let url = URL(string: urlStr), url.isFileURL {
                        results.append(url.path)
                        continue
                    }
                }
            }

            // Fallback: match window title against standard folders or known recent folders
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               title.lowercased() != "recents" {
                if let stdPath = standardMap[title.lowercased()] {
                    results.append(stdPath)
                } else if let matched = knownRecentPaths.first(where: { URL(fileURLWithPath: $0).lastPathComponent == title }) {
                    results.append(matched)
                }
            }
        }
        return results
    }
}
