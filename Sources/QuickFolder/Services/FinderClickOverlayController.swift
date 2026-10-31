import Foundation
import AppKit
import SwiftUI
import Combine

private final class FinderHighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var onPanelClicked: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            onPanelClicked?()
            return
        }
        super.sendEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        onPanelClicked?()
    }
}

private struct FinderHighlightOverlayView: View {
    let folderName: String
    let displayPath: String
    let onSelect: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.88), lineWidth: 3)
                )

            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Click để chọn thư mục Finder này: “\(folderName)”")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                    Text(displayPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
            )
            .padding(.top, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

/// Implements Default Folder X style "Finder-Click":
/// While a Save/Open dialog is active, hovering over any visible Finder window highlights it
/// and allows 1-click selection to jump the Save dialog directly to that Finder window's folder.
@MainActor
final class FinderClickOverlayController: ObservableObject {
    static let shared = FinderClickOverlayController()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            updateMonitoringState()
        }
    }

    private let enabledKey = "QuickFolder.EnableFinderClick.v1"
    private var highlightPanel: FinderHighlightPanel?
    private var hoveredFinderWindow: OpenFinderWindowInfo?
    private var mouseMoveMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastHitTestTime: TimeInterval = 0

    var overlayWindowNumber: Int? {
        highlightPanel?.windowNumber
    }

    private init() {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            self.isEnabled = true
            UserDefaults.standard.set(true, forKey: enabledKey)
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        }

        SavePanelDetector.shared.$activePanel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMonitoringState()
            }
            .store(in: &cancellables)
    }

    private func updateMonitoringState() {
        let shouldMonitor = isEnabled && (SavePanelDetector.shared.activePanel != nil)
        if shouldMonitor {
            startMouseMonitorIfNeeded()
        } else {
            stopMouseMonitor()
            hideOverlay()
        }
    }

    private func startMouseMonitorIfNeeded() {
        guard mouseMoveMonitor == nil else { return }
        FolderManager.shared.refreshNow()
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
    }

    private func handleMouseMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHitTestTime >= 0.045 else { return } // Throttle ~22fps
        lastHitTestTime = now

        guard isEnabled,
              SavePanelDetector.shared.activePanel != nil,
              !SavePanelDetector.shared.isNavigatingFolder else {
            hideOverlay()
            return
        }

        let cocoaPoint = NSEvent.mouseLocation
        let finderWindows = FolderManager.shared.openFinderWindowInfos
        guard !finderWindows.isEmpty else {
            hideOverlay()
            return
        }

        // Convert Cocoa point to Quartz point (origin top-left of primary screen)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        let quartzPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)

        let ignoredOverlayWinNum = highlightPanel?.windowNumber ?? -1

        guard let matchedInfo = Self.hitTestExposedFinderWindow(
            quartzPoint: quartzPoint,
            cocoaPoint: cocoaPoint,
            finderWindows: finderWindows,
            ignoredWindowNumber: ignoredOverlayWinNum
        ) else {
            hideOverlay()
            return
        }

        showOverlay(for: matchedInfo)
    }

    private func showOverlay(for info: OpenFinderWindowInfo) {
        guard let frame = info.cocoaFrame else { return }
        if hoveredFinderWindow == info, highlightPanel?.isVisible == true {
            return
        }
        hoveredFinderWindow = info

        let panel: FinderHighlightPanel
        if let existing = highlightPanel {
            panel = existing
        } else {
            let p = FinderHighlightPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.hidesOnDeactivate = false
            self.highlightPanel = p
            panel = p
        }

        let item = FolderItem(path: info.path, source: .openFinderWindow(windowIndex: 1))
        let selectAction: () -> Void = { [weak self] in
            self?.hideOverlay()
            FolderNavigator.shared.selectFolder(item)
        }
        panel.onPanelClicked = selectAction

        let rootView = FinderHighlightOverlayView(
            folderName: item.name,
            displayPath: item.displayPath,
            onSelect: selectAction
        )
        panel.contentView = NSHostingView(rootView: rootView)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        hoveredFinderWindow = nil
        if let panel = highlightPanel, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    nonisolated private static func hitTestExposedFinderWindow(
        quartzPoint: CGPoint,
        cocoaPoint: NSPoint,
        finderWindows: [OpenFinderWindowInfo],
        ignoredWindowNumber: Int
    ) -> OpenFinderWindowInfo? {
        guard let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier else {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Walk front-to-back in z-order: find the topmost window containing `quartzPoint`
        for entry in rawList {
            if let winNum = entry[kCGWindowNumber as String] as? Int, winNum == ignoredWindowNumber {
                continue
            }
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  layer >= 0 && layer <= 20, // Normal windows, sheets, modal panels, QuickFolder sidebar
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width >= 120, cgRect.height >= 120 else {
                continue
            }

            if cgRect.contains(quartzPoint) {
                guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                      ownerPID == finderPID else {
                    // Another window (such as the Save dialog, parent document window, or QuickFolder sidebar) is in front at this cursor point!
                    return nil
                }

                // Cursor is directly over an exposed Finder window! Match it to our OpenFinderWindowInfo list:
                if let exact = finderWindows.first(where: { info in
                    guard let f = info.cocoaFrame else { return false }
                    return f.contains(cocoaPoint)
                }) {
                    return exact
                }
                return finderWindows.first
            }
        }
        return nil
    }
}
