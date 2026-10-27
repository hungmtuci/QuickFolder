import Foundation
import ServiceManagement
import AppKit

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false
    @Published var lastErrorMessage: String?

    private let hasCompletedFirstLaunchKey = "QuickFolder.HasCompletedFirstLaunch.v1"

    private init() {
        refreshStatus()
    }

    func refreshStatus() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setEnabled(_ enable: Bool) {
        lastErrorMessage = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
        } catch {
            refreshStatus()
            lastErrorMessage = "Không thể đổi trạng thái khởi động cùng máy (hãy chép QuickFolder.app vào /Applications trước): \(error.localizedDescription)"
        }
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    /// Returns `true` only on the very first run of the app (or if Accessibility permission is not yet trusted),
    /// allowing subsequent logins/launches to start silently in the Menu Bar without popping up the dashboard window.
    func shouldOpenDashboardOnStartup() -> Bool {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: hasCompletedFirstLaunchKey)
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: hasCompletedFirstLaunchKey)
            return true
        }
        if !AXIsProcessTrusted() {
            return true
        }
        return false
    }
}
