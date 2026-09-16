import Testing
import Foundation
@testable import PanelsProject

@Suite("Script Markdown")
struct ScriptMarkdownTests {
    @Test("Plain paragraphs and headings round-trip line for line")
    func basics() {
        let text = "# Chapter One\nGuts walks into the tavern.\n\n## Beat 2\nThe eclipse begins."
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks == [
            .heading(level: 1, [.text("Chapter One")]),
            .paragraph([.text("Guts walks into the tavern.")]),
            .paragraph([]),
            .heading(level: 2, [.text("Beat 2")]),
            .paragraph([.text("The eclipse begins.")]),
        ])
        #expect(ScriptMarkdown.serialize(blocks) == text)
    }

    @Test("A citation is a link, and comes back as a chip")
    func citation() {
        let text = "He raises the sword [Berserk, Vol. 1, p. 117, panel 3](panels://cite/k7q2x4) and waits."
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks == [.paragraph([
            .text("He raises the sword "),
            .citation(id: "k7q2x4", text: "Berserk, Vol. 1, p. 117, panel 3"),
            .text(" and waits."),
        ])])
        #expect(ScriptMarkdown.serialize(blocks) == text)
    }

    @Test("Brackets, backslashes and hash signs in prose survive")
    func escapes() {
        let blocks: [ScriptBlock] = [
            .paragraph([.text("Array[0] and a \\ backslash [not a link](http://x)")]),
            .paragraph([.text("# not a heading")]),
            .paragraph([.citation(id: "abc123", text: "Odd ] title")]),
        ]
        let text = ScriptMarkdown.serialize(blocks)
        #expect(ScriptMarkdown.parse(text) == blocks)
        // And a foreign link is just prose.
        #expect(ScriptMarkdown.parse("see [docs](https://example.com)") == [.paragraph([.text("see [docs](https://example.com)")])])
    }

    @Test("Plain text for pasting elsewhere")
    func plain() {
        let blocks = ScriptMarkdown.parse("# Title\nSee [Berserk, Vol. 1, p. 3](panels://cite/aaaaaa).")
        #expect(ScriptMarkdown.plainText(blocks) == "Title\nSee Berserk, Vol. 1, p. 3.")
    }

    @Test("Citation URLs")
    func urls() {
        let url = ScriptMarkdown.citationURL(id: "zz9pza")
        #expect(url.absoluteString == "panels://cite/zz9pza")
        #expect(ScriptMarkdown.citationID(from: url) == "zz9pza")
        #expect(ScriptMarkdown.citationID(from: URL(string: "https://example.com")!) == nil)
    }
}

@Suite("Citation order in a script")
struct CitationOrderTests {
    @Test("Ids come back in the order they appear, not the order they were made")
    func order() {
        let script = """
        # Opening
        The bear falls [third](panels://cite/ccc333).
        Then [first](panels://cite/aaa111) and [second](panels://cite/bbb222).
        """
        #expect(ScriptMarkdown.citationIDs(in: script) == ["ccc333", "aaa111", "bbb222"])
    }

    @Test("A citation used twice counts once, at its first appearance")
    func duplicates() {
        let script = "A [x](panels://cite/xxx111) then B [y](panels://cite/yyy222) then A again [x](panels://cite/xxx111)."
        #expect(ScriptMarkdown.citationIDs(in: script) == ["xxx111", "yyy222"])
    }

    @Test("A script with no citations, and prose that merely looks like one")
    func none() {
        #expect(ScriptMarkdown.citationIDs(in: "Just words.").isEmpty)
        #expect(ScriptMarkdown.citationIDs(in: "See [docs](https://example.com).").isEmpty)
        #expect(ScriptMarkdown.citationIDs(in: "").isEmpty)
    }

    @Test("The line around a citation, chips stripped")
    func context() {
        let script = """
        # Title
        Guts swings [Berserk, p. 5](panels://cite/aaa111) and the bear falls.
        Another line.
        """
        #expect(ScriptMarkdown.context(of: "aaa111", in: script) == "Guts swings and the bear falls.")
        #expect(ScriptMarkdown.context(of: "missing", in: script) == nil)
    }
}

@Suite("Project store")
struct ProjectStoreTests {
    @Test("Create, save and load a project folder")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.panelsproject", isDirectory: true)

        var loaded = try ProjectStore.create(at: url, name: "Test")
        #expect(FileManager.default.fileExists(atPath: ProjectStore.capturesFolder(of: url).path))
        #expect(loaded.manifest.name == "Test")

        let comic = ComicRef(title: "Berserk", path: "/x/Berserk v01.cbz", filename: "Berserk v01.cbz", fileSize: 42)
        let cite = Citation(comicID: comic.id, pageIndex: 116, pageNumbers: [117], panel: 3,
                            polygon: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.3, y: 0.6)],
                            captureFile: "Berserk v01 p117 panel3.png", text: "Berserk, Vol. 1, p. 117, panel 3")
        loaded.manifest.comics = [comic]
        loaded.manifest.citations = [cite]
        loaded.manifest.positions[comic.id] = 58
        loaded.script = "Here [\(cite.text)](panels://cite/\(cite.id))."
        try ProjectStore.save(loaded, to: url)

        let back = try ProjectStore.load(url)
        #expect(back.manifest.comics == [comic])
        #expect(back.manifest.citations.count == 1)
        #expect(back.manifest.citations[0].id == cite.id)
        #expect(back.manifest.citations[0].polygon == cite.polygon)
        #expect(back.manifest.positions[comic.id] == 58)
        #expect(back.script == loaded.script)
        #expect(back.manifest.citation(id: cite.id)?.panel == 3)
    }

    @Test("A moved comic is matched by name and size")
    func relocate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Berserk v01.cbz")
        try Data(repeating: 1, count: 1234).write(to: file)

        let ref = ComicRef(title: "Berserk", path: "/gone/Berserk v01.cbz", filename: "Berserk v01.cbz", fileSize: 1234)
        let manifest = ProjectManifest(name: "T", comics: [ref])
        #expect(manifest.comic(for: file)?.id == ref.id)
        let other = dir.appendingPathComponent("Other.cbz")
        try Data(repeating: 1, count: 99).write(to: other)
        #expect(manifest.comic(for: other) == nil)
    }

    @Test("IDs are short, URL-safe and distinct")
    func ids() {
        let ids = (0..<200).map { _ in ProjectManifest.makeID() }
        #expect(ids.allSatisfy { $0.count == 6 && $0.allSatisfy { $0.isLetter || $0.isNumber } })
        #expect(Set(ids).count > 195)
    }
}
