import SwiftUI
import AppKit

struct FloatingPanelView: View {
    @ObservedObject var folderManager: FolderManager
    @ObservedObject var detector: SavePanelDetector
    @ObservedObject var navigator: FolderNavigator
    @ObservedObject var panelController: FloatingPanelController
    @ObservedObject var hotKeyManager: HotKeyManager

    var onCloseRequested: (() -> Void)?

    @MainActor
    init(
        panelController: FloatingPanelController,
        onCloseRequested: (() -> Void)? = nil
    ) {
        self.folderManager = FolderManager.shared
        self.detector = SavePanelDetector.shared
        self.navigator = FolderNavigator.shared
        self.panelController = panelController
        self.hotKeyManager = HotKeyManager.shared
        self.onCloseRequested = onCloseRequested
    }

    private var filteredOpen: [FolderItem] {
        folderManager.filtered(folderManager.openFinderFolders, query: panelController.searchText)
    }

    private var filteredFavorites: [FolderItem] {
        let favs = folderManager.recentFolders.filter { folderManager.isPinned($0.path) }
        return folderManager.filtered(favs, query: panelController.searchText)
    }

    private var filteredRecent: [FolderItem] {
        folderManager.filtered(folderManager.recentFolders, query: panelController.searchText)
    }

    /// Maps each visible FolderItem.id to its 1-based quick shortcut number (1...9)
    private var quickIndexMap: [String: Int] {
        let all = filteredOpen + filteredRecent
        var map: [String: Int] = [:]
        for (idx, item) in all.prefix(9).enumerated() {
            map[item.id] = idx + 1
        }
        return map
    }

    var body: some View {
        HStack(spacing: 0) {
            // Vertical Icon Bezel (Default Folder X style toolbar rail)
            iconRailColumn

            if !panelController.isCompactBezel {
                Divider()
                    .opacity(0.45)

                // Expanded Folder Picker List
                VStack(spacing: 0) {
                    headerSection

                    Divider()
                        .opacity(0.5)

                    searchBarSection

                    if let activeApp = detector.activePanel,
                       let appDefault = folderManager.defaultFolderItem(for: activeApp.appIdentifierKey),
                       panelController.searchText.isEmpty {
                        perAppDefaultBanner(folder: appDefault, appName: activeApp.appName)
                    }

                    if let firstOpen = folderManager.openFinderFolders.first,
                       panelController.searchText.isEmpty {
                        quickFrontFinderBanner(firstOpen)
                    }

                    if let banner = navigator.statusBannerMessage {
                        statusToast(banner)
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            switch panelController.selectedTab {
                            case .all:
                                openFinderSection
                                recentFoldersSection
                            case .openFinder:
                                openFinderSection
                            case .favorites:
                                favoritesSection
                            case .recents:
                                recentFoldersSection
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }

                    Divider()
                        .opacity(0.5)

                    footerSection
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Default Folder X Style Vertical Icon Rail

    private var iconRailColumn: some View {
        VStack(spacing: 12) {
            // 1. All / Default Folders Icon
            railIconButton(
                tab: .all,
                systemImage: "folder.badge.gearshape",
                badgeCount: nil,
                tooltip: "Tất cả thư mục (Đang mở & Gần đây)"
            )

            // 2. Open Finder Windows Icon
            railIconButton(
                tab: .openFinder,
                systemImage: "macwindow",
                badgeCount: folderManager.openFinderFolders.count,
                tooltip: "Cửa sổ Finder đang mở (\(folderManager.openFinderFolders.count))"
            )

            // 3. Favorites (Heart) Icon
            railIconButton(
                tab: .favorites,
                systemImage: "heart",
                badgeCount: folderManager.pinnedPaths.count,
                tooltip: "Thư mục Yêu thích đã ghim"
            )

            // 4. Recent Folders (Folder + Clock) Icon
            railIconButton(
                tab: .recents,
                systemImage: "clock.arrow.circlepath",
                badgeCount: nil,
                tooltip: "Lịch sử thư mục gần đây"
            )

            Divider()
                .frame(width: 28)
                .opacity(0.4)

            // 5. Instant Jump to Frontmost Finder Window (1-click action)
            Button {
                navigator.jumpToFrontmostFinderWindow()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .help("Nhảy ngay tới cửa sổ Finder đầu tiên (⌘⇧F)")

            Spacer()

            // Collapse / Expand Sidebar Toggle
            Button {
                panelController.isCompactBezel.toggle()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 34, height: 34)
                    Image(systemName: panelController.isCompactBezel ? "sidebar.right" : "chevron.left.2")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(panelController.isCompactBezel ? "Mở rộng danh sách thư mục" : "Thu gọn thành thanh icon")
        }
        .padding(.vertical, 12)
        .frame(width: 54)
        .background(Color.black.opacity(0.12))
    }

    private func railIconButton(tab: SidebarTab, systemImage: String, badgeCount: Int?, tooltip: String) -> some View {
        let isSelected = (!panelController.isCompactBezel && panelController.selectedTab == tab)
        return Button {
            if panelController.isCompactBezel {
                panelController.selectedTab = tab
                panelController.isCompactBezel = false
            } else if panelController.selectedTab == tab {
                // Clicking active tab again refreshes Finder windows
                folderManager.refreshNow()
            } else {
                panelController.selectedTab = tab
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
                    .frame(width: 36, height: 36)

                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                    .frame(width: 36, height: 36)

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green))
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Subviews

    private var headerSection: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(panelController.selectedTab.title)
                        .font(.system(size: 12.5, weight: .bold))
                    if let panel = detector.activePanel {
                        Text("• \(panel.appName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("Bấm chọn thư mục để chuyển ngay")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                folderManager.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Làm mới danh sách cửa sổ Finder")

            if let panel = detector.activePanel,
               panel.appPID != ProcessInfo.processInfo.processIdentifier {
                Button {
                    detector.toggleExcludedApp(panel.appIdentifierKey)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Không tự hiện bảng nổi trên \(panel.appName)")
            }

            if let onCloseRequested {
                Button {
                    onCloseRequested()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Ẩn bảng chọn (\(hotKeyManager.togglePreset.compactLabel))")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var searchBarSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Lọc nhanh thư mục...", text: $panelController.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onTapGesture {
                    panelController.enableSearchFieldFocus()
                }

            if !panelController.searchText.isEmpty {
                Button {
                    panelController.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func perAppDefaultBanner(folder: FolderItem, appName: String) -> some View {
        HStack(spacing: 8) {
            Button {
                navigator.selectFolder(folder)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mặc định cho \(appName): \(folder.name)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(folder.displayPath)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                SubfolderMenuPresenter.shared.popUpSubfolderMenu(for: folder)
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Duyệt thư mục con / Tạo thư mục mới")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private func quickFrontFinderBanner(_ folder: FolderItem) -> some View {
        Button {
            navigator.selectFolder(folder)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Finder đang mở: \(folder.name)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(folder.displayPath)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(hotKeyManager.finderJumpPreset.compactLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func statusToast(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.green.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    private var openFinderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("ĐANG MỞ TRONG FINDER", systemImage: "macwindow")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredOpen.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if filteredOpen.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(panelController.searchText.isEmpty ? "Không có cửa sổ Finder nào đang mở" : "Không khớp từ khoá")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                ForEach(filteredOpen) { item in
                    folderRow(item: item, shortcutIndex: quickIndexMap[item.id])
                }
            }
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("THƯ MỤC YÊU THÍCH ĐÃ GHIM", systemImage: "heart.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredFavorites.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if filteredFavorites.isEmpty {
                Text("Bấm biểu tượng ghim trên bất kỳ thư mục nào để lưu vào mục Yêu thích.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(filteredFavorites) { item in
                    folderRow(item: item, shortcutIndex: quickIndexMap[item.id])
                }
            }
        }
    }

    private var recentFoldersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("THƯ MỤC GẦN ĐÂY & ĐÃ GHIM", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredRecent.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            if filteredRecent.isEmpty {
                Text("Chưa có thư mục gần đây")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(filteredRecent) { item in
                    folderRow(item: item, shortcutIndex: quickIndexMap[item.id])
                }
            }
        }
    }

    private func folderRow(item: FolderItem, shortcutIndex: Int?) -> some View {
        let isHovered = panelController.hoveredID == item.id
        let isPinned = folderManager.isPinned(item.path)

        return HStack(spacing: 8) {
            Button {
                navigator.selectFolder(item)
            } label: {
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .frame(width: 20, height: 20)

                        if case .openFinderWindow(let idx) = item.source, idx == 1 {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if isPinned {
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

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered || isPinned {
                Button {
                    folderManager.togglePin(item.path)
                } label: {
                    Image(systemName: isPinned ? "pin.slash.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(isPinned ? .orange : .secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Bỏ ghim thư mục" : "Ghim thư mục lên đầu")
            }

            if let shortcutIndex {
                Text("⌥\(shortcutIndex)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Subfolder cascading menu & New Subfolder button (`▸`)
            Button {
                SubfolderMenuPresenter.shared.popUpSubfolderMenu(for: item)
            } label: {
                Image(systemName: "chevron.right.circle")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary.opacity(0.75))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Duyệt cây thư mục con / Tạo thư mục mới / Đặt mặc định cho app")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .onHover { hovering in
            panelController.hoveredID = hovering ? item.id : (panelController.hoveredID == item.id ? nil : panelController.hoveredID)
        }
    }

    private var footerSection: some View {
        HStack {
            Text("⌥1–9 Chọn nhanh")
            Spacer()
            Text("\(hotKeyManager.finderJumpPreset.compactLabel) Finder đầu")
            Spacer()
            Text("▸ Thư mục con")
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
