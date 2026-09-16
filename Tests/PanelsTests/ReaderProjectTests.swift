import Testing
import Foundation
import CoreGraphics
@testable import Panels
import PanelsProject

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
