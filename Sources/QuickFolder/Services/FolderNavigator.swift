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

            // 1. Activate the target application with focus handoff
            if let app = NSRunningApplication(processIdentifier: targetPID) {
                if #available(macOS 14.0, *) {
                    NSApplication.shared.yieldActivation(to: app)
                }
                app.activate(options: [.activateAllWindows])
            }
            let detectedFrame = detector.activePanel?.cocoaFrame
            Self.focusTargetAppSaveWindow(pid: targetPID, expectedFrame: detectedFrame)

            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms focus handoff

            // 2. Tier 1: Try instant direct sidebar click (0ms native click, no clipboard, no key simulation)
            let sidebarHandled = await Task.detached(priority: .userInitiated) {
                Self.trySelectSidebarFolderDirectly(pid: targetPID, folderPath: folderPath)
            }.value

            if sidebarHandled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                self.showBanner("✓ Đã chuyển tới “\(folderName)”")
                detector.isNavigatingFolder = false
                detector.pollNow()
                return
            }

            // 3. Tier 2: Safe Go-To-Folder (Cmd + Shift + G)
            // Save clipboard content atomically
            let pasteboard = NSPasteboard.general
            var savedItems: [[(NSPasteboard.PasteboardType, Data)]] = []
            if let items = pasteboard.pasteboardItems {
                for item in items {
                    var entry: [(NSPasteboard.PasteboardType, Data)] = []
                    for t in item.types {
                        if let d = item.data(forType: t) {
                            entry.append((t, d))
                        }
                    }
                    if !entry.isEmpty {
                        savedItems.append(entry)
                    }
                }
            }
            pasteboard.clearContents()
            pasteboard.setString(folderPath, forType: .string)

            // Step 1: Send Cmd + Shift + G ("Go to Folder...")
            Self.postKeyStroke(keyCode: 5, flags: [.maskCommand, .maskShift]) // 'g' = 5

            // Step 2: Strictly verify GoTo sheet / PathTextField appeared before sending ANY confirm keystrokes
            var isGoToOpen = false
            for _ in 0..<16 { // Poll up to 400ms (16 x 25ms)
                try? await Task.sleep(nanoseconds: 25_000_000)
                let visible = await Task.detached(priority: .userInitiated) {
                    Self.isGoToWindowVisible(pid: targetPID)
                }.value
                if visible {
                    isGoToOpen = true
                    break
                }
            }

            // CRITICAL SAFETY CHECK: NEVER SEND RETURN IF GO-TO SHEET IS NOT OPEN!
            // Prevents accidentally pressing the default "Save" button on the main dialog!
            guard isGoToOpen else {
                Self.restorePasteboard(savedItems)
                self.showBanner("⚠️ Không thể mở Go To Folder trên ứng dụng này")
                detector.isNavigatingFolder = false
                detector.pollNow()
                return
            }

            // Step 3: GoTo sheet is confirmed open. Send Cmd + A (Select All) then Cmd + V (Paste path)
            Self.postKeyStroke(keyCode: 0, flags: [.maskCommand]) // 'a' = 0
            try? await Task.sleep(nanoseconds: 35_000_000)
            Self.postKeyStroke(keyCode: 9, flags: [.maskCommand]) // 'v' = 9

            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms for path resolution

            // Step 4: Send plain Return (36) with flags = [] to navigate
            Self.postKeyStroke(keyCode: 36, flags: []) // Return = 36
            try? await Task.sleep(nanoseconds: 150_000_000)

            // If autocomplete sheet is still visible, send second plain Return to confirm
            let stillOpen = await Task.detached(priority: .userInitiated) {
                Self.isGoToWindowVisible(pid: targetPID)
            }.value
            if stillOpen {
                Self.postKeyStroke(keyCode: 36, flags: [])
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            // Step 5: Restore user's previous clipboard after navigation completes
            Self.restorePasteboard(savedItems)

            self.showBanner("✓ Đã chuyển tới “\(folderName)”")

            // Step 6: Auto-scroll ColumnView (AXBrowser) horizontal scrollbar to 1.0 (rightmost column)
            for delayNs in [90_000_000 as UInt64, 120_000_000 as UInt64, 180_000_000 as UInt64] {
                try? await Task.sleep(nanoseconds: delayNs)
                await Task.detached(priority: .userInitiated) {
                    Self.scrollColumnViewToRightmost(pid: targetPID)
                }.value
            }

            detector.isNavigatingFolder = false
            detector.pollNow()
        }
    }

    private static func restorePasteboard(_ savedItems: [[(NSPasteboard.PasteboardType, Data)]]) {
        guard !savedItems.isEmpty else { return }
        Task { @MainActor in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            var writeItems: [NSPasteboardItem] = []
            for entry in savedItems {
                let newItem = NSPasteboardItem()
                for (t, d) in entry {
                    newItem.setData(d, forType: t)
                }
                writeItems.append(newItem)
            }
            pasteboard.writeObjects(writeItems)
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

    nonisolated private static func focusTargetAppSaveWindow(pid: pid_t, expectedFrame: NSRect? = nil) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.04)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        // 1. If expectedFrame is known, find the matching window or attached sheet directly
        if let targetFrame = expectedFrame {
            var winsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
               let wins = winsRef as? [AXUIElement] {
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
                for win in wins {
                    if let f = extractCocoaFrame(win, primaryScreenHeight: primaryHeight),
                       abs(f.origin.x - targetFrame.origin.x) < 25 && abs(f.size.width - targetFrame.size.width) < 25 {
                        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                        return
                    }
                    var sheetsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(win, "AXSheets" as CFString, &sheetsRef) == .success,
                       let sheets = sheetsRef as? [AXUIElement] {
                        for sheet in sheets {
                            if let f = extractCocoaFrame(sheet, primaryScreenHeight: primaryHeight),
                               abs(f.origin.x - targetFrame.origin.x) < 25 && abs(f.size.width - targetFrame.size.width) < 25 {
                                AXUIElementSetAttributeValue(sheet, kAXMainAttribute as CFString, kCFBooleanTrue)
                                AXUIElementSetAttributeValue(sheet, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                                AXUIElementPerformAction(sheet, kAXRaiseAction as CFString)
                                return
                            }
                        }
                    }
                }
            }
        }

        // 2. Try focusing the Save/Open dialog or sheet directly first
        let roots = findSaveDialogRoots(pid: pid)
        if let dialog = roots.first {
            AXUIElementSetAttributeValue(dialog, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(dialog, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(dialog, kAXRaiseAction as CFString)
            return
        }

        // 3. Fallback to first window
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let wins = winsRef as? [AXUIElement],
           let firstWin = wins.first {
            AXUIElementSetAttributeValue(firstWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(firstWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(firstWin, kAXRaiseAction as CFString)
        }
    }

    nonisolated private static func extractCocoaFrame(_ element: AXUIElement, primaryScreenHeight: CGFloat) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return NSRect(x: pos.x, y: primaryScreenHeight - pos.y - size.height, width: size.width, height: size.height)
    }

    // MARK: - Safety Check for GoTo Sheet

    nonisolated private static func isGoToWindowVisible(pid: pid_t) -> Bool {
        for root in findSaveDialogRoots(pid: pid) {
            if hasGoToChild(in: root, depth: 0) {
                return true
            }
        }
        return false
    }

    nonisolated private static func hasGoToChild(in element: AXUIElement, depth: Int) -> Bool {
        guard depth <= 8 else { return false }
        AXUIElementSetMessagingTimeout(element, 0.04)

        var idRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &idRef) == .success,
           let id = idRef as? String {
            if id == "PathTextField" || id == "GoToWindow" {
                return true
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return false
        }

        for child in children {
            if hasGoToChild(in: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    /// Instant 0ms sidebar selection: If `folderPath` is one of the standard macOS user folders present in the
    /// Save/Open dialog's left sidebar (`AXOutline` -> `AXRow`), clicks that row directly via CGEvent without opening Cmd+Shift+G.
    nonisolated private static func trySelectSidebarFolderDirectly(pid: pid_t, folderPath: String) -> Bool {
        let standardized = (folderPath as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath

        var targetLabels: Set<String> = [
            (folderPath as NSString).lastPathComponent
        ]

        let standardPathLabels: [String: Set<String>] = [
            (home as NSString).appendingPathComponent("Desktop"): ["Desktop", "Màn hình nền"],
            (home as NSString).appendingPathComponent("Documents"): ["Documents", "Tài liệu"],
            (home as NSString).appendingPathComponent("Downloads"): ["Downloads", "Tải về"],
            "/Applications": ["Applications", "Ứng dụng"],
            (home as NSString).appendingPathComponent("Pictures"): ["Pictures", "Hình ảnh"],
            (home as NSString).appendingPathComponent("Movies"): ["Movies", "Phim"],
            (home as NSString).appendingPathComponent("Music"): ["Music", "Nhạc"],
            home: [NSUserName(), URL(fileURLWithPath: home).lastPathComponent]
        ]

        if let std = standardPathLabels[standardized] {
            targetLabels.formUnion(std)
        }
        if standardized.contains("GoogleDrive") || standardized.contains("Google Drive") {
            targetLabels.insert("Google Drive")
        }
        if standardized.contains("OneDrive") {
            targetLabels.insert("OneDrive")
        }
        if standardized.contains("Dropbox") {
            targetLabels.insert("Dropbox")
        }
        if standardized.contains("Mobile Documents") {
            targetLabels.insert("iCloud Drive")
        }

        for root in findSaveDialogRoots(pid: pid) {
            if clickMatchingSidebarRow(in: root, targetLabels: targetLabels, depth: 0) {
                return true
            }
        }
        return false
    }

    nonisolated private static func clickMatchingSidebarRow(in element: AXUIElement, targetLabels: Set<String>, depth: Int) -> Bool {
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
                    if let (label, textEl) = extractRowStaticTextElement(row), targetLabels.contains(label) {
                        if let center = extractElementCenter(textEl) ?? extractElementCenter(row) {
                            clickAtPoint(center)
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
            if clickMatchingSidebarRow(in: child, targetLabels: targetLabels, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    nonisolated private static func extractRowStaticTextElement(_ row: AXUIElement) -> (String, AXUIElement)? {
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
                            return (text, sub)
                        }
                    }
                }
            }
        }
        return nil
    }

    nonisolated private static func extractElementCenter(_ element: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            return nil
        }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    nonisolated private static func clickAtPoint(_ center: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(25_000)
        up?.post(tap: .cghidEventTap)
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
        usleep(15_000)
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
