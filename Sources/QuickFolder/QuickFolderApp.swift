import SwiftUI
import AppKit

@main
struct QuickFolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem!
    private var dashboardWindow: NSWindow?

    var isDashboardVisible: Bool {
        dashboardWindow?.isVisible ?? false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Initialize core singletons
        _ = FolderManager.shared
        _ = SavePanelDetector.shared
        _ = FloatingPanelController.shared
        _ = FinderClickOverlayController.shared
        _ = LaunchAtLoginManager.shared

        // Apply Dock icon visibility policy (.accessory hides from Dock, .regular shows on Dock)
        FloatingPanelController.shared.applyDockVisibilityPolicy()

        setupStatusBarMenu()
        setupHotKeys()

        // Auto-open the dashboard after a GitHub self-update, explicit CLI flag, first launch, or manual user launch
        let didJustUpdate = UserDefaults.standard.bool(forKey: "QF_OpenDashboardAfterUpdate")
        if didJustUpdate {
            UserDefaults.standard.removeObject(forKey: "QF_OpenDashboardAfterUpdate")
        }
        let isStartupLaunch = CommandLine.arguments.contains("--startup")
        let shouldShowDashboard: Bool
        if didJustUpdate || CommandLine.arguments.contains("--open-dashboard") {
            shouldShowDashboard = true
        } else if isStartupLaunch {
            shouldShowDashboard = LaunchAtLoginManager.shared.openDashboardOnStartup
        } else {
            // Manual launch by user (from Finder, Applications, Dock, or Spotlight)
            shouldShowDashboard = true
        }

        if shouldShowDashboard {
            showDashboardWindow()
        }

        // Silently check GitHub Releases (hungmtuci/QuickFolder) shortly after startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            UpdateChecker.shared.checkSilentlyOnStartup()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboardWindow()
        return true
    }

    private func setupHotKeys() {
        let hotKeys = HotKeyManager.shared
        hotKeys.onToggleFloatingPanel = {
            FloatingPanelController.shared.toggleManualPanel()
        }
        hotKeys.onJumpToFrontmostFinder = {
            FolderNavigator.shared.jumpToFrontmostFinderWindow()
        }
        hotKeys.onSelectQuickIndex = { index in
            guard FloatingPanelController.shared.isPanelVisible else { return }
            let all = FolderManager.shared.allQuickAccessFolders()
            if index >= 0 && index < all.count {
                FolderNavigator.shared.selectFolder(all[index])
            }
        }
        hotKeys.registerHotKeys()
    }

    private func setupStatusBarMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "folder.fill.badge.gearshape", accessibilityDescription: "QuickFolder")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "QuickFolder — Chọn nhanh thư mục khi Lưu/Mở file"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        LaunchAtLoginManager.shared.refreshStatus()

        let headerItem = NSMenuItem(
            title: "QuickFolder v\(UpdateChecker.shared.currentVersion) — Chọn nhanh thư mục",
            action: nil,
            keyEquivalent: ""
        )
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let toggleItem = NSMenuItem(
            title: "Hiện / Ẩn bảng chọn nổi (\(HotKeyManager.shared.togglePreset.compactLabel))",
            action: #selector(toggleFloatingPanelAction),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let jumpFinderItem = NSMenuItem(
            title: "Nhảy tới Finder đang mở đầu tiên (\(HotKeyManager.shared.finderJumpPreset.compactLabel))",
            action: #selector(jumpToFrontFinderAction),
            keyEquivalent: ""
        )
        jumpFinderItem.target = self
        menu.addItem(jumpFinderItem)

        menu.addItem(.separator())

        // Open Finder Windows Section
        let openHeader = NSMenuItem(title: "Đang mở trong Finder", action: nil, keyEquivalent: "")
        openHeader.isEnabled = false
        menu.addItem(openHeader)

        let openFolders = FolderManager.shared.openFinderFolders
        if openFolders.isEmpty {
            let emptyItem = NSMenuItem(title: "  (Không có cửa sổ Finder nào)", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (idx, item) in openFolders.prefix(6).enumerated() {
                let menuItem = NSMenuItem(
                    title: "\(item.name)  —  \(item.displayPath)",
                    action: #selector(selectFolderFromMenu(_:)),
                    keyEquivalent: idx < 9 ? "\(idx + 1)" : ""
                )
                if idx < 9 {
                    menuItem.keyEquivalentModifierMask = [.option]
                }
                menuItem.representedObject = item.path
                menuItem.image = item.icon
                menuItem.target = self
                menu.addItem(menuItem)
            }
        }

        menu.addItem(.separator())

        // Recent Folders Section
        let recentHeader = NSMenuItem(title: "Thư mục gần đây & Đã ghim", action: nil, keyEquivalent: "")
        recentHeader.isEnabled = false
        menu.addItem(recentHeader)

        let recentFolders = FolderManager.shared.recentFolders
        for item in recentFolders.prefix(8) {
            let menuItem = NSMenuItem(
                title: "\(item.name)  —  \(item.displayPath)",
                action: #selector(selectFolderFromMenu(_:)),
                keyEquivalent: ""
            )
            menuItem.representedObject = item.path
            menuItem.image = item.icon
            menuItem.target = self
            menu.addItem(menuItem)
        }

        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(
            title: "Khởi động cùng macOS",
            action: #selector(toggleLaunchAtLoginAction),
            keyEquivalent: ""
        )
        launchAtLoginItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let openOnStartupItem = NSMenuItem(
            title: "Bật bảng điều khiển khi khởi động",
            action: #selector(toggleOpenDashboardOnStartupAction),
            keyEquivalent: ""
        )
        openOnStartupItem.state = LaunchAtLoginManager.shared.openDashboardOnStartup ? .on : .off
        openOnStartupItem.target = self
        menu.addItem(openOnStartupItem)

        let hideDockItem = NSMenuItem(
            title: "Ẩn biểu tượng trên thanh Dock",
            action: #selector(toggleHideFromDockAction),
            keyEquivalent: ""
        )
        hideDockItem.state = FloatingPanelController.shared.hideFromDock ? .on : .off
        hideDockItem.target = self
        menu.addItem(hideDockItem)

        let finderClickItem = NSMenuItem(
            title: "Finder-Click (Click cửa sổ Finder phía sau)",
            action: #selector(toggleFinderClickAction),
            keyEquivalent: ""
        )
        finderClickItem.state = FinderClickOverlayController.shared.isEnabled ? .on : .off
        finderClickItem.target = self
        menu.addItem(finderClickItem)

        menu.addItem(.separator())

        let updater = UpdateChecker.shared
        if let button = statusItem.button {
            if let newVer = updater.availableVersion {
                button.toolTip = "QuickFolder — Đã có bản cập nhật mới v\(newVer)!"
            } else {
                button.toolTip = "QuickFolder — Chọn nhanh thư mục khi Lưu/Mở file"
            }
        }

        if updater.isInstallingUpdate {
            let installingItem = NSMenuItem(
                title: updater.statusText ?? "Đang tải & cập nhật tự động...",
                action: nil,
                keyEquivalent: ""
            )
            installingItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            installingItem.isEnabled = false
            menu.addItem(installingItem)
        } else {
            if let newVer = updater.availableVersion {
                let autoUpdateItem = NSMenuItem(
                    title: "Update ngay lên v\(newVer) từ GitHub",
                    action: #selector(installAvailableUpdateAction),
                    keyEquivalent: ""
                )
                autoUpdateItem.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
                autoUpdateItem.target = self
                menu.addItem(autoUpdateItem)
            }

            let updateItem = NSMenuItem(
                title: updater.isChecking ? "Đang kết nối GitHub..." : "Update từ GitHub...",
                action: updater.isChecking ? nil : #selector(checkForUpdatesAction),
                keyEquivalent: "u"
            )
            updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            updateItem.isEnabled = !updater.isChecking
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let dashboardItem = NSMenuItem(
            title: "Mở Bảng điều khiển & Cài đặt...",
            action: #selector(openDashboardAction),
            keyEquivalent: ","
        )
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let quitItem = NSMenuItem(
            title: "Thoát QuickFolder",
            action: #selector(quitAppAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleLaunchAtLoginAction() {
        LaunchAtLoginManager.shared.toggle()
    }

    @objc private func toggleOpenDashboardOnStartupAction() {
        LaunchAtLoginManager.shared.openDashboardOnStartup.toggle()
    }

    @objc private func toggleHideFromDockAction() {
        FloatingPanelController.shared.hideFromDock.toggle()
    }

    @objc private func toggleFinderClickAction() {
        FinderClickOverlayController.shared.isEnabled.toggle()
    }

    @objc private func checkForUpdatesAction() {
        UpdateChecker.shared.checkForUpdates(showAlert: true)
    }

    @objc private func installAvailableUpdateAction() {
        UpdateChecker.shared.installAvailableUpdate()
    }

    @objc private func toggleFloatingPanelAction() {
        FloatingPanelController.shared.toggleManualPanel()
    }

    @objc private func jumpToFrontFinderAction() {
        FolderNavigator.shared.jumpToFrontmostFinderWindow()
    }

    @objc private func selectFolderFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let folder = FolderItem(path: path, source: .recent)
        FolderNavigator.shared.selectFolder(folder)
    }

    @objc private func openDashboardAction() {
        showDashboardWindow()
    }

    @objc private func quitAppAction() {
        NSApp.terminate(nil)
    }

    func bringDashboardToFront() {
        guard let win = dashboardWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func showDashboardWindow() {
        if dashboardWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "QuickFolder — Cài đặt & Thử nghiệm"
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: SettingsAndTestView())
            self.dashboardWindow = win
        }

        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }
}
