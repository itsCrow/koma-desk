import Testing
import Foundation
@testable import ComicLibrary

@Suite("Scanning folders into series")
struct LibraryScannerTests {
    /// A collection the way one actually looks on disk: a series folder of
    /// volumes, a series folder of arcs of chapters, a volume lying loose,
    /// and the junk that comes with them.
    static func makeCollection() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KomaDeskTests-collection-\(UUID().uuidString)", isDirectory: true)
        let files: [(String, Int)] = [
            ("Berserk (Digital) (danke-Empire)/Berserk v10 (2005) (Digital).cbz", 300),
            ("Berserk (Digital) (danke-Empire)/Berserk v01 (2003) (Digital).cbz", 100),
            ("Berserk (Digital) (danke-Empire)/Berserk v02 (2003) (Digital).cbz", 200),
            ("Dragon Ball + Super [Complete Manga]/02 Turtle School Training Arc/Chapter 025 - A Rival Appears!.cbr", 25),
            ("Dragon Ball + Super [Complete Manga]/02 Turtle School Training Arc/Chapter 024 - Training Fee.cbr", 24),
            ("Dragon Ball + Super [Complete Manga]/02 Turtle School Training Arc/Chapter 024 - Training Fee.cbr.jpg", 9),
            ("Dragon Ball + Super [Complete Manga]/02 Turtle School Training Arc/Chapter 024 - Training Fee.cbr.json", 9),
            ("Dragon Ball + Super [Complete Manga]/04 Red Ribbon Army Arc/Chapter 069 - Bulma And Goku.cbr", 69),
            ("One Piece Vol. 3.cbz", 33),
            ("notes.txt", 1),
        ]
        for (path, size) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: size).write(to: url)
        }
        return root
    }

    @Test("Series come from what files say they are, not how deep they sit")
    func series() throws {
        let root = try Self.makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryScanner.scan(roots: [root])
        #expect(library.map(\.name) == ["Berserk", "Dragon Ball + Super", "One Piece"])

        let berserk = library[0]
        #expect(berserk.items.map(\.volume) == [1, 2, 10])
        #expect(berserk.items.allSatisfy { $0.arc == nil })          // its own folder is not an arc
        #expect(berserk.summary == "3 volumes")
        #expect(berserk.items[0].label == "Vol. 1")

        let dragonBall = library[1]
        #expect(dragonBall.items.map(\.chapter) == [24, 25, 69])
        #expect(dragonBall.arcs.map(\.name) == ["02 Turtle School Training Arc", "04 Red Ribbon Army Arc"])
        #expect(dragonBall.arcs[0].items.count == 2)
        #expect(dragonBall.items[0].title == "Training Fee")
        #expect(dragonBall.items[0].displayName == "Ch. 24 · Training Fee")
        #expect(dragonBall.summary == "2 arcs · 3 chapters")

        let onePiece = library[2]
        #expect(onePiece.items.count == 1)
        #expect(onePiece.items[0].volume == 3)
        #expect(onePiece.items[0].arc == nil)
    }

    @Test("A single file as a root is one item, and the same file twice is one item")
    func singleFileRoot() throws {
        let root = try Self.makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("One Piece Vol. 3.cbz")

        let alone = LibraryScanner.scan(roots: [file])
        #expect(alone.map(\.name) == ["One Piece"])
        #expect(alone[0].items[0].arc == nil)

        let both = LibraryScanner.scan(roots: [root, file])
        #expect(both.first { $0.name == "One Piece" }?.items.count == 1)
    }

    @Test("Item ids survive a move; the index round-trips")
    func identityAndIndex() throws {
        let root = try Self.makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let series = LibraryScanner.scan(roots: [root])
        let item = series[0].items[0]
        #expect(item.id == "Berserk v01 (2003) (Digital).cbz|100")

        var index = LibraryIndex(roots: [root], series: series)
        index.positions[item.id] = 12
        index.lastRead["Berserk"] = item.id
        let folder = root.appendingPathComponent("support")
        try LibraryStore.save(index, to: folder)
        let back = LibraryStore.load(from: folder)
        #expect(back == index)
        #expect(back.item(id: item.id)?.volume == 1)
        #expect(back.series(containing: item)?.name == "Berserk")
        #expect(LibraryStore.load(from: root.appendingPathComponent("nowhere")) == LibraryIndex())
    }

    @Test("Arcs keep their folder order even though chapter numbers restart in each")
    func arcsFollowFolderOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KomaDeskTests-arcs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func make(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: 8).write(to: url)
        }

        // The real shape of the Dragon Ball collection: numbered arc folders,
        // and chapter numbering that starts over inside each one. Sorting by
        // chapter number across the series would interleave them.
        try make("Dragon Ball + Super/01 Dragon Balls Quest Arc/Chapter 001 - Bloomers and Son Goku.cbr")
        try make("Dragon Ball + Super/01 Dragon Balls Quest Arc/Chapter 019 - The Dragon Finally Appears.cbr")
        try make("Dragon Ball + Super/02 Turtle School Training Arc/Chapter 024 - Kame Sen'nin's Training Fee.cbr")
        try make("Dragon Ball + Super/14 Battle of Gods Arc/Chapter 000 - Yo Son Goku and Friends Return.cbr")
        try make("Dragon Ball + Super/16 Future Trunks Arc/Chapter 014 - SOS from the Future.cbr")
        try make("Dragon Ball + Super/16 Future Trunks Arc/Chapter 019 - Another Zamas.cbr")

        let series = try #require(LibraryScanner.scan(roots: [root]).first)

        // Every arc is contiguous and in folder order, so the contents list
        // shows each arc once rather than over and over.
        #expect(series.arcs.map(\.name) == ["01 Dragon Balls Quest Arc",
                                            "02 Turtle School Training Arc",
                                            "14 Battle of Gods Arc",
                                            "16 Future Trunks Arc"])
        // Within an arc, chapters still run by number.
        #expect(series.arcs[0].items.map(\.chapter) == [1, 19])
        #expect(series.arcs[3].items.map(\.chapter) == [14, 19])
        // Arc 14's Chapter 000 does not jump to the front of the series.
        #expect(series.items.first?.chapter == 1)
        #expect(series.items.map(\.chapter) == [1, 19, 24, 0, 14, 19])
    }
}

@Suite("Remote sources: identity, and reading old libraries")
struct RemoteSourceTests {
    @Test("A library.json saved before remote sources existed still opens")
    func decodesPreRemoteSourceFormat() throws {
        // The exact shape LibraryIndex/LibraryItem wrote before `source` on
        // an item and `remoteSeries`/`remoteSources` on the index existed —
        // no such keys at all, not merely null ones.
        let json = """
        {
          "version": 1,
          "roots": [],
          "series": [
            {
              "name": "Berserk",
              "items": [
                {
                  "id": "Berserk v01 (2003) (Digital).cbz|100",
                  "url": "file:///Users/reader/Comics/Berserk%20v01%20(2003)%20(Digital).cbz",
                  "series": "Berserk",
                  "volume": 1,
                  "title": "Berserk v01 (2003) (Digital)",
                  "fileSize": 100
                }
              ]
            }
          ],
          "positions": {"Berserk v01 (2003) (Digital).cbz|100": 12},
          "lastRead": {"Berserk": "Berserk v01 (2003) (Digital).cbz|100"},
          "recentSeries": ["Berserk"],
          "covers": {}
        }
        """
        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(json.utf8))
        #expect(index.remoteSeries.isEmpty)
        #expect(index.remoteSources.isEmpty)
        let item = try #require(index.series.first?.items.first)
        #expect(item.source == .local)
        #expect(item.volume == 1)
        #expect(item.chapter == nil)
        #expect(item.arc == nil)
        #expect(item.fileSize == 100)
        #expect(index.positions[item.id] == 12)
    }

    @Test("A remote item's id depends only on where it comes from")
    func remoteItemIdentity() {
        let manifest = URL(string: "https://example.com/manifest.json")!
        let a = LibraryItem(remote: .manifest(manifestURL: manifest, chapterKey: "5"), series: "S",
                             volume: nil, chapter: 5, title: "", arc: nil, displayURL: manifest)
        let b = LibraryItem(remote: .manifest(manifestURL: manifest, chapterKey: "5"), series: "S",
                             volume: nil, chapter: 5, title: "", arc: nil, displayURL: manifest)
        #expect(a.id == b.id)

        let differentChapter = LibraryItem(remote: .manifest(manifestURL: manifest, chapterKey: "6"), series: "S",
                                            volume: nil, chapter: 6, title: "", arc: nil, displayURL: manifest)
        #expect(a.id != differentChapter.id)

        let chapterURL = URL(string: "https://example.com/chapters/1")!
        let site = LibraryItem(remote: .site(site: "weebcentral", chapterURL: chapterURL), series: "S",
                                volume: nil, chapter: 1, title: "", arc: nil, displayURL: chapterURL)
        #expect(site.id != a.id)
    }

    @Test("remoteSeries survives a rescan overwriting series")
    func remoteSeriesSurvivesRescan() {
        let manifest = URL(string: "https://example.com/manifest.json")!
        let remoteItem = LibraryItem(remote: .manifest(manifestURL: manifest, chapterKey: "1"), series: "Remote Manga",
                                      volume: nil, chapter: 1, title: "Ch. 1", arc: nil, displayURL: manifest)
        var index = LibraryIndex(series: [Series(name: "Local", items: [])],
                                  remoteSeries: [Series(name: "Remote Manga", items: [remoteItem])])

        // What Library.rescan() does: replace `series` wholesale from a
        // fresh directory scan. `remoteSeries` is a separate array, and a
        // scan never touches it.
        index.series = [Series(name: "Local Updated", items: [])]

        #expect(index.allSeries.map(\.name) == ["Local Updated", "Remote Manga"])
        #expect(index.series(named: "Remote Manga")?.items.first?.id == remoteItem.id)
        #expect(index.item(id: remoteItem.id) == remoteItem)
    }

    @Test("Another series' counterpart: by chapter, preferring the same volume or arc, else by volume")
    func matchingItem() {
        func item(_ series: String, volume: Int? = nil, chapter: Int? = nil, arc: String? = nil) -> LibraryItem {
            let name = "\(series) \(volume.map { "v\($0)" } ?? "") \(chapter.map { "c\($0)" } ?? "") \(arc ?? "")"
            return LibraryItem(url: URL(fileURLWithPath: "/tmp/\(name).cbz"), series: series,
                               volume: volume, chapter: chapter, title: name, arc: arc, fileSize: 1)
        }
        let colored = Series(name: "One Piece (Colored)", items: [
            item("One Piece (Colored)", volume: 2),
            item("One Piece (Colored)", volume: 5, chapter: 43),
            item("One Piece (Colored)", chapter: 3, arc: "Second"),
        ])
        let plain = Series(name: "One Piece", items: [
            item("One Piece", volume: 1),
            item("One Piece", volume: 2),
            item("One Piece", volume: 4, chapter: 43),
            item("One Piece", volume: 5, chapter: 43),
            item("One Piece", chapter: 3, arc: "First"),
            item("One Piece", chapter: 3, arc: "Second"),
        ])

        #expect(plain.matchingItem(for: colored.items[0])?.id == plain.items[1].id)
        #expect(plain.matchingItem(for: colored.items[1])?.id == plain.items[3].id)
        #expect(plain.matchingItem(for: colored.items[2])?.id == plain.items[5].id)
        #expect(plain.matchingItem(for: item("X", chapter: 999)) == nil)
        #expect(plain.matchingItem(for: item("X", volume: 9)) == nil)
        #expect(plain.matchingItem(for: item("X")) == nil)
    }
}
