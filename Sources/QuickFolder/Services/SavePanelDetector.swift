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

        // Low-frequency fallback safety check (1.2s instead of 0.3s) since AXObserver handles instant events
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
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

    // MARK: - Background Thread Detection (Zero Main-Thread Blocking)

    nonisolated private static func performBackgroundDetection(
        myPID: pid_t,
        frontPID: pid_t?,
        prevPID: pid_t?,
        trusted: Bool,
        primaryScreenHeight: CGFloat,
        bundleByPID: [pid_t: String],
        excludedKeys: Set<String>
    ) -> DetectedSavePanel? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Collect on-screen layer-0 windows and PIDs in front-to-back order
        var orderedPIDs: [pid_t] = []
        var seenPIDs: Set<pid_t> = [myPID]
        var windowsByPID: [pid_t: [CGRect]] = [:]
        var ownerNameByPID: [pid_t: String] = [:]

        if let frontPID, !seenPIDs.contains(frontPID) {
            orderedPIDs.append(frontPID)
            seenPIDs.insert(frontPID)
        }
        if let prevPID, !seenPIDs.contains(prevPID) {
            orderedPIDs.append(prevPID)
            seenPIDs.insert(prevPID)
        }

        for entry in windowList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID else {
                continue
            }
            if let name = entry[kCGWindowOwnerName as String] as? String, ownerNameByPID[pid] == nil {
                ownerNameByPID[pid] = name
            }
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
               let cgRect = CGRect(dictionaryRepresentation: boundsDict),
               cgRect.width >= 380, cgRect.height >= 200 {
                windowsByPID[pid, default: []].append(cgRect)
                if !seenPIDs.contains(pid) {
                    seenPIDs.insert(pid)
                    orderedPIDs.append(pid)
                }
            }
        }

        // Only inspect the top 4 candidate apps (excluding user-excluded apps)
        let candidatePIDs = orderedPIDs.filter { pid in
            let bID = bundleByPID[pid]
            let name = ownerNameByPID[pid] ?? "App"
            if let bID, excludedKeys.contains(bID) { return false }
            if excludedKeys.contains(name) { return false }
            return true
        }.prefix(4)

        // Method A: Fast Accessibility inspection (only checks AXSheet or AXDialog windows, never traverses standard windows!)
        if trusted {
            for pid in candidatePIDs {
                let appName = ownerNameByPID[pid] ?? "App"
                let bundleID = bundleByPID[pid]
                if let detected = inspectPIDForSavePanelAX(
                    pid: pid,
                    appName: appName,
                    bundleID: bundleID,
                    primaryScreenHeight: primaryScreenHeight
                ) {
                    return detected
                }
            }
        }

        // Method B: WindowServer geometry fallback for Save/Open sheets
        for pid in candidatePIDs {
            guard let rects = windowsByPID[pid], rects.count >= 2 else { continue }
            let frontRect = rects[0]
            let parentRect = rects[1]

            let isSheetSized = frontRect.width >= 500 && frontRect.width <= 1150 &&
                               frontRect.height >= 320 && frontRect.height <= 820 &&
                               frontRect.width < parentRect.width &&
                               frontRect.height < parentRect.height
            let horizontalCenterDiff = abs(frontRect.midX - parentRect.midX)

            if isSheetSized && horizontalCenterDiff <= 40 && parentRect.intersects(frontRect) {
                let cocoaFrame = convertQuartzToCocoa(frontRect, primaryScreenHeight: primaryScreenHeight)
                return DetectedSavePanel(
                    appPID: pid,
                    appName: ownerNameByPID[pid] ?? "App",
                    appBundleID: bundleByPID[pid],
                    cocoaFrame: cocoaFrame,
                    isSheet: true
                )
            }
        }

        return nil
    }

    nonisolated private static func inspectPIDForSavePanelAX(
        pid: pid_t,
        appName: String,
        bundleID: String?,
        primaryScreenHeight: CGFloat
    ) -> DetectedSavePanel? {
        let appElement = AXUIElementCreateApplication(pid)
        // Set a strict 40ms messaging timeout so slow/busy apps never stall our background worker
        AXUIElementSetMessagingTimeout(appElement, 0.04)

        var candidateWindows: [AXUIElement] = []
        if let focusedWin = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute) {
            candidateWindows.append(focusedWin)
        }
        if let allWins = copyAXElements(appElement, attribute: kAXWindowsAttribute) {
            for win in allWins.prefix(4) {
                if !candidateWindows.contains(where: { CFEqual($0, win) }) {
                    candidateWindows.append(win)
                }
            }
        }

        for window in candidateWindows {
            // 1. Check if window itself has AXIdentifier "save-panel" or "open-panel"
            let winID = (copyString(window, attribute: "AXIdentifier") ?? "").lowercased()
            if winID == "save-panel" || winID == "open-panel" || winID == "nssavepanel" || winID == "nsopenpanel" {
                if let cocoaRect = getCocoaFrame(of: window, primaryScreenHeight: primaryScreenHeight) {
                    return DetectedSavePanel(
                        appPID: pid,
                        appName: appName,
                        appBundleID: bundleID,
                        cocoaFrame: cocoaRect,
                        isSheet: false
                    )
                }
            }

            // 2. Check immediate AXSheets or direct AXSheet children of this window (O(1) depth)
            if let sheet = findDirectSaveOrOpenSheet(in: window) {
                if let cocoaRect = getCocoaFrame(of: sheet, primaryScreenHeight: primaryScreenHeight) ??
                                   getCocoaFrame(of: window, primaryScreenHeight: primaryScreenHeight) {
                    return DetectedSavePanel(
                        appPID: pid,
                        appName: appName,
                        appBundleID: bundleID,
                        cocoaFrame: cocoaRect,
                        isSheet: true
                    )
                }
            }

            // 3. Only if the window is a modal dialog (AXDialog / AXSystemDialog, NOT AXStandardWindow),
            // check its shallow controls
            let subrole = copyString(window, attribute: kAXSubroleAttribute) ?? ""
            if subrole == "AXDialog" || subrole == "AXSystemDialog" {
                if isDialogConfirmedSaveOrOpen(window) {
                    if let cocoaRect = getCocoaFrame(of: window, primaryScreenHeight: primaryScreenHeight) {
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
        }

        return nil
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
                let ident = (copyString(child, attribute: "AXIdentifier") ?? "").lowercased()
                if ident == "save-panel" || ident == "open-panel" {
                    return child
                }
                if role == "AXSheet" && isSheetConfirmedSaveOrOpen(child) {
                    return child
                }
            }
        }

        return nil
    }

    nonisolated private static func isSheetConfirmedSaveOrOpen(_ sheet: AXUIElement) -> Bool {
        let ident = (copyString(sheet, attribute: "AXIdentifier") ?? "").lowercased()
        if ident == "save-panel" || ident == "open-panel" || ident == "nssavepanel" || ident == "nsopenpanel" {
            return true
        }
        return isDialogConfirmedSaveOrOpen(sheet)
    }

    nonisolated private static func isDialogConfirmedSaveOrOpen(_ dialog: AXUIElement) -> Bool {
        let ident = (copyString(dialog, attribute: "AXIdentifier") ?? "").lowercased()
        if ident == "save-panel" || ident == "open-panel" || ident == "nssavepanel" || ident == "nsopenpanel" {
            return true
        }

        // Shallow inspection (max 35 elements, depth <= 3)
        var queue: [(AXUIElement, Int)] = [(dialog, 0)]
        var visited = 0
        let maxVisited = 35
        let maxDepth = 3

        var hasOK = false
        var hasCancel = false
        var hasBrowserControl = false

        while !queue.isEmpty && visited < maxVisited {
            let (elem, depth) = queue.removeFirst()
            visited += 1

            let eid = (copyString(elem, attribute: "AXIdentifier") ?? "").lowercased()
            if eid == "save-panel" || eid == "open-panel" || eid == "saveasnametextfield" || eid == "cmd_new_folder" || eid.contains("finderkit") {
                return true
            }
            if eid == "okbutton" { hasOK = true }
            if eid == "cancelbutton" { hasCancel = true }

            let role = copyString(elem, attribute: kAXRoleAttribute) ?? ""
            if role == "AXSplitGroup" || role == "AXBrowser" || role == "AXOutline" || role == "AXPopUpButton" {
                hasBrowserControl = true
            } else if role == "AXButton" {
                let title = (copyString(elem, attribute: kAXTitleAttribute) ?? "").lowercased()
                if title == "new folder" || title == "thư mục mới" {
                    return true
                }
                if ["save", "open", "choose", "export", "import", "lưu", "mở", "chọn"].contains(title) {
                    hasOK = true
                } else if ["cancel", "huỷ", "hủy"].contains(title) {
                    hasCancel = true
                }
            }

            if hasOK && hasCancel && hasBrowserControl {
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

    nonisolated private static func getCocoaFrame(of element: AXUIElement, primaryScreenHeight: CGFloat) -> NSRect? {
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
              cgSize.width > 100, cgSize.height > 100 else {
            return nil
        }

        return convertQuartzToCocoa(CGRect(origin: cgPoint, size: cgSize), primaryScreenHeight: primaryScreenHeight)
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
