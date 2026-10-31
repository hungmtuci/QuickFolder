import Foundation
import AppKit

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking: Bool = false
    @Published private(set) var isInstallingUpdate: Bool = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var availableVersion: String?
    @Published private(set) var statusText: String?

    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/hungmtuci/QuickFolder/releases/latest")!
    private let releasesPageURL = URL(string: "https://github.com/hungmtuci/QuickFolder/releases/latest")!

    private var cachedAutoUpdateURL: URL?
    private var cachedDmgURL: URL?
    private var cachedReleasePageURL: URL?
    private var cachedNotes: String = ""

    private var progressWindow: NSWindow?
    private var progressTitleLabel: NSTextField?
    private var progressDetailLabel: NSTextField?
    private var progressBar: NSProgressIndicator?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.3.6"
    }

    private init() {}

    func checkSilentlyOnStartup() {
        checkForUpdates(showAlert: false)
    }

    func checkForUpdates(showAlert: Bool = true) {
        guard !isChecking, !isInstallingUpdate else { return }
        isChecking = true
        statusText = "Đang kiểm tra bản cập nhật..."

        var request = URLRequest(
            url: latestReleaseAPI,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuickFolder/\(currentVersion)", forHTTPHeaderField: "User-Agent")

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

                let zipURL = release.assets
                    .first(where: { $0.name.lowercased().hasSuffix(".zip") })
                    .flatMap { URL(string: $0.browser_download_url) }

                let dmgURL = release.assets
                    .first(where: { $0.name.lowercased().hasSuffix(".dmg") })
                    .flatMap { URL(string: $0.browser_download_url) }

                let htmlURL = URL(string: release.html_url) ?? releasesPageURL
                let autoAssetURL = zipURL ?? dmgURL

                if Self.isNewerVersion(remote: remoteVersion, local: localVersion) {
                    availableVersion = remoteVersion
                    cachedAutoUpdateURL = autoAssetURL
                    cachedDmgURL = dmgURL
                    cachedReleasePageURL = htmlURL
                    cachedNotes = release.body ?? ""
                    statusText = "Đã có bản mới v\(remoteVersion)!"

                    if showAlert {
                        presentUpdateAvailableAlert(
                            remoteVersion: remoteVersion,
                            notes: cachedNotes,
                            autoUpdateURL: autoAssetURL,
                            dmgURL: dmgURL,
                            releaseURL: htmlURL
                        )
                    }
                } else {
                    availableVersion = nil
                    cachedAutoUpdateURL = autoAssetURL
                    cachedDmgURL = dmgURL
                    cachedReleasePageURL = htmlURL
                    statusText = "Đang ở bản mới nhất (v\(localVersion))"
                    if showAlert {
                        presentUpToDateAlert(
                            localVersion: localVersion,
                            remoteVersion: remoteVersion,
                            autoUpdateURL: autoAssetURL,
                            releaseURL: htmlURL
                        )
                    }
                }
            } catch {
                isChecking = false
                statusText = "Không kiểm tra được cập nhật"
                if showAlert {
                    let alert = NSAlert()
                    alert.messageText = "Không thể kết nối GitHub Releases"
                    alert.informativeText = "Hãy kiểm tra kết nối mạng hoặc mở trang phát hành hungmtuci/QuickFolder thủ công.\nChi tiết: \(error.localizedDescription)"
                    alert.addButton(withTitle: "Mở GitHub Releases")
                    alert.addButton(withTitle: "Đóng")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(releasesPageURL)
                    }
                }
            }
        }
    }

    func installAvailableUpdate() {
        guard !isInstallingUpdate else { return }
        guard let version = availableVersion else {
            checkForUpdates(showAlert: true)
            return
        }
        if let autoURL = cachedAutoUpdateURL {
            Task {
                await downloadAndInstallUpdate(
                    remoteVersion: version,
                    assetURL: autoURL,
                    fallbackURL: cachedReleasePageURL ?? releasesPageURL
                )
            }
        } else {
            NSWorkspace.shared.open(cachedReleasePageURL ?? releasesPageURL)
        }
    }

    // MARK: - Alerts

    private func presentUpdateAvailableAlert(
        remoteVersion: String,
        notes: String,
        autoUpdateURL: URL?,
        dmgURL: URL?,
        releaseURL: URL
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Đã có QuickFolder v\(remoteVersion) mới!"
        let trimmedNotes = notes.count > 440 ? String(notes.prefix(440)) + "..." : notes
        let notesBlock = trimmedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Bản phát hành mới đã sẵn sàng trên hungmtuci/QuickFolder."
            : trimmedNotes
        alert.informativeText = "Phiên bản hiện tại: v\(currentVersion) → Phiên bản mới: v\(remoteVersion)\n\n\(notesBlock)"

        if autoUpdateURL != nil {
            alert.addButton(withTitle: "Tải & Cập nhật tự động")
            if dmgURL != nil {
                alert.addButton(withTitle: "Tải bộ cài (.dmg)")
            } else {
                alert.addButton(withTitle: "Xem trên GitHub")
            }
            alert.addButton(withTitle: "Để sau")
        } else {
            alert.addButton(withTitle: "Xem trên GitHub")
            alert.addButton(withTitle: "Để sau")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if let autoURL = autoUpdateURL {
            if response == .alertFirstButtonReturn {
                Task {
                    await downloadAndInstallUpdate(
                        remoteVersion: remoteVersion,
                        assetURL: autoURL,
                        fallbackURL: releaseURL
                    )
                }
            } else if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(dmgURL ?? releaseURL)
            }
        } else if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private func presentUpToDateAlert(
        localVersion: String,
        remoteVersion: String,
        autoUpdateURL: URL?,
        releaseURL: URL
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Bạn đang ở phiên bản mới nhất (v\(localVersion))"
        alert.informativeText = "Bản mới nhất trên GitHub (hungmtuci/QuickFolder) hiện là v\(remoteVersion).\nBạn vẫn có thể bấm 'Tải & Cài lại từ GitHub' nếu muốn đồng bộ lại bản sạch trực tiếp từ GitHub."
        alert.addButton(withTitle: "Đóng")
        if autoUpdateURL != nil {
            alert.addButton(withTitle: "Tải & Cài lại từ GitHub (v\(remoteVersion))")
        }
        alert.addButton(withTitle: "Mở trang GitHub")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if let autoURL = autoUpdateURL {
            if response == .alertSecondButtonReturn {
                Task {
                    await downloadAndInstallUpdate(
                        remoteVersion: remoteVersion,
                        assetURL: autoURL,
                        fallbackURL: releaseURL
                    )
                }
            } else if response == .alertThirdButtonReturn {
                NSWorkspace.shared.open(releaseURL)
            }
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    // MARK: - Automatic Download, Extraction & Self-Replacement

    private func downloadAndInstallUpdate(remoteVersion: String, assetURL: URL, fallbackURL: URL) async {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        downloadProgress = 0
        statusText = "Đang tải QuickFolder v\(remoteVersion)..."
        showProgressWindow(version: remoteVersion)

        let stageDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuickFolderAutoUpdate-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

            let downloadedFile = try await downloadAsset(from: assetURL, into: stageDir) { [weak self] fraction in
                guard let self else { return }
                self.downloadProgress = fraction
                let pct = Int((fraction * 100).rounded())
                self.statusText = "Đang tải QuickFolder v\(remoteVersion) (\(pct)%)..."
                self.updateProgressWindow(
                    detail: "Đang tải gói cập nhật từ GitHub Releases (\(pct)%)...",
                    fraction: fraction,
                    indeterminate: false
                )
            }

            statusText = "Đang giải nén & kiểm tra bản cập nhật..."
            updateProgressWindow(
                detail: "Đang giải nén và xác thực gói ứng dụng QuickFolder.app...",
                fraction: 1.0,
                indeterminate: true
            )

            let currentVersionCopy = currentVersion
            let extractedAppURL = try await Task.detached(priority: .userInitiated) {
                try Self.extractAndValidateAppBundle(
                    archiveURL: downloadedFile,
                    stageDir: stageDir,
                    userAgentVersion: currentVersionCopy
                )
            }.value

            statusText = "Đang cài đặt v\(remoteVersion) & khởi động lại..."
            updateProgressWindow(
                detail: "Đang thay thế bản cũ và tự động mở lại QuickFolder v\(remoteVersion)...",
                fraction: 1.0,
                indeterminate: true
            )

            UserDefaults.standard.set(true, forKey: "QF_OpenDashboardAfterUpdate")
            UserDefaults.standard.synchronize()

            try launchDetachedSwapAndRestart(extractedAppURL: extractedAppURL, stageDir: stageDir)

            try? await Task.sleep(nanoseconds: 250_000_000)
            closeProgressWindow()
            NSApp.terminate(nil)

            // Fallback exit in case any modal/panel blocks normal termination
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                exit(0)
            }
        } catch {
            isInstallingUpdate = false
            downloadProgress = 0
            statusText = "Cập nhật tự động thất bại"
            closeProgressWindow()
            try? FileManager.default.removeItem(at: stageDir)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Không thể tự động cập nhật QuickFolder"
            alert.informativeText = "Quá trình tải hoặc cài đặt tự động gặp sự cố (\(error.localizedDescription)).\nBạn có muốn mở trang GitHub Releases để tải thủ công không?"
            alert.addButton(withTitle: "Mở GitHub Releases")
            alert.addButton(withTitle: "Đóng")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(fallbackURL)
            }
        }
    }

    private func downloadAsset(
        from url: URL,
        into stageDir: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 180
        )
        request.setValue("QuickFolder/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let ext = url.pathExtension.lowercased().isEmpty ? "zip" : url.pathExtension.lowercased()
        let destinationURL = stageDir.appendingPathComponent("QuickFolder-download.\(ext)")

        return try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: request) { tempURL, response, error in
                observation?.invalidate()
                observation = nil

                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let tempURL = tempURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let fraction = progress.fractionCompleted
                if fraction > 0 {
                    Task { @MainActor in
                        onProgress(min(max(fraction, 0.0), 1.0))
                    }
                }
            }

            task.resume()
        }
    }

    nonisolated private static func extractAndValidateAppBundle(
        archiveURL: URL,
        stageDir: URL,
        userAgentVersion: String
    ) throws -> URL {
        _ = userAgentVersion
        let extractDir = stageDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let ext = archiveURL.pathExtension.lowercased()
        if ext == "dmg" {
            let mountDir = stageDir.appendingPathComponent("dmg_mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
            try runCommand("/usr/bin/hdiutil", arguments: [
                "attach", "-nobrowse", "-readonly", "-noverify",
                "-mountpoint", mountDir.path, archiveURL.path
            ])
            defer {
                try? runCommand("/usr/bin/hdiutil", arguments: ["detach", mountDir.path, "-force"])
            }
            let mountedApp = mountDir.appendingPathComponent("QuickFolder.app", isDirectory: true)
            let copiedApp = extractDir.appendingPathComponent("QuickFolder.app", isDirectory: true)
            try runCommand("/usr/bin/ditto", arguments: ["--noextattr", mountedApp.path, copiedApp.path])
        } else {
            try runCommand("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractDir.path])
        }

        // Locate QuickFolder.app inside extractDir
        let directCandidate = extractDir.appendingPathComponent("QuickFolder.app", isDirectory: true)
        let appURL: URL
        if FileManager.default.fileExists(atPath: directCandidate.path) {
            appURL = directCandidate
        } else if let found = try FileManager.default.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" }) {
            appURL = found
        } else {
            throw NSError(
                domain: "QuickFolderUpdater",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy QuickFolder.app trong gói cập nhật"]
            )
        }

        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("QuickFolder")

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(
                domain: "QuickFolderUpdater",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Gói QuickFolder.app tải về không hợp lệ hoặc bị hỏng"]
            )
        }

        return appURL
    }

    nonisolated private static func runCommand(_ executable: String, arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(
                domain: "QuickFolderUpdater",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Lệnh hệ thống \((executable as NSString).lastPathComponent) thất bại (mã \(proc.terminationStatus))"]
            )
        }
    }

    private func launchDetachedSwapAndRestart(extractedAppURL: URL, stageDir: URL) throws {
        let currentBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let applicationsBundlePath = "/Applications/QuickFolder.app"

        let shouldForceApplicationsDir =
            !currentBundlePath.hasSuffix(".app") ||
            currentBundlePath.hasPrefix("/Volumes/") ||
            currentBundlePath.contains("/AppTranslocation/")

        let primaryTargetPath = shouldForceApplicationsDir ? applicationsBundlePath : currentBundlePath
        let secondaryTargetPath = (primaryTargetPath != applicationsBundlePath && FileManager.default.fileExists(atPath: applicationsBundlePath))
            ? applicationsBundlePath
            : ""

        let parentDir = (primaryTargetPath as NSString).deletingLastPathComponent
        let needsAdmin = !FileManager.default.isWritableFile(atPath: parentDir)
        let pid = ProcessInfo.processInfo.processIdentifier

        let script: String
        if needsAdmin {
            // Escalate via AppleScript administrator prompt if target folder is root-protected
            script = """
            OLD_PID="$1"
            SRC_APP="$2"
            DST_APP="$3"
            STAGE_DIR="$5"
            (
                i=0
                while kill -0 "$OLD_PID" 2>/dev/null && [ "$i" -lt 60 ]; do
                    sleep 0.1
                    i=$((i + 1))
                done
                /usr/bin/osascript -e "do shell script \\"rm -rf '$DST_APP' && /usr/bin/ditto --noextattr '$SRC_APP' '$DST_APP' && /usr/bin/xattr -cr '$DST_APP'\\" with administrator privileges" >/dev/null 2>&1
                /usr/bin/open "$DST_APP"
                rm -rf "$STAGE_DIR"
            ) </dev/null >/dev/null 2>&1 &
            """
        } else {
            script = """
            OLD_PID="$1"
            SRC_APP="$2"
            DST_APP="$3"
            SECONDARY_APP="$4"
            STAGE_DIR="$5"
            (
                i=0
                while kill -0 "$OLD_PID" 2>/dev/null && [ "$i" -lt 60 ]; do
                    sleep 0.1
                    i=$((i + 1))
                done
                rm -rf "$DST_APP"
                /usr/bin/ditto --noextattr "$SRC_APP" "$DST_APP"
                /usr/bin/xattr -cr "$DST_APP" 2>/dev/null || true
                if [ -n "$SECONDARY_APP" ] && [ "$SECONDARY_APP" != "$DST_APP" ] && [ -d "$SECONDARY_APP" ] && [ -w "$(dirname "$SECONDARY_APP")" ]; then
                    rm -rf "$SECONDARY_APP"
                    /usr/bin/ditto --noextattr "$SRC_APP" "$SECONDARY_APP"
                    /usr/bin/xattr -cr "$SECONDARY_APP" 2>/dev/null || true
                fi
                /usr/bin/open "$DST_APP"
                rm -rf "$STAGE_DIR"
            ) </dev/null >/dev/null 2>&1 &
            """
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c",
            script,
            "--",
            "\(pid)",
            extractedAppURL.path,
            primaryTargetPath,
            secondaryTargetPath,
            stageDir.path
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Native AppKit Progress Window

    private func showProgressWindow(version: String) {
        closeProgressWindow()

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 118),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Cập nhật tự động QuickFolder"
        win.isFloatingPanel = true
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 118))

        let titleField = NSTextField(labelWithString: "Đang cập nhật lên QuickFolder v\(version)")
        titleField.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleField.frame = NSRect(x: 20, y: 68, width: 370, height: 20)
        container.addSubview(titleField)

        let detailField = NSTextField(labelWithString: "Đang kết nối GitHub Releases (hungmtuci/QuickFolder)...")
        detailField.font = .systemFont(ofSize: 11.5)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.frame = NSRect(x: 20, y: 44, width: 370, height: 18)
        container.addSubview(detailField)

        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 18, width: 370, height: 18))
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = 0.04
        indicator.isIndeterminate = false
        container.addSubview(indicator)

        win.contentView = container
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        progressWindow = win
        progressTitleLabel = titleField
        progressDetailLabel = detailField
        progressBar = indicator
    }

    private func updateProgressWindow(detail: String, fraction: Double, indeterminate: Bool) {
        progressDetailLabel?.stringValue = detail
        guard let bar = progressBar else { return }
        if bar.isIndeterminate != indeterminate {
            bar.isIndeterminate = indeterminate
            if indeterminate {
                bar.startAnimation(nil)
            } else {
                bar.stopAnimation(nil)
            }
        }
        if !indeterminate {
            bar.doubleValue = max(0.04, min(1.0, fraction))
        }
    }

    private func closeProgressWindow() {
        progressBar?.stopAnimation(nil)
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressTitleLabel = nil
        progressDetailLabel = nil
        progressBar = nil
    }

    // MARK: - Semver Tag Comparison

    nonisolated static func cleanVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^([vV]|release-)", with: "", options: .regularExpression)
    }

    nonisolated static func isNewerVersion(remote: String, local: String) -> Bool {
        let rMainAndPre = remote.split(separator: "-", maxSplits: 1).map(String.init)
        let lMainAndPre = local.split(separator: "-", maxSplits: 1).map(String.init)

        let rParts = (rMainAndPre.first ?? "").split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let lParts = (lMainAndPre.first ?? "").split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r != l {
                return r > l
            }
        }
        // Stable release (no "-beta") is newer than pre-release of the same version
        if rMainAndPre.count == 1 && lMainAndPre.count > 1 {
            return true
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
