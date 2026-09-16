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
        // The whole page went alongside.
        #expect(FileManager.default.fileExists(atPath: project.capturesFolder.appendingPathComponent(
            file.replacingOccurrences(of: "shape", with: "page")).path))
        #expect(project.pendingInsertion?.id == citation.id)
        model.closeProject()
    }
}
