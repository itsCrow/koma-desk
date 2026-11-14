import CryptoKit
import Foundation


/// Reads a comic from the web: a link to a known site, or a link to a
/// generic JSON manifest. Downloads a chapter's pages once and keeps them
/// until the series is removed — the network equivalent of `ComicArchive` —
/// so the rest of the app treats a chapter read this way exactly like one
/// extracted from an archive.
public enum RemoteComicSource {
    /// Swapped out by tests so they never touch the network.
    nonisolated(unsafe) static var fetcher: PageFetching = URLSessionFetcher()
    /// Known sites, tried in order before falling back to manifest mode.
    static let adapters: [SiteAdapter] = [WeebCentralAdapter()]

    /// Tests point downloads at a scratch folder. Production leaves this nil.
    nonisolated(unsafe) static var cacheRootOverride: URL?

    /// Where a chapter's pages live. Application Support, not the temporary
    /// directory: the system deletes that on its own schedule, which is how
    /// a series the user still has in the library lost its pages.
    public static var cacheRoot: URL {
        cacheRootOverride ?? persistentCacheRoot
    }

    /// The real on-disk location, ignoring any test override.
    public static var persistentCacheRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PanelsMVP/RemotePages", isDirectory: true)
    }

    /// Downloads used to live here. Moved once into `persistentCacheRoot`.
    private static var legacyCacheRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PanelsRemote", isDirectory: true)
    }

    /// Moves chapters downloaded before the cache left the temporary folder.
    /// A chapter already in the new location wins; the leftover copy is dropped.
    public static func migrateLegacyCacheIfNeeded() {
        migrateLegacyCache(from: legacyCacheRoot, into: persistentCacheRoot)
    }

    static func migrateLegacyCache(from legacy: URL, into root: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ), !entries.isEmpty else { return }
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            let destination = root.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            if manager.fileExists(atPath: destination.path) {
                try? manager.removeItem(at: entry)
            } else {
                try? manager.moveItem(at: entry, to: destination)
            }
        }
        try? manager.removeItem(at: legacy)
    }

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
    /// `retryingIncomplete` tries again for a saved chapter that's missing
    /// pages, keeping the saved copy unless the new one has more of them.
    public static func open(
        _ source: ChapterSource,
        retryingIncomplete: Bool = false,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RemoteComic {
        let identity = cacheKey(for: source)
        let directory = cacheRoot.appendingPathComponent(identity, isDirectory: true)

        if let cached = loadManifest(in: directory, source: source, identity: identity) {
            guard retryingIncomplete, cached.warning != nil else { return cached }
            let retry = directory.deletingLastPathComponent().appendingPathComponent(identity + "-retry", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: retry) }
            guard let fresh = try? await download(source, identity: identity, into: retry, progress: progress),
                  fresh.pages.count > cached.pages.count
            else { return cached }
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.moveItem(at: retry, to: directory)
            return loadManifest(in: directory, source: source, identity: identity) ?? fresh
        }
        return try await download(source, identity: identity, into: directory, progress: progress)
    }

    private static func download(
        _ source: ChapterSource, identity: String, into directory: URL,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> RemoteComic {

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

    /// Image hosts drop connections and time out under load; a page that
    /// failed that way usually comes through a moment later.
    private static let fetchAttempts = 3

    private static func fetchRetryingTransient(_ url: URL) async throws -> Data {
        var attempt = 1
        while true {
            do {
                return try await fetcher.fetchData(url)
            } catch where attempt < fetchAttempts && isTransient(error) {
                try await Task.sleep(for: .seconds(Double(attempt) * 1.5))
                attempt += 1
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed]
                .contains(urlError.code)
        }
        if case RemoteSourceError.http(let status, _) = error {
            return status == 429 || (500..<600).contains(status)
        }
        return false
    }

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
                        let data = try await fetchRetryingTransient(url)
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
        return RemoteComic(source: source, identity: identity, pages: pages, warning: manifest.warning)
    }

    /// Whether a chapter is saved with every page, without downloading:
    /// false when it's not saved, or saved with pages missing.
    public static func isComplete(_ source: ChapterSource) -> Bool {
        let identity = cacheKey(for: source)
        let directory = cacheRoot.appendingPathComponent(identity, isDirectory: true)
        guard let cached = loadManifest(in: directory, source: source, identity: identity) else { return false }
        return cached.warning == nil
    }

    private static func saveManifest(_ manifest: Manifest, in directory: URL) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(in: directory), options: .atomic)
    }
}
