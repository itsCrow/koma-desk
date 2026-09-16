import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import ComicArchive
import ComicLibrary
import PanelsFormat
import PageSearch
import PageCapture
import PanelsProject

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

/// Where to land when the next item opens as part of reading straight through.
enum ItemStart {
    case beginning, end
}

/// What a capture covers.
enum CaptureShape {
    case page
    case rect(CGRect)
    /// Unit coords, top-left origin. Everything outside is transparent.
    case polygon([CGPoint])
}

/// The two halves of the home screen.
enum HomeTab: String {
    case library, projects
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
    var homeTab: HomeTab = .library
    /// The series whose page the library half of home is showing, if any.
    var browsingSeries: String?
    /// ⌘N: the projects half should offer the name field straight away.
    var wantsNewProject = false
    /// The script pane has the keyboard: every reader key stands down.
    var isScriptEditing = false
    /// Whether the script pane is shown when a project is open.
    var showsScript: Bool {
        didSet { UserDefaults.standard.set(showsScript, forKey: Self.showsScriptKey) }
    }
    /// The script pane is showing the shot list rather than the writing.
    var showsShotList = false
    /// The controls panel is expanded into a grid filling the page area.
    var isOverviewExpanded = false
    /// The series' contents beside the pages.
    var showsContents: Bool {
        didSet { UserDefaults.standard.set(showsContents, forKey: Self.showsContentsKey) }
    }
    var scriptPlacement: ScriptPlacement {
        didSet { UserDefaults.standard.set(scriptPlacement.rawValue, forKey: Self.scriptPlacementKey) }
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

    @ObservationIgnored private let cache = PageCache()
    @ObservationIgnored private var source: URL?
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
    @ObservationIgnored private var focusTask: Task<Void, Never>?

    private static let directionKey = "PanelsReadingDirection"
    private static let showsScriptKey = "PanelsShowsScript"
    private static let showsContentsKey = "PanelsShowsSeriesContents"
    private static let scriptPlacementKey = "PanelsScriptPlacement"

    init(library: Library = Library(), projects: ProjectLibrary = ProjectLibrary()) {
        self.library = library
        self.projects = projects
        let stored = UserDefaults.standard.string(forKey: Self.directionKey)
        // Defaults to manga order.
        direction = stored.flatMap(ReadingDirection.init(rawValue:)) ?? .rightToLeft
        showsScript = UserDefaults.standard.object(forKey: Self.showsScriptKey) as? Bool ?? true
        showsContents = UserDefaults.standard.object(forKey: Self.showsContentsKey) as? Bool ?? true
        scriptPlacement = UserDefaults.standard.string(forKey: Self.scriptPlacementKey)
            .flatMap(ScriptPlacement.init(rawValue:)) ?? .right
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
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            library.rescan()
            errorMessage = "“\(item.url.lastPathComponent)” isn’t where it was. If it moved, add its new folder to the library."
            return
        }
        self.item = item
        self.series = library.series(containing: item)
        isLoading = true
        errorMessage = nil
        warning = nil
        let url = item.url

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
                pendingStart = nil
                errorMessage = Self.describe(error, for: url)
            }
        }
    }

    /// Picks a series up where it was left, or starts it.
    func read(_ series: Series) {
        guard let item = library.continueItem(in: series) else { return }
        showsHome = false
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

        let restored = item.map { library.position(for: $0) } ?? 0
        switch pendingStart {
        case .beginning: spreadIndex = 0
        case .end: spreadIndex = max(spreads.count - 1, 0)
        case nil: spreadIndex = min(max(restored, 0), max(spreads.count - 1, 0))
        }
        pendingStart = nil
        if let item {
            // Landing on the first spread doesn't change spreadIndex, so the
            // position is written here as well as in its didSet.
            library.setPosition(spreadIndex, for: item)
            library.noteRead(item)
        }
        prefetchNeighbours()
        NSDocumentController.shared.noteNewRecentDocumentURL(comic.source)
        startIndexing(comic)

        if let jump = pendingJump, jump.itemID == item?.id {
            pendingJump = nil
            land(on: jump)
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

    /// Back to the series' page on the home screen.
    func showSeriesPage() {
        guard let series else { return }
        browsingSeries = series.name
        homeTab = .library
        showsHome = true
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
        guard let source, hasComic else { return nil }
        return ComicIdentity(fileURL: source).citation(pages: visiblePages.map(\.number))
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
    func requestNewProject() {
        wantsNewProject = true
        homeTab = .projects
        showsHome = true
    }

    /// A new project about a series, opened. Made from the series' page, or
    /// from the projects list with a series chosen; with nothing chosen, the
    /// series being read.
    func newProject(named name: String, series seriesName: String? = nil) {
        guard let seriesName = seriesName ?? series?.name ?? project?.manifest.series else {
            errorMessage = "A project is about one series. Add its comics to the library, then make the project from the series’ page."
            return
        }
        do {
            let url = try projects.create(named: name, series: seriesName)
            closeProject()
            adopt(try Project.open(url))
            showsHome = false
            if series?.name != seriesName, let found = library.series(named: seriesName) {
                read(found)
            }
        } catch {
            errorMessage = "Couldn’t create the project. \(error.localizedDescription)"
        }
    }

    /// Another project takes the place of this one. Its series comes up where
    /// it was last read — unless that's the series already on screen, in
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
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            showsHome = false
            if series?.name != next.manifest.series, let found = library.series(named: next.manifest.series) {
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
        panel.allowedContentTypes = [.panelsProject]
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
        clearFocus()
    }

    /// The open project's series, when the library hasn't got it — the
    /// editor's Mac, before they've added the folder.
    var missingSeries: String? {
        guard let project, library.series(named: project.manifest.series) == nil else { return nil }
        return project.manifest.series
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
        guard !shots.isEmpty else {
            errorMessage = "There are no citations in the script yet."
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
            for (index, citation) in shots.enumerated() {
                let number = String(format: "%02d", index + 1)
                var filename = "\(number)_(no capture)"
                if let source = project.captureURL(for: citation),
                   FileManager.default.fileExists(atPath: source.path) {
                    let stem = source.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: " ", with: "_")
                    filename = "\(number)_\(stem).\(source.pathExtension)"
                    let destination = folder.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                lines.append("\(number). \(citation.text)")
                lines.append("    \(filename)")
                if let context = project.context(of: citation.id), !context.isEmpty {
                    lines.append("    \(context)")
                }
                lines.append("")
            }
            try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("Shots.txt"),
                                                    atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            lastCaptureMessage = "Exported \(shots.count) shots"
        } catch {
            errorMessage = "Couldn’t export the shots. \(error.localizedDescription)"
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
        guard let project else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(project.plainTextScript, forType: .string)
        lastCaptureMessage = "Script copied as plain text"
    }

    func format(_ command: ScriptCommand) {
        project?.pendingCommand = command
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

    func jump(toCitation id: String) {
        guard let project, let citation = project.citation(id: id) else { return }
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

    private func land(on citation: Citation) {
        guard let spread = spreads.firstIndex(where: { $0.pageIndices.contains(citation.pageIndex) }) else { return }
        goTo(spread: spread)
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
            try? await Task.sleep(for: .seconds(4))
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
        guard let source, let pageIndex = pageIndexByURL[pageURL] else { return }
        guard let project else {
            lastCaptureMessage = "Captures belong to a project — make or open one first"
            return
        }
        let folder = project.capturesFolder
        let panel = panelNumber(enclosing: shape, on: pageURL)
        let identity = ComicIdentity(fileURL: source)
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
}
