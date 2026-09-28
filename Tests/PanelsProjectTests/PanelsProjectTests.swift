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

    @Test("Bold and italic round-trip through star runs, alone and together")
    func boldAndItalic() {
        let text = "*Hushed.* **He roars.** ***Both at once.*** Plain again."
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks == [.paragraph([
            .styledText(TextRun(text: "Hushed.", italic: true)),
            .text(" "),
            .styledText(TextRun(text: "He roars.", bold: true)),
            .text(" "),
            .styledText(TextRun(text: "Both at once.", bold: true, italic: true)),
            .text(" Plain again."),
        ])])
        #expect(ScriptMarkdown.serialize(blocks) == text)
    }

    @Test("A highlight and a text color nest inside emphasis, and round-trip")
    func highlightAndColor() {
        let text = "Plain **{hl:yellow}{fg:blue}both{/fg}{/hl}** and {hl:pink}just a highlight{/hl}."
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks == [.paragraph([
            .text("Plain "),
            .styledText(TextRun(text: "both", bold: true, highlight: .yellow, textColor: .blue)),
            .text(" and "),
            .styledText(TextRun(text: "just a highlight", highlight: .pink)),
            .text("."),
        ])])
        #expect(ScriptMarkdown.serialize(blocks) == text)
    }

    @Test("A literal asterisk in prose is escaped, not read as emphasis")
    func literalAsterisk() {
        let blocks: [ScriptBlock] = [.paragraph([.text("5 * 3 = 15, *not* italic on its own")])]
        let text = ScriptMarkdown.serialize(blocks)
        #expect(ScriptMarkdown.parse(text) == blocks)
    }

    @Test("A third heading level — Subheading — parses and round-trips")
    func subheading() {
        let text = "### A quieter beat"
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks == [.heading(level: 3, [.text("A quieter beat")])])
        #expect(ScriptMarkdown.serialize(blocks) == text)
        #expect(blocks[0].headingLevel == 3)
    }

    @Test("Alignment is its own marker, independent of the span marker, and round-trips")
    func alignment() {
        let text = """
        <align:center> Centered.
        <span:k7m2pq> <align:trailing> Right-aligned, and in a block of writing.
        Left is the default and is never written.
        """
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks == [
            .paragraph([.text("Centered.")], alignment: .center),
            .paragraph([.text("Right-aligned, and in a block of writing.")], span: "k7m2pq", alignment: .trailing),
            .paragraph([.text("Left is the default and is never written.")]),
        ])
        #expect(ScriptMarkdown.serialize(blocks) == text)
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

@Suite("Beats in a script")
struct ScriptBeatTests {
    @Test("A beat marker sits on its own line, independent of a span marker, and round-trips")
    func markers() {
        let text = "<span:aaa111> <beat:bbb222> Cold open begins here."
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks[0].spanID == "aaa111")
        #expect(blocks[0].beatID == "bbb222")
        #expect(blocks[0].inlines == [.text("Cold open begins here.")])
        #expect(ScriptMarkdown.serialize(blocks) == text)
    }

    @Test("A beat marker coexists with a span and an alignment marker, in order")
    func fullMarkerOrder() {
        let text = "<span:aaa111> <beat:bbb222> <align:center> Centered and both."
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks[0].spanID == "aaa111")
        #expect(blocks[0].beatID == "bbb222")
        #expect(blocks[0].alignment == .center)
        #expect(blocks[0].inlines == [.text("Centered and both.")])
        #expect(ScriptMarkdown.serialize(blocks) == text)
    }

    @Test("Prose that looks like a beat marker stays prose")
    func markerEscapes() {
        #expect(ScriptMarkdown.parse("<beat:abc123> hello")[0].beatID == "abc123")
        let typed: [ScriptBlock] = [.paragraph([.text("<beat:abc123> hello")])]
        let serialized = ScriptMarkdown.serialize(typed)
        #expect(serialized == "\\<beat:abc123> hello")
        #expect(ScriptMarkdown.parse(serialized) == typed)

        for line in ["<beat:abc123>hello", "<beat:abc123 hello", "<beat:> hello",
                     "<beat:has a space> hi", "<beet:abc123> hello", "<beat:abc123>"] {
            #expect(ScriptMarkdown.parse(line)[0].beatID == nil, "\(line) should be prose")
        }
    }

    @Test("Beats come back in the order they first appear, each once")
    func order() {
        let text = """
        <beat:aaa111> Cold open.
        No beat here.
        <beat:bbb222> Act one.
        <span:xxx999> <beat:aaa111> A duplicate marker, same id.
        """
        #expect(ScriptMarkdown.beatIDs(in: text) == ["aaa111", "bbb222"])
        #expect(ScriptMarkdown.beatIDs(in: "nothing here") == [])
    }
}

@Suite("Notes to the editor")
struct ScriptNoteTests {
    @Test("A note is a line of its own, and round-trips as a blockquote")
    func notes() {
        let text = """
        Goku's training begins in earnest.
        > Hold this panel a beat before the cut.
        The milk gag lands three times over.
        """
        let blocks = ScriptMarkdown.parse(text)
        #expect(blocks.map(\.isNote) == [false, true, false])
        #expect(blocks[1].inlines == [.text("Hold this panel a beat before the cut.")])
        #expect(ScriptMarkdown.serialize(blocks) == text)

        // Notes carry citations and page ranges like any other line.
        let rich = "<span:k7m2pq> > Maybe use [p. 14](panels://cite/abc123) instead."
        let parsed = ScriptMarkdown.parse(rich)
        #expect(parsed[0].isNote)
        #expect(parsed[0].spanID == "k7m2pq")
        #expect(ScriptMarkdown.citationIDs(in: rich) == ["abc123"])
        #expect(ScriptMarkdown.serialize(parsed) == rich)
    }

    @Test("Prose that begins like a note stays prose")
    func noteEscapes() {
        let typed: [ScriptBlock] = [.paragraph([.text("> not a note, just a chevron")])]
        let serialized = ScriptMarkdown.serialize(typed)
        #expect(serialized == "\\> not a note, just a chevron")
        #expect(ScriptMarkdown.parse(serialized) == typed)
        // A chevron with no space after it was never a note to begin with.
        #expect(ScriptMarkdown.parse(">nospace")[0].isNote == false)
    }

    @Test("A note is not narration, unless the paste asks for it")
    func notesInPlainText() {
        let blocks = ScriptMarkdown.parse("""
        <span:k7m2pq> Goku's training begins.
        <span:k7m2pq> > Hold this panel a beat.
        The milk gag lands three times over.
        """)
        // Left out, and the range's label moves up to the line that remains —
        // it must not be dropped along with the note.
        #expect(ScriptMarkdown.plainText(blocks, spanLabels: ["k7m2pq": "pp. 12–17"]) == """
        Goku's training begins. (pp. 12–17)
        The milk gag lands three times over.
        """)
        // Or brought along, marked, for a document the editor reads.
        #expect(ScriptMarkdown.plainText(blocks, spanLabels: ["k7m2pq": "pp. 12–17"], notes: .marked) == """
        Goku's training begins.
        [NOTE: Hold this panel a beat.] (pp. 12–17)
        The milk gag lands three times over.
        """)
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

    @Test("Beats round-trip, and replace rather than pile up")
    func beatsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Beats.panelsproject", isDirectory: true)
        var loaded = try ProjectStore.create(at: url, name: "Beats", series: "Berserk")

        let beat = Beat(id: "k7m2pq", title: "Cold Open", date: Date(timeIntervalSince1970: 0))
        loaded.manifest.store(beat)
        #expect(loaded.manifest.beats.count == 1)
        // Checking it off keeps one record, not two.
        var done = beat
        done.isDone = true
        loaded.manifest.store(done)
        #expect(loaded.manifest.beats.count == 1)
        #expect(loaded.manifest.beats[0].isDone)
        loaded.script = "<beat:k7m2pq> The eclipse begins."
        try ProjectStore.save(loaded, to: url)

        let back = try ProjectStore.load(url)
        #expect(back.manifest.beats == [done])
        #expect(back.manifest.beat(id: "k7m2pq")?.title == "Cold Open")
        #expect(back.manifest.beat(id: "nope12") == nil)
        #expect(ScriptMarkdown.beatIDs(in: back.script) == ["k7m2pq"])

        var manifest = back.manifest
        manifest.removeBeat(id: "k7m2pq")
        #expect(manifest.beats.isEmpty)
    }

    @Test("A beat's tags round-trip, in order, with their own color")
    func beatTagsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Tags.panelsproject", isDirectory: true)
        var loaded = try ProjectStore.create(at: url, name: "Tags", series: "Berserk")

        var beat = Beat(id: "k7m2pq", title: "Cold Open", date: Date(timeIntervalSince1970: 0))
        beat.tags = [
            Tag(id: "aaa111", text: "green screen", color: .green),
            Tag(id: "bbb222", text: "zoom", color: .blue),
        ]
        loaded.manifest.store(beat)
        loaded.script = "<beat:k7m2pq> The eclipse begins."
        try ProjectStore.save(loaded, to: url)

        let back = try ProjectStore.load(url)
        let restored = try #require(back.manifest.beat(id: "k7m2pq"))
        #expect(restored.tags.map(\.text) == ["green screen", "zoom"])
        #expect(restored.tags.map(\.color) == [.green, .blue])

        // Removing one, keeping the other.
        var updated = restored
        updated.tags.removeAll { $0.id == "aaa111" }
        loaded.manifest.store(updated)
        #expect(loaded.manifest.beat(id: "k7m2pq")?.tags.map(\.text) == ["zoom"])
    }

    @Test("A beat saved before tags existed loads with none, not a decode failure")
    func beatWithoutTagsKeyDecodes() throws {
        let json = """
        {
          "id" : "k7m2pq",
          "title" : "Cold Open",
          "isDone" : false,
          "date" : "2026-09-16T08:37:40Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let beat = try decoder.decode(Beat.self, from: Data(json.utf8))
        #expect(beat.title == "Cold Open")
        #expect(beat.tags.isEmpty)
        #expect(beat.color == nil)
    }

    @Test("A beat's own color round-trips, and defaults to none")
    func beatColorRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Color.panelsproject", isDirectory: true)
        var loaded = try ProjectStore.create(at: url, name: "Color", series: "Berserk")

        var beat = Beat(id: "k7m2pq", title: "Cold Open", date: Date(timeIntervalSince1970: 0))
        #expect(beat.color == nil)
        beat.color = .pink
        loaded.manifest.store(beat)
        loaded.script = "<beat:k7m2pq> The eclipse begins."
        try ProjectStore.save(loaded, to: url)

        let back = try ProjectStore.load(url)
        #expect(back.manifest.beat(id: "k7m2pq")?.color == .pink)

        // Setting it back to nil (the rail's "None" option) round-trips too.
        var reset = try #require(back.manifest.beat(id: "k7m2pq"))
        reset.color = nil
        loaded.manifest.store(reset)
        try ProjectStore.save(loaded, to: url)
        #expect(try ProjectStore.load(url).manifest.beat(id: "k7m2pq")?.color == nil)
    }

    @Test("A beat saved before a color existed loads with none, not a decode failure")
    func beatWithoutColorKeyDecodes() throws {
        let json = """
        {
          "id" : "k7m2pq",
          "title" : "Cold Open",
          "isDone" : false,
          "date" : "2026-09-16T08:37:40Z",
          "tags" : []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let beat = try decoder.decode(Beat.self, from: Data(json.utf8))
        #expect(beat.title == "Cold Open")
        #expect(beat.color == nil)
    }

    @Test("A version-4 project opens and comes forward, with no beats yet")
    func upgradesFromVersion4() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.panelsproject", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Written by hand exactly as version 4 wrote it — no "beats" key.
        let v4 = """
        {
          "citations" : [],
          "items" : [],
          "name" : "turtle school",
          "series" : "Dragon Ball + Super",
          "spans" : [],
          "version" : 4
        }
        """
        try Data(v4.utf8).write(to: ProjectStore.manifestURL(of: url))

        let manifest = try ProjectStore.loadManifest(url)
        #expect(manifest.version == ProjectManifest.currentVersion)
        #expect(manifest.name == "turtle school")
        #expect(manifest.beats.isEmpty)
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

@Suite("Linking writing to pages")
struct LinkingPagesTests {
    @Test("Pages read the way a writer types them")
    func parsePages() {
        #expect(PageSpan.parsePages("42") == 42...42)
        #expect(PageSpan.parsePages("42-45") == 42...45)
        #expect(PageSpan.parsePages("42–45") == 42...45)
        #expect(PageSpan.parsePages(" 42 — 45 ") == 42...45)
        #expect(PageSpan.parsePages("pp. 42–45") == 42...45)
        #expect(PageSpan.parsePages("p. 7") == 7...7)
        // Backwards is still a range, just put in order.
        #expect(PageSpan.parsePages("45-42") == 42...45)
        #expect(PageSpan.parsePages("0") == nil)
        #expect(PageSpan.parsePages("") == nil)
        #expect(PageSpan.parsePages("42-") == nil)
        #expect(PageSpan.parsePages("1-2-3") == nil)
        #expect(PageSpan.parsePages("forty") == nil)
    }

    @Test("Relinking the middle of a block leaves its ends in the old one")
    func relinkMiddle() {
        var blocks = ScriptMarkdown.parse("""
        <span:k7m2pq> The eclipse begins.
        <span:k7m2pq> Griffith makes his choice.
        <span:k7m2pq> The brand.
        """)
        blocks[1].spanID = "q3wz8n"
        let text = ScriptMarkdown.serialize(blocks)
        #expect(ScriptMarkdown.parse(text).map(\.spanID) == ["k7m2pq", "q3wz8n", "k7m2pq"])
        #expect(ScriptMarkdown.spanIDs(in: text) == ["k7m2pq", "q3wz8n"])
    }
}

@Suite("Fountain-lite")
struct FountainLiteTests {
    /// A video-essay script the way a writer would draft it: acts as
    /// sections, a synopsis under each, a Fountain note and a Markdown note,
    /// shouted lettering quoted in capitals, and panel citations throughout.
    static let sample = """
    # Act One: The Brand
    = Guts before the Eclipse — why the brand matters.
    <span:k7m2pq> The first time we see the brand, it's already bleeding [p. 12](panels://cite/c1abcd).
    [[Hold on this panel for two beats]]
    He screams: I WON'T DIE HERE.
    ## The Eclipse
    = Griffith's choice, told through three panels.
    > Zoom in slowly.
    It happens across a single spread [pp. 40–41](panels://cite/c2efgh), and then [again](panels://cite/c1abcd).
    ===
    INT. TAVERN - NIGHT
    """

    @Test("A sample VO script parses into sections, synopses, notes and narration")
    func parsesSample() {
        let blocks = ScriptMarkdown.parse(Self.sample)
        #expect(blocks.map(\.kind) == [
            .heading(level: 1), .synopsis, .paragraph, .note, .paragraph,
            .heading(level: 2), .synopsis, .note, .paragraph, .paragraph, .paragraph,
        ])
        #expect(blocks[1].plainText == "Guts before the Eclipse — why the brand matters.")
        // The Fountain note is the same note the script already had.
        #expect(blocks[3] == .note([.text("Hold on this panel for two beats")]))
        // Screenplay grammar stays narration: capitals, a page break, a scene heading.
        #expect(blocks[4].plainText == "He screams: I WON'T DIE HERE.")
        #expect(blocks[9].plainText == "===")
        #expect(blocks[10].plainText == "INT. TAVERN - NIGHT")
        // The span marker still belongs to its line.
        #expect(blocks[2].spanID == "k7m2pq")
    }

    @Test("Citations survive: every cite parses, in order, and points at the same id")
    func preservesCites() {
        let blocks = ScriptMarkdown.parse(Self.sample)
        #expect(ScriptMarkdown.citationIDs(in: Self.sample) == ["c1abcd", "c2efgh"])
        #expect(blocks[2].inlines.contains(.citation(id: "c1abcd", text: "p. 12")))
        let reparsed = ScriptMarkdown.parse(ScriptMarkdown.serialize(blocks))
        #expect(ScriptMarkdown.citationIDs(in: ScriptMarkdown.serialize(reparsed)) == ["c1abcd", "c2efgh"])
        // The shot list's sentence around a shot still reads, chips removed.
        #expect(ScriptMarkdown.context(of: "c2efgh", in: Self.sample) == "It happens across a single spread , and then .")
    }

    @Test("script.md round-trips: the app's own form exactly, and a [[note]] without losing a word")
    func roundTrips() {
        let blocks = ScriptMarkdown.parse(Self.sample)
        let saved = ScriptMarkdown.serialize(blocks)
        // The one rewrite: a [[note]] line is saved as the script's `> ` note.
        #expect(saved == Self.sample.replacingOccurrences(of: "[[Hold on this panel for two beats]]",
                                                          with: "> Hold on this panel for two beats"))
        // From then on it's stable, byte for byte.
        #expect(ScriptMarkdown.serialize(ScriptMarkdown.parse(saved)) == saved)
        #expect(ScriptMarkdown.parse(saved) == blocks)
    }

    @Test("Prose that begins like a synopsis stays prose")
    func escapesEquals() {
        let blocks: [ScriptBlock] = [.paragraph([.text("= is how Fountain marks a synopsis")]), .paragraph([.text("=5")])]
        let text = ScriptMarkdown.serialize(blocks)
        #expect(text == "\\= is how Fountain marks a synopsis\n\\=5")
        #expect(ScriptMarkdown.parse(text) == blocks)
    }

    @Test("Synopsis forms: with or without the space, never a page break or a lone =")
    func synopsisForms() {
        #expect(ScriptMarkdown.parse("=Tight") == [.synopsis([.text("Tight")])])
        #expect(ScriptMarkdown.parse("= Spaced") == [.synopsis([.text("Spaced")])])
        #expect(ScriptMarkdown.parse("==").first?.kind == .paragraph)
        #expect(ScriptMarkdown.parse("=").first?.kind == .paragraph)
        // Only a line that's entirely a note is one.
        #expect(ScriptMarkdown.parse("Say it [[softly]] here").first?.kind == .paragraph)
        #expect(ScriptMarkdown.parse("[[a]] and [[b]]").first?.kind == .paragraph)
    }

    @Test("A synopsis is never read aloud, whatever happens to the notes")
    func plainTextLeavesOutSynopses() {
        let blocks = ScriptMarkdown.parse("# Act\n= What it's about\nNarration.\n> Aside")
        #expect(ScriptMarkdown.plainText(blocks) == "Act\nNarration.")
        #expect(ScriptMarkdown.plainText(blocks, notes: .marked) == "Act\nNarration.\n[NOTE: Aside]")
    }

    @Test("The outline: one section per heading, with its synopsis and the shots in it")
    func outline() {
        let sections = ScriptMarkdown.outline(in: Self.sample)
        #expect(sections.map(\.title) == ["Act One: The Brand", "The Eclipse"])
        #expect(sections.map(\.level) == [1, 2])
        #expect(sections.map(\.synopsis) == ["Guts before the Eclipse — why the brand matters.",
                                             "Griffith's choice, told through three panels."])
        #expect(sections.map(\.citationIDs) == [["c1abcd"], ["c2efgh", "c1abcd"]])
        // Shots before any heading get an untitled section of their own.
        let opening = ScriptMarkdown.outline(in: "Cold open [p. 1](panels://cite/c0zzzz).\n# Act One")
        #expect(opening.map(\.title) == [nil, "Act One"])
        #expect(opening.first?.citationIDs == ["c0zzzz"])
    }

    @Test("Plain text pasted in keeps every character, and gains structure only from structural lines")
    func fromPlainText() {
        let text = "# Act One\n= The setup\n[[check this]]\n> and this\nFive * three [is] {not} markup.\n\nINT. HOUSE"
        #expect(FountainLite.hasStructure(text))
        #expect(!FountainLite.hasStructure("Just words.\nMore words."))
        let blocks = FountainLite.blocks(fromPlainText: text)
        #expect(blocks == [
            .heading(level: 1, [.text("Act One")]), .synopsis([.text("The setup")]),
            .note([.text("check this")]), .note([.text("and this")]),
            .paragraph([.text("Five * three [is] {not} markup.")]), .paragraph([]),
            .paragraph([.text("INT. HOUSE")]),
        ])
        // And it saves as the same words, escaped where Markdown needs it.
        #expect(ScriptMarkdown.parse(ScriptMarkdown.serialize(blocks)) == blocks)
    }
}
