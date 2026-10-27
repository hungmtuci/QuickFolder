import Foundation
import AppKit
import ApplicationServices

@MainActor
final class FolderNavigator: ObservableObject {
    static let shared = FolderNavigator()

    @Published var statusBannerMessage: String?

    /// Weak reference to in-process test save panel if open
    weak var activeTestSavePanel: NSSavePanel?

    private init() {}

    /// Navigates the active Save/Open dialog to `folder.path`, or opens it in Finder if no Save/Open dialog is open.
    func selectFolder(_ folder: FolderItem) {
        FolderManager.shared.recordFolderUsed(folder.path)

        // 1. If our built-in Test Save Panel is open, update its directoryURL directly for instant response
        if let testPanel = activeTestSavePanel, testPanel.isVisible {
            testPanel.directoryURL = URL(fileURLWithPath: folder.path, isDirectory: true)
            showBanner("✓ Đã chuyển tới “\(folder.name)”")
            return
        }

        // 2. If an external app's Save/Open dialog is detected, navigate it via Cmd+Shift+G + Unicode input
        if let activePanel = SavePanelDetector.shared.activePanel {
            navigateExternalSavePanel(targetPID: activePanel.appPID, folderPath: folder.path, folderName: folder.name)
            return
        }

        // 3. Fallback: if no Save/Open panel is open, open the folder in Finder
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        showBanner("Đã mở “\(folder.name)” trong Finder")
    }

    /// Instant shortcut action: Jumps the active Save/Open dialog to the frontmost open Finder window
    func jumpToFrontmostFinderWindow() {
        FolderManager.shared.refreshNow()
        if let firstOpen = FolderManager.shared.openFinderFolders.first {
            selectFolder(firstOpen)
        } else if let firstRecent = FolderManager.shared.recentFolders.first {
            selectFolder(firstRecent)
        } else {
            showBanner("Không tìm thấy cửa sổ Finder nào đang mở")
        }
    }

    func navigateToSpecificTarget(targetPID: pid_t, folderPath: String, folderName: String) {
        navigateExternalSavePanel(targetPID: targetPID, folderPath: folderPath, folderName: folderName)
    }

    private func navigateExternalSavePanel(targetPID: pid_t, folderPath: String, folderName: String) {
        let detector = SavePanelDetector.shared
        detector.isNavigatingFolder = true
        showBanner("✓ Đang chuyển tới “\(folderName)”...")

        // Release any key-window focus from our floating panel so the Save dialog receives all keystrokes
        FloatingPanelController.shared.resignKeyForNavigation()

        Task { @MainActor in
            guard AXIsProcessTrusted() else {
                SavePanelDetector.shared.checkAccessibilityPermission(prompt: true)
                self.showBanner("⚠️ Hãy bật quyền Accessibility cho QuickFolder")
                detector.isNavigatingFolder = false
                return
            }

            // 1. Fast Path (0ms, no popup): If target folder is a standard sidebar favorite in the Save dialog, select its AXRow directly
            let selectedViaSidebar = await Task.detached(priority: .userInitiated) {
                Self.trySelectSidebarFolderDirectly(pid: targetPID, folderPath: folderPath)
            }.value

            if selectedViaSidebar {
                self.showBanner("✓ Đã chuyển tới “\(folderName)”")
                try? await Task.sleep(nanoseconds: 80_000_000)
                await Task.detached(priority: .userInitiated) {
                    Self.scrollColumnViewToRightmost(pid: targetPID)
                }.value
                detector.isNavigatingFolder = false
                detector.pollNow()
                return
            }

            // 2. Ultra-fast Go-To-Folder path for arbitrary/deep folders
            if let app = NSRunningApplication(processIdentifier: targetPID) {
                app.activate(options: [.activateAllWindows])
            }
            Self.focusTargetAppSaveWindow(pid: targetPID)

            try? await Task.sleep(nanoseconds: 45_000_000) // 45ms focus handoff

            // Step 1: Send Cmd + Shift + G ("Go to Folder...")
            Self.postKeyStroke(keyCode: 5, flags: [.maskCommand, .maskShift]) // 'g' = 5

            try? await Task.sleep(nanoseconds: 145_000_000) // 145ms for Go-To-Folder field to open

            // Step 2: Clear default text (Backspace = 51) and inject full UTF-16 path atomically
            Self.postKeyStroke(keyCode: 51, flags: []) // Backspace
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            Self.postUnicodeString(folderPath)

            try? await Task.sleep(nanoseconds: 65_000_000) // 65ms for path resolution

            // Step 3: Send Return (36) to confirm and jump to folder
            Self.postKeyStroke(keyCode: 36, flags: []) // Return = 36

            self.showBanner("✓ Đã chuyển tới “\(folderName)”")

            // Step 4: Auto-scroll ColumnView (AXBrowser) horizontal scrollbar to 1.0 (rightmost column)
            // Triggered at 90ms, 190ms, and 310ms so even deeply nested Google Drive/cloud folders scroll to the end
            for delayNs in [90_000_000 as UInt64, 100_000_000 as UInt64, 120_000_000 as UInt64] {
                try? await Task.sleep(nanoseconds: delayNs)
                await Task.detached(priority: .userInitiated) {
                    Self.scrollColumnViewToRightmost(pid: targetPID)
                }.value
            }

            detector.isNavigatingFolder = false
            detector.pollNow()
        }
    }

    func showBanner(_ text: String) {
        self.statusBannerMessage = text
        let captured = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.statusBannerMessage == captured {
                self.statusBannerMessage = nil
            }
        }
    }

    // MARK: - Low-Level Focus & Key Event Injection

    nonisolated private static func focusTargetAppSaveWindow(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.04)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let wins = winsRef as? [AXUIElement],
           let firstWin = wins.first {
            AXUIElementSetAttributeValue(firstWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(firstWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(firstWin, kAXRaiseAction as CFString)
        }
    }

    /// Instant 0ms sidebar selection: If `folderPath` is one of the standard macOS user folders present in the
    /// Save/Open dialog's left sidebar (`AXOutline` -> `AXRow`), selects that row directly via Accessibility without opening Cmd+Shift+G.
    nonisolated private static func trySelectSidebarFolderDirectly(pid: pid_t, folderPath: String) -> Bool {
        let standardized = (folderPath as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath

        let standardPathLabels: [String: Set<String>] = [
            (home as NSString).appendingPathComponent("Desktop"): ["Desktop", "Màn hình nền"],
            (home as NSString).appendingPathComponent("Documents"): ["Documents", "Tài liệu"],
            (home as NSString).appendingPathComponent("Downloads"): ["Downloads", "Tải về"],
            "/Applications": ["Applications", "Ứng dụng"],
            (home as NSString).appendingPathComponent("Pictures"): ["Pictures", "Hình ảnh"],
            (home as NSString).appendingPathComponent("Movies"): ["Movies", "Phim"],
            (home as NSString).appendingPathComponent("Music"): ["Music", "Nhạc"],
            home: [NSUserName()]
        ]

        guard let targetLabels = standardPathLabels[standardized] else {
            return false
        }

        for root in findSaveDialogRoots(pid: pid) {
            if selectMatchingSidebarRow(in: root, targetLabels: targetLabels, depth: 0) {
                return true
            }
        }
        return false
    }

    nonisolated private static func findSaveDialogRoots(pid: pid_t) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.04)

        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else {
            return []
        }

        var roots: [AXUIElement] = []
        for win in wins.prefix(4) {
            AXUIElementSetMessagingTimeout(win, 0.04)

            // 1. Check if window has an attached AXSheet
            var sheetsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, "AXSheets" as CFString, &sheetsRef) == .success,
               let sheets = sheetsRef as? [AXUIElement], !sheets.isEmpty {
                for sheet in sheets {
                    AXUIElementSetMessagingTimeout(sheet, 0.04)
                    roots.append(sheet)
                }
                continue
            }

            // 2. Check direct children for AXSheet
            var childrenRef: CFTypeRef?
            var foundSheetChild = false
            if AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children.prefix(20) {
                    AXUIElementSetMessagingTimeout(child, 0.04)
                    var roleRef: CFTypeRef?
                    let role = (AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success)
                        ? (roleRef as? String ?? "") : ""
                    if role == "AXSheet" {
                        roots.append(child)
                        foundSheetChild = true
                    }
                }
            }
            if foundSheetChild { continue }

            // 3. Otherwise check if window itself is a Save/Open dialog
            var idRef: CFTypeRef?
            let winID = ((AXUIElementCopyAttributeValue(win, "AXIdentifier" as CFString, &idRef) == .success)
                ? (idRef as? String ?? "") : "").lowercased()
            var subroleRef: CFTypeRef?
            let subrole = (AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef) == .success)
                ? (subroleRef as? String ?? "") : ""

            if winID == "save-panel" || winID == "open-panel" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                roots.append(win)
            }
        }
        return roots
    }

    nonisolated private static func selectMatchingSidebarRow(in element: AXUIElement, targetLabels: Set<String>, depth: Int) -> Bool {
        guard depth <= 7 else { return false }
        AXUIElementSetMessagingTimeout(element, 0.04)

        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success)
            ? (roleRef as? String ?? "") : ""

        if role == "AXOutline" {
            var rowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rowsRef) == .success,
               let rows = rowsRef as? [AXUIElement] {
                for row in rows {
                    AXUIElementSetMessagingTimeout(row, 0.04)
                    if let label = extractRowStaticText(row), targetLabels.contains(label) {
                        if AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                            return true
                        }
                    }
                }
            }
            return false
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return false
        }

        for child in children.prefix(25) {
            if selectMatchingSidebarRow(in: child, targetLabels: targetLabels, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    nonisolated private static func extractRowStaticText(_ row: AXUIElement) -> String? {
        var cellsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(row, kAXChildrenAttribute as CFString, &cellsRef) == .success,
              let cells = cellsRef as? [AXUIElement] else {
            return nil
        }
        for cell in cells {
            AXUIElementSetMessagingTimeout(cell, 0.04)
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(cell, kAXChildrenAttribute as CFString, &subRef) == .success,
               let subs = subRef as? [AXUIElement] {
                for sub in subs {
                    AXUIElementSetMessagingTimeout(sub, 0.04)
                    var roleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(sub, kAXRoleAttribute as CFString, &roleRef) == .success,
                       (roleRef as? String) == "AXStaticText" {
                        var valRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(sub, kAXValueAttribute as CFString, &valRef) == .success,
                           let text = valRef as? String, !text.isEmpty {
                            return text
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Scrolls any ColumnView (`AXBrowser`) horizontal scrollbar inside the active Save/Open dialog to `1.0` (rightmost column),
    /// ensuring deeply nested target folders are immediately visible at the end without manual horizontal scrolling.
    nonisolated private static func scrollColumnViewToRightmost(pid: pid_t) {
        for root in findSaveDialogRoots(pid: pid) {
            scrollBrowserHorizontalBars(in: root, insideBrowser: false, depth: 0)
        }
    }

    nonisolated private static func scrollBrowserHorizontalBars(in element: AXUIElement, insideBrowser: Bool, depth: Int) {
        guard depth <= 8 else { return }
        AXUIElementSetMessagingTimeout(element, 0.04)

        var roleRef: CFTypeRef?
        let role = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success)
            ? (roleRef as? String ?? "") : ""

        let nowInBrowser = insideBrowser || (role == "AXBrowser")

        if nowInBrowser && role == "AXScrollBar" {
            var orientRef: CFTypeRef?
            let orient = (AXUIElementCopyAttributeValue(element, kAXOrientationAttribute as CFString, &orientRef) == .success)
                ? (orientRef as? String ?? "") : ""
            if orient == "AXHorizontalOrientation" || orient.isEmpty {
                AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, NSNumber(value: 1.0))
            }
            return
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }

        for child in children.prefix(25) {
            scrollBrowserHorizontalBars(in: child, insideBrowser: nowInBrowser, depth: depth + 1)
        }
    }

    nonisolated private static func postKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }
    }

    nonisolated private static func postUnicodeString(_ string: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let utf16 = Array(string.utf16)
        guard !utf16.isEmpty else { return }

        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            keyDown.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            keyUp.flags = []
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
