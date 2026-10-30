import Foundation
import AppKit
import ApplicationServices
import Combine

struct DetectedSavePanel: Equatable, Sendable {
    let appPID: pid_t
    let appName: String
    let appBundleID: String?
    /// Frame in AppKit screen coordinates (origin at bottom-left of primary screen)
    let cocoaFrame: NSRect
    let isSheet: Bool

    var appIdentifierKey: String {
        appBundleID ?? appName
    }
}

private let axObserverCallback: AXObserverCallback = { _, _, _, _ in
    Task { @MainActor in
        SavePanelDetector.shared.handleAXEvent()
    }
}

@MainActor
final class SavePanelDetector: ObservableObject {
    static let shared = SavePanelDetector()

    @Published private(set) var activePanel: DetectedSavePanel?
    @Published private(set) var isAccessibilityTrusted: Bool = false
    @Published private(set) var excludedBundleIDs: Set<String> = []

    /// Temporarily locks the panel from hiding while FolderNavigator executes Cmd+Shift+G
    var isNavigatingFolder: Bool = false

    private let excludedAppsKey = "QuickFolder.ExcludedBundleIDs.v1"
    private var timer: Timer?
    private var lastTargetPID: pid_t?
    private var observedPID: pid_t?
    private var axObserver: AXObserver?
    private weak var inProcessTestPanel: NSSavePanel?
    private let workerQueue = DispatchQueue(label: "com.hunglx.QuickFolder.SavePanelDetector", qos: .userInitiated)
    private var isPollingInFlight = false
    private var lastAutoJumpedSessionKey: String?

    private init() {
        if let savedExcluded = UserDefaults.standard.stringArray(forKey: excludedAppsKey) {
            self.excludedBundleIDs = Set(savedExcluded)
        }
        checkAccessibilityPermission(prompt: false)
        startMonitoring()
    }

    func isExcluded(_ appKey: String) -> Bool {
        excludedBundleIDs.contains(appKey)
    }

    func toggleExcludedApp(_ appKey: String) {
        if excludedBundleIDs.contains(appKey) {
            excludedBundleIDs.remove(appKey)
        } else {
            excludedBundleIDs.insert(appKey)
            if activePanel?.appIdentifierKey == appKey {
                activePanel = nil
            }
        }
        UserDefaults.standard.set(Array(excludedBundleIDs), forKey: excludedAppsKey)
    }

    @discardableResult
    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        self.isAccessibilityTrusted = trusted
        if trusted {
            attachAXObserverToFrontmostApp()
        }
        return trusted
    }

    func registerInProcessTestPanel(_ panel: NSSavePanel?) {
        self.inProcessTestPanel = panel
        pollNow()
    }

    func startMonitoring() {
        attachAXObserverToFrontmostApp()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.attachAXObserverToFrontmostApp()
                self?.pollNow()
            }
        }

        // Low-frequency fallback safety check (2.5s) since AXObserver + NSWorkspace handle instant events
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if self.activePanel == nil && self.inProcessTestPanel == nil &&
                   (frontBundle == "com.apple.finder" || frontBundle == Bundle.main.bundleIdentifier) {
                    return
                }
                self.pollNow()
            }
        }
    }

    fileprivate func handleAXEvent() {
        pollNow()
        // Re-check once after 120ms to catch sheet slide-in final bounds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.pollNow()
        }
    }

    private func attachAXObserverToFrontmostApp() {
        guard AXIsProcessTrusted(),
              let frontApp = NSWorkspace.shared.frontmostApplication else {
            detachAXObserver()
            return
        }

        let pid = frontApp.processIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        if pid == myPID || frontApp.bundleIdentifier == "com.apple.finder" {
            detachAXObserver()
            return
        }

        if observedPID == pid, axObserver != nil {
            return
        }

        detachAXObserver()

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &newObserver) == .success,
              let observer = newObserver else {
            return
        }

        let axApp = AXUIElementCreateApplication(pid)
        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXSheetCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification
        ]

        for notif in notifications {
            AXObserverAddNotification(observer, axApp, notif as CFString, nil)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.axObserver = observer
        self.observedPID = pid
    }

    private func detachAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        observedPID = nil
    }

    func pollNow() {
        // 1. Check if our built-in Test Save Panel is currently visible on the main thread
        if let testPanel = inProcessTestPanel, testPanel.isVisible {
            let myPID = ProcessInfo.processInfo.processIdentifier
            self.lastTargetPID = myPID
            self.activePanel = DetectedSavePanel(
                appPID: myPID,
                appName: "QuickFolder (Thử nghiệm)",
                appBundleID: Bundle.main.bundleIdentifier,
                cocoaFrame: testPanel.frame,
                isSheet: testPanel.sheetParent != nil
            )
            return
        }

        // Keep panel steady while FolderNavigator is sending Cmd+Shift+G
        if isNavigatingFolder, activePanel != nil {
            return
        }

        guard !isPollingInFlight else { return }
        isPollingInFlight = true

        let myPID = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier
        let prevPID = self.lastTargetPID
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1440
        let excludedSnapshot = self.excludedBundleIDs

        // Cache bundleIDs of running apps on MainActor
        var bundleByPID: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                bundleByPID[app.processIdentifier] = bid
            }
        }

        // Run all WindowServer & Accessibility IPC off the main thread so the UI never blocks
        workerQueue.async { [weak self] in
            let trusted = AXIsProcessTrusted()
            let detected = Self.performBackgroundDetection(
                myPID: myPID,
                frontPID: frontPID,
                prevPID: prevPID,
                trusted: trusted,
                primaryScreenHeight: primaryScreenHeight,
                bundleByPID: bundleByPID,
                excludedKeys: excludedSnapshot
            )

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPollingInFlight = false
                if self.isAccessibilityTrusted != trusted {
                    self.isAccessibilityTrusted = trusted
                }
                if self.isNavigatingFolder, self.activePanel != nil {
                    return
                }
                if let testPanel = self.inProcessTestPanel, testPanel.isVisible {
                    return
                }
                if let detected = detected {
                    let wasNil = (self.activePanel == nil)
                    let isNewApp = (self.activePanel?.appPID != detected.appPID)
                    self.lastTargetPID = detected.appPID
                    if self.activePanel != detected {
                        self.activePanel = detected
                        if isNewApp || wasNil {
                            FolderManager.shared.refreshNow()
                            self.triggerPerAppAutoJumpIfNeeded(for: detected)
                        }
                    }
                } else {
                    self.lastAutoJumpedSessionKey = nil
                    if self.activePanel != nil {
                        self.activePanel = nil
                    }
                }
            }
        }
    }

    private func triggerPerAppAutoJumpIfNeeded(for panel: DetectedSavePanel) {
        guard FolderManager.shared.autoJumpToAppDefault,
              let defaultItem = FolderManager.shared.defaultFolderItem(for: panel.appIdentifierKey) else {
            return
        }
        let sessionKey = "\(panel.appPID):\(defaultItem.path)"
        guard lastAutoJumpedSessionKey != sessionKey else { return }
        lastAutoJumpedSessionKey = sessionKey

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard self.activePanel?.appPID == panel.appPID else { return }
            FolderNavigator.shared.selectFolder(defaultItem)
        }
    }

    // MARK: - Background Thread Detection (Zero Main-Thread Blocking & Zero False Positives)

    nonisolated private static let officialPanelIdentifiers: Set<String> = [
        "save-panel",
        "open-panel",
        "nssavepanel",
        "nsopenpanel"
    ]

    nonisolated private static let rejectedDialogKeywords: [String] = [
        "cài đặt",
        "settings",
        "preferences",
        "tuỳ chỉnh",
        "tùy chỉnh",
        "print",
        "page setup",
        "about ",
        "giới thiệu",
        "kiểm tra cập nhật",
        "software update",
        "sign in",
        "đăng nhập"
    ]

    nonisolated private static func isOfficialSaveOpenIdentifier(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return officialPanelIdentifiers.contains(lower)
    }

    nonisolated private static func performBackgroundDetection(
        myPID: pid_t,
        frontPID: pid_t?,
        prevPID: pid_t?,
        trusted: Bool,
        primaryScreenHeight: CGFloat,
        bundleByPID: [pid_t: String],
        excludedKeys: Set<String>
    ) -> DetectedSavePanel? {
        // Never guess from window geometry without Accessibility: prevents all false positives on normal sheets/modals
        guard trusted, let frontPID else {
            return nil
        }

        let frontBundle = bundleByPID[frontPID]
        if frontBundle == "com.apple.finder" {
            return nil
        }

        // Determine the single active target app PID (either frontmost app, or previous app while interacting with QuickFolder / openAndSavePanelService)
        let targetPID: pid_t
        if frontPID == myPID || frontBundle == "com.apple.appkit.xpc.openAndSavePanelService" {
            guard let prevPID,
                  prevPID != myPID,
                  bundleByPID[prevPID] != "com.apple.finder" else {
                return nil
            }
            targetPID = prevPID
        } else {
            targetPID = frontPID
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var onScreenRects: [CGRect] = []
        var appName: String?

        for entry in windowList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid == targetPID else {
                continue
            }
            if appName == nil, let name = entry[kCGWindowOwnerName as String] as? String {
                appName = name
            }
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
               let cgRect = CGRect(dictionaryRepresentation: boundsDict),
               cgRect.width >= 280, cgRect.height >= 130 {
                onScreenRects.append(cgRect)
            }
        }

        // Target app must currently have at least one visible window on screen
        guard !onScreenRects.isEmpty else {
            return nil
        }

        let resolvedName = appName ?? "App"
        let bundleID = bundleByPID[targetPID]
        if let bundleID, excludedKeys.contains(bundleID) {
            return nil
        }
        if excludedKeys.contains(resolvedName) {
            return nil
        }

        return inspectPIDForSavePanelAX(
            pid: targetPID,
            appName: resolvedName,
            bundleID: bundleID,
            onScreenQuartzRects: onScreenRects,
            primaryScreenHeight: primaryScreenHeight
        )
    }

    nonisolated private static func inspectPIDForSavePanelAX(
        pid: pid_t,
        appName: String,
        bundleID: String?,
        onScreenQuartzRects: [CGRect],
        primaryScreenHeight: CGFloat
    ) -> DetectedSavePanel? {
        let appElement = AXUIElementCreateApplication(pid)
        // Strict 50ms messaging timeout so slow/busy apps never stall our background worker
        AXUIElementSetMessagingTimeout(appElement, 0.05)

        var candidateWindows: [AXUIElement] = []
        if let focusedWin = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute) {
            candidateWindows.append(focusedWin)
        }
        if let mainWin = copyAXElement(appElement, attribute: kAXMainWindowAttribute),
           !candidateWindows.contains(where: { CFEqual($0, mainWin) }) {
            candidateWindows.append(mainWin)
        }
        if let allWins = copyAXElements(appElement, attribute: kAXWindowsAttribute) {
            for win in allWins.prefix(6) {
                if !candidateWindows.contains(where: { CFEqual($0, win) }) {
                    candidateWindows.append(win)
                }
            }
        }

        for window in candidateWindows {
            // 1. Official AppKit NSSavePanel / NSOpenPanel identifier directly on the window/sheet
            let winID = copyString(window, attribute: "AXIdentifier") ?? ""
            if isOfficialSaveOpenIdentifier(winID) {
                if let (quartzRect, cocoaRect) = getFrames(of: window, primaryScreenHeight: primaryScreenHeight),
                   isRectOnScreen(quartzRect, candidates: onScreenQuartzRects) {
                    let role = copyString(window, attribute: kAXRoleAttribute) ?? ""
                    return DetectedSavePanel(
                        appPID: pid,
                        appName: appName,
                        appBundleID: bundleID,
                        cocoaFrame: cocoaRect,
                        isSheet: role == "AXSheet"
                    )
                }
            }

            // 2. Attached Save/Open AXSheet inside this window (ignores generic SwiftUI/Settings/Print sheets!)
            if let sheet = findDirectSaveOrOpenSheet(in: window) {
                if let (quartzRect, cocoaRect) = getFrames(of: sheet, primaryScreenHeight: primaryScreenHeight) ??
                                                 getFrames(of: window, primaryScreenHeight: primaryScreenHeight),
                   isRectOnScreen(quartzRect, candidates: onScreenQuartzRects) {
                    return DetectedSavePanel(
                        appPID: pid,
                        appName: appName,
                        appBundleID: bundleID,
                        cocoaFrame: cocoaRect,
                        isSheet: true
                    )
                }
            }

            // 3. Standalone modal dialog from custom frameworks (Qt/Java/Office custom dialogs)
            let subrole = copyString(window, attribute: kAXSubroleAttribute) ?? ""
            if subrole == "AXDialog" || subrole == "AXSystemDialog" {
                if isDialogConfirmedSaveOrOpen(window),
                   let (quartzRect, cocoaRect) = getFrames(of: window, primaryScreenHeight: primaryScreenHeight),
                   isRectOnScreen(quartzRect, candidates: onScreenQuartzRects) {
                    return DetectedSavePanel(
                        appPID: pid,
                        appName: appName,
                        appBundleID: bundleID,
                        cocoaFrame: cocoaRect,
                        isSheet: false
                    )
                }
            }
        }

        return nil
    }

    nonisolated private static func isRectOnScreen(_ rect: CGRect, candidates: [CGRect]) -> Bool {
        for c in candidates {
            if c.insetBy(dx: -24, dy: -24).intersects(rect) {
                return true
            }
        }
        return false
    }

    nonisolated private static func findDirectSaveOrOpenSheet(in window: AXUIElement) -> AXUIElement? {
        if let sheets = copyAXElements(window, attribute: "AXSheets") {
            for sheet in sheets {
                if isSheetConfirmedSaveOrOpen(sheet) {
                    return sheet
                }
            }
        }

        if let children = copyAXElements(window, attribute: kAXChildrenAttribute) {
            for child in children.prefix(20) {
                let role = copyString(child, attribute: kAXRoleAttribute) ?? ""
                let ident = copyString(child, attribute: "AXIdentifier") ?? ""
                if isOfficialSaveOpenIdentifier(ident) {
                    return child
                }
                if role == "AXSheet" && isSheetConfirmedSaveOrOpen(child) {
                    return child
                }
                // Check 1 level inside container groups in case a sheet is wrapped
                if role == "AXGroup" || role == "AXSplitGroup",
                   let subChildren = copyAXElements(child, attribute: kAXChildrenAttribute) {
                    for sub in subChildren.prefix(12) {
                        let subRole = copyString(sub, attribute: kAXRoleAttribute) ?? ""
                        let subIdent = copyString(sub, attribute: "AXIdentifier") ?? ""
                        if isOfficialSaveOpenIdentifier(subIdent) {
                            return sub
                        }
                        if subRole == "AXSheet" && isSheetConfirmedSaveOrOpen(sub) {
                            return sub
                        }
                    }
                }
            }
        }

        return nil
    }

    nonisolated private static func isSheetConfirmedSaveOrOpen(_ sheet: AXUIElement) -> Bool {
        let ident = copyString(sheet, attribute: "AXIdentifier") ?? ""
        if isOfficialSaveOpenIdentifier(ident) {
            return true
        }
        return isDialogConfirmedSaveOrOpen(sheet)
    }

    nonisolated private static func isDialogConfirmedSaveOrOpen(_ dialog: AXUIElement) -> Bool {
        let ident = copyString(dialog, attribute: "AXIdentifier") ?? ""
        if isOfficialSaveOpenIdentifier(ident) {
            return true
        }

        let dialogTitle = (copyString(dialog, attribute: kAXTitleAttribute) ?? "").lowercased()
        if !dialogTitle.isEmpty && rejectedDialogKeywords.contains(where: { dialogTitle.contains($0) }) {
            return false
        }

        // Shallow inspection (max 45 elements, depth <= 4) requiring genuine file-picker controls
        var queue: [(AXUIElement, Int)] = [(dialog, 0)]
        var visited = 0
        let maxVisited = 45
        let maxDepth = 4

        var hasFileActionButton = false
        var hasCancelButton = false
        var hasColumnBrowser = false
        var hasNewFolderButton = false
        var hasFileFieldLabel = false

        let fileActionTitles: Set<String> = [
            "save", "open", "choose", "choose folder", "export", "import", "upload", "select",
            "lưu", "mở", "chọn", "chọn thư mục", "xuất", "nhập", "tải lên"
        ]
        let cancelTitles: Set<String> = ["cancel", "huỷ", "hủy", "bỏ qua"]
        let newFolderTitles: Set<String> = [
            "new folder", "new folder…", "new folder...",
            "thư mục mới", "thư mục mới…", "thư mục mới...",
            "create folder", "tạo thư mục"
        ]
        let fileFieldLabels: Set<String> = [
            "save as:", "save as", "where:", "export as:", "file name:",
            "lưu thành:", "lưu dưới dạng:", "vị trí:", "tên tệp:", "tên file:"
        ]

        while !queue.isEmpty && visited < maxVisited {
            let (elem, depth) = queue.removeFirst()
            visited += 1

            let eid = (copyString(elem, attribute: "AXIdentifier") ?? "").lowercased()
            if isOfficialSaveOpenIdentifier(eid) ||
               eid == "saveasnametextfield" ||
               eid == "cmd_new_folder" ||
               eid == "nsnavsidebar" ||
               eid.contains("finderkit") {
                return true
            }
            if eid == "cancelbutton" {
                hasCancelButton = true
            }

            let role = copyString(elem, attribute: kAXRoleAttribute) ?? ""
            if role == "AXBrowser" {
                hasColumnBrowser = true
            } else if role == "AXButton" {
                let title = (copyString(elem, attribute: kAXTitleAttribute) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if newFolderTitles.contains(title) {
                    hasNewFolderButton = true
                } else if fileActionTitles.contains(title) {
                    hasFileActionButton = true
                } else if cancelTitles.contains(title) {
                    hasCancelButton = true
                }
            } else if role == "AXStaticText" {
                let rawText = copyString(elem, attribute: kAXValueAttribute)
                    ?? copyString(elem, attribute: kAXTitleAttribute)
                    ?? ""
                let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if depth <= 2 && !text.isEmpty && rejectedDialogKeywords.contains(where: { text.hasPrefix($0) }) {
                    return false
                }
                if fileFieldLabels.contains(text) {
                    hasFileFieldLabel = true
                }
            }

            if hasFileActionButton && hasCancelButton && (hasColumnBrowser || hasNewFolderButton || hasFileFieldLabel) {
                return true
            }

            if depth < maxDepth, let children = copyAXElements(elem, attribute: kAXChildrenAttribute) {
                for child in children.prefix(12) {
                    queue.append((child, depth + 1))
                }
            }
        }

        return false
    }

    // MARK: - Coordinate Conversion (Quartz Top-Left -> AppKit Bottom-Left)

    nonisolated private static func getFrames(of element: AXUIElement, primaryScreenHeight: CGFloat) -> (CGRect, NSRect)? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef else {
            return nil
        }

        var cgPoint = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &cgPoint),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &cgSize),
              cgSize.width >= 260, cgSize.height >= 120 else {
            return nil
        }

        let quartzRect = CGRect(origin: cgPoint, size: cgSize)
        return (quartzRect, convertQuartzToCocoa(quartzRect, primaryScreenHeight: primaryScreenHeight))
    }

    nonisolated private static func convertQuartzToCocoa(_ cgRect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        let cocoaY = primaryScreenHeight - cgRect.origin.y - cgRect.size.height
        return NSRect(x: cgRect.origin.x, y: cocoaY, width: cgRect.size.width, height: cgRect.size.height)
    }

    // MARK: - AX Attribute Helpers

    nonisolated private static func copyAXElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let val = ref else {
            return nil
        }
        return (val as! AXUIElement)
    }

    nonisolated private static func copyAXElements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement] else {
            return nil
        }
        return array
    }

    nonisolated private static func copyString(_ element: AXUIElement, attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let str = ref as? String else {
            return nil
        }
        return str
    }
}
