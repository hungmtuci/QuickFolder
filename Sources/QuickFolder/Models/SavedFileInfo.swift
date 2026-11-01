import Foundation
import AppKit

struct SavedFileInfo: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let parentPath: String
    let modificationDate: Date
    let fileSize: Int64
    let formattedDate: String
    let formattedSize: String

    init(
        name: String,
        path: String,
        parentPath: String,
        modificationDate: Date,
        fileSize: Int64
    ) {
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.formattedDate = FileMetadataCache.shared.formattedRelativeDate(modificationDate)
        self.formattedSize = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var icon: NSImage {
        FileMetadataCache.shared.icon(forPath: path, size: 20)
    }

    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
