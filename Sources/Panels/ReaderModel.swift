import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import ComicArchive
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

/// What a capture covers.
enum CaptureShape {
    case page
    case rect(CGRect)
    /// Unit coords, top-left origin. Everything outside is transparent.
    case polygon([CGPoint])
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

    /// The open project, if any: the script lives beside the pages.
    private(set) var project: Project?
    /// The script pane has the keyboard: every reader key stands down.
    var isScriptEditing = false
    /// Whether the script pane is shown when a project is open.
    var showsScript: Bool {
        didSet { UserDefaults.standard.set(showsScript, forKey: Self.showsScriptKey) }
    }
    /// The script pane is showing the shot list rather than the writing.
    var showsShotList = false
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
            saveProgress()
            prefetchNeighbours()
            // Turning the page means you're done capturing from this one.
            isCapturing = false
            isChoosingPageToSave = false
            if let project, let source, let ref = project.manifest.comic(for: source) {
                project.manifest.positions[ref.id] = spreadIndex
            }
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
    /// A citation to land on once the comic it's in has opened.
    @ObservationIgnored private var pendingJump: Citation?
    @ObservationIgnored private var focusTask: Task<Void, Never>?

    private static let directionKey = "PanelsReadingDirection"
    private static let showsScriptKey = "PanelsShowsScript"
    private static let scriptPlacementKey = "PanelsScriptPlacement"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.directionKey)
        // Defaults to manga order.
        direction = stored.flatMap(ReadingDirection.init(rawValue:)) ?? .rightToLeft
        showsScript = UserDefaults.standard.object(forKey: Self.showsScriptKey) as? Bool ?? true
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

        if let project {
            let ref = project.comicRef(for: comic.source, title: comic.title)
            project.manifest.lastComicID = ref.id
        }
        if let jump = pendingJump, resolvedURL(forComicID: jump.comicID) == comic.source {
            pendingJump = nil
            land(on: jump)
        }
    }

    func closeComic() {
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
        if let source, let pageIndex = visiblePages.map({ pageIndexByURL[$0.url] ?? 0 }).min() {
            recordCitation(comicURL: source, pageIndex: pageIndex, pageNumbers: visiblePages.map(\.number),
                           panel: nil, polygon: nil, region: nil, captureFile: nil, text: citation)
        }
        return citation
    }

    // MARK: - Project

    func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.nameFieldStringValue = (title ?? "Untitled") + ".panelsproject"
        panel.allowedContentTypes = [.panelsProject]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != ProjectStore.packageExtension {
            url = url.appendingPathExtension(ProjectStore.packageExtension)
        }
        do {
            closeProject()
            let created = try Project.create(at: url)
            adopt(created)
        } catch {
            errorMessage = "Couldn’t create the project. \(error.localizedDescription)"
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

    func openProject(at url: URL) {
        do {
            closeProject()
            let opened = try Project.open(url)
            adopt(opened)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            // Pick up where the script left off.
            if !hasComic, let lastID = opened.manifest.lastComicID,
               let ref = opened.manifest.comic(id: lastID), let comicURL = opened.locate(ref) {
                open(comicURL)
            }
        } catch {
            errorMessage = "Couldn’t open the project. \(error.localizedDescription)"
        }
    }

    private func adopt(_ project: Project) {
        self.project = project
        if let source, let title {
            let ref = project.comicRef(for: source, title: title)
            project.manifest.lastComicID = ref.id
        }
    }

    func closeProject() {
        project?.saveNow()
        project = nil
        pendingJump = nil
        clearFocus()
    }

    /// A shot picked from the list: go to its page, and show where it sits
    /// in the script.
    func revealShot(_ citation: Citation) {
        project?.pendingReveal = citation.id
        jump(toCitation: citation.id)
    }

    /// Comics this project references that aren't on this Mac.
    var missingComics: [ComicRef] { project?.missingComics ?? [] }

    /// Asks for a missing comic and records where it is. The file has to be
    /// the same one: a different release has different pages, so every
    /// citation would land somewhere else.
    func locateComic(_ ref: ComicRef) {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.title = "Locate “\(ref.filename)”"
        panel.message = "Find your copy of “\(ref.filename)”. It must be the same file this script was written against."
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        let size = (try? chosen.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard chosen.lastPathComponent == ref.filename || size == ref.fileSize else {
            errorMessage = """
                That doesn’t look like the same comic.

                The script cites “\(ref.filename)” (\(ByteCountFormatter.string(fromByteCount: Int64(ref.fileSize), countStyle: .file))),                 but “\(chosen.lastPathComponent)” is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).                 A different release has different pages, so the citations would point at the wrong ones.
                """
            return
        }
        project.comicRef(for: chosen, title: ref.title)
        if !hasComic { open(chosen) }
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

    /// Records a citation in the project and queues its chip for the script.
    private func recordCitation(comicURL: URL, pageIndex: Int, pageNumbers: [Int], panel: Int?,
                                polygon: [CGPoint]?, region: CGRect?, captureFile: String?, text: String) {
        guard let project, let title else { return }
        let ref = project.comicRef(for: comicURL, title: title)
        let citation = Citation(comicID: ref.id, pageIndex: pageIndex, pageNumbers: pageNumbers, panel: panel,
                                polygon: polygon, region: region, captureFile: captureFile, text: text)
        project.add(citation)
        project.pendingInsertion = citation
    }

    // MARK: - Jumping to a citation

    /// Where a project comic is now, asking the reader if it can't be found.
    private func resolvedURL(forComicID id: String) -> URL? {
        guard let project, let ref = project.manifest.comic(id: id) else { return nil }
        return project.locate(ref)
    }

    func jump(toCitation id: String) {
        guard let project, let citation = project.citation(id: id) else { return }
        var url = resolvedURL(forComicID: citation.comicID)
        if url == nil, let ref = project.manifest.comic(id: citation.comicID) {
            let panel = NSOpenPanel()
            panel.title = "Locate “\(ref.filename)”"
            panel.message = "The comic this citation points to isn’t where it was. Find it to continue."
            panel.allowedContentTypes = Self.supportedContentTypes
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            project.comicRef(for: chosen, title: ref.title)  // updates the path
            url = chosen
        }
        guard let url else { return }
        if source == url {
            land(on: citation)
        } else {
            pendingJump = citation
            open(url)
        }
    }

    private func land(on citation: Citation) {
        guard let spread = spreads.firstIndex(where: { $0.pageIndices.contains(citation.pageIndex) }) else { return }
        goTo(spread: spread)
        guard pages.indices.contains(citation.pageIndex) else { return }
        let page = pages[citation.pageIndex]
        let outline: [CGPoint]
        if let polygon = citation.polygon {
            outline = polygon
        } else if let region = citation.region {
            outline = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                       CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)]
        } else {
            outline = [CGPoint(x: 0.01, y: 0.01), CGPoint(x: 0.99, y: 0.01), CGPoint(x: 0.99, y: 0.99), CGPoint(x: 0.01, y: 0.99)]
        }
        focusOutlines = [page: [outline]]
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

    private static let capturesRootKey = "PanelsCapturesRoot"

    /// Where captures go: `<root>/<Series>/`. The root is
    /// ~/Documents/Panels Captures unless the reader chose another.
    var capturesRoot: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: Self.capturesRootKey) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            return documents.appendingPathComponent("Panels Captures", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Self.capturesRootKey) }
    }

    var capturesFolder: URL? {
        if let project { return project.capturesFolder }
        guard let source else { return nil }
        return capturesRoot.appendingPathComponent(ComicIdentity(fileURL: source).series, isDirectory: true)
    }

    func toggleCapture() {
        guard hasComic else { return }
        isCapturing.toggle()
    }

    func chooseCapturesRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where captured panels are saved"
        panel.prompt = "Use This Folder"
        panel.directoryURL = capturesRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        capturesRoot = url
    }

    func revealCapturesFolder() {
        let folder = capturesFolder ?? capturesRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
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
        guard let source, let folder = capturesFolder,
              let pageIndex = pageIndexByURL[pageURL]
        else { return }
        let panel = panelNumber(enclosing: shape, on: pageURL)
        let identity = ComicIdentity(fileURL: source)
        let pageNumber = pageIndex + 1
        let citation = identity.citation(pages: [pageNumber], panel: panel)

        let kind: CaptureRecord.Kind
        var region: CGRect?
        var polygon: [CGPoint]?
        switch shape {
        case .page:
            kind = .page
        case .rect(let rect):
            kind = panel == nil ? .region : .panel
            region = rect
        case .polygon(let points):
            kind = panel == nil ? .shape : .panel
            polygon = points
            region = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let record = CaptureRecord(
            kind: kind, series: identity.series, volume: identity.volume, chapter: identity.chapter,
            pages: [pageNumber], panel: panel, region: region, polygon: polygon, citation: citation,
            source: source.lastPathComponent, file: ""
        )
        let writer = CaptureWriter(folder: folder)

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    let image: CGImage
                    switch shape {
                    case .page: image = try PageCropper.crop(pageURL, unitRect: nil)
                    case .rect(let rect): image = try PageCropper.crop(pageURL, unitRect: rect)
                    case .polygon(let points): image = try PageCropper.crop(pageURL, polygon: points)
                    }
                    // Only what was asked for: a drawn shape saves the shape.
                    // The whole page is its own command when it's wanted.
                    let written = try writer.write(image, record: record)
                    return .success(written.file)
                } catch {
                    return .failure(error)
                }
            }.value

            switch outcome {
            case .success(let file):
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(citation, forType: .string)
                lastCaptureMessage = project == nil ? "Saved \(file) · citation copied" : "Saved \(file) · cited in script"
                recordCitation(comicURL: source, pageIndex: pageIndex, pageNumbers: [pageNumber], panel: panel,
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
