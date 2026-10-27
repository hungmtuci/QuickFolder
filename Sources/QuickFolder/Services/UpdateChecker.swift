import Foundation
import AppKit

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking: Bool = false
    @Published private(set) var statusText: String?

    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/hungmtuci/QuickFolder/releases/latest")!
    private let releasesPageURL = URL(string: "https://github.com/hungmtuci/QuickFolder/releases/latest")!

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.0"
    }

    private init() {}

    func checkForUpdates(showAlert: Bool = true) {
        guard !isChecking else { return }
        isChecking = true
        statusText = "Đang kiểm tra bản cập nhật..."

        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
                let remoteVersion = Self.cleanVersion(release.tag_name)
                let localVersion = Self.cleanVersion(currentVersion)

                isChecking = false

                if Self.isNewerVersion(remote: remoteVersion, local: localVersion) {
                    statusText = "Có bản mới v\(remoteVersion)!"
                    let downloadURL = release.assets
                        .first(where: { $0.name.lowercased().hasSuffix(".dmg") })
                        .flatMap { URL(string: $0.browser_download_url) }
                        ?? URL(string: release.html_url)
                        ?? releasesPageURL

                    if showAlert {
                        presentUpdateAvailableAlert(
                            remoteVersion: remoteVersion,
                            notes: release.body ?? "",
                            downloadURL: downloadURL
                        )
                    }
                } else {
                    statusText = "Đang ở bản mới nhất (v\(localVersion))"
                    if showAlert {
                        presentUpToDateAlert(version: localVersion)
                    }
                }
            } catch {
                isChecking = false
                statusText = "Không kiểm tra được cập nhật"
                if showAlert {
                    let alert = NSAlert()
                    alert.messageText = "Không thể kết nối GitHub Releases"
                    alert.informativeText = "Hãy kiểm tra kết nối mạng hoặc mở trang phát hành thủ công.\nChi tiết: \(error.localizedDescription)"
                    alert.addButton(withTitle: "Mở trang GitHub Releases")
                    alert.addButton(withTitle: "Đóng")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(releasesPageURL)
                    }
                }
            }
        }
    }

    private func presentUpdateAvailableAlert(remoteVersion: String, notes: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Đã có QuickFolder v\(remoteVersion) mới!"
        let trimmedNotes = notes.count > 420 ? String(notes.prefix(420)) + "..." : notes
        alert.informativeText = "Phiên bản hiện tại của bạn: v\(currentVersion)\n\n\(trimmedNotes)"
        alert.addButton(withTitle: "Tải bộ cài (.dmg)")
        alert.addButton(withTitle: "Xem trên GitHub")
        alert.addButton(withTitle: "Để sau")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(releasesPageURL)
        }
    }

    private func presentUpToDateAlert(version: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Bạn đang dùng phiên bản mới nhất"
        alert.informativeText = "QuickFolder v\(version) hiện là bản phát hành mới nhất trên GitHub."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    nonisolated private static func cleanVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
    }

    nonisolated private static func isNewerVersion(remote: String, local: String) -> Bool {
        let rParts = remote.split(separator: ".").map { Int($0) ?? 0 }
        let lParts = local.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r != l {
                return r > l
            }
        }
        return false
    }

    private struct GitHubReleaseResponse: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }
}
