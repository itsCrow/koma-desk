import Foundation

extension ComicArchive {
    /// How much extracted comic data to keep on disk between runs. One
    /// high-resolution volume runs to roughly half a gigabyte, so this holds
    /// the last several comics read.
    public static let defaultCacheBudget = 4 << 30  // 4 GB

    /// Trims the extraction cache to `budget` bytes, dropping the
    /// least-recently-read comics first.
    ///
    /// Extractions are pure derived data — `open` rebuilds any directory that
    /// goes missing, and `loadManifest` already rejects a half-present one — so
    /// pruning can't lose anything the reader can't recreate. The most recent
    /// extraction is always kept, even if it alone exceeds the budget.
    public static func pruneCache(in root: URL = cacheRoot, budget: Int = defaultCacheBudget) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let extractions = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { url in
                let read = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url: url, lastRead: read, size: directorySize(url))
            }
            .sorted { $0.lastRead > $1.lastRead }

        var kept = 0
        for (rank, extraction) in extractions.enumerated() {
            kept += extraction.size
            guard rank > 0, kept > budget else { continue }
            try? manager.removeItem(at: extraction.url)
        }
    }

    private static func directorySize(_ directory: URL) -> Int {
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return enumerator.reduce(into: 0) { total, entry in
            guard let file = entry as? URL else { return }
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
    }

    private static var manager: FileManager { .default }
}
