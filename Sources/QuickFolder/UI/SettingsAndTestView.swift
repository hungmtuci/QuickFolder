import SwiftUI
import AppKit

struct SettingsAndTestView: View {
    @ObservedObject var folderManager = FolderManager.shared
    @ObservedObject var detector = SavePanelDetector.shared
    @ObservedObject var panelController = FloatingPanelController.shared
    @ObservedObject var navigator = FolderNavigator.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroBanner

                permissionsSection

                preferencesAndShortcutsSection

                liveFoldersPreviewSection
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    // MARK: - 1. Hero & Built-in Test Save Dialog

    private var heroBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("QuickFolder — Chọn nhanh thư mục khi Lưu / Mở file")
                    .font(.system(size: 16, weight: .bold))
                Text("Tự động hiện bảng chọn thư mục đang mở trong Finder & thư mục gần đây bám sát cạnh hộp thoại Save/Open của mọi ứng dụng.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openBuiltInTestSavePanel()
            } label: {
                Label("Mở hộp thoại Save thử nghiệm", systemImage: "play.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - 2. Permissions Status

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRẠNG THÁI QUYỀN HỆ THỐNG (MACOS PERMISSIONS)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Accessibility Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: detector.isAccessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(detector.isAccessibilityTrusted ? .green : .orange)
                            .font(.system(size: 16))
                        Text("Quyền Trợ năng (Accessibility)")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(detector.isAccessibilityTrusted ? "Đã bật" : "Cần cấp quyền")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((detector.isAccessibilityTrusted ? Color.green : Color.orange).opacity(0.16))
                            .foregroundStyle(detector.isAccessibilityTrusted ? .green : .orange)
                            .clipShape(Capsule())
                    }

                    Text("Dùng để phát hiện khi các ứng dụng khác mở hộp thoại Save/Open và tự động điền đường dẫn thư mục.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(detector.isAccessibilityTrusted ? "Kiểm tra lại" : "Cấp quyền Accessibility...") {
                            let ok = detector.checkAccessibilityPermission(prompt: true)
                            if !ok {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .controlSize(.small)

                        if !detector.isAccessibilityTrusted {
                            Button("Mở Cài đặt") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))

                // Finder Automation Card
                VStack(alignment: .leading, spacing: 8) {
                    let isFinderOK = folderManager.finderAutomationStatus == .granted
                    HStack {
                        Image(systemName: isFinderOK ? "checkmark.circle.fill" : "folder.badge.questionmark")
                            .foregroundStyle(isFinderOK ? .green : .orange)
                            .font(.system(size: 16))
                        Text("Quyền đọc cửa sổ Finder")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(isFinderOK ? "Đã kết nối" : "Kiểm tra")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((isFinderOK ? Color.green : Color.orange).opacity(0.16))
                            .foregroundStyle(isFinderOK ? .green : .orange)
                            .clipShape(Capsule())
                    }

                    Text("Dùng để lấy danh sách các cửa sổ Finder đang mở trên màn hình theo thời gian thực.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Làm mới Finder") {
                            folderManager.refreshNow()
                        }
                        .controlSize(.small)

                        if case .denied = folderManager.finderAutomationStatus {
                            Button("Mở Cài đặt Automation") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            }
        }
    }

    // MARK: - 3. Preferences & Keyboard Shortcuts

    private var preferencesAndShortcutsSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("TUỲ CHỈNH HIỂN THỊ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                Picker("Vị trí bảng nổi:", selection: $panelController.dockSide) {
                    ForEach(DockSide.allCases, id: \.self) { side in
                        Text(side.title).tag(side)
                    }
                }
                .pickerStyle(.radioGroup)
                .font(.system(size: 12.5))

                Toggle(isOn: $panelController.hideFromDock) {
                    HStack(spacing: 6) {
                        Image(systemName: "dock.rectangle")
                            .foregroundStyle(.secondary)
                        Text("Ẩn biểu tượng trên thanh Dock (chỉ hiện ở Menu Bar)")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                }
                .toggleStyle(.checkbox)

                Divider()

                HStack(spacing: 8) {
                    Button {
                        pickFolderToPin()
                    } label: {
                        Label("Ghim thêm thư mục...", systemImage: "pin.fill")
                    }
                    .controlSize(.small)

                    Button {
                        panelController.toggleManualPanel()
                    } label: {
                        Label("Hiện/Ẩn bảng nổi (⌘⇧D)", systemImage: "sidebar.right")
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("PHÍM TẮT NHANH (GLOBAL HOTKEYS)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                shortcutRow(keys: "⌘ ⇧ F", desc: "Nhảy ngay tới cửa sổ Finder đang mở đầu tiên")
                shortcutRow(keys: "⌘ ⇧ D", desc: "Hiện / Ẩn nhanh bảng chọn thư mục nổi")
                shortcutRow(keys: "⌥ 1 … ⌥ 9", desc: "Chọn nhanh thư mục số 1…9 trong danh sách")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
    }

    private func shortcutRow(keys: String, desc: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - 4. Live Preview of Open Finder Windows & Recent Folders

    private var liveFoldersPreviewSection: some View {
        HStack(alignment: .top, spacing: 12) {
            // Open Finder Windows column
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("ĐANG MỞ TRONG FINDER (\(folderManager.openFinderFolders.count))", systemImage: "macwindow")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        folderManager.refreshNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }

                if folderManager.openFinderFolders.isEmpty {
                    Text("Hiện không có cửa sổ Finder nào đang mở. Hãy thử mở 1 cửa sổ Finder!")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(folderManager.openFinderFolders) { item in
                        compactFolderCard(item)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))

            // Recent & Pinned Folders column
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("THƯ MỤC GẦN ĐÂY & ĐÃ GHIM (\(folderManager.recentFolders.count))", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Nhập từ Finder") {
                        folderManager.importFinderRecentBookmarks()
                        folderManager.refreshNow()
                    }
                    .font(.system(size: 10.5))
                    .buttonStyle(.link)
                }

                ForEach(folderManager.recentFolders.prefix(10)) { item in
                    compactFolderCard(item)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
    }

    private func compactFolderCard(_ item: FolderItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if folderManager.isPinned(item.path) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
                Text(item.displayPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                folderManager.togglePin(item.path)
            } label: {
                Image(systemName: folderManager.isPinned(item.path) ? "pin.slash" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Ghim / Bỏ ghim")

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Mở trong Finder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Actions

    private func openBuiltInTestSavePanel() {
        folderManager.refreshNow()
        let savePanel = NSSavePanel()
        savePanel.title = "Lưu tài liệu thử nghiệm (QuickFolder Demo)"
        savePanel.message = "Hãy bấm chọn bất kỳ thư mục nào ở bảng QuickFolder bên cạnh (hoặc bấm ⌥1..⌥9, ⌘⇧F) để nhảy tới thư mục đó!"
        savePanel.nameFieldStringValue = "BaoCao_DuAn_2026.pdf"
        savePanel.canCreateDirectories = true

        navigator.activeTestSavePanel = savePanel
        detector.registerInProcessTestPanel(savePanel)

        savePanel.begin { _ in
            Task { @MainActor in
                navigator.activeTestSavePanel = nil
                detector.registerInProcessTestPanel(nil)
            }
        }
    }

    private func pickFolderToPin() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Chọn thư mục để ghim cố định"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        if openPanel.runModal() == .OK, let url = openPanel.url {
            if !folderManager.isPinned(url.path) {
                folderManager.togglePin(url.path)
            }
        }
    }
}
