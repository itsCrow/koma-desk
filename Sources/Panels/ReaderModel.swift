import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import ComicArchive

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
                Result { () -> (ComicArchive, [Bool]) in
                    let comic = try ComicArchive.open(url)
                    return (comic, comic.pages.map(isWidePage))
                }
            }.value

            switch result {
            case .success(let (comic, wideFlags)):
                apply(comic, wideFlags: wideFlags)
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

    private func apply(_ comic: ComicArchive, wideFlags scanned: [Bool]) {
        cache.removeAll()
        source = comic.source
        title = comic.title
        pages = comic.pages
        wideFlags = scanned
        spreads = buildSpreads(pageCount: pages.count, isWide: wideFlags)
        warning = comic.warning?.message
        isLoading = false

        let restored = restoredProgress()
        spreadIndex = min(max(restored, 0), max(spreads.count - 1, 0))
        prefetchNeighbours()
        NSDocumentController.shared.noteNewRecentDocumentURL(comic.source)
    }

    func closeComic() {
        cache.removeAll()
        source = nil
        title = nil
        pages = []
        spreads = []
        wideFlags = []
        warning = nil
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
