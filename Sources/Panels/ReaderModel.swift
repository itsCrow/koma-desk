import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import ComicArchive
import PageSearch

extension ReadingDirection {
    /// How the direction is named in the menu. The enum itself lives in
    /// ComicArchive, which has no business knowing about menus.
    var label: String {
        switch self {
        case .rightToLeft: return "Right to Left (Manga)"
        case .leftToRight: return "Left to Right"
        }
    }
}

@Observable
@MainActor
final class ReaderModel {
    /// Single shared reader — the app has one window, and the app delegate needs
    /// somewhere to deliver files opened from Finder.
    static let shared = ReaderModel()

    private(set) var title: String?
    private(set) var pages: [URL] = []
    private(set) var spreads: [Spread] = []
    private(set) var warning: String?
    private(set) var isLoading = false
    /// Width-to-height of a two-page spread of the open comic. The window keeps
    /// this shape, which is what lets a spread fill it with no bars either side.
    private(set) var spreadAspect: CGFloat?

    /// The comic's lettering, read page by page in the background. Pages not
    /// yet read are nil; `isIndexing` is true until they're all in.
    private(set) var textIndex: PageTextIndex?
    /// Set by ⌘F; the reader opens the controls panel and focuses the field.
    var wantsSearchFocus = false
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch() } }
    }
    private(set) var searchHits: [SearchHit] = []
    /// Hits per zero-based page index, for the badges.
    private(set) var hitsByPage: [Int: Int] = [:]

    var errorMessage: String?
    var spreadIndex = 0 {
        didSet {
            guard spreadIndex != oldValue else { return }
            saveProgress()
            prefetchNeighbours()
        }
    }

    var direction: ReadingDirection {
        didSet {
            guard direction != oldValue else { return }
            UserDefaults.standard.set(direction.rawValue, forKey: Self.directionKey)
        }
    }

    @ObservationIgnored private let cache = PageCache()
    @ObservationIgnored private var source: URL?
    /// Pages that are wider than they are tall — double-page scans, shown alone.
    @ObservationIgnored private var wideFlags: [Bool] = []
    @ObservationIgnored private var pageIndexByURL: [URL: Int] = [:]
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let indexStore = TextIndexStore()

    private static let directionKey = "PanelsReadingDirection"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.directionKey)
        // Defaults to manga order.
        direction = stored.flatMap(ReadingDirection.init(rawValue:)) ?? .rightToLeft
    }

    var hasComic: Bool { !pages.isEmpty }

    // MARK: - Opening

    /// File extensions the reader accepts.
    static let supportedExtensions = ["cbr", "cbz", "cb7", "rar", "zip"]

    static var supportedContentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.message = "Choose a comic to read"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        warning = nil

        Task {
            // The page scan reads metadata for every page in the comic, so it
            // rides along with extraction rather than landing on the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> (ComicArchive, [Bool], CGFloat?) in
                    let comic = try ComicArchive.open(url)
                    let sizes = comic.pages.map(pagePixelSize)
                    return (comic, sizes.map(isWidePage), spreadAspectRatio(pageSizes: sizes))
                }
            }.value

            switch result {
            case .success(let (comic, wideFlags, aspect)):
                apply(comic, wideFlags: wideFlags, spreadAspect: aspect)
            case .failure(let error):
                isLoading = false
                errorMessage = Self.describe(error, for: url)
            }
        }
    }

    private static func describe(_ error: Error, for url: URL) -> String {
        guard let archiveError = error as? ArchiveError else {
            return "“\(url.lastPathComponent)” couldn’t be opened. \(error.localizedDescription)"
        }
        let headline = archiveError.errorDescription ?? "The comic couldn’t be opened."
        if let reason = archiveError.failureReason {
            return "\(headline)\n\n\(reason)"
        }
        return headline
    }

    private func apply(_ comic: ComicArchive, wideFlags scanned: [Bool], spreadAspect aspect: CGFloat?) {
        cache.removeAll()
        source = comic.source
        title = comic.title
        pages = comic.pages
        wideFlags = scanned
        spreadAspect = aspect
        pageIndexByURL = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($1, $0) })
        searchQuery = ""
        searchHits = []
        hitsByPage = [:]
        spreads = buildSpreads(pageCount: pages.count, isWide: wideFlags)
        warning = comic.warning?.message
        isLoading = false

        let restored = restoredProgress()
        spreadIndex = min(max(restored, 0), max(spreads.count - 1, 0))
        prefetchNeighbours()
        NSDocumentController.shared.noteNewRecentDocumentURL(comic.source)
        startIndexing(comic)
    }

    func closeComic() {
        indexingTask?.cancel()
        indexingTask = nil
        textIndex = nil
        searchQuery = ""
        searchHits = []
        hitsByPage = [:]
        pageIndexByURL = [:]
        cache.removeAll()
        source = nil
        title = nil
        pages = []
        spreads = []
        wideFlags = []
        warning = nil
        spreadAspect = nil
        spreadIndex = 0
    }

    // MARK: - Spreads

    var currentSpread: Spread? {
        spreads.indices.contains(spreadIndex) ? spreads[spreadIndex] : nil
    }

    /// A spread's page URLs in the order they appear on screen.
    func orderedPages(forSpreadAt index: Int) -> [(number: Int, url: URL)] {
        guard spreads.indices.contains(index) else { return [] }
        let indices = spreads[index].pageIndices
        let ordered = direction == .rightToLeft ? indices.reversed().map { $0 } : indices
        return ordered.map { (number: $0 + 1, url: pages[$0]) }
    }

    /// The current spread's page URLs in the order they appear on screen.
    var visiblePages: [(number: Int, url: URL)] {
        orderedPages(forSpreadAt: spreadIndex)
    }

    /// A spread's images, but only if they're already decoded. The strip builds
    /// an incoming panel with these so a swipe never waits on the disk;
    /// `prefetchNeighbours` is what keeps them warm.
    func cachedImages(forSpreadAt index: Int) -> [NSImage]? {
        let urls = orderedPages(forSpreadAt: index).map(\.url)
        guard !urls.isEmpty else { return nil }
        let images = urls.compactMap { cache.cached($0) }
        return images.count == urls.count ? images : nil
    }

    /// The spread waiting off-screen on the given side, if there is one.
    func spreadIndex(on side: ScreenSide) -> Int? {
        neighbouringSpread(
            from: spreadIndex,
            on: side,
            direction: direction,
            spreadCount: spreads.count
        )
    }

    /// e.g. "12–11 / 84", matching the on-screen left-to-right order.
    var positionLabel: String {
        let numbers = visiblePages.map(\.number)
        guard let first = numbers.first else { return "" }
        let range = numbers.count > 1 ? "\(first)–\(numbers[numbers.count - 1])" : "\(first)"
        return "\(range) / \(pages.count)"
    }

    // MARK: - Navigation

    var canGoForward: Bool { spreadIndex + 1 < spreads.count }
    var canGoBack: Bool { spreadIndex > 0 }

    /// Forward always means further into the book, whichever way it reads.
    func goForward() {
        guard canGoForward else { return }
        spreadIndex += 1
    }

    func goBack() {
        guard canGoBack else { return }
        spreadIndex -= 1
    }

    func goToStart() { spreadIndex = 0 }

    func goTo(spread index: Int) {
        guard spreads.indices.contains(index) else { return }
        spreadIndex = index
    }

    /// The lower-numbered page on screen — what "page 2 of 8" means for a
    /// spread showing 2 and 3.
    var currentPageNumber: Int {
        visiblePages.map(\.number).min() ?? 0
    }

    func goToEnd() { spreadIndex = max(spreads.count - 1, 0) }

    /// Maps a physical arrow key to a direction of travel. In manga the book
    /// runs right to left, so the left arrow moves forward.
    func pressedLeftArrow() {
        direction == .rightToLeft ? goForward() : goBack()
    }

    func pressedRightArrow() {
        direction == .rightToLeft ? goBack() : goForward()
    }

    func toggleDirection() {
        direction = direction.flipped
    }

    // MARK: - Image loading

    func image(for url: URL) async -> NSImage? {
        let cache = self.cache
        return await Task.detached(priority: .userInitiated) {
            cache.load(url)
        }.value?.image
    }

    private func prefetchNeighbours() {
        // Both sides, two deep: the strip can be asked for either neighbour at
        // any moment, and which one is "next" flips with the reading direction.
        let neighbours = [spreadIndex + 1, spreadIndex - 1, spreadIndex + 2, spreadIndex - 2]
            .filter { spreads.indices.contains($0) }
            .flatMap { spreads[$0].pageIndices }
            .map { pages[$0] }
        guard !neighbours.isEmpty else { return }
        let cache = self.cache
        Task.detached(priority: .background) {
            cache.prefetch(neighbours)
        }
    }

    // MARK: - Text search

    var isIndexing: Bool { textIndex.map { !$0.isComplete } ?? false }
    var indexedPageCount: Int { textIndex?.indexedPages ?? 0 }
    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    var pagesWithHits: Int { hitsByPage.count }

    func requestSearch() {
        wantsSearchFocus = true
    }

    func hitCount(forSpreadAt index: Int) -> Int {
        guard spreads.indices.contains(index) else { return 0 }
        return spreads[index].pageIndices.reduce(0) { $0 + hitsByPage[$1, default: 0] }
    }

    /// The spreads worth showing in the overview: all of them, or only those
    /// with hits while a search is active.
    var overviewSpreads: [Int] {
        isSearching ? spreads.indices.filter { hitCount(forSpreadAt: $0) > 0 } : Array(spreads.indices)
    }

    /// Where the hits sit on each page, keyed by page file, for drawing.
    var highlightsByPage: [URL: [CGRect]] {
        var result: [URL: [CGRect]] = [:]
        for hit in searchHits where pages.indices.contains(hit.page) {
            result[pages[hit.page], default: []].append(hit.line.box)
        }
        return result
    }

    /// Reads the lettering off every page not already in the stored index,
    /// one page at a time at low priority so it never contends with the page
    /// decodes that keep turns instant. Saves as it goes, so a quit mid-way
    /// resumes rather than restarts.
    private func startIndexing(_ comic: ComicArchive) {
        indexingTask?.cancel()
        let store = indexStore
        let identity = comic.identity
        let pages = comic.pages
        let initial = store.load(identity: identity, pageCount: pages.count)
            ?? PageTextIndex(pageCount: pages.count)
        textIndex = initial
        guard !initial.isComplete else { return }

        indexingTask = Task.detached(priority: .utility) { [weak self, initial] in
            var index = initial
            var unsaved = 0
            for page in index.unreadPages {
                if Task.isCancelled { return }
                // A page that can't be read counts as read with nothing on it;
                // otherwise one bad file would stall the whole comic forever.
                index.pages[page] = (try? PageTextRecognizer.recognise(pages[page])) ?? PageText(lines: [])
                unsaved += 1
                if unsaved >= 10 || index.isComplete {
                    try? store.save(index, identity: identity)
                    unsaved = 0
                }
                let snapshot = index
                await MainActor.run { [weak self] in
                    guard let self, self.source == comic.source else { return }
                    self.textIndex = snapshot
                    // A search typed while pages were still being read picks
                    // up the new ones as they land.
                    if self.isSearching { self.publishHits(search(self.searchQuery, in: snapshot)) }
                }
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearching else {
            publishHits([])
            return
        }
        searchTask = Task { [query = searchQuery] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let textIndex else { return }
            publishHits(search(query, in: textIndex))
        }
    }

    private func publishHits(_ hits: [SearchHit]) {
        searchHits = hits
        hitsByPage = hits.reduce(into: [:]) { $0[$1.page, default: 0] += 1 }
    }

    // MARK: - Reading position

    private func progressKey(for url: URL) -> String {
        "PanelsProgress:\(url.standardizedFileURL.path)"
    }

    private func saveProgress() {
        guard let source else { return }
        UserDefaults.standard.set(spreadIndex, forKey: progressKey(for: source))
    }

    private func restoredProgress() -> Int {
        guard let source,
              let stored = UserDefaults.standard.object(forKey: progressKey(for: source)) as? Int
        else { return 0 }
        return stored
    }
}
