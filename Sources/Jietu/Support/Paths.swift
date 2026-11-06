import Foundation

enum Paths {
    /// 应用自己的缓存目录（用户在访达里一般看不到）。
    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.wuyinan.jietu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 点对勾时放进剪贴板的临时文件目录，24 小时后清理。
    static var clipboardDir: URL { subdir("Clipboard") }

    /// 录制中的原始文件目录。
    static var recordingsDir: URL { subdir("Recordings") }

    /// 滚动截图拼接失败时保存的排查画面，24 小时后清理。
    static var scrollDebugDir: URL { subdir("ScrollDebug") }

    private static func subdir(_ name: String) -> URL {
        let dir = cacheDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    static func screenshotName() -> String { "截图 \(timestamp()).png" }
    static func recordingName(ext: String) -> String { "录屏 \(timestamp()).\(ext)" }

    /// 删除超过 24 小时的剪贴板临时文件和残留的原始录制文件。
    static func cleanupOldFiles(maxAge: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        let now = Date()
        for dir in [clipboardDir, recordingsDir, scrollDebugDir] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in items {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(date) > maxAge { try? fm.removeItem(at: url) }
            }
        }
    }

    static func freeDiskSpace() -> Int64 {
        let values = try? cacheDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }
}
