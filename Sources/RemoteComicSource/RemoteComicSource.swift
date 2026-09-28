import CryptoKit
import Foundation

/// Reads a comic from the web: a link to a known site, or a link to a
/// generic JSON manifest. Downloads a chapter's pages once into a local
/// cache — the network equivalent of `ComicArchive` — so the rest of the
/// app treats a chapter read this way exactly like one extracted from an
/// archive.
public enum RemoteComicSource {
    /// Swapped out by tests so they never touch the network.
    nonisolated(unsafe) static var fetcher: PageFetching = URLSessionFetcher()
    /// Known sites, tried in order before falling back to manifest mode.
    static let adapters: [SiteAdapter] = [WeebCentralAdapter()]

    public static var cacheRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PanelsRemote", isDirectory: true)
    }

    /// Downloaded chapters are typically much smaller per-volume than local
    /// archives (single chapters, not whole tankōbon), so a smaller budget
    /// still holds plenty of recently-read material.
    public static let defaultCacheBudget = 2 << 30  // 2 GB

    /// Given any URL the user pastes, finds the series and its chapters —
    /// via a matching site adapter, or by treating the URL as a manifest.
    public static func resolveSeries(from url: URL) async throws -> ResolvedSeries {
        if let adapter = adapters.first(where: { $0.canHandle(url) }) {
            return try await adapter.resolveSeries(from: url)
        }
        return try await ManifestSource.resolveSeries(from: url)
    }

    /// The site adapter that would handle `url`, if any — so a caller
    /// building a `LibraryItem` can tell a site chapter from a manifest one
    /// without duplicating the adapter lookup.
    public static func siteID(for url: URL) -> String? {
        adapters.first(where: { $0.canHandle(url) })?.id
    }

    /// Downloads (or reuses) one chapter's pages, in order, to local disk.
    /// `progress` reports `(downloaded, total)` as pages complete.
    public static func open(
        _ source: ChapterSource,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RemoteComic {
        let identity = cacheKey(for: source)
        let directory = cacheRoot.appendingPathComponent(identity, isDirectory: true)

        if let cached = loadManifest(in: directory, source: source, identity: identity) {
            return cached
        }

        let imageURLs = try await pageImageURLs(for: source)
        guard !imageURLs.isEmpty else { throw RemoteSourceError.noPages }

        // A stale or half-downloaded chapter is worse than none.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let downloaded = await downloadPages(imageURLs, into: directory, progress: progress)
        guard !downloaded.pages.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            throw RemoteSourceError.noPages
        }

        let manifest = Manifest(pages: downloaded.pages, warning: downloaded.warning)
        saveManifest(manifest, in: directory)
        return RemoteComic(
            source: source,
            identity: identity,
            pages: downloaded.pages.map { directory.appendingPathComponent($0) },
            warning: downloaded.warning
        )
    }

    /// Deletes one chapter's cached pages, if any — used when a series is
    /// removed from the library, so a later re-add downloads every chapter
    /// fresh instead of a fresh `resolveSeries` quietly reusing pages left
    /// over from before.
    public static func forget(_ source: ChapterSource) {
        let directory = cacheRoot.appendingPathComponent(cacheKey(for: source), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Trims the download cache to `budget` bytes, dropping the
    /// least-recently-read chapters first. Mirrors `ComicArchive.pruneCache`.
    public static func pruneCache(in root: URL = cacheRoot, budget: Int = defaultCacheBudget) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let chapters = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { url in
                let read = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url: url, lastRead: read, size: directorySize(url))
            }
            .sorted { $0.lastRead > $1.lastRead }

        var kept = 0
        for (rank, chapter) in chapters.enumerated() {
            kept += chapter.size
            guard rank > 0, kept > budget else { continue }
            try? manager.removeItem(at: chapter.url)
        }
    }

    // MARK: - Resolving pages

    private static func pageImageURLs(for source: ChapterSource) async throws -> [URL] {
        switch source {
        case .manifest(let manifestURL, let chapterKey):
            return try await ManifestSource.pageImageURLs(manifestURL: manifestURL, chapterKey: chapterKey)
        case .site(let site, let chapterURL):
            guard let adapter = adapters.first(where: { $0.id == site }) else {
                throw RemoteSourceError.unknownSite(site)
            }
            return try await adapter.pageImageURLs(chapterURL: chapterURL)
        }
    }

    // MARK: - Downloading

    private struct Download {
        var pages: [String] = []
        var warning: String?
    }

    /// Unbounded concurrency for a 40-page chapter would be rude to the
    /// source site and likely to get the requester rate-limited.
    private static let maxConcurrentDownloads = 6

    private static func downloadPages(
        _ urls: [URL], into directory: URL, progress: (@Sendable (Int, Int) -> Void)?
    ) async -> Download {
        let total = urls.count
        var filenames = [String?](repeating: nil, count: total)
        var completed = 0
        var failures = 0

        await withTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func startNext() {
                guard next < total else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask {
                    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                    let name = String(format: "%04d.%@", index, ext)
                    do {
                        let data = try await fetcher.fetchData(url)
                        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                        return (index, name)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            for _ in 0..<min(maxConcurrentDownloads, total) { startNext() }
            while let (index, name) = await group.next() {
                filenames[index] = name
                completed += 1
                if name == nil { failures += 1 }
                progress?(completed, total)
                startNext()
            }
        }

        let pages = filenames.compactMap { $0 }
        let warning = failures > 0
            ? "\(failures) of \(total) page\(total == 1 ? "" : "s") couldn’t be downloaded."
            : nil
        return Download(pages: pages, warning: warning)
    }

    // MARK: - Cache identity & manifest

    private static func cacheKey(for source: ChapterSource) -> String {
        let digest = SHA256.hash(data: Data(source.cacheSeed.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Codable {
        let pages: [String]
        let warning: String?
    }

    private static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private static func loadManifest(in directory: URL, source: ChapterSource, identity: String) -> RemoteComic? {
        guard let data = try? Data(contentsOf: manifestURL(in: directory)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.pages.isEmpty
        else { return nil }

        let pages = manifest.pages.map { directory.appendingPathComponent($0) }
        guard pages.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        // Counts as a read, so pruning measures least-recently-*used*.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: directory.path
        )
        return RemoteComic(source: source, identity: identity, pages: pages, warning: manifest.warning)
    }

    private static func saveManifest(_ manifest: Manifest, in directory: URL) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(in: directory), options: .atomic)
    }

    private static func directorySize(_ directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return enumerator.reduce(into: 0) { total, entry in
            guard let file = entry as? URL else { return }
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
    }
}
