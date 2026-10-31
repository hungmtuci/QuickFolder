import Foundation
import ServiceManagement
import AppKit

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false
    @Published var openDashboardOnStartup: Bool {
        didSet {
            UserDefaults.standard.set(openDashboardOnStartup, forKey: openDashboardOnStartupKey)
        }
    }
    @Published var lastErrorMessage: String?

    private let hasCompletedFirstLaunchKey = "QuickFolder.HasCompletedFirstLaunch.v1"
    private let openDashboardOnStartupKey = "QuickFolder.OpenDashboardOnStartup.v1"
    private let launchAgentLabel = "com.hunglx.QuickFolder.launcher"

    private var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private init() {
        if UserDefaults.standard.object(forKey: openDashboardOnStartupKey) == nil {
            self.openDashboardOnStartup = false
            UserDefaults.standard.set(false, forKey: openDashboardOnStartupKey)
        } else {
            self.openDashboardOnStartup = UserDefaults.standard.bool(forKey: openDashboardOnStartupKey)
        }
        refreshStatus()
    }

    func refreshStatus() {
        let smStatus = SMAppService.mainApp.status
        let hasAgentPlist = FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
        isEnabled = (smStatus == .enabled || smStatus == .requiresApproval || hasAgentPlist)
    }

    func setEnabled(_ enable: Bool) {
        lastErrorMessage = nil
        if enable {
            var registeredViaSM = false
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                let st = SMAppService.mainApp.status
                if st == .enabled || st == .requiresApproval {
                    registeredViaSM = true
                    removeFallbackLaunchAgent()
                    if st == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            } catch {
                registeredViaSM = false
            }

            if !registeredViaSM {
                do {
                    try writeFallbackLaunchAgent()
                } catch {
                    lastErrorMessage = "Không thể bật Khởi động cùng macOS: \(error.localizedDescription)"
                }
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeFallbackLaunchAgent()
        }
        refreshStatus()
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    /// Returns `true` on the very first run after installation, or whenever the user enables "Bật bảng này khi khởi động".
    func shouldOpenDashboardOnStartup() -> Bool {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: hasCompletedFirstLaunchKey)
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: hasCompletedFirstLaunchKey)
            return true
        }
        return openDashboardOnStartup
    }

    // MARK: - Fallback ~/Library/LaunchAgents Plist (ensures reliable Launch at Login on ad-hoc signed builds)

    private func writeFallbackLaunchAgent() throws {
        let dir = launchAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let preferredAppPath = FileManager.default.fileExists(atPath: "/Applications/QuickFolder.app")
            ? "/Applications/QuickFolder.app"
            : Bundle.main.bundleURL.standardizedFileURL.path
        let executablePath = "\(preferredAppPath)/Contents/MacOS/QuickFolder"

        let plistDict: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executablePath, "--startup"],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try data.write(to: launchAgentPlistURL, options: .atomic)
    }

    private func removeFallbackLaunchAgent() {
        if FileManager.default.fileExists(atPath: launchAgentPlistURL.path) {
            try? FileManager.default.removeItem(at: launchAgentPlistURL)
        }
    }
}
