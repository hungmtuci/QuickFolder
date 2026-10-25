import Foundation
import AppKit

enum FolderSource: Equatable, Hashable {
    case openFinderWindow(windowIndex: Int)
    case pinned
    case recent
}

struct FolderItem: Identifiable, Hashable {
    var id: String { "\(sourceTag):\(path)" }
    let path: String
    let name: String
    let displayPath: String
    let source: FolderSource
    let lastUsed: Date

    private var sourceTag: String {
        switch source {
        case .openFinderWindow(let idx):
            return "finder-\(idx)"
        case .pinned:
            return "pinned"
        case .recent:
            return "recent"
        }
    }

    init(path: String, source: FolderSource, lastUsed: Date = Date()) {
        let standardized = FolderItem.standardizePath(path)
        self.path = standardized
        let url = URL(fileURLWithPath: standardized)
        self.name = url.lastPathComponent.isEmpty ? standardized : url.lastPathComponent
        self.displayPath = FolderItem.abbreviateWithTilde(standardized)
        self.source = source
        self.lastUsed = lastUsed
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 20, height: 20)
        return img
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if fullPath == home {
            return "~"
        }
        if fullPath.hasPrefix(home + "/") {
            return "~" + fullPath.dropFirst(home.count)
        }
        return fullPath
    }
}

struct StoredRecentFolder: Codable, Hashable {
    let path: String
    var lastUsed: Date
}
