import Foundation
import AppKit
import SwiftUI
import Combine

final class QuickFolderNSPanel: NSPanel {
    var allowKeyFocus: Bool = false
    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { false }
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

    var title: String {
        switch self {
        case .all: return "Tất cả thư mục"
        case .openFinder: return "Cửa sổ Finder đang mở"
        case .favorites: return "Thư mục Yêu thích"
        case .recents: return "Thư mục Gần đây"
        }
    }
}

@MainActor
final class FloatingPanelController: ObservableObject {
    static let shared = FloatingPanelController()

    @Published var searchText: String = ""
    @Published var hoveredID: String?
    @Published var selectedTab: SidebarTab = .all
    @Published var isCompactBezel: Bool = false {
        didSet {
            if let active = SavePanelDetector.shared.activePanel {
                positionBeside(savePanelFrame: active.cocoaFrame)
            }
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
        if UserDefaults.standard.object(forKey: "QuickFolder.HideFromDock") == nil {
            self.hideFromDock = true
            UserDefaults.standard.set(true, forKey: "QuickFolder.HideFromDock")
        } else {
            self.hideFromDock = UserDefaults.standard.bool(forKey: "QuickFolder.HideFromDock")
        }
        setupPanel()
        bindDetector()
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
        }
    }

    private func hidePanel() {
        guard let panel = panel, panel.isVisible else { return }
        panel.allowKeyFocus = false
        panel.orderOut(nil)
    }

    func positionBeside(savePanelFrame: NSRect) {
        guard let panel = panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(savePanelFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = currentWidth
        let height = min(max(savePanelFrame.height, 380), min(680, visibleFrame.height - 20))
        let gap: CGFloat = 2
        var targetX: CGFloat

        switch dockSide {
        case .right:
            let rightCandidate = savePanelFrame.maxX + gap
            if rightCandidate + width <= visibleFrame.maxX {
                targetX = rightCandidate
            } else if savePanelFrame.minX - gap - width >= visibleFrame.minX {
                targetX = savePanelFrame.minX - gap - width
            } else {
                targetX = visibleFrame.maxX - width - 6
            }
        case .left:
            let leftCandidate = savePanelFrame.minX - gap - width
            if leftCandidate >= visibleFrame.minX {
                targetX = leftCandidate
            } else if savePanelFrame.maxX + gap + width <= visibleFrame.maxX {
                targetX = savePanelFrame.maxX + gap
            } else {
                targetX = visibleFrame.minX + 6
            }
        }

        var targetY = savePanelFrame.maxY - height
        targetY = max(visibleFrame.minY + 6, min(targetY, visibleFrame.maxY - height - 6))

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
