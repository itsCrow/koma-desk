import AppKit
import CryptoKit
import Foundation
import Observation
import ComicArchive
import ComicLibrary
import RemoteComicSource

/// The comics on this Mac, as the app understands them: folders being
/// watched, the series found in them, and how far each item has been read.
/// Nothing is copied; the folders are read where they are.
@Observable
@MainActor
final class Library {
    private(set) var index: LibraryIndex
    /// Where the index and the covers live.
    let folder: URL

    /// A chapter prefetch in progress for a series, keyed by series name —
    /// so the library shelf can show it's really downloading everything,
    /// not just the one chapter someone happens to click.
    private(set) var remoteDownloadProgress: [String: DownloadProgress] = [:]

    /// A check for new chapters in flight, so a second request for the same
    /// series waits on the first instead of hitting the site twice.
    private(set) var remoteRefreshInFlight: Set<String> = []
    /// What the last check found, long enough to read, then cleared.
    private(set) var remoteRefreshNotice: [String: RemoteRefreshNotice] = [:]

    @ObservationIgnored private var refreshTasks: [String: Task<RemoteRefreshOutcome, Never>] = [:]
    @ObservationIgnored private var noticeGeneration: [String: Int] = [:]

    struct DownloadProgress: Equatable {
        var done: Int
        var total: Int
        var isComplete: Bool { done >= total }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var coverTasks: [String: Task<NSImage?, Never>] = [:]

    /// `folder` other than the default keeps a test's library to itself.
    init(folder: URL = LibraryStore.defaultFolder) {
        self.folder = folder
        index = LibraryStore.load(from: folder)
        // Files come and go between launches.
        rescan()
        resumeDownloads()
    }

    /// Downloads whatever a series from the web still lacks: chapters a
    /// download that was cut short — the app quitting mid-import — never
    /// reached, and chapters saved with pages missing.
    private func resumeDownloads() {
        let remote = index.remoteSeries
        guard !remote.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for series in remote {
                let lacking = series.items.filter { item in
                    Self.chapterSource(for: item.source).map { !RemoteComicSource.isComplete($0) } ?? false
                }
                guard !lacking.isEmpty else { continue }
                // One series at a time: every series at once is more
                // connections than the image hosts will hold open.
                await self?.prefetchAllPages(for: lacking, seriesName: series.name, retryingIncomplete: true)?.value
            }
        }
    }

    var roots: [URL] { index.roots }
    var series: [Series] { index.allSeries }
    var isEmpty: Bool { index.allSeries.isEmpty }

    func series(named name: String) -> Series? { index.series(named: name) }
    func item(id: String) -> LibraryItem? { index.item(id: id) }
    func series(containing item: LibraryItem) -> Series? { index.series(containing: item) }

    // MARK: - Folders

    /// Watches a folder, or a single file, and reads what's in it.
    func addRoot(_ url: URL) {
        let standard = url.standardizedFileURL
        guard !index.roots.contains(where: { $0.standardizedFileURL == standard }) else {
            rescan()
            return
        }
        index.roots.append(standard)
        rescan()
    }

    func removeRoot(_ url: URL) {
        index.roots.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        rescan()
    }

    /// Reads every root again. Quick — it's a directory walk, not an
    /// extraction — so it runs whenever the app comes back to the front.
    func rescan() {
        let found = LibraryScanner.scan(roots: index.roots)
        if found != index.series {
            index.series = found
        }
        scheduleSave()
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add to Library"
        panel.message = "Choose a folder of comics — a series, or a folder of series — or a single comic file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ReaderModel.supportedContentTypes
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addRoot(url) }
    }

    // MARK: - Web sources

    /// Adds a comic from the web: a manifest URL, or a known site's series
    /// or chapter URL. Returns the series name, so the caller can jump to it.
    @discardableResult
    func addRemoteSource(_ url: URL) async throws -> String {
        let siteID = RemoteComicSource.siteID(for: url)
        let resolved = try await RemoteComicSource.resolveSeries(from: url)
        let record = RemoteSourceRecord(
            url: url, kind: siteID != nil ? .site : .manifest, siteID: siteID,
            seriesName: resolved.seriesName, addedDate: Date(), lastRefreshed: Date()
        )
        index.remoteSources.removeAll { $0.url == url }
        index.remoteSources.append(record)
        let newItems = mergeRemoteSeries(resolved, into: resolved.seriesName, siteID: siteID, manifestURL: url)
        scheduleSave()
        prefetchAllPages(for: newItems, seriesName: resolved.seriesName)
        return resolved.seriesName
    }

    /// How long a saved link can sit before opening its series checks again.
    static let remoteRefreshStaleInterval: TimeInterval = 24 * 60 * 60

    /// Re-reads one series' saved link and downloads chapters that weren't
    /// there last time. Chapters already saved are left on disk.
    func refreshRemoteSeries(named name: String) async -> RemoteRefreshOutcome {
        if let task = refreshTasks[name] { return await task.value }
        let task = Task { await performRefresh(named: name) }
        refreshTasks[name] = task
        defer { refreshTasks[name] = nil }
        return await task.value
    }

    /// The same check, only when the last one is older than a day — or has
    /// never succeeded. Returns nil for a series that didn't come from a
    /// link, and nil when the saved check is still fresh, so opening a
    /// series doesn't talk to the site every time.
    func refreshRemoteSeriesIfStale(named name: String, now: Date = Date()) async -> RemoteRefreshOutcome? {
        let records = index.remoteSources.filter { $0.seriesName == name }
        guard !records.isEmpty else { return nil }
        let stale = records.contains { record in
            guard let last = record.lastRefreshed else { return true }
            return now.timeIntervalSince(last) >= Self.remoteRefreshStaleInterval
        }
        guard stale else { return nil }
        return await refreshRemoteSeries(named: name)
    }

    func isCheckingForChapters(_ seriesName: String) -> Bool {
        remoteRefreshInFlight.contains(seriesName)
    }

    /// Puts the outcome where the shelf and the series page can show it.
    /// "Up to date" is only worth saying when someone asked — a background
    /// check that finds nothing should stay quiet.
    func presentRefreshNotice(for seriesName: String, outcome: RemoteRefreshOutcome, announceUpToDate: Bool) {
        guard let notice = RemoteRefreshNotice.make(outcome, announceUpToDate: announceUpToDate) else { return }
        noticeGeneration[seriesName, default: 0] += 1
        let generation = noticeGeneration[seriesName, default: 0]
        remoteRefreshNotice[seriesName] = notice
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(notice.kind.lingerSeconds))
            guard let self, self.noticeGeneration[seriesName] == generation else { return }
            self.remoteRefreshNotice[seriesName] = nil
        }
    }

    private func performRefresh(named name: String) async -> RemoteRefreshOutcome {
        let records = index.remoteSources.filter { $0.seriesName == name }
        guard !records.isEmpty else {
            return .failed("This series didn’t come from a link.")
        }
        remoteRefreshInFlight.insert(name)
        defer { remoteRefreshInFlight.remove(name) }

        var newCount = 0
        var failures: [String] = []
        for record in records {
            do {
                let resolved = try await RemoteComicSource.resolveSeries(from: record.url)
                let newItems = mergeRemoteSeries(
                    resolved, into: record.seriesName, siteID: record.siteID, manifestURL: record.url
                )
                newCount += newItems.count
                if let i = index.remoteSources.firstIndex(where: { $0.url == record.url }) {
                    index.remoteSources[i].lastRefreshed = Date()
                }
                prefetchAllPages(for: newItems, seriesName: record.seriesName)
            } catch {
                failures.append(Self.describeRemoteError(error))
            }
        }
        scheduleSave()
        if newCount > 0 { return .newChapters(newCount) }
        if let failure = failures.first { return .failed(failure) }
        return .upToDate
    }

    /// `siteID` non-nil means every chapter came from that site adapter;
    /// nil means the URL was read as a manifest. Chapters land in the
    /// source's order. Only chapters that weren't already known come back,
    /// so the caller can download just those.
    @discardableResult
    private func mergeRemoteSeries(_ resolved: ResolvedSeries, into seriesName: String, siteID: String?, manifestURL: URL) -> [LibraryItem] {
        let items = resolved.chapters.map { chapter -> LibraryItem in
            let source: ItemSource = siteID.map { .site(site: $0, chapterURL: chapter.chapterURL) }
                ?? .manifest(manifestURL: manifestURL, chapterKey: chapter.chapterKey)
            return LibraryItem(
                remote: source, series: seriesName, volume: chapter.volume,
                chapter: chapter.number.map { Int($0) }, title: chapter.title ?? "",
                arc: nil, displayURL: chapter.chapterURL
            )
        }
        if let i = index.remoteSeries.firstIndex(where: { $0.name == seriesName }) {
            let merged = RemoteSeriesMerge.merge(existing: index.remoteSeries[i].items, incoming: items)
            index.remoteSeries[i].items = merged.items
            return merged.newItems
        } else {
            index.remoteSeries.append(Series(name: seriesName, items: items))
            return items
        }
    }

    private static func describeRemoteError(_ error: Error) -> String {
        if let described = error as? LocalizedError, let message = described.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    /// How many chapters download at once — each one already fans its own
    /// pages out across `RemoteComicSource`'s own concurrency limit, so this
    /// just bounds how many chapters are mid-download simultaneously.
    private nonisolated static let maxConcurrentChapterPrefetches = 3

    private nonisolated static func chapterSource(for source: ItemSource) -> ChapterSource? {
        switch source {
        case .local: return nil
        case .manifest(let manifestURL, let chapterKey): return .manifest(manifestURL: manifestURL, chapterKey: chapterKey)
        case .site(let site, let chapterURL): return .site(site: site, chapterURL: chapterURL)
        }
    }

    /// How long a "done" badge lingers on the shelf before it clears —
    /// long enough to actually notice, short enough not to look stuck.
    private static let downloadCompleteLingerSeconds = 2.5

    /// Downloads every page of every given chapter into the cache right
    /// away, so opening one later — from the shot list, from Continue
    /// Reading, from clicking it in the contents — is instant instead of a
    /// wait that reads as a hang. Detached from the caller so import
    /// returns as soon as the chapter *list* is known; failures are left
    /// for opening the chapter, or the next launch, to retry. Progress is published
    /// to `remoteDownloadProgress` as chapters finish, so the shelf can show
    /// it's actually happening.
    @discardableResult
    private func prefetchAllPages(for items: [LibraryItem], seriesName: String, retryingIncomplete: Bool = false) -> Task<Void, Never>? {
        let sources = items.compactMap { Self.chapterSource(for: $0.source) }
        guard !sources.isEmpty else { return nil }
        remoteDownloadProgress[seriesName] = DownloadProgress(done: 0, total: sources.count)
        return Task.detached(priority: .utility) { [weak self] in
            var completed = 0
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func startNext() {
                    guard next < sources.count else { return }
                    let source = sources[next]
                    next += 1
                    group.addTask { _ = try? await RemoteComicSource.open(source, retryingIncomplete: retryingIncomplete) }
                }
                for _ in 0..<min(Self.maxConcurrentChapterPrefetches, sources.count) { startNext() }
                while await group.next() != nil {
                    completed += 1
                    let done = completed
                    await self?.noteDownloadProgress(seriesName: seriesName, done: done, total: sources.count)
                    startNext()
                }
            }
        }
    }

    /// Records one chapter finishing (or failing — either way it's off the
    /// queue), and once every chapter has settled, clears the badge after a
    /// moment so the shelf goes back to normal on its own.
    private func noteDownloadProgress(seriesName: String, done: Int, total: Int) {
        remoteDownloadProgress[seriesName] = DownloadProgress(done: done, total: total)
        guard done >= total else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.downloadCompleteLingerSeconds))
            guard let self, self.remoteDownloadProgress[seriesName]?.done == done else { return }
            self.remoteDownloadProgress[seriesName] = nil
        }
    }

    /// Whether `series` came in from the web rather than a scanned folder —
    /// only these can be removed on their own; a folder-scanned series goes
    /// away with `removeRoot` instead.
    func isRemoteSeries(_ series: Series) -> Bool {
        index.remoteSeries.contains { $0.name == series.name }
    }

    func isRemoteItem(_ item: LibraryItem) -> Bool {
        if case .local = item.source { return false }
        return true
    }

    /// Drops one chapter's cached pages so the next download fetches them
    /// again. Used when a chapter's pages were replaced at the same link.
    func forgetCachedPages(of item: LibraryItem) {
        guard let source = Self.chapterSource(for: item.source) else { return }
        RemoteComicSource.forget(source)
    }

    /// Downloads one chapter into the cache. The shelf badge shows it the
    /// same way it shows a new chapter arriving.
    func downloadChapter(_ item: LibraryItem) {
        prefetchAllPages(for: [item], seriesName: item.series)
    }

    /// Forgets a series brought in from the web entirely: its entry, the
    /// source URL(s) that fed it, its reading position and progress, its
    /// cached covers, and every chapter's downloaded pages — so adding the
    /// same URL again starts clean instead of `mergeRemoteSeries` treating
    /// every chapter as already known and skipping the fresh download.
    func removeRemoteSeries(_ series: Series) {
        guard let i = index.remoteSeries.firstIndex(where: { $0.name == series.name }) else { return }
        let removed = index.remoteSeries.remove(at: i)
        index.remoteSources.removeAll { $0.seriesName == removed.name }
        index.lastRead[removed.name] = nil
        index.recentSeries.removeAll { $0 == removed.name }
        remoteDownloadProgress[removed.name] = nil
        remoteRefreshNotice[removed.name] = nil
        remoteRefreshInFlight.remove(removed.name)
        for item in removed.items {
            index.positions[item.id] = nil
            index.spreadCounts[item.id] = nil
            index.covers[item.id] = nil
            try? FileManager.default.removeItem(at: coverURL(for: item))
            if let source = Self.chapterSource(for: item.source) {
                RemoteComicSource.forget(source)
            }
        }
        scheduleSave()
    }

    // MARK: - Reading

    func position(for item: LibraryItem) -> Int {
        index.positions[item.id] ?? 0
    }

    func setPosition(_ spread: Int, for item: LibraryItem) {
        guard index.positions[item.id] != spread else { return }
        index.positions[item.id] = spread
        scheduleSave()
    }

    /// Learned the first time an item is opened — turns a bare spread index
    /// into an actual read-percentage. Never shrinks: a page-count guess
    /// from a damaged open shouldn't erase a good one from before.
    func noteSpreadCount(_ count: Int, for item: LibraryItem) {
        guard count > 0, (index.spreadCounts[item.id] ?? 0) != count else { return }
        index.spreadCounts[item.id] = count
        scheduleSave()
    }

    /// How far into `item` the reader has gotten, 0 to 1 — nil until it's
    /// been opened at least once, since the total isn't known before then.
    func progress(for item: LibraryItem) -> Double? {
        guard let total = index.spreadCounts[item.id], total > 1 else { return nil }
        return min(max(Double(position(for: item)) / Double(total - 1), 0), 1)
    }

    func noteRead(_ item: LibraryItem) {
        index.noteRead(item)
        scheduleSave()
    }

    /// The item to pick up in a series: the one last read there, or the first.
    func continueItem(in series: Series) -> LibraryItem? {
        index.continueItem(in: series)
    }

    /// Whether anything of this item has been read past its first spread.
    func hasStarted(_ item: LibraryItem) -> Bool {
        position(for: item) > 0
    }

    /// Series with something to pick up, most recently read first.
    var recentlyRead: [(series: Series, item: LibraryItem)] {
        index.recentSeries.compactMap { name in
            guard let series = index.series(named: name),
                  let id = index.lastRead[name], let item = series.item(id: id) else { return nil }
            return (series, item)
        }
    }

    // MARK: - Covers

    /// The first page of the item, small, from a cache that's filled the
    /// first time it's asked for — without extracting the whole file.
    func cover(for item: LibraryItem) async -> NSImage? {
        if let task = coverTasks[item.id] { return await task.value }
        let file = coverURL(for: item)
        let itemSource = item.source
        let localURL = item.url
        let task = Task<NSImage?, Never> {
            if let image = NSImage(contentsOf: file) { return image }
            let data: Data?
            switch itemSource {
            case .local:
                data = await Task.detached(priority: .utility) {
                    try? ComicArchive.firstPageData(of: localURL)
                }.value
            case .manifest(let manifestURL, let chapterKey):
                // Phase 1: reuse the same download a full read would use —
                // wasteful for a thumbnail, but it's cached forever after,
                // and it warms the chapter for when the reader opens it.
                data = await Self.firstRemotePageData(.manifest(manifestURL: manifestURL, chapterKey: chapterKey))
            case .site(let site, let chapterURL):
                data = await Self.firstRemotePageData(.site(site: site, chapterURL: chapterURL))
            }
            guard let data else { return nil }
            return await Task.detached(priority: .utility) { () -> NSImage? in
                guard let full = NSImage(data: data) else { return nil }
                let small = Self.downscale(full, toHeight: 600)
                if let jpeg = Self.jpegData(small) {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: file, options: .atomic)
                }
                return small
            }.value
        }
        coverTasks[item.id] = task
        let image = await task.value
        if image == nil { coverTasks[item.id] = nil }
        return image
    }

    /// A series' cover is its first item's.
    func cover(for series: Series) async -> NSImage? {
        guard let first = series.items.first else { return nil }
        return await cover(for: first)
    }

    private static func firstRemotePageData(_ source: ChapterSource) async -> Data? {
        guard let comic = try? await RemoteComicSource.open(source), let first = comic.pages.first else { return nil }
        return try? Data(contentsOf: first)
    }

    private func coverURL(for item: LibraryItem) -> URL {
        let digest = SHA256.hash(data: Data(item.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return LibraryStore.coversFolder(in: folder).appendingPathComponent("\(digest).jpg")
    }

    nonisolated private static func downscale(_ image: NSImage, toHeight height: CGFloat) -> NSImage {
        guard image.size.height > height, image.size.height > 0 else { return image }
        let scale = height / image.size.height
        let size = NSSize(width: (image.size.width * scale).rounded(), height: height)
        let small = NSImage(size: size)
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        small.unlockFocus()
        return small
    }

    nonisolated private static func jpegData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? LibraryStore.save(index, to: folder)
    }
}

/// What a check for new chapters found.
enum RemoteRefreshOutcome: Equatable {
    case newChapters(Int)
    case upToDate
    case failed(String)
}

/// A line under a series' name after a check, or while explaining a failure.
struct RemoteRefreshNotice: Equatable {
    enum Kind: Equatable {
        case newChapters, upToDate, failed

        var lingerSeconds: Double {
            switch self {
            case .newChapters: return 6
            case .upToDate: return 3
            case .failed: return 8
            }
        }
    }

    var message: String
    var kind: Kind

    static func make(_ outcome: RemoteRefreshOutcome, announceUpToDate: Bool) -> RemoteRefreshNotice? {
        switch outcome {
        case .newChapters(let count):
            let message = count == 1 ? "1 new chapter" : "\(count) new chapters"
            return RemoteRefreshNotice(message: message, kind: .newChapters)
        case .upToDate:
            guard announceUpToDate else { return nil }
            return RemoteRefreshNotice(message: "Up to date", kind: .upToDate)
        case .failed(let reason):
            return RemoteRefreshNotice(message: "Couldn’t check for new chapters. \(reason)", kind: .failed)
        }
    }
}

extension LibraryItem {
    /// "Berserk · Vol. 1", "Dragon Ball · Ch. 24" — the item named with its series.
    var fullName: String { "\(series) · \(label)" }
}

// The app module's `Library` is a class; SwiftUI also has a `LibraryItem`, so the
// library's item type is named through the module.
typealias LibraryItem = ComicLibrary.LibraryItem
typealias Series = ComicLibrary.Series

/// How the library's series are ordered.
enum LibrarySort: String, CaseIterable, Sendable {
    case recent, name

    var label: String {
        switch self {
        case .recent: return "Recently Read"
        case .name: return "Name"
        }
    }

    /// Recently Read puts what's been read, most recent first, ahead of
    /// everything else by name; Name is just the names, the way Finder
    /// orders them.
    func sorted(_ series: [Series], recent: [String]) -> [Series] {
        let byName = series.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard self == .recent else { return byName }
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let read = series.filter { rank[$0.name] != nil }.sorted { rank[$0.name]! < rank[$1.name]! }
        return read + byName.filter { rank[$0.name] == nil }
    }
}

extension Library {
    /// How far through a whole series the reader is: the items before the
    /// one being read, plus how far into that one. Nil before it's started.
    func seriesProgress(_ series: Series) -> Double? {
        guard index.lastRead[series.name] != nil, let current = continueItem(in: series),
              let position = series.items.firstIndex(where: { $0.id == current.id })
        else { return nil }
        return Self.seriesFraction(index: position, itemProgress: progress(for: current), count: series.items.count)
    }

    nonisolated static func seriesFraction(index: Int, itemProgress: Double?, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return min(max((Double(index) + (itemProgress ?? 0)) / Double(count), 0), 1)
    }
}
