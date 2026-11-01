import Foundation
import AppKit
import ApplicationServices
import Combine

struct OpenFinderWindowInfo: Equatable, Sendable {
    let path: String
    let cocoaFrame: NSRect?
}

@MainActor
final class FolderManager: ObservableObject {
    static let shared = FolderManager()

    @Published var openFinderFolders: [FolderItem] = []
    @Published var openFinderWindowInfos: [OpenFinderWindowInfo] = []
    @Published var recentFolders: [FolderItem] = []
    @Published var pinnedPaths: [String] = []
    @Published var perAppDefaults: [String: String] = [:]
    @Published var recentSavedFiles: [SavedFileInfo] = []
    @Published var finderAutomationStatus: PermissionStatus = .unknown

    @Published var autoJumpToAppDefault: Bool {
        didSet {
            UserDefaults.standard.set(autoJumpToAppDefault, forKey: autoJumpAppDefaultKey)
        }
    }

    enum PermissionStatus: Equatable {
        case unknown
        case granted
        case denied(String)
    }

    private let recentsKey = "QuickFolder.StoredRecents.v1"
    private let pinnedKey = "QuickFolder.PinnedFolders.v1"
    private let perAppDefaultsKey = "QuickFolder.PerAppDefaults.v1"
    private let autoJumpAppDefaultKey = "QuickFolder.AutoJumpAppDefault.v1"
    private let maxRecentCount = 25
    private var storedRecents: [StoredRecentFolder] = []
    private var pollTimer: Timer?
    private var isRefreshingFinder = false

    private init() {
        self.autoJumpToAppDefault = UserDefaults.standard.bool(forKey: autoJumpAppDefaultKey)
        loadPersistedData()
        importFinderRecentBookmarks()
        rebuildPublishedLists(openInfos: [])
        startMonitoring()
    }

    func startMonitoring() {
        refreshNow()
        pollTimer?.invalidate()
        // Only poll Finder when the floating panel or Save dialog is visible on screen
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard FloatingPanelController.shared.isPanelVisible || SavePanelDetector.shared.activePanel != nil else { return }
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
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 900

        Task.detached(priority: .userInitiated) {
            let result = Self.fetchOpenFinderWindows(
                knownRecentPaths: knownPaths,
                primaryScreenHeight: primaryScreenHeight
            )
            await MainActor.run {
                self.isRefreshingFinder = false
                switch result {
                case .success(let infos):
                    self.finderAutomationStatus = .granted
                    self.recordSeenPaths(infos.map(\.path))
                    self.rebuildPublishedLists(openInfos: infos)
                case .failure(let err):
                    self.finderAutomationStatus = .denied(err.message)
                    self.rebuildPublishedLists(openInfos: [])
                }
            }
        }
    }

    // MARK: - Per-App Default Folder

    func defaultFolderPath(for appKey: String) -> String? {
        guard let raw = perAppDefaults[appKey] else { return nil }
        let std = FolderItem.standardizePath(raw)
        return isDirectoryExists(std) ? std : nil
    }

    func defaultFolderItem(for appKey: String) -> FolderItem? {
        guard let path = defaultFolderPath(for: appKey) else { return nil }
        return FolderItem(path: path, source: .pinned)
    }

    func setDefaultFolder(_ path: String?, for appKey: String) {
        if let path = path {
            let std = FolderItem.standardizePath(path)
            perAppDefaults[appKey] = std
        } else {
            perAppDefaults.removeValue(forKey: appKey)
        }
        UserDefaults.standard.set(perAppDefaults, forKey: perAppDefaultsKey)
    }

    // MARK: - Recents & Pins

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
        rebuildPublishedLists(openInfos: openFinderWindowInfos)
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
        rebuildPublishedLists(openInfos: openFinderWindowInfos)
    }

    func removeRecent(path: String) {
        let std = FolderItem.standardizePath(path)
        storedRecents.removeAll(where: { $0.path == std })
        pinnedPaths.removeAll(where: { $0 == std })
        savePersistedData()
        UserDefaults.standard.set(pinnedPaths, forKey: pinnedKey)
        rebuildPublishedLists(openInfos: openFinderWindowInfos)
    }

    func purgeStaleRecents() {
        var changed = false
        let initialRecentsCount = storedRecents.count
        storedRecents.removeAll { item in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) && isDir.boolValue
            return !exists
        }
        if storedRecents.count != initialRecentsCount {
            changed = true
        }

        let initialPinnedCount = pinnedPaths.count
        pinnedPaths.removeAll { path in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            return !exists
        }
        if pinnedPaths.count != initialPinnedCount {
            changed = true
            UserDefaults.standard.set(pinnedPaths, forKey: pinnedKey)
        }

        if changed {
            savePersistedData()
            rebuildPublishedLists(openInfos: openFinderWindowInfos)
        }
    }

    func clearRecentHistory() {
        storedRecents.removeAll()
        UserDefaults.standard.removeObject(forKey: recentsKey)
        rebuildPublishedLists(openInfos: openFinderWindowInfos)
    }

    /// Refresh recent saved files across key user locations (Downloads, Desktop, Documents, recent folders)
    func refreshRecentSavedFiles() {
        Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var targetFolders = [
                "\(home)/Downloads",
                "\(home)/Desktop",
                "\(home)/Documents"
            ]
            let extraRecents = await MainActor.run {
                self.storedRecents.prefix(5).map(\.path)
            }
            targetFolders.append(contentsOf: extraRecents)

            var collected: [SavedFileInfo] = []
            let fm = FileManager.default
            let threeDaysAgo = Date().addingTimeInterval(-3 * 86400)

            for folder in Set(targetFolders) {
                let folderURL = URL(fileURLWithPath: folder)
                guard let enumerator = fm.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                ) else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                          vals.isRegularFile == true,
                          let modDate = vals.contentModificationDate,
                          modDate > threeDaysAgo else { continue }

                    let name = fileURL.lastPathComponent
                    guard !name.hasPrefix("."), !name.hasSuffix(".download"), !name.hasSuffix(".crdownload") else { continue }

                    collected.append(
                        SavedFileInfo(
                            name: name,
                            path: fileURL.path,
                            parentPath: folder,
                            modificationDate: modDate,
                            fileSize: Int64(vals.fileSize ?? 0)
                        )
                    )
                }
            }

            collected.sort { $0.modificationDate > $1.modificationDate }
            let trimmed = Array(collected.prefix(20))

            await MainActor.run {
                self.recentSavedFiles = trimmed
            }
        }
    }

    /// Returns a combined ordered list for quick keyboard shortcuts (Opt+1 .. Opt+9)
    func allQuickAccessFolders(searchQuery: String = "") -> [FolderItem] {
        let openList = filtered(openFinderFolders, query: searchQuery)
        let recentList = filtered(recentFolders, query: searchQuery)
        return openList + recentList
    }

    func filtered(_ items: [FolderItem], query: String) -> [FolderItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let normalized = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return items.filter {
            $0.searchKey.contains(normalized)
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

    private func rebuildPublishedLists(openInfos: [OpenFinderWindowInfo]) {
        let validInfos = openInfos.compactMap { info -> OpenFinderWindowInfo? in
            let std = FolderItem.standardizePath(info.path)
            guard isDirectoryExists(std) else { return nil }
            return OpenFinderWindowInfo(path: std, cocoaFrame: info.cocoaFrame)
        }
        self.openFinderWindowInfos = validInfos

        // 1. Deduplicate open Finder windows while preserving front-to-back window order
        var seenOpen = Set<String>()
        var openItems: [FolderItem] = []
        for info in validInfos {
            guard !seenOpen.contains(info.path) else { continue }
            seenOpen.insert(info.path)
            openItems.append(
                FolderItem(
                    path: info.path,
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
        if let appMap = UserDefaults.standard.dictionary(forKey: perAppDefaultsKey) as? [String: String] {
            self.perAppDefaults = appMap
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

    nonisolated private static func fetchOpenFinderWindows(
        knownRecentPaths: [String],
        primaryScreenHeight: CGFloat
    ) -> Result<[OpenFinderWindowInfo], FinderQueryError> {
        // 1. Try Accessibility API on Finder first (fast, includes exact window frames for Finder-Click!)
        if AXIsProcessTrusted(),
           let axInfos = fetchFinderWindowsViaAX(knownRecentPaths: knownRecentPaths, primaryScreenHeight: primaryScreenHeight) {
            return .success(axInfos)
        }

        // 2. Fallback to AppleScript via osascript (also fetches bounds + target path)
        let scriptSource = """
        tell application "Finder"
            if not running then return ""
            set outputText to ""
            repeat with w in Finder windows
                try
                    set b to bounds of w
                    set bStr to (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
                    set tabList to {}
                    try
                        set tabList to tabs of w
                    end try
                    if (count of tabList) > 0 then
                        repeat with t in tabList
                            try
                                set p to POSIX path of (target of t as alias)
                                set lineStr to p & "\t" & bStr
                                if outputText is "" then
                                    set outputText to lineStr
                                else
                                    set outputText to outputText & linefeed & lineStr
                                end if
                            end try
                        end repeat
                    else
                        set p to POSIX path of (target of w as alias)
                        set lineStr to p & "\t" & bStr
                        if outputText is "" then
                            set outputText to lineStr
                        else
                            set outputText to outputText & linefeed & lineStr
                        end if
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
        var results: [OpenFinderWindowInfo] = []
        for rawLine in outStr.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "\t")
            let path = parts[0]
            var cocoaRect: NSRect?
            if parts.count >= 2 {
                let nums = parts[1].split(separator: ",").compactMap { Double($0) }
                if nums.count == 4 {
                    let x1 = CGFloat(nums[0])
                    let y1 = CGFloat(nums[1])
                    let x2 = CGFloat(nums[2])
                    let y2 = CGFloat(nums[3])
                    let w = max(x2 - x1, 0)
                    let h = max(y2 - y1, 0)
                    cocoaRect = NSRect(x: x1, y: primaryScreenHeight - y1 - h, width: w, height: h)
                }
            }
            results.append(OpenFinderWindowInfo(path: path, cocoaFrame: cocoaRect))
        }

        return .success(results)
    }

    nonisolated private static func fetchFinderWindowsViaAX(
        knownRecentPaths: [String],
        primaryScreenHeight: CGFloat
    ) -> [OpenFinderWindowInfo]? {
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
            "màn hình nền": "\(home)/Desktop",
            "tài liệu": "\(home)/Documents",
            "tải về": "\(home)/Downloads",
            "ứng dụng": "/Applications",
            "hình ảnh": "\(home)/Pictures",
            "nhạc": "\(home)/Music",
            "phim": "\(home)/Movies",
            URL(fileURLWithPath: home).lastPathComponent.lowercased(): home
        ]

        var results: [OpenFinderWindowInfo] = []
        for win in wins {
            AXUIElementSetMessagingTimeout(win, 0.04)
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == "AXWindow" else { continue }

            let cocoaFrame = extractCocoaFrame(win, primaryScreenHeight: primaryScreenHeight)

            var windowPaths: [String] = []

            // 1. Check AXDocument URL first
            var docRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docRef) == .success,
               let docStr = docRef as? String,
               let url = URL(string: docStr), let p = (url as NSURL).filePathURL?.path, !p.isEmpty {
                windowPaths.append(p)
            }

            // 2. Check AXProxy URL
            var proxyRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXProxyAttribute as CFString, &proxyRef) == .success,
               let proxy = proxyRef {
                let proxyEl = proxy as! AXUIElement
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(proxyEl, kAXURLAttribute as CFString, &urlRef) == .success {
                    if let url = urlRef as? URL, let p = (url as NSURL).filePathURL?.path, !p.isEmpty {
                        windowPaths.append(p)
                    } else if let urlStr = urlRef as? String, let url = URL(string: urlStr), let p = (url as NSURL).filePathURL?.path, !p.isEmpty {
                        windowPaths.append(p)
                    }
                }
            }

            // 3. Deep Path Bar, AXURL & Finder Tabs Search
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            let rawTitle = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let normalizedTitle = rawTitle.precomposedStringWithCanonicalMapping

            func searchFinderWindowPath(_ elem: AXUIElement, depth: Int) {
                if depth > 9 { return }

                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
                let role = roleRef as? String

                // Check tab buttons in Finder tab bar
                if role == "AXRadioButton" || role == "AXTab" {
                    var tabTitleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &tabTitleRef)
                    if let tabTitle = (tabTitleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !tabTitle.isEmpty {
                        let normTab = tabTitle.precomposedStringWithCanonicalMapping.lowercased()
                        if let std = standardMap[normTab] {
                            windowPaths.append(std)
                        } else if let matched = knownRecentPaths.first(where: {
                            URL(fileURLWithPath: $0).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == normTab
                        }) {
                            windowPaths.append(matched)
                        }
                    }
                }

                var uRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem, "AXURL" as CFString, &uRef) == .success,
                   let u = uRef as? URL ?? (uRef as? String).flatMap(URL.init(string:)),
                   let p = (u as NSURL).filePathURL?.path, !p.isEmpty {
                    let uNorm = URL(fileURLWithPath: p)
                    // Case A: Element AXURL matches the window title directly
                    if !normalizedTitle.isEmpty && uNorm.lastPathComponent.precomposedStringWithCanonicalMapping == normalizedTitle {
                        windowPaths.append(uNorm.path)
                    } else if !normalizedTitle.isEmpty && uNorm.deletingLastPathComponent().lastPathComponent.precomposedStringWithCanonicalMapping == normalizedTitle {
                        windowPaths.append(uNorm.deletingLastPathComponent().path)
                    } else {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue {
                            windowPaths.append(p)
                        }
                    }
                }

                var kidsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                   let kids = kidsRef as? [AXUIElement] {
                    for child in kids.reversed() {
                        searchFinderWindowPath(child, depth: depth + 1)
                    }
                }
            }

            searchFinderWindowPath(win, depth: 0)

            // 4. Fallback: match window title against standard folders or known recent paths
            if !normalizedTitle.isEmpty, normalizedTitle.lowercased() != "recents" {
                if let stdPath = standardMap[normalizedTitle.lowercased()] {
                    windowPaths.append(stdPath)
                } else if let matched = knownRecentPaths.first(where: {
                    URL(fileURLWithPath: $0).lastPathComponent.precomposedStringWithCanonicalMapping == normalizedTitle
                }) {
                    windowPaths.append(matched)
                }
            }

            // Deduplicate paths found for this window while preserving order
            var seenInWindow = Set<String>()
            for path in windowPaths {
                let std = FolderItem.standardizePath(path)
                if !seenInWindow.contains(std) {
                    seenInWindow.insert(std)
                    results.append(OpenFinderWindowInfo(path: std, cocoaFrame: cocoaFrame))
                }
            }
        }
        return results
    }

    nonisolated private static func extractCocoaFrame(_ element: AXUIElement, primaryScreenHeight: CGFloat) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
              sz.width >= 150, sz.height >= 120 else {
            return nil
        }
        let cocoaY = primaryScreenHeight - pt.y - sz.height
        return NSRect(x: pt.x, y: cocoaY, width: sz.width, height: sz.height)
    }
}
