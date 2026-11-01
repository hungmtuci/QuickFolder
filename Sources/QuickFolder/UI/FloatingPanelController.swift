import Foundation
import AppKit
import SwiftUI
import Combine

final class QuickFolderNSPanel: NSPanel {
    var allowKeyFocus: Bool = false
    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125 { // Down arrow
            FloatingPanelController.shared.moveSelection(down: true)
            return
        } else if event.keyCode == 126 { // Up arrow
            FloatingPanelController.shared.moveSelection(down: false)
            return
        } else if event.keyCode == 36 { // Return / Enter
            if FloatingPanelController.shared.confirmCurrentSelection() {
                return
            }
        } else if event.keyCode == 53 { // Escape
            if FloatingPanelController.shared.handleEscape() {
                return
            }
        }
        super.keyDown(with: event)
    }
}

enum DisplayDensity: String, CaseIterable {
    case comfortable = "comfortable"
    case compact = "compact"

    var title: String {
        switch self {
        case .comfortable: return "Thoải mái (Comfortable)"
        case .compact: return "Gọn gàng (Compact)"
        }
    }
}

enum DockSide: String, CaseIterable {
    case right = "right"
    case left = "left"

    var title: String {
        switch self {
        case .right: return "Bên phải hộp thoại Save/Open"
        case .left: return "Bên trái hộp thoại Save/Open"
        }
    }
}

enum SidebarTab: String, CaseIterable {
    case all = "all"
    case openFinder = "finder"
    case favorites = "favorites"
    case recents = "recents"
    case recentFiles = "files"

    var title: String {
        switch self {
        case .all: return "Tất cả thư mục"
        case .openFinder: return "Cửa sổ Finder đang mở"
        case .favorites: return "Thư mục Yêu thích"
        case .recents: return "Thư mục Gần đây"
        case .recentFiles: return "Tệp đã lưu gần đây"
        }
    }
}

@MainActor
final class FloatingPanelController: ObservableObject {
    static let shared = FloatingPanelController()

    @Published var searchText: String = ""
    @Published var hoveredID: String?
    @Published var selectedIndex: Int? = nil
    @Published var isDropTargeted: Bool = false
    @Published var selectedTab: SidebarTab = .all {
        didSet {
            selectedIndex = nil
        }
    }
    @Published var isCompactBezel: Bool = false {
        didSet {
            if let active = SavePanelDetector.shared.activePanel {
                positionBeside(savePanelFrame: active.cocoaFrame)
            }
        }
    }

    @Published var displayDensity: DisplayDensity {
        didSet {
            UserDefaults.standard.set(displayDensity.rawValue, forKey: "QuickFolder.DisplayDensity")
        }
    }

    @Published var dockSide: DockSide {
        didSet {
            UserDefaults.standard.set(dockSide.rawValue, forKey: "QuickFolder.DockSide")
            if let active = SavePanelDetector.shared.activePanel {
                positionBeside(savePanelFrame: active.cocoaFrame)
            }
        }
    }

    @Published var hideFromDock: Bool {
        didSet {
            UserDefaults.standard.set(hideFromDock, forKey: "QuickFolder.HideFromDock")
            applyDockVisibilityPolicy()
        }
    }

    private var panel: QuickFolderNSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var isManuallyHiddenForCurrentDialog = false
    private var isManuallySummoned = false

    var currentWidth: CGFloat {
        isCompactBezel ? 58 : 340
    }

    private init() {
        let savedSide = UserDefaults.standard.string(forKey: "QuickFolder.DockSide") ?? DockSide.right.rawValue
        self.dockSide = DockSide(rawValue: savedSide) ?? .right

        let savedDensity = UserDefaults.standard.string(forKey: "QuickFolder.DisplayDensity") ?? DisplayDensity.comfortable.rawValue
        self.displayDensity = DisplayDensity(rawValue: savedDensity) ?? .comfortable

        if UserDefaults.standard.object(forKey: "QuickFolder.HideFromDock") == nil {
            self.hideFromDock = true
            UserDefaults.standard.set(true, forKey: "QuickFolder.HideFromDock")
        } else {
            self.hideFromDock = UserDefaults.standard.bool(forKey: "QuickFolder.HideFromDock")
        }
        setupPanel()
        bindDetector()
    }

    // MARK: - Keyboard Navigation (Arrow Up / Down / Enter / Esc)

    func moveSelection(down: Bool) {
        let all = currentVisibleItems()
        guard !all.isEmpty else {
            selectedIndex = nil
            return
        }
        if let current = selectedIndex {
            if down {
                selectedIndex = min(current + 1, all.count - 1)
            } else {
                selectedIndex = max(current - 1, 0)
            }
        } else {
            selectedIndex = down ? 0 : (all.count - 1)
        }
    }

    func confirmCurrentSelection() -> Bool {
        let all = currentVisibleItems()
        guard let idx = selectedIndex, idx >= 0, idx < all.count else { return false }
        FolderNavigator.shared.selectFolder(all[idx])
        return true
    }

    func handleEscape() -> Bool {
        if !searchText.isEmpty {
            searchText = ""
            selectedIndex = nil
            return true
        }
        dismissPanelManually()
        return true
    }

    func currentVisibleItems() -> [FolderItem] {
        let fm = FolderManager.shared
        switch selectedTab {
        case .all:
            return fm.allQuickAccessFolders(searchQuery: searchText)
        case .openFinder:
            return fm.filtered(fm.openFinderFolders, query: searchText)
        case .favorites:
            let favs = fm.recentFolders.filter { fm.isPinned($0.path) }
            return fm.filtered(favs, query: searchText)
        case .recents:
            return fm.filtered(fm.recentFolders, query: searchText)
        case .recentFiles:
            return []
        }
    }

    func applyDockVisibilityPolicy() {
        let wasDashboardVisible = AppDelegate.shared?.isDashboardVisible ?? false
        NSApp.setActivationPolicy(hideFromDock ? .accessory : .regular)
        if wasDashboardVisible {
            DispatchQueue.main.async {
                AppDelegate.shared?.bringDashboardToFront()
            }
        }
    }

    private func setupPanel() {
        let contentRect = NSRect(x: 0, y: 0, width: 340, height: 520)
        let p = QuickFolderNSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.allowKeyFocus = false
        // Sit above modal sheets & dialogs so the sidebar is always visible right next to Save/Open panels
        p.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false

        let rootView = FloatingPanelView(panelController: self, onCloseRequested: { [weak self] in
            self?.dismissPanelManually()
        })
        p.contentView = NSHostingView(rootView: rootView)
        self.panel = p
    }

    func enableSearchFieldFocus() {
        guard let panel = panel else { return }
        panel.allowKeyFocus = true
        panel.makeKey()
    }

    func resignKeyForNavigation() {
        guard let panel = panel else { return }
        panel.allowKeyFocus = false
        if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    private func bindDetector() {
        SavePanelDetector.shared.$activePanel
            .receive(on: RunLoop.main)
            .sink { [weak self] detected in
                guard let self = self else { return }
                if let detected = detected {
                    self.isManuallySummoned = false
                    guard !self.isManuallyHiddenForCurrentDialog else { return }
                    self.positionBeside(savePanelFrame: detected.cocoaFrame)
                    self.showPanel()
                } else {
                    self.isManuallyHiddenForCurrentDialog = false
                    if !self.isManuallySummoned {
                        self.hidePanel()
                    }
                }
            }
            .store(in: &cancellables)
    }

    func toggleManualPanel() {
        guard let panel = panel else { return }
        if panel.isVisible {
            dismissPanelManually()
        } else {
            FolderManager.shared.refreshNow()
            isManuallyHiddenForCurrentDialog = false
            isCompactBezel = false
            if let active = SavePanelDetector.shared.activePanel {
                positionBeside(savePanelFrame: active.cocoaFrame)
            } else {
                isManuallySummoned = true
                positionNearMouseOrCenter()
            }
            showPanel()
        }
    }

    func dismissPanelManually() {
        if SavePanelDetector.shared.activePanel != nil {
            isManuallyHiddenForCurrentDialog = true
        }
        isManuallySummoned = false
        hidePanel()
    }

    var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

    private func showPanel() {
        guard let panel = panel else { return }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            HotKeyManager.shared.notifyPanelVisibilityChanged()
        }
    }

    private func hidePanel() {
        guard let panel = panel, panel.isVisible else { return }
        panel.allowKeyFocus = false
        panel.orderOut(nil)
        HotKeyManager.shared.notifyPanelVisibilityChanged()
    }

    func positionBeside(savePanelFrame: NSRect) {
        guard let panel = panel else { return }
        let centerPoint = NSPoint(x: savePanelFrame.midX, y: savePanelFrame.midY)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(centerPoint, $0.frame, false) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(savePanelFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = currentWidth
        let height = min(max(savePanelFrame.height, 380), min(720, visibleFrame.height - 24))
        let gap: CGFloat = 3
        var targetX: CGFloat

        switch dockSide {
        case .right:
            let rightCandidate = savePanelFrame.maxX + gap
            if rightCandidate + width <= visibleFrame.maxX {
                targetX = rightCandidate
            } else if savePanelFrame.minX - gap - width >= visibleFrame.minX {
                // Auto-flip to left side if right side overflows screen
                targetX = savePanelFrame.minX - gap - width
            } else {
                targetX = max(visibleFrame.minX + 4, visibleFrame.maxX - width - 4)
            }
        case .left:
            let leftCandidate = savePanelFrame.minX - gap - width
            if leftCandidate >= visibleFrame.minX {
                targetX = leftCandidate
            } else if savePanelFrame.maxX + gap + width <= visibleFrame.maxX {
                // Auto-flip to right side if left side overflows screen
                targetX = savePanelFrame.maxX + gap
            } else {
                targetX = visibleFrame.minX + 4
            }
        }

        var targetY = savePanelFrame.maxY - height
        // Clamp strictly within the target screen's visible frame (above Dock, below Menu Bar)
        targetY = max(visibleFrame.minY + 4, min(targetY, visibleFrame.maxY - height - 4))

        let newFrame = NSRect(x: round(targetX), y: round(targetY), width: width, height: round(height))
        if abs(panel.frame.origin.x - newFrame.origin.x) > 1 ||
           abs(panel.frame.origin.y - newFrame.origin.y) > 1 ||
           abs(panel.frame.width - newFrame.width) > 1 ||
           abs(panel.frame.height - newFrame.height) > 1 {
            panel.setFrame(newFrame, display: true)
        }
    }

    private func positionNearMouseOrCenter() {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = currentWidth
        let height: CGFloat = 500
        var x = mouse.x - width / 2
        var y = mouse.y - height / 2
        x = max(visibleFrame.minX + 12, min(x, visibleFrame.maxX - width - 12))
        y = max(visibleFrame.minY + 12, min(y, visibleFrame.maxY - height - 12))
        panel.setFrame(NSRect(x: round(x), y: round(y), width: width, height: height), display: true)
    }
}
