import Testing
import Foundation
import CoreGraphics
@testable import Panels
import PanelsProject
import PageCapture

/// The reader and a project together, driven the way the menus drive them.
/// Needs a real comic: set PANELS_TEST_CBR.
@Suite("Reader and project", .serialized)
@MainActor
struct ReaderProjectTests {
    static var comicPath: String? { ProcessInfo.processInfo.environment["PANELS_TEST_CBR"] }

    static func scratchProject() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Test.panelsproject", isDirectory: true)
        _ = try ProjectStore.create(at: url, name: "Test")
        return url
    }

    static func wait(seconds: Double = 30, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    static func scratchLibrary() throws -> (ProjectLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "PanelsTests-\(UUID().uuidString)")!
        return (ProjectLibrary(root: root, defaults: defaults), root)
    }

    @Test("The library groups projects by series and puts the newest first")
    func libraryGrouping() throws {
        let (library, root) = try Self.scratchLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        func make(_ name: String, series: String?, title: String, editedSecondsAgo: Double) throws {
            let url = try library.create(named: name)
            var loaded = try ProjectStore.load(url)
            if let series {
                loaded.manifest.comics = [ComicRef(title: title, path: "/x/\(title).cbz", filename: "\(title).cbz", fileSize: 1, series: series)]
            }
            try ProjectStore.save(loaded, to: url)
            let date = Date().addingTimeInterval(-editedSecondsAgo)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ProjectStore.scriptURL(of: url).path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ProjectStore.manifestURL(of: url).path)
        }
        try make("Eclipse", series: "Berserk", title: "Berserk v13", editedSecondsAgo: 100)
        try make("Golden Age", series: "Berserk", title: "Berserk v04", editedSecondsAgo: 3000)
        try make("Buu Saga", series: "Dragon Ball", title: "Chapter 467", editedSecondsAgo: 500)
        try make("Nothing yet", series: nil, title: "", editedSecondsAgo: 9000)
        library.refresh()

        let groups = library.groupedBySeries
        #expect(groups.map(\.series) == ["Berserk", "Dragon Ball", ProjectLibrary.unsortedSeries])
        #expect(groups[0].projects.map(\.name) == ["Eclipse", "Golden Age"])
        #expect(groups[1].projects.map(\.name) == ["Buu Saga"])
        #expect(library.summary(for: groups[0].projects[0].url)?.comics == ["Berserk v13"])
    }

    @Test("Rename, duplicate and trash keep the folder and the list in step")
    func libraryEdits() throws {
        let (library, root) = try Self.scratchLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try library.create(named: "Draft")
        #expect(library.summaries.map(\.name) == ["Draft"])

        let renamed = try library.rename(url, to: "Final")
        #expect(renamed.lastPathComponent == "Final.panelsproject")
        #expect(try ProjectStore.loadManifest(renamed).name == "Final")
        #expect(library.summaries.map(\.name) == ["Final"])

        let copy = try library.duplicate(renamed)
        #expect(copy.lastPathComponent == "Final copy.panelsproject")
        #expect(Set(library.summaries.map(\.name)) == ["Final", "Final copy"])

        try library.trash(copy)
        #expect(library.summaries.map(\.name) == ["Final"])
    }

    @Test("Switching between two projects on the same comic changes the script, not the pages")
    func switching() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let (library, root) = try Self.scratchLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ReaderModel(library: library)
        model.open(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let comic = URL(fileURLWithPath: path)

        // Two scripts about the one comic.
        model.newProject(named: "First")
        let first = try #require(model.project)
        #expect(first.manifest.comics.count == 1)
        #expect(first.manifest.comics[0].series == "Berserk")
        first.script = "The first script."
        model.goTo(spread: 7)

        model.newProject(named: "Second")
        let second = try #require(model.project)
        #expect(second.name == "Second")
        #expect(second.manifest.comics.count == 1)
        #expect(model.spreadIndex == 7)
        // The first was saved on the way out.
        #expect(try ProjectStore.load(first.url).script == "The first script.")

        // Back to the first: same comic, so the pages don't move.
        model.switchTo(first.url)
        #expect(model.project?.name == "First")
        #expect(model.project?.script == "The first script.")
        #expect(model.spreadIndex == 7)
        #expect(model.hasComic)
        _ = comic
        #expect(library.summaries.map(\.name).sorted() == ["First", "Second"])
        model.closeProject()
    }

    static var folderPath: String? { ProcessInfo.processInfo.environment["PANELS_TEST_FOLDER"] }

    @Test("A folder reads as one series: the last page turns into the next chapter, and back")
    func readThroughASeries() async throws {
        guard let path = Self.folderPath else {
            withKnownIssue("Set PANELS_TEST_FOLDER to a folder of chapters to run.") { Issue.record("skipped") }
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let (library, root) = try Self.scratchLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ReaderModel(library: library)

        model.open(folder: folder)
        #expect(model.chapters.count >= 2)
        #expect(await Self.wait { model.hasComic })
        let firstIndex = try #require(model.currentChapterIndex)
        let firstTitle = try #require(model.title)
        #expect(model.seriesTitle?.isEmpty == false)

        // Off the end of this chapter, into the start of the next.
        model.goToEnd()
        #expect(model.canGoForward)
        model.goForward()
        #expect(await Self.wait { model.title != firstTitle && model.hasComic })
        #expect(model.title == model.chapters[firstIndex + 1].title)
        #expect(model.spreadIndex == 0)

        // Back off the front of it, onto the last spread of the one before.
        model.goBack()
        #expect(await Self.wait { model.title == firstTitle && model.hasComic })
        #expect(model.spreadIndex == model.spreads.count - 1)

        // A project made here remembers the folder as well as the chapter.
        model.newProject(named: "Arc")
        let project = try #require(model.project)
        #expect(project.manifest.seriesFolder == folder.path)
        #expect(project.manifest.comics.count == 1)

        // A file from outside the series ends the series.
        if let comic = Self.comicPath {
            model.open(URL(fileURLWithPath: comic))
            #expect(await Self.wait { model.title != firstTitle && model.hasComic })
            #expect(model.seriesRoot == nil)
            #expect(model.chapters.isEmpty)
        }
        model.closeProject()
    }

    @Test("Citing puts a citation in the project, queues its chip, and can be jumped to")
    func citeAndJump() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let projectURL = try Self.scratchProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let model = ReaderModel()
        model.openProject(at: projectURL)
        let project = try #require(model.project)
        model.open(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })

        // The comic is now one of the project's.
        #expect(project.manifest.comics.count == 1)
        #expect(project.manifest.lastComicID == project.manifest.comics[0].id)

        model.goTo(spread: 5)
        let text = try #require(model.copyCitation())
        #expect(text.hasPrefix("Berserk"))
        #expect(project.manifest.citations.count == 1)
        let citation = project.manifest.citations[0]
        #expect(citation.text == text)
        #expect(citation.pageNumbers == model.visiblePages.map(\.number))
        #expect(project.pendingInsertion?.id == citation.id)

        // Go elsewhere, then follow the citation back.
        model.goTo(spread: 40)
        model.jump(toCitation: citation.id)
        #expect(model.spreadIndex == 5)
        #expect(!model.focusOutlines.isEmpty)

        // The project saves itself.
        #expect(await Self.wait(seconds: 5) { (try? ProjectStore.load(projectURL))?.manifest.citations.count == 1 })
        model.closeProject()
    }

    @Test("Shots come back in script order, and a deleted chip leaves an unused citation")
    func shotOrder() throws {
        let projectURL = try Self.scratchProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        let project = try Project.open(projectURL)

        // Three citations, made in one order...
        let comic = ComicRef(title: "Berserk", path: "/x/b.cbz", filename: "b.cbz", fileSize: 1)
        project.manifest.comics = [comic]
        let first = Citation(comicID: comic.id, pageIndex: 10, pageNumbers: [11], text: "first")
        let second = Citation(comicID: comic.id, pageIndex: 20, pageNumbers: [21], text: "second")
        let third = Citation(comicID: comic.id, pageIndex: 30, pageNumbers: [31], text: "third")
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
        let projectURL = try Self.scratchProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        let project = try Project.open(projectURL)
        let comic = ComicRef(title: "B", path: "/x/b.cbz", filename: "b.cbz", fileSize: 1)
        project.manifest.comics = [comic]

        func writeCapture(_ name: String) throws {
            try Data(repeating: 7, count: 2048).write(to: project.capturesFolder.appendingPathComponent(name))
        }
        // One cited, one whose chip was deleted, one belonging to no citation
        // at all — a page saved automatically beside a panel, as used to happen.
        try writeCapture("kept.png")
        try writeCapture("orphan.png")
        try writeCapture("stray.png")
        let kept = Citation(comicID: comic.id, pageIndex: 1, pageNumbers: [2], captureFile: "kept.png", text: "kept")
        let orphan = Citation(comicID: comic.id, pageIndex: 5, pageNumbers: [6], captureFile: "orphan.png", text: "orphan")
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
        let projectURL = try Self.scratchProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        let project = try Project.open(projectURL)
        let comic = ComicRef(title: "B", path: "/x/b.cbz", filename: "b.cbz", fileSize: 1)
        project.manifest.comics = [comic]

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

        let cited = Citation(comicID: comic.id, pageIndex: 0, pageNumbers: [1], captureFile: keptFile, text: "kept")
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
        let projectURL = try Self.scratchProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        let project = try Project.open(projectURL)
        let comic = ComicRef(title: "B", path: "/x/b.cbz", filename: "b.cbz", fileSize: 1)
        project.manifest.comics = [comic]
        for name in ["a.png", "b.png"] {
            try Data(repeating: 1, count: 16).write(to: project.capturesFolder.appendingPathComponent(name))
        }
        let a = Citation(comicID: comic.id, pageIndex: 0, pageNumbers: [1], captureFile: "a.png", text: "a")
        let b = Citation(comicID: comic.id, pageIndex: 1, pageNumbers: [2], captureFile: "b.png", text: "b")
        project.manifest.citations = [a, b]
        project.script = "Kept [b](panels://cite/\(b.id))."

        project.removeCitation(id: a.id)
        let left = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(left == ["b.png"])
    }

    @Test("A comic that isn't on this Mac is reported, and found again beside the project")
    func missingComic() throws {
        let projectURL = try Self.scratchProject()
        let parent = projectURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let project = try Project.open(projectURL)

        project.manifest.comics = [ComicRef(title: "Berserk", path: "/gone/b.cbz", filename: "b.cbz", fileSize: 4)]
        #expect(project.missingComics.count == 1)

        // Dropped in a folder beside the project, as a shared folder would be.
        let comics = parent.appendingPathComponent("Comics", isDirectory: true)
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4).write(to: comics.appendingPathComponent("b.cbz"))
        #expect(project.missingComics.isEmpty)
        #expect(project.locate(project.manifest.comics[0])?.lastPathComponent == "b.cbz")
    }

    @Test("A capture in a project lands in its captures folder as a citation with its shape")
    func captureIntoProject() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let projectURL = try Self.scratchProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let model = ReaderModel()
        model.openProject(at: projectURL)
        let project = try #require(model.project)
        model.open(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })

        let page = model.pages[10]
        let triangle = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.3, y: 0.5)]
        model.capture(page: page, shape: .polygon(triangle))
        #expect(await Self.wait(seconds: 20) { project.manifest.citations.count == 1 })

        let citation = project.manifest.citations[0]
        #expect(citation.polygon == triangle)
        #expect(citation.pageIndex == 10)
        let file = try #require(citation.captureFile)
        #expect(FileManager.default.fileExists(atPath: project.capturesFolder.appendingPathComponent(file).path))
        // Only the shape: the whole page is its own command, not a companion.
        #expect(!FileManager.default.fileExists(atPath: project.capturesFolder.appendingPathComponent(
            file.replacingOccurrences(of: "shape", with: "page")).path))
        let written = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(written == [file])
        #expect(project.pendingInsertion?.id == citation.id)
        model.closeProject()
    }
}
