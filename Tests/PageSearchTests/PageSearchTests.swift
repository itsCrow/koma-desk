import Testing
import Foundation
import KomaFormat
@testable import PageSearch
import ComicArchive

private func line(_ text: String, y: CGFloat = 0.5) -> TextLine {
    TextLine(text: text, box: PageRect(x: 0.1, y: y, width: 0.3, height: 0.05))
}

private func index(_ pages: [[String]?]) -> PageTextIndex {
    var result = PageTextIndex(pageCount: pages.count)
    for (i, texts) in pages.enumerated() {
        result.pages[i] = texts.map { PageText(lines: $0.map { line($0) }) }
    }
    return result
}

@Suite("Searching page text")
struct SearchTests {
    @Test("Finds a word regardless of case, anywhere in a line")
    func caseInsensitive() {
        let hits = search("guts", in: index([["GUTS!"], ["...Guts?"], ["Nothing here"]]))
        #expect(hits.map(\.page) == [0, 1])
    }

    @Test("Accents don't matter either way")
    func diacritics() {
        #expect(search("cafe", in: index([["CAFÉ AU LAIT"]])).count == 1)
        #expect(search("café", in: index([["CAFE AU LAIT"]])).count == 1)
    }

    @Test("Several hits on one page, in line order, one per line")
    func multipleOnPage() {
        let hits = search("sword", in: index([["MY SWORD!", "no", "THE SWORD... a sword"]]))
        #expect(hits.map(\.line.text) == ["MY SWORD!", "THE SWORD... a sword"])
    }

    @Test("Hits come back in page order and skip unread pages")
    func pageOrder() {
        let hits = search("x", in: index([["x"], nil, ["x"], ["y"], ["X"]]))
        #expect(hits.map(\.page) == [0, 2, 4])
    }

    @Test("An empty or blank query matches nothing")
    func emptyQuery() {
        #expect(search("", in: index([["anything"]])).isEmpty)
        #expect(search("   ", in: index([["anything"]])).isEmpty)
    }
}

@Suite("Index bookkeeping")
struct IndexTests {
    @Test("Knows what's left to read")
    func progress() {
        var idx = PageTextIndex(pageCount: 3)
        #expect(idx.indexedPages == 0 && !idx.isComplete && idx.unreadPages == [0, 1, 2])
        idx.pages[1] = PageText(lines: [])
        #expect(idx.indexedPages == 1 && idx.unreadPages == [0, 2])
        idx.pages[0] = PageText(lines: []); idx.pages[2] = PageText(lines: [])
        #expect(idx.isComplete)
    }

    @Test("Round-trips through the store, and rejects a stale page count")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KomaDeskTests-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TextIndexStore(directory: dir)

        var idx = PageTextIndex(pageCount: 2)
        idx.pages[0] = PageText(lines: [line("HELLO", y: 0.25)])
        try store.save(idx, identity: "abc")

        #expect(store.load(identity: "abc", pageCount: 2) == idx)
        #expect(store.load(identity: "abc", pageCount: 3) == nil)
        #expect(store.load(identity: "missing", pageCount: 2) == nil)
    }
}

@Suite("Recognising real pages", .serialized)
struct RecogniserTests {
    @Test("Reads lettering off a real comic when PANELS_TEST_CBR is set, and reports the speed")
    func realPages() throws {
        guard let path = ProcessInfo.processInfo.environment["PANELS_TEST_CBR"] else {
            withKnownIssue("Set PANELS_TEST_CBR to a comic to exercise OCR.") { Issue.record("skipped") }
            return
        }
        let comic = try ComicArchive.open(URL(fileURLWithPath: path))
        let sample = Array(comic.pages.prefix(12))
        let start = Date()
        var lines = 0
        for page in sample {
            let text = try PageTextRecognizer.recognise(page)
            lines += text.lines.count
        }
        let perPage = Date().timeIntervalSince(start) / Double(sample.count)
        print(String(format: "OCR: %.2f s/page over %d pages, %d lines read", perPage, sample.count, lines))
        print("Sample lines:", sample.prefix(4).compactMap { try? PageTextRecognizer.recognise($0).lines.prefix(3).map(\.text) })
        #expect(lines > 0)
    }
}
