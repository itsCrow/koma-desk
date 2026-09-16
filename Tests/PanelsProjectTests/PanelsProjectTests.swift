import Testing
import Foundation
import PanelsFormat
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

@Suite("Page ranges in a script")
struct ScriptSpanTests {
    @Test("A block of writing carries its range on every line, and round-trips")
    func markers() {
        let text = """
        <span:k7m2pq> The eclipse begins here.
        <span:k7m2pq> ## Still the same block
        <span:k7m2pq> And it keeps going.
        Then something unrelated.
        """
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks.map(\.spanID) == ["k7m2pq", "k7m2pq", "k7m2pq", nil])
        // The marker sits before the heading hashes, so the heading still reads.
        #expect(blocks[1].headingLevel == 2)
        #expect(blocks[1].inlines == [.text("Still the same block")])
        #expect(blocks[0].inlines == [.text("The eclipse begins here.")])
        #expect(ScriptMarkdown.serialize(blocks) == text)
    }

    @Test("A citation inside a block keeps working, and knows which block it's in")
    func citationInsideASpan() {
        let text = "<span:k7m2pq> He raises it [Berserk, p. 117](panels://cite/abc123) and waits."
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks[0].spanID == "k7m2pq")
        #expect(blocks[0].inlines == [
            .text("He raises it "),
            .citation(id: "abc123", text: "Berserk, p. 117"),
            .text(" and waits."),
        ])
        #expect(ScriptMarkdown.serialize(blocks) == text)
        #expect(ScriptMarkdown.spanID(containing: "abc123", in: text) == "k7m2pq")
        #expect(ScriptMarkdown.spanID(containing: "nope12", in: text) == nil)
        // A citation outside any block belongs to none.
        let loose = "Just a [shot](panels://cite/xyz789) here."
        #expect(ScriptMarkdown.spanID(containing: "xyz789", in: loose) == nil)
    }

    @Test("Prose that looks like a marker stays prose")
    func markerEscapes() {
        // Written by hand into the file, this is a real block marker...
        #expect(ScriptMarkdown.parse("<span:abc123> hello")[0].spanID == "abc123")
        // ...but the same text typed as prose has to survive a round trip.
        let typed: [ScriptBlock] = [.paragraph([.text("<span:abc123> hello")])]
        let serialized = ScriptMarkdown.serialize(typed)
        #expect(serialized == "\\<span:abc123> hello")
        #expect(ScriptMarkdown.parse(serialized) == typed)

        // Near misses are never markers: no space, no closing bracket, bad id.
        for line in ["<span:abc123>hello", "<span:abc123 hello", "<span:> hello",
                     "<span:has a space> hi", "<spam:abc123> hello", "<span:abc123>"] {
            #expect(ScriptMarkdown.parse(line)[0].spanID == nil, "\(line) should be prose")
        }
        // And an unrelated tag at the start of a line is left alone entirely.
        #expect(ScriptMarkdown.serialize(ScriptMarkdown.parse("<b>bold</b>")) == "<b>bold</b>")
    }

    @Test("Ranges come back in the order they first appear, each once")
    func order() {
        let text = """
        <span:aaa111> One.
        <span:aaa111> Still one.
        Unlinked.
        <span:bbb222> Two.
        <span:aaa111> One again, later.
        """
        #expect(ScriptMarkdown.spanIDs(in: text) == ["aaa111", "bbb222"])
        #expect(ScriptMarkdown.spanIDs(in: "nothing here") == [])
    }

    @Test("Pasting elsewhere carries the ranges, or drops them")
    func plainTextWithLabels() {
        let blocks = ScriptMarkdown.parse("""
        <span:k7m2pq> The eclipse begins.
        <span:k7m2pq> And it keeps going.
        Then something unrelated.
        """)
        let labels = ["k7m2pq": "pp. 12–17"]
        // The range lands once, on the last line of the block.
        #expect(ScriptMarkdown.plainText(blocks, spanLabels: labels) == """
        The eclipse begins.
        And it keeps going. (pp. 12–17)
        Then something unrelated.
        """)
        // Without labels, nothing changes from before.
        #expect(ScriptMarkdown.plainText(blocks) == """
        The eclipse begins.
        And it keeps going.
        Then something unrelated.
        """)
        // A label with no matching range is simply not used.
        #expect(ScriptMarkdown.plainText(blocks, spanLabels: ["other1": "pp. 1–2"])
                == ScriptMarkdown.plainText(blocks))
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

        var loaded = try ProjectStore.create(at: url, name: "Test", series: "Berserk")
        #expect(FileManager.default.fileExists(atPath: ProjectStore.capturesFolder(of: url).path))
        #expect(loaded.manifest.name == "Test")
        #expect(loaded.manifest.series == "Berserk")
        #expect(loaded.manifest.version == ProjectManifest.currentVersion)

        let item = ItemRef(itemID: "Berserk v01.cbz|42", filename: "Berserk v01.cbz", fileSize: 42,
                           series: "Berserk", volume: 1, title: "Vol. 1")
        let cite = Citation(itemID: item.itemID, pageIndex: 116, pageNumbers: [117], panel: 3,
                            polygon: [PagePoint(x: 0.1, y: 0.2), PagePoint(x: 0.5, y: 0.2), PagePoint(x: 0.3, y: 0.6)],
                            captureFile: "Berserk v01 p117 panel3.png", text: "Berserk, Vol. 1, p. 117, panel 3")
        loaded.manifest.register(item)
        loaded.manifest.register(item)   // citing the same volume again adds nothing
        loaded.manifest.citations = [cite]
        loaded.script = "Here [\(cite.text)](panels://cite/\(cite.id))."
        try ProjectStore.save(loaded, to: url)

        let back = try ProjectStore.load(url)
        #expect(back.manifest.items == [item])
        #expect(back.manifest.citations.count == 1)
        #expect(back.manifest.citations[0].id == cite.id)
        #expect(back.manifest.citations[0].itemID == item.itemID)
        #expect(back.manifest.citations[0].polygon == cite.polygon)
        #expect(back.script == loaded.script)
        #expect(back.manifest.citation(id: cite.id)?.panel == 3)
        #expect(back.manifest.item(id: item.itemID)?.volume == 1)
    }

    @Test("A version-3 project opens and comes forward, keeping everything it had")
    func upgradesFromVersion3() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.panelsproject", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Written by hand exactly as version 3 wrote it — no "spans" key at
        // all. A round-trip of the current type could never catch this: the
        // synthesized decoder throws keyNotFound rather than defaulting.
        let v3 = """
        {
          "citations" : [
            {
              "captureFile" : "Dragon Ball + Super ch028 p14 panel5.png",
              "date" : "2026-09-16T08:37:40Z",
              "id" : "enzyk7",
              "itemID" : "Chapter 028.cbr|15030490",
              "pageIndex" : 13,
              "pageNumbers" : [ 14 ],
              "panel" : 5,
              "region" : { "height" : 0.18, "width" : 0.88, "x" : 0.05, "y" : 0.4 },
              "text" : "Dragon Ball + Super, Ch. 28, p. 14, panel 5"
            }
          ],
          "items" : [
            {
              "chapter" : 28,
              "fileSize" : 15030490,
              "filename" : "Chapter 028.cbr",
              "itemID" : "Chapter 028.cbr|15030490",
              "series" : "Dragon Ball + Super",
              "title" : "Ch. 28"
            }
          ],
          "name" : "turtle school",
          "series" : "Dragon Ball + Super",
          "version" : 3
        }
        """
        try Data(v3.utf8).write(to: ProjectStore.manifestURL(of: url))

        let manifest = try ProjectStore.loadManifest(url)
        #expect(manifest.version == ProjectManifest.currentVersion)
        #expect(manifest.name == "turtle school")
        #expect(manifest.series == "Dragon Ball + Super")
        #expect(manifest.citations.count == 1)
        #expect(manifest.citations[0].id == "enzyk7")
        #expect(manifest.citations[0].panel == 5)
        #expect(manifest.citations[0].region == PageRect(x: 0.05, y: 0.4, width: 0.88, height: 0.18))
        #expect(manifest.items.map(\.itemID) == ["Chapter 028.cbr|15030490"])
        // It simply has no ranges yet.
        #expect(manifest.spans.isEmpty)
    }

    @Test("Page ranges round-trip, and replace rather than pile up")
    func spansRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Spans.panelsproject", isDirectory: true)
        var loaded = try ProjectStore.create(at: url, name: "Spans", series: "Berserk")

        let span = PageSpan(id: "k7m2pq", itemID: "b.cbz|5", firstPageIndex: 11,
                            pageNumbers: [12, 17], text: "Berserk, Vol. 1, pp. 12–17",
                            date: Date(timeIntervalSince1970: 0))
        loaded.manifest.store(span)
        #expect(loaded.manifest.spans.count == 1)
        // Stretching the range keeps one record, not two.
        var stretched = span
        stretched.pageNumbers = [12, 20]
        loaded.manifest.store(stretched)
        #expect(loaded.manifest.spans.count == 1)
        #expect(loaded.manifest.spans[0].lastPage == 20)
        loaded.script = "<span:k7m2pq> The eclipse begins."
        try ProjectStore.save(loaded, to: url)

        let back = try ProjectStore.load(url)
        #expect(back.manifest.spans == [stretched])
        #expect(back.manifest.span(id: "k7m2pq")?.firstPage == 12)
        #expect(back.manifest.span(id: "nope12") == nil)
        #expect(ScriptMarkdown.spanIDs(in: back.script) == ["k7m2pq"])
    }

    @Test("A project from the earlier format is refused, not half-read")
    func refusesOldFormat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.panelsproject", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let legacy = """
        {"version":1,"name":"Old","comics":[{"id":"abc123","title":"Berserk v01","path":"/x/b.cbz","filename":"b.cbz","fileSize":5}],"citations":[],"positions":{}}
        """
        try Data(legacy.utf8).write(to: ProjectStore.manifestURL(of: url))

        #expect(throws: ProjectError.unsupportedVersion(1)) { try ProjectStore.load(url) }
        #expect(throws: ProjectError.unsupportedVersion(1)) { try ProjectStore.loadManifest(url) }
        #expect(ProjectError.unsupportedVersion(1).errorDescription?.contains("earlier version") == true)
    }

    @Test("Listing a folder finds its projects and nothing else")
    func listing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try ProjectStore.create(at: root.appendingPathComponent("A.panelsproject"), name: "A", series: "S")
        _ = try ProjectStore.create(at: root.appendingPathComponent("B.panelsproject"), name: "B", series: "S")
        // Things that look like projects but aren't.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty.panelsproject"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.panelsproject"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let found = Set(ProjectStore.list(in: root).map(\.lastPathComponent))
        #expect(found == ["A.panelsproject", "B.panelsproject"])
        #expect(ProjectStore.list(in: root.appendingPathComponent("missing")).isEmpty)
        #expect(try ProjectStore.loadManifest(root.appendingPathComponent("A.panelsproject")).name == "A")
    }

    @Test("New projects get names that aren't taken, and folder-safe ones")
    func uniqueNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-names-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = ProjectStore.uniqueURL(named: "Eclipse", in: root)
        #expect(first.lastPathComponent == "Eclipse.panelsproject")
        _ = try ProjectStore.create(at: first, name: "Eclipse", series: "Berserk")
        #expect(ProjectStore.uniqueURL(named: "Eclipse", in: root).lastPathComponent == "Eclipse 2.panelsproject")
        #expect(ProjectStore.uniqueURL(named: "Ch: 1/2", in: root).lastPathComponent == "Ch 12.panelsproject")
        #expect(ProjectStore.uniqueURL(named: "   ", in: root).lastPathComponent == "Untitled.panelsproject")
    }

    @Test("Citation geometry is written with named keys, so anything can read it")
    func geometryWireFormat() throws {
        // The exact JSON is the contract with whatever reads a project next —
        // a Windows build, a script, a browser. Apple used to write these as
        // bare positional arrays ([[x,y],[w,h]]), which said nothing about
        // which number was which. Assert the literal text, not a round-trip.
        let cite = Citation(id: "abc123", itemID: "b.cbz|5", pageIndex: 0, pageNumbers: [1],
                            polygon: [PagePoint(x: 0.25, y: 0.5)],
                            region: PageRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                            text: "t", date: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(cite), as: UTF8.self)

        #expect(json.contains(#""polygon":[{"x":0.25,"y":0.5}]"#))
        #expect(json.contains(#""region":{"height":0.4,"width":0.3,"x":0.1,"y":0.2}"#))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Citation.self, from: Data(json.utf8)) == cite)
    }

    @Test("A rectangle knows its edges and the box around a drawn shape")
    func geometryHelpers() {
        // Halves and quarters throughout, so these compare exactly as binary
        // floating point and the test isn't about arithmetic precision.
        let rect = PageRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        #expect(rect.minX == 0.25 && rect.maxX == 0.75)
        #expect(rect.minY == 0.5 && rect.maxY == 0.75)
        #expect(rect.midX == 0.5 && rect.midY == 0.625)
        #expect(rect.corners == [PagePoint(x: 0.25, y: 0.5), PagePoint(x: 0.75, y: 0.5),
                                 PagePoint(x: 0.75, y: 0.75), PagePoint(x: 0.25, y: 0.75)])
        #expect(rect.contains(PagePoint(x: 0.5, y: 0.625)))
        #expect(!rect.contains(PagePoint(x: 0.875, y: 0.625)))
        #expect(PageRect.zero.isEmpty)

        let shape = [PagePoint(x: 0.5, y: 0.25), PagePoint(x: 0.25, y: 0.75), PagePoint(x: 0.75, y: 0.5)]
        #expect(PageRect(bounding: shape) == PageRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(PageRect(bounding: []) == nil)
    }

    @Test("Names are safe on Windows too, since these folders get shared")
    func portableNames() {
        // Reserved since MS-DOS; Windows refuses them whatever follows.
        #expect(PortableName.sanitised("CON") == "CON_")
        #expect(PortableName.sanitised("aux") == "aux_")
        #expect(PortableName.sanitised("COM4") == "COM4_")
        #expect(PortableName.sanitised("LPT9") == "LPT9_")
        // Reserved-ness is decided before the first dot.
        #expect(PortableName.sanitised("NUL.png") == "NUL.png_")
        // ...but a longer name that merely starts with one is fine.
        #expect(PortableName.sanitised("Conan the Barbarian") == "Conan the Barbarian")
        #expect(PortableName.sanitised("Berserk v01 p117 page") == "Berserk v01 p117 page")

        // Windows silently drops trailing dots and spaces, merging two names
        // into one file.
        #expect(PortableName.sanitised("Chapter 1. ") == "Chapter 1")
        // Characters no filesystem takes, and the control characters.
        #expect(PortableName.sanitised("What: Is/This?") == "What- Is-This-")
        #expect(PortableName.sanitised("a\u{0007}b") == "a-b")
        #expect(PortableName.sanitised("Ch: 1/2", replacingIllegalWith: "") == "Ch 12")
        // Nothing left to work with.
        #expect(PortableName.sanitised("   ") == "Untitled")
        #expect(PortableName.sanitised("///", replacingIllegalWith: "", fallback: "Capture") == "Capture")
    }

    @Test("Long labels are split, so the pages never get truncated away")
    func referenceLabels() {
        var manifest = ProjectManifest(name: "T", series: "Dragon Ball + Super")
        manifest.register(ItemRef(itemID: "ch28|1", filename: "Chapter 028.cbr", fileSize: 1,
                                  series: "Dragon Ball + Super", chapter: 28, title: "Ch. 28 · Training Begins!!"))
        manifest.register(ItemRef(itemID: "v01|1", filename: "Berserk v01.cbz", fileSize: 1,
                                  series: "Berserk", volume: 1, title: "Vol. 1"))

        let citation = Citation(itemID: "ch28|1", pageIndex: 13, pageNumbers: [14], panel: 5,
                                text: "Dragon Ball + Super, Ch. 28, p. 14, panel 5")
        let label = manifest.label(for: citation)
        #expect(label.pages == "p. 14, panel 5")
        #expect(label.item == "Ch. 28")
        #expect(label.series == "Dragon Ball + Super")
        // In the app the series is a given, so it comes off the front.
        #expect(label.short == "Ch. 28 · p. 14, panel 5")
        #expect(label.detail == "Ch. 28 · Dragon Ball + Super")
        // The whole thing survives for the clipboard and the export.
        #expect(label.full == citation.text)

        let span = PageSpan(itemID: "ch28|1", firstPageIndex: 11, pageNumbers: [12, 17],
                            text: "Dragon Ball + Super, Ch. 28, pp. 12–17")
        #expect(manifest.label(for: span).short == "Ch. 28 · pp. 12–17")

        // A volume reads as a volume.
        let volumeSpan = PageSpan(itemID: "v01|1", firstPageIndex: 0, pageNumbers: [3, 9], text: "x")
        #expect(manifest.label(for: volumeSpan).short == "Vol. 1 · pp. 3–9")

        // An item the project has never registered still shows its pages.
        let orphan = Citation(itemID: "gone|1", pageIndex: 0, pageNumbers: [1, 2], text: "Somewhere, pp. 1–2")
        #expect(manifest.label(for: orphan).item == nil)
        #expect(manifest.label(for: orphan).short == "pp. 1–2")

        // And a citation with no pages at all falls back to what it has.
        let empty = Citation(itemID: "gone|1", pageIndex: 0, pageNumbers: [], text: "Somewhere")
        #expect(manifest.label(for: empty).short == "Somewhere")
    }

    @Test("IDs are short, URL-safe and distinct")
    func ids() {
        let ids = (0..<200).map { _ in ProjectManifest.makeID() }
        #expect(ids.allSatisfy { $0.count == 6 && $0.allSatisfy { $0.isLetter || $0.isNumber } })
        #expect(Set(ids).count > 195)
    }
}
