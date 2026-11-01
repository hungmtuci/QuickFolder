import Foundation
import AppKit

enum ScreenGeometry {
    /// Height of the primary display (origin 0,0) used by macOS Quartz/Accessibility top-left coordinates.
    static var primaryScreenHeight: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin.x == 0 && $0.frame.origin.y == 0 }) {
            return primary.frame.height
        }
        return NSScreen.screens.first?.frame.height ?? 900
    }
}

final class FileMetadataCache: @unchecked Sendable {
    static let shared = FileMetadataCache()

    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    private struct ExistenceEntry {
        let exists: Bool
        let timestamp: TimeInterval
    }

    private struct TooltipEntry {
        let text: String
        let timestamp: TimeInterval
    }

    private let lock = NSLock()
    private var existenceCache: [String: ExistenceEntry] = [:]
    private var tooltipCache: [String: TooltipEntry] = [:]

    private let existenceTTL: TimeInterval = 4.0
    private let tooltipTTL: TimeInterval = 12.0

    private let mediumDateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    private let shortTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()

    private let shortDateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    private init() {}

    func icon(forPath path: String, size: CGFloat = 20) -> NSImage {
        let key = "\(Int(size)):\(path)" as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: size, height: size)
        iconCache.setObject(img, forKey: key)
        return img
    }

    func directoryExistsCached(_ path: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let entry = existenceCache[path], now - entry.timestamp < existenceTTL {
            lock.unlock()
            return entry.exists
        }
        lock.unlock()

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue

        lock.lock()
        if existenceCache.count > 512 {
            existenceCache.removeAll(keepingCapacity: true)
        }
        existenceCache[path] = ExistenceEntry(exists: exists, timestamp: now)
        lock.unlock()
        return exists
    }

    func invalidateDirectory(_ path: String) {
        lock.lock()
        existenceCache.removeValue(forKey: path)
        tooltipCache.removeValue(forKey: path)
        lock.unlock()
    }

    func formattedRelativeDate(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Hôm nay \(shortTimeFormatter.string(from: date))"
        } else if cal.isDateInYesterday(date) {
            return "Hôm qua \(shortTimeFormatter.string(from: date))"
        } else {
            return shortDateTimeFormatter.string(from: date)
        }
    }

    func formattedFolderTooltip(name: String, path: String) -> String {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let entry = tooltipCache[path], now - entry.timestamp < tooltipTTL {
            lock.unlock()
            return entry.text
        }
        lock.unlock()

        var lines: [String] = [
            "📁 \(name)",
            "Đường dẫn: \(path)"
        ]
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .volumeAvailableCapacityForImportantUsageKey]) {
            if let modDate = values.contentModificationDate {
                lock.lock()
                let modStr = mediumDateTimeFormatter.string(from: modDate)
                lock.unlock()
                lines.append("Sửa đổi gần nhất: \(modStr)")
            }
            if let free = values.volumeAvailableCapacityForImportantUsage {
                let byteCount = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                lines.append("Dung lượng trống ổ đĩa: \(byteCount)")
            }
        }
        let result = lines.joined(separator: "\n")

        lock.lock()
        if tooltipCache.count > 256 {
            tooltipCache.removeAll(keepingCapacity: true)
        }
        tooltipCache[path] = TooltipEntry(text: result, timestamp: now)
        lock.unlock()
        return result
    }
}
