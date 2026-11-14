import Testing
import Foundation
@testable import RemoteComicSource

/// Serves fixed bytes per URL, and never touches the network.
struct FakeFetcher: PageFetching {
    var responses: [URL: Data]
    var failing: Set<URL> = []

    func fetchData(_ url: URL) async throws -> Data {
        if failing.contains(url) { throw RemoteSourceError.http(status: 404, url: url.absoluteString) }
        guard let data = responses[url] else { throw RemoteSourceError.http(status: 404, url: url.absoluteString) }
        return data
    }
}

/// Every suite here swaps out `RemoteComicSource.fetcher` — a single shared,
/// mutable static — so any two of them running concurrently race on it (one
/// test's fixture silently serves another's request, or a fixture-backed
/// test hits the real network mid-run). `.serialized` on a parent suite
/// cascades to every nested suite, which is the only thing that actually
/// rules that out; putting it on each suite individually does not, since
/// unrelated suites still run in parallel with each other by default.
@Suite("RemoteComicSource (serialized — shares a mutable test fetcher)", .serialized)
struct RemoteComicSourceFetcherTests {}

extension RemoteComicSourceFetcherTests {

@Suite("Reading a comic from a JSON manifest")
struct ManifestSourceTests {
    let manifestURL = URL(string: "https://example.com/manifest.json")!
    let page1 = URL(string: "https://example.com/ch1/001.jpg")!
    let page2 = URL(string: "https://example.com/ch1/002.jpg")!

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsRemoteTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RemoteComicSource.cacheRootOverride = root
    }

    func manifestJSON() -> Data {
        let json = """
        {
          "formatVersion": 1,
          "title": "Example Manga",
          "chapters": [
            { "id": "1", "number": 1, "title": "The Beginning",
              "pages": ["\(page1.absoluteString)", "\(page2.absoluteString)"] },
            { "number": 2, "pages": ["\(page1.absoluteString)"] }
          ]
        }
        """
        return Data(json.utf8)
    }

    @Test("A manifest's chapters resolve with their numbers, titles and keys")
    func resolvesSeries() async throws {
        RemoteComicSource.fetcher = FakeFetcher(responses: [manifestURL: manifestJSON()])
        let series = try await RemoteComicSource.resolveSeries(from: manifestURL)
        #expect(series.seriesName == "Example Manga")
        #expect(series.chapters.map(\.chapterKey) == ["1", "2.0"])
        #expect(series.chapters[0].title == "The Beginning")
        #expect(series.chapters[1].number == 2)
    }

    @Test("A chapter's pages download in order, and a repeat open reuses the cache")
    func opensAndCachesAChapter() async throws {
        RemoteComicSource.fetcher = FakeFetcher(responses: [
            manifestURL: manifestJSON(),
            page1: Data([0xAA]),
            page2: Data([0xBB]),
        ])
        let source = ChapterSource.manifest(manifestURL: manifestURL, chapterKey: "1")

        let comic = try await RemoteComicSource.open(source)
        #expect(comic.pages.count == 2)
        #expect(try Data(contentsOf: comic.pages[0]) == Data([0xAA]))
        #expect(try Data(contentsOf: comic.pages[1]) == Data([0xBB]))
        #expect(comic.warning == nil)

        // Swap in a fetcher that fails everything — a cached open must not
        // need it at all.
        RemoteComicSource.fetcher = FakeFetcher(responses: [:], failing: [manifestURL, page1, page2])
        let cached = try await RemoteComicSource.open(source)
        #expect(cached.pages == comic.pages)
        #expect(cached.identity == comic.identity)
    }

    @Test("A page that fails to download becomes a warning, not a hard failure")
    func partialDownloadWarns() async throws {
        // A manifest and pages of its own, so this chapter's cache identity
        // never collides with another test's.
        let manifestURL = URL(string: "https://example.com/partial-manifest.json")!
        let page1 = URL(string: "https://example.com/partial/001.jpg")!
        let page2 = URL(string: "https://example.com/partial/002.jpg")!
        let json = """
        { "formatVersion": 1, "title": "Partial", "chapters": [
            { "id": "1", "pages": ["\(page1.absoluteString)", "\(page2.absoluteString)"] }
        ] }
        """
        RemoteComicSource.fetcher = FakeFetcher(
            responses: [manifestURL: Data(json.utf8), page1: Data([0xAA])],
            failing: [page2]
        )
        let comic = try await RemoteComicSource.open(.manifest(manifestURL: manifestURL, chapterKey: "1"))
        #expect(comic.pages.count == 1)
        #expect(comic.warning != nil)
    }

    @Test("What's saved of a chapter: missing, complete, incomplete, and missing again when a page goes")
    func cacheState() async throws {
        let manifestURL = URL(string: "https://example.com/state-manifest.json")!
        let page1 = URL(string: "https://example.com/state/001.jpg")!
        let page2 = URL(string: "https://example.com/state/002.jpg")!
        let json = """
        { "formatVersion": 1, "title": "State", "chapters": [
            { "id": "1", "pages": ["\(page1.absoluteString)", "\(page2.absoluteString)"] },
            { "id": "2", "pages": ["\(page1.absoluteString)", "\(page2.absoluteString)"] }
        ] }
        """
        let full = ChapterSource.manifest(manifestURL: manifestURL, chapterKey: "1")
        let partial = ChapterSource.manifest(manifestURL: manifestURL, chapterKey: "2")
        #expect(RemoteComicSource.cacheState(full) == .missing)

        RemoteComicSource.fetcher = FakeFetcher(responses: [manifestURL: Data(json.utf8), page1: Data([0xAA]), page2: Data([0xBB])])
        let comic = try await RemoteComicSource.open(full)
        #expect(RemoteComicSource.cacheState(full) == .complete)

        RemoteComicSource.fetcher = FakeFetcher(responses: [manifestURL: Data(json.utf8), page1: Data([0xAA])], failing: [page2])
        _ = try await RemoteComicSource.open(partial)
        #expect(RemoteComicSource.cacheState(partial) == .incomplete)

        try FileManager.default.removeItem(at: comic.pages[1])
        #expect(RemoteComicSource.cacheState(full) == .missing)
    }

    @Test("A chapter no longer in the manifest fails clearly")
    func missingChapterFails() async throws {
        RemoteComicSource.fetcher = FakeFetcher(responses: [manifestURL: manifestJSON()])
        await #expect(throws: RemoteSourceError.self) {
            _ = try await RemoteComicSource.open(.manifest(manifestURL: manifestURL, chapterKey: "does-not-exist"))
        }
    }

    @Test("An unrecognised manifest version is refused")
    func rejectsUnsupportedVersion() async throws {
        let url = URL(string: "https://example.com/future-manifest.json")!
        let json = Data("""
        { "formatVersion": 99, "title": "From the future", "chapters": [] }
        """.utf8)
        RemoteComicSource.fetcher = FakeFetcher(responses: [url: json])
        await #expect(throws: RemoteSourceError.self) {
            _ = try await RemoteComicSource.resolveSeries(from: url)
        }
    }
}

} // extension RemoteComicSourceFetcherTests

@Suite("Downloaded chapters stay until the series is removed")
struct RemoteCacheLifetimeTests {
    @Test("A chapter left in the temporary folder moves, and an existing copy is kept")
    func migratesWithoutReplacing() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsRemoteMigrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let legacy = scratch.appendingPathComponent("legacy", isDirectory: true)
        let dest = scratch.appendingPathComponent("dest", isDirectory: true)
        let kept = dest.appendingPathComponent("already", isDirectory: true)
        let moving = legacy.appendingPathComponent("moving", isDirectory: true)
        let duplicate = legacy.appendingPathComponent("already", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moving, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
        try Data([1]).write(to: kept.appendingPathComponent("page.jpg"))
        try Data([2]).write(to: moving.appendingPathComponent("page.jpg"))
        try Data([3]).write(to: duplicate.appendingPathComponent("page.jpg"))

        RemoteComicSource.migrateLegacyCache(from: legacy, into: dest)

        #expect(try Data(contentsOf: dest.appendingPathComponent("already/page.jpg")) == Data([1]))
        #expect(try Data(contentsOf: dest.appendingPathComponent("moving/page.jpg")) == Data([2]))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
