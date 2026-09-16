import Testing
import Foundation
import CoreGraphics
@testable import Panels
import ComicArchive
import ComicLibrary
import PanelsProject
import PageCapture

/// The reader, the library and a project together, driven the way the menus
/// drive them. The tests on real comics need PANELS_TEST_CBR (a single file)
/// and PANELS_TEST_FOLDER (a folder of chapters).
@Suite("Reader, library and project", .serialized)
@MainActor
struct ReaderProjectTests {
    static var comicPath: String? { ProcessInfo.processInfo.environment["PANELS_TEST_CBR"] }
    static var folderPath: String? { ProcessInfo.processInfo.environment["PANELS_TEST_FOLDER"] }

    /// A library, a projects folder and a reader of their own, in a scratch
    /// folder that goes when the test does.
    @MainActor
    struct Scratch {
        let root: URL
        let library: Library
        let projects: ProjectLibrary
        let model: ReaderModel

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = Library(folder: root.appendingPathComponent("Library", isDirectory: true))
            let projectsRoot = root.appendingPathComponent("Projects", isDirectory: true)
            try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            projects = ProjectLibrary(root: projectsRoot, defaults: UserDefaults(suiteName: "PanelsTests-\(UUID().uuidString)")!)
            model = ReaderModel(library: library, projects: projects)
        }

        func tearDown() {
            model.closeProject()
            model.closeComic()
            try? FileManager.default.removeItem(at: root)
        }

        /// A project folder about `series`, made directly rather than
        /// through the reader.
        func project(named name: String, series: String) throws -> Project {
            let url = try projects.create(named: name, series: series)
            return try Project.open(url)
        }
    }

    static func wait(seconds: Double = 30, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    // MARK: - Projects folder

    @Test("Projects are grouped by the series they're about, newest first")
    func projectGrouping() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }

        func make(_ name: String, series: String, cites title: String?, editedSecondsAgo: Double) throws {
            let url = try scratch.projects.create(named: name, series: series)
            var loaded = try ProjectStore.load(url)
            if let title {
                loaded.manifest.register(ItemRef(itemID: "\(title).cbz|1", filename: "\(title).cbz", fileSize: 1, series: series, title: title))
            }
            try ProjectStore.save(loaded, to: url)
            let date = Date().addingTimeInterval(-editedSecondsAgo)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ProjectStore.scriptURL(of: url).path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ProjectStore.manifestURL(of: url).path)
        }
        try make("Eclipse", series: "Berserk", cites: "Vol. 13", editedSecondsAgo: 100)
        try make("Golden Age", series: "Berserk", cites: "Vol. 4", editedSecondsAgo: 3000)
        try make("Buu Saga", series: "Dragon Ball", cites: nil, editedSecondsAgo: 500)
        scratch.projects.refresh()

        let groups = scratch.projects.groupedBySeries
        #expect(groups.map(\.series) == ["Berserk", "Dragon Ball"])
        #expect(groups[0].projects.map(\.name) == ["Eclipse", "Golden Age"])
        #expect(groups[1].projects.map(\.name) == ["Buu Saga"])
        #expect(scratch.projects.summary(for: groups[0].projects[0].url)?.items == ["Vol. 13"])
        #expect(scratch.projects.summary(for: groups[1].projects[0].url)?.items == [])
    }

    @Test("Rename, duplicate and trash keep the folder and the list in step")
    func projectEdits() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let projects = scratch.projects

        let url = try projects.create(named: "Draft", series: "Berserk")
        #expect(projects.summaries.map(\.name) == ["Draft"])

        let renamed = try projects.rename(url, to: "Final")
        #expect(renamed.lastPathComponent == "Final.panelsproject")
        #expect(try ProjectStore.loadManifest(renamed).name == "Final")
        #expect(try ProjectStore.loadManifest(renamed).series == "Berserk")
        #expect(projects.summaries.map(\.name) == ["Final"])

        let copy = try projects.duplicate(renamed)
        #expect(copy.lastPathComponent == "Final copy.panelsproject")
        #expect(Set(projects.summaries.map(\.name)) == ["Final", "Final copy"])

        try projects.trash(copy)
        #expect(projects.summaries.map(\.name) == ["Final"])
    }

    @Test("A project can't be made without a series to be about")
    func projectNeedsSeries() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        scratch.model.newProject(named: "Nothing")
        #expect(scratch.model.project == nil)
        #expect(scratch.model.errorMessage != nil)
    }

    // MARK: - Reading through the library

    @Test("A comic file joins the library as a series of one and opens where it was left")
    func libraryOpensAFile() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        let file = URL(fileURLWithPath: path)

        model.addToLibrary(file)
        #expect(scratch.library.series.count == 1)
        let series = try #require(scratch.library.series.first)
        #expect(series.items.count == 1)
        #expect(series.items[0].id == LibraryItem.makeID(filename: file.lastPathComponent,
                                                         fileSize: (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1))
        #expect(await Self.wait { model.hasComic })
        #expect(model.item?.id == series.items[0].id)
        #expect(model.series?.name == series.name)
        // One item: nothing to list beside the pages.
        #expect(!model.hasContents)

        // The position lives in the library, per item.
        model.goTo(spread: 9)
        #expect(scratch.library.position(for: series.items[0]) == 9)
        #expect(scratch.library.recentlyRead.map(\.item.id) == [series.items[0].id])

        model.closeComic()
        #expect(model.item == nil)
        model.read(series)
        #expect(await Self.wait { model.hasComic })
        #expect(model.spreadIndex == 9)

        // Adding the same file again changes nothing.
        model.addToLibrary(file)
        #expect(scratch.library.series.count == 1)
        #expect(scratch.library.roots.count == 1)

        // Forgetting the folder forgets the series.
        scratch.library.removeRoot(file)
        #expect(scratch.library.isEmpty)
    }

    @Test("A folder reads as one series: the last page turns into the next chapter, and back")
    func readThroughASeries() async throws {
        guard let path = Self.folderPath else {
            withKnownIssue("Set PANELS_TEST_FOLDER to a folder of chapters to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        let folder = URL(fileURLWithPath: path, isDirectory: true)

        model.addToLibrary(folder)
        // A folder lands on its series' page rather than opening anything.
        #expect(model.showsHome)
        #expect(model.homeTab == .library)
        let series = try #require(scratch.library.series.first)
        #expect(model.browsingSeries == series.name)
        #expect(series.items.count >= 2)
        #expect(series.chapterCount == series.items.count)

        model.read(series)
        #expect(await Self.wait { model.hasComic })
        #expect(!model.showsHome)
        #expect(model.hasContents)
        let first = try #require(model.item)
        #expect(first.id == series.items[0].id)
        #expect(model.currentItemIndex == 0)
        #expect(model.itemNoun == "Chapter")

        // Off the end of this chapter, into the start of the next.
        model.goToEnd()
        let lastSpread = model.spreadIndex
        #expect(model.canGoForward)
        model.goForward()
        // `item` moves on at once; the pages follow when the file has opened.
        #expect(await Self.wait { model.item?.id == series.items[1].id && !model.isLoading })
        #expect(model.spreadIndex == 0)
        #expect(scratch.library.position(for: first) == lastSpread)

        // Back off the front of it, onto the last spread of the one before.
        model.goBack()
        #expect(await Self.wait { model.item?.id == first.id && !model.isLoading })
        #expect(model.spreadIndex == model.spreads.count - 1)

        // A project made while reading is about this series.
        model.newProject(named: "Arc")
        let project = try #require(model.project)
        #expect(project.manifest.series == series.name)
        #expect(scratch.projects.summaries.map(\.series) == [series.name])

        // Picking the series up again lands on the chapter last read.
        model.closeComic()
        #expect(scratch.library.continueItem(in: series)?.id == first.id)
    }

    // MARK: - Projects and citations

    @Test("Opening a project brings up its series where it was left; the same series keeps its pages")
    func switching() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let series = try #require(model.series)

        model.newProject(named: "First")
        let first = try #require(model.project)
        #expect(first.manifest.series == series.name)
        first.script = "The first script."
        model.goTo(spread: 7)

        model.newProject(named: "Second")
        let second = try #require(model.project)
        #expect(second.name == "Second")
        #expect(model.spreadIndex == 7)
        // The first was saved on the way out.
        #expect(try ProjectStore.load(first.url).script == "The first script.")

        // Back to the first: same series, so the pages don't move.
        model.switchTo(first.url)
        #expect(model.project?.name == "First")
        #expect(model.project?.script == "The first script.")
        #expect(model.spreadIndex == 7)
        #expect(model.hasComic)
        model.closeProject()

        // With nothing open, a project brings its series up where it was left.
        model.closeComic()
        model.switchTo(second.url)
        #expect(await Self.wait { model.hasComic })
        #expect(model.series?.name == series.name)
        #expect(model.spreadIndex == 7)
        #expect(scratch.projects.summaries.map(\.name).sorted() == ["First", "Second"])
    }

    @Test("A project about a series that isn't here says so, until its folder is added")
    func missingSeries() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        let file = URL(fileURLWithPath: path)
        let seriesName = ComicIdentity(fileURL: file).series

        let project = try scratch.project(named: "Elsewhere", series: seriesName)
        model.openProject(at: project.url)
        #expect(model.project?.name == "Elsewhere")
        #expect(model.missingSeries == seriesName)
        #expect(!model.hasComic)

        scratch.library.addRoot(file)
        #expect(model.missingSeries == nil)
        // Nothing to capture into without pages; nothing opened by itself.
        #expect(!model.hasComic)
        model.read(try #require(scratch.library.series(named: seriesName)))
        #expect(await Self.wait { model.hasComic })
    }

    @Test("Citing puts a citation in the project by library item, queues its chip, and can be jumped to")
    func citeAndJump() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let item = try #require(model.item)
        model.newProject(named: "Cited")
        let project = try #require(model.project)
        #expect(project.manifest.items.isEmpty)

        model.goTo(spread: 5)
        let text = try #require(model.copyCitation())
        #expect(text.hasPrefix(item.series))
        #expect(project.manifest.citations.count == 1)
        let citation = project.manifest.citations[0]
        #expect(citation.itemID == item.id)
        #expect(citation.text == text)
        #expect(citation.pageNumbers == model.visiblePages.map(\.number))
        #expect(project.pendingInsertion?.id == citation.id)
        // The item is on record, once, however often it's cited.
        model.copyCitation()
        #expect(project.manifest.items.map(\.itemID) == [item.id])
        #expect(project.manifest.items[0].filename == item.url.lastPathComponent)
        #expect(project.manifest.items[0].series == item.series)

        // Go elsewhere, then follow the citation back.
        model.goTo(spread: 40)
        model.jump(toCitation: citation.id)
        #expect(model.spreadIndex == 5)
        #expect(!model.focusOutlines.isEmpty)

        // From nothing open, the jump opens the item first.
        model.closeComic()
        model.jump(toCitation: citation.id)
        #expect(await Self.wait { model.hasComic && model.spreadIndex == 5 })
        #expect(!model.focusOutlines.isEmpty)

        // The project saves itself.
        #expect(await Self.wait(seconds: 5) { (try? ProjectStore.load(project.url))?.manifest.citations.count == 2 })
    }

    @Test("Shots come back in script order, and a deleted chip leaves an unused citation")
    func shotOrder() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Order", series: "Berserk")

        // Three citations, made in one order...
        let first = Citation(itemID: "b|1", pageIndex: 10, pageNumbers: [11], text: "first")
        let second = Citation(itemID: "b|1", pageIndex: 20, pageNumbers: [21], text: "second")
        let third = Citation(itemID: "b|1", pageIndex: 30, pageNumbers: [31], text: "third")
        project.manifest.citations = [first, second, third]

        // ...and written into the script in another, with one left out.
        project.script = """
        # Beat one
        The bear falls [third](panels://cite/\(third.id)) and then [first](panels://cite/\(first.id)).
        """

        #expect(project.citationsInScriptOrder.map(\.text) == ["third", "first"])
        #expect(project.unusedCitations.map(\.text) == ["second"])
        #expect(project.context(of: third.id) == "The bear falls and then .")

        project.removeCitation(id: second.id)
        #expect(project.unusedCitations.isEmpty)
        #expect(project.manifest.citations.count == 2)
    }

    @Test("Cleaning up trashes only what the script doesn't use")
    func cleanUp() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Clean", series: "B")

        func writeCapture(_ name: String) throws {
            try Data(repeating: 7, count: 2048).write(to: project.capturesFolder.appendingPathComponent(name))
        }
        // One cited, one whose chip was deleted, one belonging to no citation
        // at all — a page saved automatically beside a panel, as used to happen.
        try writeCapture("kept.png")
        try writeCapture("orphan.png")
        try writeCapture("stray.png")
        let kept = Citation(itemID: "b|1", pageIndex: 1, pageNumbers: [2], captureFile: "kept.png", text: "kept")
        let orphan = Citation(itemID: "b|1", pageIndex: 5, pageNumbers: [6], captureFile: "orphan.png", text: "orphan")
        project.manifest.citations = [kept, orphan]
        project.script = "Only [kept](panels://cite/\(kept.id)) is in the script."

        #expect(Set(project.unusedCaptureFiles.map(\.lastPathComponent)) == ["orphan.png", "stray.png"])
        #expect(project.unusedCaptureBytes == 4096)

        let gone = project.cleanUpUnusedCaptures()
        #expect(gone.files == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(left == ["kept.png"])
        #expect(project.manifest.citations.map(\.id) == [kept.id])
        #expect(project.unusedCaptureFiles.isEmpty)
    }

    @Test("Cleaning up leaves the writer's manifest describing what's really there")
    func cleanUpPrunesWriterManifest() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Prune", series: "B")

        // Two captures written properly, so captures.json knows them both.
        let writer = CaptureWriter(folder: project.capturesFolder)
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        let image = context.makeImage()!
        func record(_ page: Int) -> CaptureRecord {
            CaptureRecord(kind: .page, series: "B", volume: 1, chapter: nil, pages: [page], panel: nil,
                          region: nil, citation: "p\(page)", source: "b.cbz", file: "")
        }
        let keptFile = try writer.write(image, record: record(1)).record.file
        let droppedFile = try writer.write(image, record: record(2)).record.file
        #expect(writer.loadManifest().count == 2)

        let cited = Citation(itemID: "b|1", pageIndex: 0, pageNumbers: [1], captureFile: keptFile, text: "kept")
        project.manifest.citations = [cited]
        project.script = "Only [kept](panels://cite/\(cited.id))."

        project.cleanUpUnusedCaptures()

        let onDisk = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(onDisk == [keptFile])
        #expect(writer.loadManifest().map(\.file) == [keptFile])
        #expect(!writer.loadManifest().contains { $0.file == droppedFile })
    }

    @Test("Removing one citation trashes its capture, but not one still cited")
    func removeOne() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Remove", series: "B")
        for name in ["a.png", "b.png"] {
            try Data(repeating: 1, count: 16).write(to: project.capturesFolder.appendingPathComponent(name))
        }
        let a = Citation(itemID: "b|1", pageIndex: 0, pageNumbers: [1], captureFile: "a.png", text: "a")
        let b = Citation(itemID: "b|1", pageIndex: 1, pageNumbers: [2], captureFile: "b.png", text: "b")
        project.manifest.citations = [a, b]
        project.script = "Kept [b](panels://cite/\(b.id))."

        project.removeCitation(id: a.id)
        let left = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(left == ["b.png"])
    }

    @Test("A capture lands in the project's captures folder as a citation with its shape — and needs a project")
    func captureIntoProject() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let page = model.pages[10]
        let triangle = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.3, y: 0.5)]

        // Without a project there's nowhere for a capture to go.
        #expect(!model.canCapture)
        model.toggleCapture()
        #expect(!model.isCapturing)
        model.capture(page: page, shape: .polygon(triangle))
        #expect(model.lastCaptureMessage?.contains("project") == true)

        model.newProject(named: "Shots")
        let project = try #require(model.project)
        #expect(model.canCapture)
        model.capture(page: page, shape: .polygon(triangle))
        #expect(await Self.wait(seconds: 20) { project.manifest.citations.count == 1 })

        let citation = project.manifest.citations[0]
        #expect(citation.polygon == triangle)
        #expect(citation.pageIndex == 10)
        #expect(citation.itemID == model.item?.id)
        let file = try #require(citation.captureFile)
        #expect(FileManager.default.fileExists(atPath: project.capturesFolder.appendingPathComponent(file).path))
        // Only the shape: the whole page is its own command, not a companion.
        let written = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(written == [file])
        #expect(project.pendingInsertion?.id == citation.id)
    }
}
