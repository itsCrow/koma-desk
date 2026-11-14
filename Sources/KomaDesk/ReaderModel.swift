import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import ComicArchive
import ComicLibrary
import KomaFormat
import PageSearch
import PageCapture
import KomaProject
import RemoteComicSource

/// Which side of the pages the script pane sits on.
enum ScriptPlacement: String, CaseIterable {
    case right, left, bottom, top

    var label: String {
        switch self {
        case .right: return "Right"
        case .left: return "Left"
        case .bottom: return "Bottom"
        case .top: return "Top"
        }
    }

    var isVertical: Bool { self == .top || self == .bottom }
}

/// How the projects browser lays out what it's showing.
enum ProjectsViewMode: String {
    case grid, list
}

/// How many pages the reader shows together — independent of whether that's
/// turned horizontally or scrolled vertically, and independent of
/// `ReadingDirection`, which only says which side is forward and stops
/// applying once there's no "side" at all (Single Page, either orientation).
enum PageLayout: String, CaseIterable {
    case twoPage, singlePage

    var label: String {
        switch self {
        case .twoPage: return "Two-Page Spread"
        case .singlePage: return "Single Page"
        }
    }
}

/// How the reader moves between pages — turned horizontally, or scrolled
/// continuously top to bottom. Mixes freely with `PageLayout`: a vertical
/// scroll can show one page per row or two side by side, same as horizontal.
enum ReadingOrientation: String, CaseIterable {
    case horizontal, vertical

    var label: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical Scroll"
        }
    }
}

/// Where to land when the next item opens as part of reading straight through.
enum ItemStart: Equatable {
    case beginning, end
    /// A one-based page — the same page, swapping to another series' copy
    /// of a chapter. Past the end lands on the last page.
    case page(Int)
}

/// What a capture covers.
enum CaptureShape {
    case page
    case rect(CGRect)
    /// Unit coords, top-left origin. Everything outside is transparent.
    case polygon([CGPoint])
}

/// The sidebar destinations on the home screen.
enum HomeTab: String {
    case reading, library, projects
}

/// How the script pane shows the writing. Writer edits it, full fidelity.
/// Voice reads it clean — no notes, chips, or page-range highlighting, for
/// reading aloud. Editor is read-only like Voice, but full fidelity like
/// Writer, plus it's where beats — the script's sections — live.
enum ScriptMode: String, CaseIterable, Equatable, Sendable {
    case writer, voice, editor

    var label: String {
        switch self {
        case .writer: return "Writer"
        case .voice: return "Voice"
        case .editor: return "Editor"
        }
    }

    var icon: String {
        switch self {
        case .writer: return "pencil"
        case .voice: return "book"
        case .editor: return "checklist"
        }
    }
}

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

extension ItemRef {
    /// How a project refers to a library item.
    init(_ item: LibraryItem) {
        self.init(itemID: item.id, filename: item.url.lastPathComponent, fileSize: item.fileSize,
                  series: item.series, volume: item.volume, chapter: item.chapter, title: item.displayName)
    }
}

extension ComicIdentity {
    /// An item's identity as the library already knows it — works the same
    /// for a local file and a remote chapter, with no filename to parse.
    init(_ item: LibraryItem) {
        self.init(series: item.series, volume: item.volume, chapter: item.chapter, chapterTitle: item.title)
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
    /// Set while a remote chapter's pages are downloading: (downloaded, total).
    /// A bare spinner reads as a hang for a multi-page download.
    private(set) var remoteFetchProgress: (done: Int, total: Int)?
    /// Width-to-height of a two-page spread of the open comic. The window uses
    /// this while two pages are on screen, so a spread fills it with no bars.
    private(set) var spreadAspect: CGFloat?
    /// One page's width-to-height. The window uses this in single-page layout
    /// so the page fills the window instead of being cropped by a spread-shaped one.
    private(set) var pageAspect: CGFloat?

    /// What the page area should be shaped to right now.
    var windowAspect: CGFloat? {
        pageLayout == .singlePage ? (pageAspect ?? spreadAspect) : spreadAspect
    }

    /// The comic's lettering, read page by page in the background. Pages not
    /// yet read are nil; `isIndexing` is true until they're all in.
    private(set) var textIndex: PageTextIndex?
    /// Set by ⌘F; the reader opens the controls panel and focuses the field.
    var wantsSearchFocus = false
    /// Capture mode: clicks and drags on a page save it for the editor.
    var isCapturing = false
    /// Two pages are up and Save Page was asked for: the reader picks one.
    var isChoosingPageToSave = false

    /// The comics on this Mac, and how far each has been read.
    let library: Library
    /// The item being read — a volume or a chapter — and the series it's from.
    private(set) var item: LibraryItem?
    private(set) var series: Series?

    /// The open project, if any: the script lives beside the pages.
    private(set) var project: Project?
    /// Every project there is; the home screen and the switcher read it.
    let projects: ProjectLibrary
    /// The home screen — library and projects — is showing. It stands in for
    /// the pages when nothing is open, and lies over them when something is.
    var showsHome = false
    var homeTab: HomeTab = .reading
    /// What the home sidebar's search field holds — every tab filters by it.
    var homeSearch = ""
    /// ⌘F while home is showing: the search field should take the keyboard.
    var wantsHomeSearchFocus = false
    /// Home fills the window when nothing's open, and lies over the pages
    /// when asked for.
    var isHomeVisible: Bool { showsHome || !hasComic }
    /// The series whose page the library half of home is showing, if any.
    var browsingSeries: String?
    /// "New Project…" should show its dialog.
    var wantsNewProject = false
    /// Set by a caller that already knows which series the new project is
    /// about — read once by the dialog, then irrelevant until set again.
    var newProjectSeriesOverride: String?
    /// "Add Series to Project…" is showing its picker.
    var wantsAddSeries = false
    /// The library's import bar should take focus.
    /// "Import from Link…" is showing its sheet.
    var isImportingLink = false
    /// How the library's series are ordered.
    var librarySort: LibrarySort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: "KomaDeskLibrarySort") ?? "") ?? .recent {
        didSet { UserDefaults.standard.set(librarySort.rawValue, forKey: "KomaDeskLibrarySort") }
    }
    /// The "Open URL…" sheet is resolving what's at the link.
    private(set) var isAddingRemoteSource = false
    /// The script pane has the keyboard: every reader key stands down.
    var isScriptEditing = false
    /// The block of writing the cursor sits in, reported by the editor — what
    /// makes one key both start a range and end it.
    var spanAtCursor: String?
    /// Whether any of the script is selected — what turns ⌘R from starting
    /// a block into linking what's already written.
    var hasScriptSelection = false
    /// "Link to Page…" is asking which comic and pages — see `LinkPagesSheet`.
    var linkingPages: LinkPagesRequest?
    /// Whether the cursor is in a note, so ⌘N can end one as well as start it.
    var isWritingNote = false
    /// Whether the script pane is shown when a project is open.
    var showsScript: Bool {
        didSet { UserDefaults.standard.set(showsScript, forKey: Self.showsScriptKey) }
    }
    /// The script pane is showing the shot list rather than the writing.
    var showsShotList = false
    /// The comic is hidden and the script pane takes the whole window, the
    /// pages set aside for a stretch of uninterrupted writing.
    var isFocusedWriting = false
    /// Writer, Voice, or Editor — see `ScriptMode`.
    var scriptMode: ScriptMode = .writer
    /// The formatting at the cursor or across the selection, published by the
    /// editor so the formatting toolbar's buttons can show which ones are on.
    var selectionFormatting = ScriptSelectionFormatting()
    /// The controls panel is expanded into a grid filling the page area.
    var isOverviewExpanded = false
    /// The series' contents beside the pages.
    var showsContents: Bool {
        didSet { UserDefaults.standard.set(showsContents, forKey: Self.showsContentsKey) }
    }
    var scriptPlacement: ScriptPlacement {
        didSet { UserDefaults.standard.set(scriptPlacement.rawValue, forKey: Self.scriptPlacementKey) }
    }
    /// How wide Editor mode's beat rail is — a real resizable sidebar, not a
    /// fixed width, so it's persisted the same way `scriptPlacement` is.
    /// Clamped by whoever sets it from a drag; kept unclamped here so a
    /// narrower future minimum doesn't need a migration.
    var beatRailWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(beatRailWidth), forKey: Self.beatRailWidthKey) }
    }
    /// Where each beat's highlighted block currently sits in the script's own
    /// content coordinates (its top, ignoring scroll) — published by
    /// `ScriptTextView` so the beat rail can place each row at the same
    /// height as its beat instead of just stacking them. Not persisted:
    /// this is live geometry, recomputed on every layout pass.
    var beatBoxTops: [String: CGFloat] = [:]
    /// The script's total laid-out height, so the rail's own content area
    /// can match it.
    var scriptContentHeight: CGFloat = 0
    /// How far the script is scrolled, so the rail can scroll the same
    /// amount and stay lined up as the writer scrolls either pane.
    var scriptScrollOffset: CGFloat = 0
    /// Grid of cards, or a list of rows — how the projects browser shows
    /// what's in the projects folder.
    var projectsViewMode: ProjectsViewMode {
        didSet { UserDefaults.standard.set(projectsViewMode.rawValue, forKey: Self.projectsViewModeKey) }
    }
    /// How projects are ordered within their series on the Projects tab.
    var projectsSort: ProjectsSort = ProjectsSort(rawValue: UserDefaults.standard.string(forKey: "KomaDeskProjectsSort") ?? "") ?? .recent {
        didSet { UserDefaults.standard.set(projectsSort.rawValue, forKey: "KomaDeskProjectsSort") }
    }
    /// Shapes to outline on pages after a jump, keyed by page file. Unit
    /// coords, top-left origin. Cleared after a moment.
    private(set) var focusOutlines: [URL: [[CGPoint]]] = [:]
    /// "Saved Berserk v01 p119 panel6.png · citation copied", briefly.
    var lastCaptureMessage: String?
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
            if let item { library.setPosition(spreadIndex, for: item) }
            followReadingWhileWriting()
            prefetchNeighbours()
            // Turning the page means you're done capturing from this one.
            isCapturing = false
            isChoosingPageToSave = false
        }
    }

    var direction: ReadingDirection {
        didSet {
            guard direction != oldValue else { return }
            UserDefaults.standard.set(direction.rawValue, forKey: Self.directionKey)
        }
    }
    /// Two pages at a time, or one — independent of which side is forward.
    var pageLayout: PageLayout {
        didSet {
            guard pageLayout != oldValue else { return }
            UserDefaults.standard.set(pageLayout.rawValue, forKey: Self.pageLayoutKey)
            rebuildSpreadsForCurrentMode()
        }
    }
    /// Turned horizontally, or scrolled vertically — independent of how many
    /// pages a "spread" is (`pageLayout`).
    var readingOrientation: ReadingOrientation {
        didSet {
            guard readingOrientation != oldValue else { return }
            UserDefaults.standard.set(readingOrientation.rawValue, forKey: Self.readingOrientationKey)
        }
    }

    @ObservationIgnored private let cache = PageCache()
    @ObservationIgnored private var source: URL?
    /// The open comic's identity — compared against a completed indexing
    /// pass to tell whether the reader has since moved to a different comic.
    @ObservationIgnored private var openIdentity: String?
    /// Pages that are wider than they are tall — double-page scans, shown alone.
    @ObservationIgnored private var wideFlags: [Bool] = []
    @ObservationIgnored private var pageIndexByURL: [URL: Int] = [:]
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let indexStore = TextIndexStore()
    @ObservationIgnored private var detectedPanels: [URL: [DetectedPanel]] = [:]
    /// A citation to land on once the item it's in has opened.
    @ObservationIgnored private var pendingJump: Citation?
    /// Where to land in the item being opened: its start when reading
    /// forward into it, its end when reading back into it.
    @ObservationIgnored private var pendingStart: ItemStart?
    /// True while the reader is being put somewhere rather than read there —
    /// restoring a position, following a citation. A block being written
    /// shouldn't swallow those pages.
    @ObservationIgnored private var isRestoringPosition = false
    /// A page to land on once the comic a range points at has opened.
    @ObservationIgnored private var pendingSpanLanding: Int?
    @ObservationIgnored private var focusTask: Task<Void, Never>?

    private static let directionKey = "KomaDeskReadingDirection"
    private static let pageLayoutKey = "KomaDeskPageLayout"
    private static let readingOrientationKey = "KomaDeskReadingOrientation"
    private static let showsScriptKey = "KomaDeskShowsScript"
    private static let showsContentsKey = "KomaDeskShowsSeriesContents"
    private static let scriptPlacementKey = "KomaDeskScriptPlacement"
    private static let projectsViewModeKey = "KomaDeskProjectsViewMode"
    private static let beatRailWidthKey = "KomaDeskBeatRailWidth"

    init(library: Library = Library(), projects: ProjectLibrary = ProjectLibrary()) {
        self.library = library
        self.projects = projects
        let stored = UserDefaults.standard.string(forKey: Self.directionKey)
        // Defaults to manga order.
        direction = stored.flatMap(ReadingDirection.init(rawValue:)) ?? .rightToLeft
        pageLayout = UserDefaults.standard.string(forKey: Self.pageLayoutKey)
            .flatMap(PageLayout.init(rawValue:)) ?? .twoPage
        readingOrientation = UserDefaults.standard.string(forKey: Self.readingOrientationKey)
            .flatMap(ReadingOrientation.init(rawValue:)) ?? .horizontal
        showsScript = UserDefaults.standard.object(forKey: Self.showsScriptKey) as? Bool ?? true
        showsContents = UserDefaults.standard.object(forKey: Self.showsContentsKey) as? Bool ?? true
        scriptPlacement = UserDefaults.standard.string(forKey: Self.scriptPlacementKey)
            .flatMap(ScriptPlacement.init(rawValue:)) ?? .right
        let storedRailWidth = UserDefaults.standard.object(forKey: Self.beatRailWidthKey) as? Double
        beatRailWidth = storedRailWidth.map { CGFloat($0) } ?? 150
        projectsViewMode = UserDefaults.standard.string(forKey: Self.projectsViewModeKey)
            .flatMap(ProjectsViewMode.init(rawValue:)) ?? .grid
    }

    var hasComic: Bool { !pages.isEmpty }

    // MARK: - Opening

    /// File extensions the reader accepts.
    static let supportedExtensions = ["cbr", "cbz", "cb7", "rar", "zip"]

    static var supportedContentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Starts reading an item of the library: at its remembered position, or
    /// where reading straight through the series has asked for.
    func open(item: LibraryItem) {
        guard !isLoading else { return }
        if case .local = item.source {
            guard FileManager.default.fileExists(atPath: item.url.path) else {
                library.rescan()
                errorMessage = "“\(item.url.lastPathComponent)” isn’t where it was. If it moved, add its new folder to the library."
                return
            }
        }
        // What's on screen until the new one actually opens. A failed open
        // must put these back: the pages stay as they were, so the model has
        // to keep saying which comic they belong to, or the next citation is
        // recorded against a comic that never opened.
        let previousItem = self.item
        let previousSeries = self.series
        self.item = item
        self.series = library.series(containing: item)
        isLoading = true
        errorMessage = nil
        warning = nil
        remoteFetchProgress = nil

        Task {
            let result: Result<OpenedComic, Error>
            switch item.source {
            case .local:
                let url = item.url
                // The page scan reads metadata for every page in the comic,
                // so it rides along with extraction rather than landing on
                // the main actor.
                result = await Task.detached(priority: .userInitiated) {
                    Result { () -> OpenedComic in
                        let comic = try ComicArchive.open(url)
                        let sizes = comic.pages.map(pagePixelSize)
                        return OpenedComic(
                            source: comic.source, pages: comic.pages, identity: comic.identity,
                            warning: comic.warning?.message, title: comic.title,
                            wideFlags: sizes.map(isWidePage), aspect: spreadAspectRatio(pageSizes: sizes),
                            pageAspect: singlePageAspectRatio(pageSizes: sizes),
                            notesRecentDocument: true
                        )
                    }
                }.value
            case .manifest(let manifestURL, let chapterKey):
                result = await fetchRemote(.manifest(manifestURL: manifestURL, chapterKey: chapterKey), item: item)
            case .site(let site, let chapterURL):
                result = await fetchRemote(.site(site: site, chapterURL: chapterURL), item: item)
            }

            switch result {
            case .success(let opened):
                apply(opened)
            case .failure(let error):
                isLoading = false
                remoteFetchProgress = nil
                pendingStart = nil
                pendingJump = nil
                self.item = previousItem
                self.series = previousSeries
                errorMessage = Self.describe(error, for: item)
            }
        }
    }

    /// Downloads a remote chapter's pages, reporting progress as it goes.
    private func fetchRemote(_ source: ChapterSource, item: LibraryItem) async -> Result<OpenedComic, Error> {
        do {
            let comic = try await RemoteComicSource.open(source) { [weak self] done, total in
                Task { @MainActor in self?.remoteFetchProgress = (done, total) }
            }
            library.noteChapterOpened(item)
            let sizes = comic.pages.map(pagePixelSize)
            return .success(OpenedComic(
                source: item.url, pages: comic.pages, identity: comic.identity, warning: comic.warning,
                title: item.displayName, wideFlags: sizes.map(isWidePage), aspect: spreadAspectRatio(pageSizes: sizes),
                pageAspect: singlePageAspectRatio(pageSizes: sizes),
                notesRecentDocument: false
            ))
        } catch {
            return .failure(error)
        }
    }

    /// Picks a series up where it was left, or starts it.
    func read(_ series: Series) {
        guard let item = library.continueItem(in: series) else { return }
        showsHome = false
        let seriesToCheck = series
        Task { await refreshSeriesIfStale(seriesToCheck) }
        open(item: item)
    }

    /// A file or folder from outside — Finder, a drop — joins the library
    /// first. A file then opens; a folder shows its series on the home screen.
    func addToLibrary(_ url: URL) {
        library.addRoot(url)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDirectory {
            showsHome = true
            homeTab = .library
            browsingSeries = library.series.first { series in
                series.items.contains { $0.url.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") }
            }?.name
        } else if let item = library.series.lazy.flatMap(\.items).first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            showsHome = false
            open(item: item)
        } else {
            errorMessage = "“\(url.lastPathComponent)” couldn’t be added to the library."
        }
    }

    /// From the "Open URL…" sheet: reads a manifest or a known site's link,
    /// adds its series to the library, and shows it.
    func addRemoteSource(urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            errorMessage = "That doesn’t look like a web address."
            return
        }
        isAddingRemoteSource = true
        defer { isAddingRemoteSource = false }
        do {
            let seriesName = try await library.addRemoteSource(url)
            isImportingLink = false
            showsHome = true
            homeTab = .library
            browsingSeries = seriesName
        } catch {
            errorMessage = Self.describeRemoteSourceError(error)
        }
    }

    /// Asked for: re-read this series' link, then say what came of it.
    func checkForNewChapters(named seriesName: String) async {
        let outcome = await library.refreshRemoteSeries(named: seriesName)
        library.presentRefreshNotice(for: seriesName, outcome: outcome, announceUpToDate: true)
        adoptRefreshedSeries(seriesName)
    }

    /// Opening a linked series whose last check is more than a day old.
    /// Quiet when nothing new has come out.
    func refreshSeriesIfStale(_ series: Series) async {
        guard let outcome = await library.refreshRemoteSeriesIfStale(named: series.name) else { return }
        library.presentRefreshNotice(for: series.name, outcome: outcome, announceUpToDate: false)
        adoptRefreshedSeries(series.name)
    }

    /// Fetches one chapter's pages again. If it's the chapter on screen, the
    /// reader reloads it; otherwise the download happens in the background.
    func redownloadChapter(_ item: LibraryItem) {
        guard library.isRemoteItem(item) else { return }
        guard !(isLoading && item.id == self.item?.id) else { return }
        library.forgetCachedPages(of: item)
        if item.id == self.item?.id {
            open(item: item)
        } else {
            library.downloadChapter(item)
        }
    }

    /// The contents sidebar holds the series from when the comic opened.
    /// A check that adds chapters has to hand it the updated list, or the
    /// new chapter stays invisible until the next open.
    private func adoptRefreshedSeries(_ name: String) {
        guard series?.name == name, let updated = library.series(named: name) else { return }
        series = updated
    }

    private static func describeRemoteSourceError(_ error: Error) -> String {
        if let remoteError = error as? RemoteSourceError {
            return remoteError.errorDescription ?? "That link couldn’t be opened."
        }
        return "That link couldn’t be opened. \(error.localizedDescription)"
    }

    private static func describe(_ error: Error, for item: LibraryItem) -> String {
        if let archiveError = error as? ArchiveError {
            let headline = archiveError.errorDescription ?? "The comic couldn’t be opened."
            if let reason = archiveError.failureReason {
                return "\(headline)\n\n\(reason)"
            }
            return headline
        }
        if let remoteError = error as? RemoteSourceError {
            return remoteError.errorDescription ?? "“\(item.displayName)” couldn’t be opened."
        }
        return "“\(item.url.lastPathComponent)” couldn’t be opened. \(error.localizedDescription)"
    }

    /// What opening a comic produces, whichever source it came from — a
    /// local archive extracted to disk, or a remote chapter downloaded to
    /// disk. Nothing past this point needs to know which.
    private struct OpenedComic {
        let source: URL
        let pages: [URL]
        let identity: String
        let warning: String?
        let title: String
        let wideFlags: [Bool]
        let aspect: CGFloat?
        let pageAspect: CGFloat?
        /// Only a real local file belongs in the Open Recent menu.
        let notesRecentDocument: Bool
    }

    private func spreadsForCurrentMode(pageCount: Int, isWide: [Bool]) -> [Spread] {
        // Pairing is purely about `pageLayout` — whether that's turned
        // horizontally or scrolled vertically doesn't change which pages
        // share a spread, only how the spread is shown.
        switch pageLayout {
        case .twoPage: return buildSpreads(pageCount: pageCount, isWide: isWide)
        case .singlePage: return buildSinglePageSpreads(pageCount: pageCount)
        }
    }

    /// The spread layout changed under an already-open comic — rebuild it
    /// landing on the same page, rather than resetting to the start.
    private func rebuildSpreadsForCurrentMode() {
        guard hasComic else { return }
        let currentPage = spreads.indices.contains(spreadIndex) ? spreads[spreadIndex].pageIndices.first ?? 0 : 0
        spreads = spreadsForCurrentMode(pageCount: pages.count, isWide: wideFlags)
        isRestoringPosition = true
        spreadIndex = spreads.firstIndex { $0.pageIndices.contains(currentPage) } ?? 0
        isRestoringPosition = false
        if let item { library.noteSpreadCount(spreads.count, for: item) }
    }

    private func apply(_ comic: OpenedComic) {
        cache.removeAll()
        source = comic.source
        openIdentity = comic.identity
        title = comic.title
        pages = comic.pages
        wideFlags = comic.wideFlags
        spreadAspect = comic.aspect
        pageAspect = comic.pageAspect
        pageIndexByURL = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($1, $0) })
        searchQuery = ""
        searchHits = []
        hitsByPage = [:]
        spreads = spreadsForCurrentMode(pageCount: pages.count, isWide: wideFlags)
        warning = comic.warning
        isLoading = false
        remoteFetchProgress = nil

        let restored = item.map { library.position(for: $0) } ?? 0
        isRestoringPosition = true
        switch pendingStart {
        case .beginning: spreadIndex = 0
        case .end: spreadIndex = max(spreads.count - 1, 0)
        case .page(let page):
            spreadIndex = spreadIndex(containingPage: min(max(page, 1), pages.count) - 1) ?? 0
        case nil: spreadIndex = min(max(restored, 0), max(spreads.count - 1, 0))
        }
        isRestoringPosition = false
        pendingStart = nil
        if let item {
            // Landing on the first spread doesn't change spreadIndex, so the
            // position is written here as well as in its didSet.
            library.setPosition(spreadIndex, for: item)
            library.noteRead(item)
            library.noteSpreadCount(spreads.count, for: item)
        }
        prefetchNeighbours()
        if comic.notesRecentDocument {
            NSDocumentController.shared.noteNewRecentDocumentURL(comic.source)
        }
        startIndexing(identity: comic.identity, pages: comic.pages)

        if let jump = pendingJump, jump.itemID == item?.id {
            pendingJump = nil
            land(on: jump)
        }
        if let page = pendingSpanLanding {
            pendingSpanLanding = nil
            goToPage(page)
        }
    }

    func closeComic() {
        item = nil
        series = nil
        isOverviewExpanded = false
        isCapturing = false
        isChoosingPageToSave = false
        detectedPanels = [:]
        indexingTask?.cancel()
        indexingTask = nil
        textIndex = nil
        searchQuery = ""
        searchHits = []
        hitsByPage = [:]
        pageIndexByURL = [:]
        cache.removeAll()
        source = nil
        openIdentity = nil
        remoteFetchProgress = nil
        title = nil
        pages = []
        spreads = []
        wideFlags = []
        warning = nil
        spreadAspect = nil
        pageAspect = nil
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

    var canGoForward: Bool { spreadIndex + 1 < spreads.count || hasNextItem }
    var canGoBack: Bool { spreadIndex > 0 || hasPreviousItem }

    /// Forward always means further into the book, whichever way it reads —
    /// and past the last page of a volume or chapter, into the next.
    func goForward() {
        if spreadIndex + 1 < spreads.count {
            spreadIndex += 1
        } else if hasNextItem {
            nextItem()
        }
    }

    func goBack() {
        if spreadIndex > 0 {
            spreadIndex -= 1
        } else if hasPreviousItem {
            previousItem(landingAtEnd: true)
        }
    }

    // MARK: - Reading through a series

    /// The series' items, in reading order; empty when nothing is open.
    var seriesItems: [LibraryItem] { series?.items ?? [] }

    /// Whether there's a list worth showing beside the pages.
    var hasContents: Bool { seriesItems.count > 1 }

    var currentItemIndex: Int? {
        guard let item else { return nil }
        return seriesItems.firstIndex { $0.id == item.id }
    }

    var hasNextItem: Bool {
        currentItemIndex.map { $0 + 1 < seriesItems.count } ?? false
    }

    var hasPreviousItem: Bool {
        currentItemIndex.map { $0 > 0 } ?? false
    }

    /// What the next thing along is called, for the menu: "Volume" or "Chapter".
    var itemNoun: String {
        if let item, item.volume != nil, item.chapter == nil { return "Volume" }
        return "Chapter"
    }

    func openItem(_ item: LibraryItem) {
        guard item.id != self.item?.id else { return }
        open(item: item)
    }

    func nextItem() {
        guard let index = currentItemIndex, index + 1 < seriesItems.count else { return }
        pendingStart = .beginning
        open(item: seriesItems[index + 1])
    }

    func previousItem(landingAtEnd: Bool = false) {
        guard let index = currentItemIndex, index > 0 else { return }
        pendingStart = landingAtEnd ? .end : .beginning
        open(item: seriesItems[index - 1])
    }

    // MARK: - Switching series

    /// Where the reader can swap to: the open project's other series, in
    /// the project's order, then the rest of the library. Never the series
    /// on screen, nor a series this library hasn't got.
    var switchableSeries: (inProject: [Series], others: [Series]) {
        let current = series?.name
        let projectNames = project?.manifest.series ?? []
        let inProject = projectNames.filter { $0 != current }.compactMap { library.series(named: $0) }
        let others = library.series.filter { $0.name != current && !projectNames.contains($0.name) }
        return (inProject, others)
    }

    /// Reading the same thing in another series — One Piece (Colored) to
    /// One Piece: the same chapter or volume at the same page. A series
    /// without that chapter opens where it was left instead.
    func switchSeries(to target: Series) {
        guard target.name != series?.name, !isLoading else { return }
        guard let current = item, hasComic, let match = target.matchingItem(for: current) else {
            if let current = item {
                lastCaptureMessage = "No \(current.label) in \(target.name), opened where you left it"
            }
            read(target)
            return
        }
        showsHome = false
        pendingStart = .page(currentPageNumber)
        open(item: match)
        lastCaptureMessage = "\(match.label) in \(target.name)"
    }

    /// The project's series this library has, in the project's order.
    private var projectSeriesHere: [Series] {
        (project?.manifest.series ?? []).compactMap { library.series(named: $0) }
    }

    /// Whether ⌃⌘S has somewhere to go.
    var canSwitchToNextProjectSeries: Bool {
        projectSeriesHere.contains { $0.name != series?.name }
    }

    /// ⌃⌘S: the project's next series, wrapping round — with two, one key
    /// flips between them.
    func switchToNextProjectSeries() {
        let ordered = projectSeriesHere
        guard !ordered.isEmpty else { return }
        let start = ordered.firstIndex { $0.name == series?.name }.map { $0 + 1 } ?? 0
        let next = (0..<ordered.count).lazy
            .map { ordered[(start + $0) % ordered.count] }
            .first { $0.name != self.series?.name }
        if let next { switchSeries(to: next) }
    }

    /// Back to the series' page on the home screen.
    func showSeriesPage() {
        guard let series else { return }
        browsingSeries = series.name
        homeTab = .library
        showsHome = true
    }

    /// Closes the comic — and whatever project was open about it — outright,
    /// landing on the app's main view. Not just the series it was reading,
    /// the way the contents panel's own back arrow used to (that's still one
    /// tap away, from Library).
    func closeComicToHome() {
        closeProject()
        closeComic()
        homeTab = .reading
        browsingSeries = nil
    }

    func goToStart() { spreadIndex = 0 }

    func goTo(spread index: Int) {
        guard spreads.indices.contains(index) else { return }
        spreadIndex = index
    }

    /// The spread a page belongs to — a grid of pages has to turn a page back
    /// into the spread that holds it.
    func spreadIndex(containingPage page: Int) -> Int? {
        spreads.firstIndex { $0.pageIndices.contains(page) }
    }

    func goToPage(_ page: Int) {
        guard let index = spreadIndex(containingPage: page) else { return }
        goTo(spread: index)
    }

    /// Pages to show in the expanded grid: every page, or only those with
    /// hits while a search is running.
    var overviewPages: [Int] {
        isSearching ? pages.indices.filter { hitsByPage[$0, default: 0] > 0 } : Array(pages.indices)
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

    // MARK: - Citation

    /// "Berserk, Vol. 1, pp. 116–117" for whatever is on screen.
    var citation: String? {
        guard let item, hasComic else { return nil }
        return ComicIdentity(item).citation(pages: visiblePages.map(\.number))
    }

    /// Cites what's on screen: into the script at the cursor when a project is
    /// open, and onto the clipboard either way. Returns the text.
    @discardableResult
    func copyCitation() -> String? {
        guard let citation else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(citation, forType: .string)
        if let pageIndex = visiblePages.map({ pageIndexByURL[$0.url] ?? 0 }).min() {
            recordCitation(pageIndex: pageIndex, pageNumbers: visiblePages.map(\.number),
                           panel: nil, polygon: nil, region: nil, captureFile: nil, text: citation)
        }
        return citation
    }

    // MARK: - Project

    /// ⌘N: bring up the projects half of home with the name field ready.
    /// From the menu (⇧⌘N), or a "New Project…" button anywhere: a small
    /// dialog over whatever's on screen, rather than a trip to the projects
    /// list. A caller that already knows which series it means — a series'
    /// own page, say — passes it explicitly, rather than leaving the sheet
    /// to guess between "what's being read" and "what's being browsed".
    func requestNewProject(series: String? = nil) {
        newProjectSeriesOverride = series
        wantsNewProject = true
    }

    /// From the menu, or ⇧⌘U: brings up the library with the sheet that
    /// takes a link.
    func requestOpenURL() {
        homeTab = .library
        showsHome = true
        isImportingLink = true
    }

    /// A new project about one or more series, opened. Made from the series'
    /// page, or from the projects list with series chosen; with nothing
    /// chosen, the series being read.
    func newProject(named name: String, series seriesNames: [String] = [], targetWordCount: Int? = nil) {
        let chosen = seriesNames.isEmpty
            ? (series.map { [$0.name] } ?? project?.manifest.series ?? [])
            : seriesNames
        guard !chosen.isEmpty else {
            errorMessage = "A project needs a series to be about. Add its comics to the library, then make the project from the series’ page."
            return
        }
        do {
            let url = try projects.create(named: name, series: chosen, targetWordCount: targetWordCount)
            closeProject()
            adopt(try Project.open(url))
            projects.noteLastOpened(url)
            showsHome = false
            if series.map({ !chosen.contains($0.name) }) ?? true,
               let found = chosen.lazy.compactMap({ self.library.series(named: $0) }).first {
                read(found)
            }
        } catch {
            errorMessage = "Couldn’t create the project. \(error.localizedDescription)"
        }
    }

    /// The series a project should open on: the one its writing last
    /// pointed at, or else the first it's about that this library has.
    func landingSeries(for manifest: ProjectManifest) -> Series? {
        let recent = (manifest.spans.map { ($0.date, $0.itemID) }
                      + manifest.citations.map { ($0.date, $0.itemID) })
            .sorted { $0.0 > $1.0 }
        for (_, itemID) in recent {
            if let name = manifest.item(id: itemID)?.series, let found = library.series(named: name) {
                return found
            }
        }
        return manifest.series.lazy.compactMap { self.library.series(named: $0) }.first
    }

    /// Another project takes the place of this one. Its series comes up where
    /// it was last read — unless one of its series is already on screen, in
    /// which case the pages stay exactly where they are and only the script
    /// changes.
    func switchTo(_ url: URL) {
        if let project, project.url.standardizedFileURL == url.standardizedFileURL {
            showsHome = false
            return
        }
        do {
            let next = try Project.open(url)
            closeProject()
            adopt(next)
            projects.noteOpened(url)
            projects.noteLastOpened(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            showsHome = false
            if series.map({ !next.manifest.series.contains($0.name) }) ?? true,
               let found = landingSeries(for: next.manifest) {
                read(found)
            }
        } catch {
            errorMessage = "Couldn’t open the project. \(error.localizedDescription)"
        }
    }

    func renameProject(_ url: URL, to name: String) {
        let wasOpen = project?.url.standardizedFileURL == url.standardizedFileURL
        if wasOpen { project?.saveNow() }
        do {
            let moved = try projects.rename(url, to: name)
            if wasOpen {
                project = nil
                adopt(try Project.open(moved))
            }
        } catch {
            errorMessage = "Couldn’t rename the project. \(error.localizedDescription)"
        }
    }

    func duplicateProject(_ url: URL) {
        if project?.url.standardizedFileURL == url.standardizedFileURL { project?.saveNow() }
        do { _ = try projects.duplicate(url) } catch {
            errorMessage = "Couldn’t duplicate the project. \(error.localizedDescription)"
        }
    }

    func trashProject(_ url: URL) {
        if project?.url.standardizedFileURL == url.standardizedFileURL { closeProject() }
        do { try projects.trash(url) } catch {
            errorMessage = "Couldn’t move the project to the Trash. \(error.localizedDescription)"
        }
    }

    func presentOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.allowedContentTypes = [.komaDeskProject, .legacyProject]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    /// A project from anywhere — Finder, Open Project…. Same as switching.
    func openProject(at url: URL) {
        switchTo(url)
    }

    private func adopt(_ project: Project) {
        self.project = project
    }

    func closeProject() {
        project?.saveNow()
        project = nil
        pendingJump = nil
        liveSpanID = nil
        linkingPages = nil
        clearFocus()
    }

    /// The open project's series the library hasn't got — the editor's Mac,
    /// before they've added the folders.
    var missingSeries: [String] {
        guard let project else { return [] }
        return project.manifest.series.filter { library.series(named: $0) == nil }
    }

    /// Library series the open project isn't about yet.
    var seriesNotInProject: [Series] {
        guard let project else { return [] }
        return library.series.filter { !project.manifest.series.contains($0.name) }
    }

    func requestAddSeries() {
        guard project != nil else { return }
        wantsAddSeries = true
    }

    /// Makes the open project about another series too.
    func addSeriesToProject(_ name: String) {
        guard let project else { return }
        project.manifest.addSeries(name)
        projects.refresh()
        lastCaptureMessage = "Added \(name) to the project"
    }

    /// A shot picked from the list: go to its page, and show where it sits
    /// in the script.
    func revealShot(_ citation: Citation) {
        project?.pendingReveal = citation.id
        jump(toCitation: citation.id)
    }

    /// Sends captures the script doesn't use to the Trash.
    func cleanUpUnusedCaptures() {
        guard let project else { return }
        let gone = project.cleanUpUnusedCaptures()
        guard gone.files > 0 else {
            lastCaptureMessage = "Nothing to clean up"
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: gone.bytes, countStyle: .file)
        lastCaptureMessage = "Moved \(gone.files) unused capture\(gone.files == 1 ? "" : "s") to the Trash · \(size)"
    }

    // MARK: - Shots as files

    /// Writes the captures as numbered copies in script order, so a folder
    /// dragged into an editor lands in the order the video runs. Copies, not
    /// renames: the project's own files keep the names it refers to.
    func exportShots() {
        guard let project else { return }
        let shots = project.citationsInScriptOrder
        let notes = project.notesInScriptOrder
        // A script can be worth handing over before a single panel has been
        // captured — the ranges and the notes are the point of it.
        guard !shots.isEmpty || !notes.isEmpty || !project.spansInScriptOrder.isEmpty else {
            errorMessage = "There's nothing to export yet — no shots, page ranges or notes in the script."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Shots"
        panel.nameFieldStringValue = "\(project.name) Shots"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var lines: [String] = ["\(project.name) — \(shots.count) shots", ""]
            // Grouped under the script's own sections when it has them —
            // written the way the script writes them, `# section` and
            // `= synopsis`, so the file reads like the outline it is.
            let sections = project.shotSections
            let groups: [(header: [String], shots: [(number: Int, citation: Citation)])] = sections.isEmpty
                ? [([], shots.enumerated().map { ($0.offset + 1, $0.element) })]
                : sections.map { group in
                    var header: [String] = []
                    if let title = group.section.title {
                        header.append(String(repeating: "#", count: max(1, group.section.level)) + " " + title)
                    }
                    if let synopsis = group.section.synopsis { header.append("= " + synopsis) }
                    if group.shots.isEmpty { header.append("(no shots yet)") }
                    return (header, group.shots)
                }
            for group in groups {
                if !group.header.isEmpty { lines += group.header + [""] }
                for (shotNumber, citation) in group.shots {
                    let number = String(format: "%02d", shotNumber)
                    var filename = "\(number)_(no capture)"
                    if let image = project.shotImage(number: shotNumber, citation: citation) {
                        filename = image.name
                        let destination = folder.appendingPathComponent(filename)
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.copyItem(at: image.source, to: destination)
                    }
                    lines.append("\(number). \(citation.text)")
                    lines.append("    \(filename)")
                    if let span = project.span(containing: citation.id) {
                        lines.append("    in \(span.text)")
                    }
                    if let context = project.context(of: citation.id), !context.isEmpty {
                        lines.append("    \(context)")
                    }
                    lines.append("")
                }
            }
            // The ranges the script covers, whether or not a panel was ever
            // captured from them — what to put on screen between the shots.
            let ranges = project.spansInScriptOrder
            if !ranges.isEmpty {
                lines.append("PAGE RANGES — \(ranges.count)")
                lines.append("")
                for span in ranges {
                    lines.append("· \(span.text)")
                    if let opening = project.opening(of: span.id), !opening.isEmpty {
                        lines.append("    \(opening)")
                    }
                }
                lines.append("")
            }
            if !notes.isEmpty {
                lines.append("NOTES — \(notes.count)")
                lines.append("")
                for note in notes { lines.append("· \(note)") }
                lines.append("")
            }
            try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("Shots.txt"),
                                                    atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            lastCaptureMessage = notes.isEmpty
                ? "Exported \(shots.count) shots"
                : "Exported \(shots.count) shots and \(notes.count) note\(notes.count == 1 ? "" : "s")"
        } catch {
            errorMessage = "Couldn’t export the shots. \(error.localizedDescription)"
        }
    }

    /// Whether any shot in the script has a captured image to save.
    var hasShotImages: Bool {
        project.map { !$0.shotImages.isEmpty } ?? false
    }

    /// Just the shot images, numbered in script order, into a folder of the
    /// writer's choosing — no list beside them.
    func saveShotImages() {
        guard let project else { return }
        guard !project.shotImages.isEmpty else {
            errorMessage = "There are no captured shots in the script yet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Shot Images"
        panel.nameFieldStringValue = "\(project.name) Shots"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let count = try project.writeShotImages(to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            lastCaptureMessage = "Saved \(count) shot image\(count == 1 ? "" : "s")"
        } catch {
            errorMessage = "Couldn’t save the shot images. \(error.localizedDescription)"
        }
    }

    func revealProject() {
        guard let project else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    func revealCaptures() {
        guard let project else { return }
        try? FileManager.default.createDirectory(at: project.capturesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([project.capturesFolder])
    }

    func copyScriptAsPlainText() {
        copyScript(notes: .omit, saying: "Script copied as plain text")
    }

    /// For a document the editor reads rather than a voice booth.
    func copyScriptWithNotes() {
        copyScript(notes: .marked, saying: "Script copied with notes")
    }

    private func copyScript(notes: ScriptMarkdown.NoteHandling, saying message: String) {
        guard let project else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(project.plainTextScript(notes: notes), forType: .string)
        lastCaptureMessage = message
    }

    func format(_ command: ScriptCommand) {
        project?.pendingCommand = command
    }

    /// One key does both: make this line a note, or turn it back into script.
    func toggleNote() {
        format(isWritingNote ? .body : .note)
    }

    /// Bold, italic, a highlight, or a text-color override on the current
    /// selection — see `format(_:)` for the whole-paragraph equivalent.
    func formatInline(_ command: InlineCommand) {
        project?.pendingInlineCommand = command
    }

    /// Records a citation of the open item in the project and queues its
    /// chip for the script.
    private func recordCitation(pageIndex: Int, pageNumbers: [Int], panel: Int?,
                                polygon: [PagePoint]?, region: PageRect?, captureFile: String?, text: String) {
        guard let project, let item else { return }
        project.register(ItemRef(item))
        let citation = Citation(itemID: item.id, pageIndex: pageIndex, pageNumbers: pageNumbers, panel: panel,
                                polygon: polygon, region: region, captureFile: captureFile, text: text)
        project.add(citation)
        project.pendingInsertion = citation
    }

    // MARK: - Jumping to a citation

    /// Clicking a citation or a page range is how the writer checks the
    /// source it points at — showing that only makes sense back in the
    /// normal split view, so a jump always leaves the extended writing area
    /// first.
    private func leaveFocusedWritingIfNeeded() {
        guard isFocusedWriting else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { isFocusedWriting = false }
    }

    func jump(toCitation id: String) {
        guard let project, let citation = project.citation(id: id) else { return }
        leaveFocusedWritingIfNeeded()
        if citation.itemID == item?.id {
            land(on: citation)
            return
        }
        guard let target = library.item(id: citation.itemID) else {
            let name = project.manifest.item(id: citation.itemID)?.filename ?? "the comic it cites"
            errorMessage = "“\(name)” isn’t in your library. Add the folder it’s in, and the citation will open."
            return
        }
        pendingJump = citation
        open(item: target)
    }

    // MARK: - Page ranges

    /// The block ⌘R opened, the one reading on grows. A range linked to
    /// writing after the fact names the pages the writer chose, and turning
    /// pages with the caret inside it mustn't quietly stretch it.
    @ObservationIgnored private var liveSpanID: String?

    /// One key does all of it: with writing selected, link it to the pages
    /// on screen; otherwise start a block here, or end the one being written.
    func togglePageRange() {
        if hasScriptSelection {
            linkSelectionToPagesOnScreen()
        } else if spanAtCursor != nil {
            endPageRange()
        } else {
            startPageRange()
        }
    }

    /// Whether the cursor is inside a block of writing.
    var isWritingInRange: Bool { spanAtCursor != nil }

    /// Starts a block of writing about the pages on screen. What's selected in
    /// the script takes the range now, and whatever is written next joins it,
    /// until the writer ends it.
    func startPageRange() {
        guard let project, let item, hasComic,
              let pages = pagesOnScreen, let span = storeSpan(item: item, pages: pages)
        else { return }
        liveSpanID = span.id
        project.pendingSpanCommand = .start(span)
        lastCaptureMessage = "Writing about \(project.manifest.label(for: span).short)"
    }

    /// Stops the block here: what's written next belongs to no range.
    func endPageRange() {
        liveSpanID = nil
        project?.pendingSpanCommand = .end
        lastCaptureMessage = "Range ended"
    }

    /// Takes the range off the block of writing at the cursor.
    func removePageRange() {
        if spanAtCursor == liveSpanID { liveSpanID = nil }
        project?.pendingSpanCommand = .remove
    }

    /// The first and last page of the spread on screen.
    private var pagesOnScreen: ClosedRange<Int>? {
        let pages = visiblePages.map(\.number)
        guard let first = pages.min(), let last = pages.max() else { return nil }
        return first...last
    }

    /// "pp. 42–43" for the spread on screen, for a menu item to say what it
    /// would link to.
    var pagesOnScreenPhrase: String? {
        guard hasComic, let pages = pagesOnScreen else { return nil }
        return ReferenceLabel.pagePhrase([pages.lowerBound, pages.upperBound])
    }

    /// Makes (or, given an id, remakes) the range for these pages of an item
    /// and puts it on record — every way a range is made goes through here.
    @discardableResult
    private func storeSpan(item: LibraryItem, pages: ClosedRange<Int>, id: String? = nil) -> PageSpan? {
        guard let project else { return nil }
        let numbers = [pages.lowerBound, pages.upperBound]
        let span = PageSpan(id: id ?? ProjectManifest.makeID(), itemID: item.id,
                            firstPageIndex: pages.lowerBound - 1, pageNumbers: numbers,
                            text: ComicIdentity(item).citation(pages: numbers))
        // On record like a citation's comic, so the range can be named by its
        // chapter rather than only by its pages.
        project.register(ItemRef(item))
        project.manifest.store(span)
        return span
    }

    /// Links the selected writing to the pages on screen — or `selection`,
    /// when the right-click that asked saw a different one.
    func linkSelectionToPagesOnScreen(selection: NSRange? = nil) {
        guard let project, let item, hasComic,
              let pages = pagesOnScreen, let span = storeSpan(item: item, pages: pages)
        else { return }
        project.pendingSpanCommand = .link(span, selection: selection)
        lastCaptureMessage = "Linked to \(project.manifest.label(for: span).short)"
    }

    /// Asks which comic and pages: for the selected writing, or — given a
    /// range's id — to change the pages an existing range points at.
    func beginLinkingPages(selection: NSRange? = nil, changing spanID: String? = nil) {
        guard let project else { return }
        let existing = spanID.flatMap { project.manifest.span(id: $0) }
        let pages = existing.map { ReferenceLabel.pagePhrase($0.pageNumbers) }
            ?? pagesOnScreenPhrase
            ?? ""
        linkingPages = LinkPagesRequest(
            selection: selection, changingSpanID: existing?.id,
            itemID: existing?.itemID ?? defaultLinkItem?.id,
            pages: pages.replacingOccurrences(of: "pp. ", with: "").replacingOccurrences(of: "p. ", with: ""))
    }

    /// The comics a range can point at: every series in the project, and
    /// whatever is open if it's from somewhere else.
    var linkCandidates: [LibraryItem] {
        guard let project else { return [] }
        var items = project.manifest.series.flatMap { library.series(named: $0)?.items ?? [] }
        if let item, !items.contains(where: { $0.id == item.id }) { items.insert(item, at: 0) }
        return items
    }

    /// What "Link to Page…" suggests: the comic that's open, or else the
    /// one last cited.
    private var defaultLinkItem: LibraryItem? {
        if let item { return item }
        guard let project else { return nil }
        let recent = (project.manifest.spans.map { ($0.date, $0.itemID) }
                      + project.manifest.citations.map { ($0.date, $0.itemID) })
            .max { $0.0 < $1.0 }
        return recent.flatMap { library.item(id: $0.1) }
    }

    /// The sheet's answer. A new range goes on the writing the request was
    /// made for; a changed one keeps its id, so the writing needn't change.
    func finishLinkingPages(_ request: LinkPagesRequest, item: LibraryItem, pages: ClosedRange<Int>) {
        linkingPages = nil
        guard let project, let span = storeSpan(item: item, pages: pages, id: request.changingSpanID) else { return }
        if request.changingSpanID == nil {
            project.pendingSpanCommand = .link(span, selection: request.selection)
            lastCaptureMessage = "Linked to \(project.manifest.label(for: span).short)"
        } else {
            lastCaptureMessage = "Now \(project.manifest.label(for: span).short)"
        }
    }

    /// Reading on while a block is being written grows the block's range with
    /// you — that is what "keeps growing" means, and having to say so on every
    /// page turn made the range stop at wherever it started.
    ///
    /// Forward only: turning back to check something leaves the start alone,
    /// so a block never quietly swallows the pages before it. ⇧⌘R still pulls
    /// the start back when that is what's wanted.
    private func followReadingWhileWriting() {
        guard !isRestoringPosition, let project, let item, hasComic,
              let id = spanAtCursor, id == liveSpanID, var span = project.manifest.span(id: id),
              span.itemID == item.id
        else { return }
        guard let reached = visiblePages.map(\.number).max(), reached > span.lastPage else { return }
        span.pageNumbers = [span.firstPage, reached]
        span.text = ComicIdentity(item).citation(pages: [span.firstPage, reached])
        project.manifest.store(span)
        lastCaptureMessage = "Now \(project.manifest.label(for: span).short)"
    }

    /// Stretches the block the cursor is in to the page now on screen — you
    /// read on while writing about the same beat.
    func extendPageRange() {
        guard let project, let item, hasComic,
              let id = spanAtCursor, var span = project.manifest.span(id: id)
        else { return }
        // Pages only mean anything inside one comic. Reading on into the next
        // chapter and stretching would merge two unrelated numberings.
        guard span.itemID == item.id else {
            lastCaptureMessage = "That range is in \(project.manifest.label(for: span).detail)"
            return
        }
        let pages = visiblePages.map(\.number).sorted()
        guard let reached = pages.last else { return }
        let first = min(span.firstPage, pages.first ?? reached)
        let last = max(span.lastPage, reached)
        guard first != span.firstPage || last != span.lastPage else { return }
        span.pageNumbers = [first, last]
        // Reading *back* moves the start, and the page the margin rule opens
        // has to move with it.
        span.firstPageIndex = first - 1
        span.text = ComicIdentity(item).citation(pages: [first, last])
        project.manifest.store(span)
        lastCaptureMessage = "Now \(project.manifest.label(for: span).short)"
    }

    /// Only the block the cursor is in, and only while its own comic is open.
    var canExtendPageRange: Bool {
        guard let project, let item, hasComic, let id = spanAtCursor,
              let span = project.manifest.span(id: id)
        else { return false }
        return span.itemID == item.id
    }

    /// Brings the pages a block of writing is about back on screen.
    func jump(toSpan id: String) {
        guard let project, let span = project.manifest.span(id: id) else { return }
        leaveFocusedWritingIfNeeded()
        guard let target = library.item(id: span.itemID) else {
            errorMessage = "The comic this range points at isn’t in your library. Add the folder it’s in and it will open."
            return
        }
        if target.id == item?.id {
            isRestoringPosition = true
            goToPage(span.firstPageIndex)
            isRestoringPosition = false
        } else {
            pendingSpanLanding = span.firstPageIndex
            open(item: target)
        }
    }

    private func land(on citation: Citation) {
        guard let spread = spreads.firstIndex(where: { $0.pageIndices.contains(citation.pageIndex) }) else { return }
        isRestoringPosition = true
        goTo(spread: spread)
        isRestoringPosition = false
        guard pages.indices.contains(citation.pageIndex) else { return }
        let page = pages[citation.pageIndex]
        let outline: [PagePoint]
        if let polygon = citation.polygon {
            outline = polygon
        } else if let region = citation.region {
            outline = region.corners
        } else {
            // No shape recorded: ring the whole page.
            outline = PageRect(x: 0.01, y: 0.01, width: 0.98, height: 0.98).corners
        }
        focusOutlines = [page: [outline.cgPoints]]
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            // Long enough to spot, short enough not to sit over the page
            // while the writer goes back to typing. Clicking the chip again
            // shows it again.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.focusOutlines = [:]
        }
    }

    private func clearFocus() {
        focusTask?.cancel()
        focusOutlines = [:]
    }

    // MARK: - Capturing for the editor

    /// Captures belong to a project: they're its shots.
    var canCapture: Bool { hasComic && project != nil }

    func toggleCapture() {
        guard hasComic else { return }
        guard project != nil else {
            lastCaptureMessage = "Captures belong to a project — make or open one first"
            return
        }
        isCapturing.toggle()
    }

    /// Panels on a page, detected once and kept for the life of the comic.
    func panels(on pageURL: URL) async -> [DetectedPanel] {
        if let known = detectedPanels[pageURL] { return known }
        let rightToLeft = direction == .rightToLeft
        let found = await Task.detached(priority: .userInitiated) {
            PanelDetector.detect(in: pageURL, rightToLeft: rightToLeft)
        }.value
        detectedPanels[pageURL] = found
        return found
    }

    /// Saves a drawn shape, a dragged rectangle, or the whole page — at native
    /// resolution, named and tagged with its citation — then puts the citation
    /// on the clipboard. A polygon is masked: outside it the file is
    /// transparent. If the shape sits inside a detected panel, the citation
    /// names that panel.
    func capture(page pageURL: URL, shape: CaptureShape) {
        guard let source, let item, let pageIndex = pageIndexByURL[pageURL] else { return }
        guard let project else {
            lastCaptureMessage = "Captures belong to a project — make or open one first"
            return
        }
        let folder = project.capturesFolder
        let panel = panelNumber(enclosing: shape, on: pageURL)
        let identity = ComicIdentity(item)
        let pageNumber = pageIndex + 1
        let citation = identity.citation(pages: [pageNumber], panel: panel)

        let kind: CaptureRecord.Kind
        var region: PageRect?
        var polygon: [PagePoint]?
        switch shape {
        case .page:
            kind = .page
        case .rect(let rect):
            kind = panel == nil ? .region : .panel
            region = PageRect(rect)
        case .polygon(let points):
            kind = panel == nil ? .shape : .panel
            polygon = points.pagePoints
            region = PageRect(bounding: points.pagePoints)
        }
        let record = CaptureRecord(
            kind: kind, series: identity.series, volume: identity.volume, chapter: identity.chapter,
            pages: [pageNumber], panel: panel, region: region, polygon: polygon, citation: citation,
            source: source.lastPathComponent, file: ""
        )
        let writer = CaptureWriter(folder: folder)

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<WriteResult, Error> in
                do {
                    let image: CGImage
                    switch shape {
                    case .page: image = try PageCropper.crop(pageURL, unitRect: nil)
                    case .rect(let rect): image = try PageCropper.crop(pageURL, unitRect: rect)
                    case .polygon(let points): image = try PageCropper.crop(pageURL, polygon: points)
                    }
                    // Only what was asked for: a drawn shape saves the shape.
                    // The whole page is its own command when it's wanted.
                    return .success(try writer.write(image, record: record))
                } catch {
                    return .failure(error)
                }
            }.value

            switch outcome {
            case .success(let written):
                let file = written.record.file
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(citation, forType: .string)
                let verb = written.reused ? "Already saved as" : "Saved"
                lastCaptureMessage = "\(verb) \(file) · cited in script"
                recordCitation(pageIndex: pageIndex, pageNumbers: [pageNumber], panel: panel,
                               polygon: polygon, region: region, captureFile: file, text: citation)
            case .failure(let error):
                lastCaptureMessage = "Couldn’t save the capture: \(error.localizedDescription)"
            }
        }
    }

    /// Save the page on screen. With a spread up, asks which one.
    func savePage() {
        let pages = visiblePages
        guard !pages.isEmpty else { return }
        guard project != nil else {
            lastCaptureMessage = "Captures belong to a project — make or open one first"
            return
        }
        if pages.count == 1 {
            capture(page: pages[0].url, shape: .page)
        } else {
            isCapturing = false
            isChoosingPageToSave = true
        }
    }

    /// The reader's answer to `savePage` on a spread.
    func savePage(_ url: URL) {
        isChoosingPageToSave = false
        capture(page: url, shape: .page)
    }

    /// Both pages of the spread, whole.
    func saveVisiblePages() {
        isChoosingPageToSave = false
        for page in visiblePages {
            capture(page: page.url, shape: .page)
        }
    }

    /// Which detected panel, if any, the shape's centre falls in — so a shape
    /// drawn around panel 3 is cited as panel 3. Detection is only ever used
    /// for this; it never decides what gets captured.
    private func panelNumber(enclosing shape: CaptureShape, on pageURL: URL) -> Int? {
        guard let panels = detectedPanels[pageURL], !panels.isEmpty else { return nil }
        let centre: CGPoint
        switch shape {
        case .page:
            return nil
        case .rect(let rect):
            centre = CGPoint(x: rect.midX, y: rect.midY)
        case .polygon(let points):
            guard !points.isEmpty else { return nil }
            centre = CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                             y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        // Smallest containing box wins, so a shape inside a fused region is
        // still attributed to the tighter panel when there is one.
        return panels.indices
            .filter { panels[$0].box.contains(centre) }
            .min { panels[$0].box.width * panels[$0].box.height < panels[$1].box.width * panels[$1].box.height }
            .map { $0 + 1 }
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
            result[pages[hit.page], default: []].append(hit.line.box.cgRect)
        }
        return result
    }

    /// Reads the lettering off every page not already in the stored index,
    /// one page at a time at low priority so it never contends with the page
    /// decodes that keep turns instant. Saves as it goes, so a quit mid-way
    /// resumes rather than restarts.
    private func startIndexing(identity: String, pages: [URL]) {
        indexingTask?.cancel()
        let store = indexStore
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
                    guard let self, self.openIdentity == identity else { return }
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
}
