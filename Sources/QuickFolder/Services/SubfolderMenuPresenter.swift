import Foundation
import AppKit

private final class SubfolderNSMenu: NSMenu {
    let folderPath: String
    init(title: String, folderPath: String) {
        self.folderPath = folderPath
        super.init(title: title)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class SubfolderMenuPresenter: NSObject, NSMenuDelegate {
    static let shared = SubfolderMenuPresenter()

    private var activeRootMenu: SubfolderNSMenu?

    private override init() {
        super.init()
    }

    /// Pops up a cascading subfolder browser & quick-actions menu at the current mouse cursor location.
    func popUpSubfolderMenu(for folder: FolderItem) {
        let menu = SubfolderNSMenu(title: folder.name, folderPath: folder.path)
        menu.delegate = self
        menu.autoenablesItems = false
        self.activeRootMenu = menu

        let mouseLoc = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: mouseLoc, in: nil)
    }

    // MARK: - NSMenuDelegate (Lazy Cascading Tree)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let subMenu = menu as? SubfolderNSMenu else { return }
        subMenu.removeAllItems()

        let folderPath = subMenu.folderPath
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent

        // 1. Direct select current folder
        let chooseItem = NSMenuItem(
            title: "Chọn ngay “\(folderName)”",
            action: #selector(selectFolderAction(_:)),
            keyEquivalent: ""
        )
        chooseItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        chooseItem.representedObject = folderPath
        chooseItem.target = self
        subMenu.addItem(chooseItem)

        // 2. Create a new subfolder inside this folder & jump directly into it
        let newFolderItem = NSMenuItem(
            title: "Tạo thư mục con mới tại đây...",
            action: #selector(createSubfolderAndSelectAction(_:)),
            keyEquivalent: ""
        )
        newFolderItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        newFolderItem.representedObject = folderPath
        newFolderItem.target = self
        subMenu.addItem(newFolderItem)

        // 3. Per-App Default Folder assignment if an external Save/Open dialog is active
        if let activePanel = SavePanelDetector.shared.activePanel,
           activePanel.appPID != ProcessInfo.processInfo.processIdentifier {
            let appKey = activePanel.appIdentifierKey
            let currentDefault = FolderManager.shared.defaultFolderPath(for: appKey)
            let isCurrentDefault = (currentDefault == FolderItem.standardizePath(folderPath))

            let appDefaultItem = NSMenuItem(
                title: isCurrentDefault
                    ? "Bỏ đặt mặc định cho \(activePanel.appName)"
                    : "Đặt làm thư mục mặc định cho \(activePanel.appName)",
                action: #selector(toggleAppDefaultAction(_:)),
                keyEquivalent: ""
            )
            appDefaultItem.image = NSImage(
                systemSymbolName: isCurrentDefault ? "star.slash.fill" : "star.fill",
                accessibilityDescription: nil
            )
            appDefaultItem.representedObject = [
                "appKey": appKey,
                "appName": activePanel.appName,
                "folderPath": folderPath
            ] as [String: String]
            appDefaultItem.target = self
            subMenu.addItem(appDefaultItem)
        }

        subMenu.addItem(.separator())

        // 4. Lazy load immediate child directories (cached + time-boxed so the menu opens instantly)
        let childDirs = SubfolderIndex.shared.children(of: folderPath)
        if childDirs.isEmpty {
            let emptyItem = NSMenuItem(title: "(Không có thư mục con)", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            subMenu.addItem(emptyItem)
        } else {
            let folderIcon = FileMetadataCache.shared.genericFolderIcon16
            let limit = 300
            for child in childDirs.prefix(limit) {
                let item = NSMenuItem(
                    title: child.name,
                    action: #selector(selectFolderAction(_:)),
                    keyEquivalent: ""
                )
                item.image = folderIcon
                item.representedObject = child.path
                item.target = self

                // Attach nested lazy submenu unless we already know the child has no subfolders.
                // (Unknown = still being probed in the background → keep it browsable.)
                if child.hasSubfolders != false {
                    let nested = SubfolderNSMenu(title: child.name, folderPath: child.path)
                    nested.delegate = self
                    nested.autoenablesItems = false
                    item.submenu = nested
                }

                subMenu.addItem(item)
            }
            if childDirs.count > limit {
                let more = NSMenuItem(title: "… và \(childDirs.count - limit) thư mục khác", action: nil, keyEquivalent: "")
                more.isEnabled = false
                subMenu.addItem(more)
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func selectFolderAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let item = FolderItem(path: path, source: .recent)
        FolderNavigator.shared.selectFolder(item)
    }

    @objc private func toggleAppDefaultAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let appKey = info["appKey"],
              let appName = info["appName"],
              let folderPath = info["folderPath"] else { return }

        let std = FolderItem.standardizePath(folderPath)
        if FolderManager.shared.defaultFolderPath(for: appKey) == std {
            FolderManager.shared.setDefaultFolder(nil, for: appKey)
            FolderNavigator.shared.showBanner("Đã bỏ thư mục mặc định của \(appName)")
        } else {
            FolderManager.shared.setDefaultFolder(std, for: appKey)
            let name = URL(fileURLWithPath: std).lastPathComponent
            FolderNavigator.shared.showBanner("★ Đã đặt “\(name)” làm mặc định cho \(appName)")
        }
    }

    @objc private func createSubfolderAndSelectAction(_ sender: NSMenuItem) {
        guard let parentPath = sender.representedObject as? String else { return }
        // Capture the active Save panel BEFORE showing our NSAlert so we can restore focus and jump right after!
        let capturedActivePanel = SavePanelDetector.shared.activePanel
        let capturedTestPanel = FolderNavigator.shared.activeTestSavePanel

        let parentName = URL(fileURLWithPath: parentPath).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Tạo thư mục mới trong “\(parentName)”"
        alert.informativeText = "Nhập tên thư mục mới (hộp thoại Save sẽ tự động chuyển ngay vào thư mục này):"
        alert.addButton(withTitle: "Tạo & Chọn ngay")
        alert.addButton(withTitle: "Huỷ")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        inputField.placeholderString = "Ví dụ: BaoCao_Thang10"
        inputField.stringValue = "ThuMucMoi"
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            if let captured = capturedActivePanel,
               let app = NSRunningApplication(processIdentifier: captured.appPID) {
                app.activate(options: [.activateAllWindows])
            }
            return
        }

        let newName = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, !newName.contains("/") else { return }

        let newURL = URL(fileURLWithPath: parentPath, isDirectory: true).appendingPathComponent(newName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
            FolderManager.shared.recordFolderUsed(newURL.path)

            if let testPanel = capturedTestPanel, testPanel.isVisible {
                testPanel.directoryURL = newURL
                FolderNavigator.shared.showBanner("✓ Đã tạo & chuyển tới “\(newName)”")
            } else if let captured = capturedActivePanel {
                FolderNavigator.shared.navigateToSpecificTarget(
                    targetPID: captured.appPID,
                    folderPath: newURL.path,
                    folderName: newName
                )
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: newURL.path)
            }
        } catch {
            let errAlert = NSAlert(error: error)
            errAlert.runModal()
        }
    }
}

// MARK: - Subfolder Index (background, cached, time-boxed)

/// Lists child folders and probes whether each has subfolders, in parallel and off the main thread.
/// `menuNeedsUpdate` waits at most `menuBudget`; anything slower (e.g. CloudStorage) finishes in the
/// background and lands in the cache, so re-opening the same menu is instant.
final class SubfolderIndex: @unchecked Sendable {
    static let shared = SubfolderIndex()

    struct Child: Sendable {
        let name: String
        let path: String
        let hasSubfolders: Bool?
    }

    private struct Entry {
        let children: [Child]
        let timestamp: TimeInterval
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var probes: [String: Bool] = [:]
    private let ttl: TimeInterval = 30
    private let menuBudget: TimeInterval = 0.25
    private let queue = DispatchQueue(label: "QuickFolder.SubfolderIndex", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    func children(of path: String) -> [Child] {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let entry = cache[path], now - entry.timestamp < ttl {
            let resolved = entry.children.map { c in
                Child(name: c.name, path: c.path, hasSubfolders: c.hasSubfolders ?? probes[c.path])
            }
            lock.unlock()
            return resolved
        }
        lock.unlock()

        // 1. List immediate children (bounded wait so a slow volume never freezes the menu)
        let listSem = DispatchSemaphore(value: 0)
        var listed: [URL]?
        queue.async {
            let urls = Self.listImmediateSubfolders(at: path)
            self.lock.lock(); listed = urls; self.lock.unlock()
            listSem.signal()
        }
        if listSem.wait(timeout: .now() + 1.5) == .timedOut {
            return []
        }
        lock.lock(); let urls = listed ?? []; lock.unlock()

        // 2. Probe each child for subfolders in parallel, within the time budget
        let group = DispatchGroup()
        for url in urls.prefix(300) {
            let childPath = url.path
            lock.lock(); let known = probes[childPath] != nil; lock.unlock()
            if known { continue }
            group.enter()
            queue.async {
                let has = Self.hasAnySubfolderFast(at: childPath)
                self.lock.lock(); self.probes[childPath] = has; self.lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + menuBudget)

        lock.lock()
        let result = urls.map { url in
            Child(name: url.lastPathComponent, path: url.path, hasSubfolders: probes[url.path])
        }
        cache[path] = Entry(
            children: result.map { Child(name: $0.name, path: $0.path, hasSubfolders: nil) },
            timestamp: now
        )
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        if probes.count > 5000 { probes.removeAll(keepingCapacity: true) }
        lock.unlock()
        return result
    }

    private static func listImmediateSubfolders(at path: String) -> [URL] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return contents.filter { item in
            guard let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  vals.isDirectory == true,
                  vals.isPackage != true else {
                return false
            }
            return true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func hasAnySubfolderFast(at path: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else {
            return false
        }
        var inspectedCount = 0
        while let childURL = enumerator.nextObject() as? URL {
            inspectedCount += 1
            if inspectedCount > 200 {
                break
            }
            if let vals = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
               vals.isDirectory == true,
               vals.isPackage != true {
                return true
            }
        }
        return false
    }
}
