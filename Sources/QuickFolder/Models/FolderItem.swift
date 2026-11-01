import Foundation
import AppKit

enum FolderSource: Equatable, Hashable {
    case openFinderWindow(windowIndex: Int)
    case pinned
    case recent
}

struct FolderItem: Identifiable, Hashable {
    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    let id: String
    let path: String
    let name: String
    let displayPath: String
    let searchKey: String
    let source: FolderSource
    let lastUsed: Date

    init(path: String, source: FolderSource, lastUsed: Date = .distantPast) {
        let standardized = FolderItem.standardizePath(path)
        self.path = standardized
        let url = URL(fileURLWithPath: standardized)
        let resolvedName = url.lastPathComponent.isEmpty ? standardized : url.lastPathComponent
        let resolvedDisplay = FolderItem.abbreviateWithTilde(standardized)
        self.name = resolvedName
        self.displayPath = resolvedDisplay
        self.searchKey = "\(resolvedName) \(resolvedDisplay)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        self.source = source
        self.lastUsed = lastUsed

        let tag: String
        switch source {
        case .openFinderWindow(let idx):
            tag = "finder-\(idx)"
        case .pinned:
            tag = "pinned"
        case .recent:
            tag = "recent"
        }
        self.id = "\(tag):\(standardized)"
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var icon: NSImage {
        FileMetadataCache.shared.icon(forPath: path, size: 20)
    }

    /// Cached check (4s TTL) for smooth 60fps SwiftUI list rendering without blocking on CloudStorage I/O.
    var existsCached: Bool {
        FileMetadataCache.shared.directoryExistsCached(path)
    }

    /// Live check performed right before navigating to guarantee directory validity.
    var existsOnDisk: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        if !exists {
            FileMetadataCache.shared.invalidateDirectory(path)
        }
        return exists
    }

    var formattedTooltip: String {
        FileMetadataCache.shared.formattedFolderTooltip(name: name, path: path)
    }

    static func standardizePath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let standard = (expanded as NSString).standardizingPath
        if standard.count > 1 && standard.hasSuffix("/") {
            return String(standard.dropLast())
        }
        return standard
    }

    static func abbreviateWithTilde(_ fullPath: String) -> String {
        if fullPath == homePath {
            return "~"
        }
        if fullPath.hasPrefix(homePath + "/") {
            return "~" + fullPath.dropFirst(homePath.count)
        }
        return fullPath
    }
}

struct StoredRecentFolder: Codable, Hashable {
    let path: String
    var lastUsed: Date
}
