import Foundation
import AppKit

struct SavedFileInfo: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let parentPath: String
    let modificationDate: Date
    let fileSize: Int64

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var formattedDate: String {
        let df = DateFormatter()
        if Calendar.current.isDateInToday(modificationDate) {
            df.timeStyle = .short
            return "Hôm nay \(df.string(from: modificationDate))"
        } else if Calendar.current.isDateInYesterday(modificationDate) {
            df.timeStyle = .short
            return "Hôm qua \(df.string(from: modificationDate))"
        } else {
            df.dateStyle = .short
            df.timeStyle = .short
            return df.string(from: modificationDate)
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 20, height: 20)
        return img
    }

    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
