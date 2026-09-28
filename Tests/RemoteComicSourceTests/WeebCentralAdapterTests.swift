import Testing
import Foundation
@testable import RemoteComicSource

extension RemoteComicSourceFetcherTests {

/// Parses saved HTML fixtures — real markup captured from weebcentral.com —
/// never the live site. A markup change breaks these deliberately, rather
/// than the tests flaking on whatever the site currently looks like.
///
/// Nested under `RemoteComicSourceFetcherTests` (see that file) so its
/// `.serialized` trait keeps this suite from racing another one over
/// `RemoteComicSource.fetcher`, a shared mutable static.
@Suite("Reading weebcentral from saved markup")
struct WeebCentralAdapterTests {
    static func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try! String(contentsOf: url, encoding: .utf8)
    }

    struct FixtureFetcher: PageFetching {
        func fetchData(_ url: URL) async throws -> Data {
            let name: String
            switch true {
            case url.path.hasSuffix("/full-chapter-list"): name = "weebcentral-chapter-list.html"
            case url.path.hasSuffix("/images"): name = "weebcentral-chapter-images.html"
            case url.path.hasPrefix("/chapters/"): name = "weebcentral-chapter-page.html"
            default: name = "weebcentral-series.html"
            }
            return Data(fixture(name).utf8)
        }
    }

    let adapter = WeebCentralAdapter()
    let seriesURL = URL(string: "https://weebcentral.com/series/01J76XYB8Y1TBX756V0EW065J4/Dragon-Ball-Super")!

    @Test("Recognises weebcentral links, and nothing else")
    func recognisesHost() {
        #expect(adapter.canHandle(seriesURL))
        #expect(adapter.canHandle(URL(string: "https://www.weebcentral.com/series/x/y")!))
        #expect(!adapter.canHandle(URL(string: "https://example.com/manifest.json")!))
    }

    @Test("A series page resolves its title, cover and chapters in reading order")
    func resolvesSeries() async throws {
        RemoteComicSource.fetcher = FixtureFetcher()
        let series = try await adapter.resolveSeries(from: seriesURL)
        #expect(series.seriesName == "Dragon Ball Super")
        #expect(series.cover?.absoluteString == "https://temp.compsci88.com/cover/fallback/01J76XYB8Y1TBX756V0EW065J4.jpg")
        #expect(series.chapters.count == 104)
        // Oldest first, even though the page lists newest first.
        #expect(series.chapters.first?.number == 1)
        #expect(series.chapters.first?.chapterURL.absoluteString == "https://weebcentral.com/chapters/01J76XYZ3GEXPKYVJZ9MJ3FHMQ")
        #expect(series.chapters.last?.number == 104)
        #expect(series.chapters.last?.chapterURL.absoluteString == "https://weebcentral.com/chapters/01JMFC2BJSXNKME7648E39X96E")
    }

    @Test("A chapter's pages come back in order, with the broken-image fallback filtered out")
    func resolvesPages() async throws {
        RemoteComicSource.fetcher = FixtureFetcher()
        let chapterURL = URL(string: "https://weebcentral.com/chapters/01J76XYZ3GEXPKYVJZ9MJ3FHMQ")!
        let pages = try await adapter.pageImageURLs(chapterURL: chapterURL)
        #expect(pages.count == 22)
        #expect(pages.first?.absoluteString == "https://official.lowee.us/manga/Dragon-Ball-Super/0001-001.png")
        #expect(pages.last?.absoluteString == "https://official.lowee.us/manga/Dragon-Ball-Super/0001-022.png")
        #expect(pages.allSatisfy { !$0.absoluteString.contains("broken_image") })
    }

    @Test("A chapter link resolves back to its series")
    func resolvesSeriesFromAChapterLink() async throws {
        RemoteComicSource.fetcher = FixtureFetcher()
        let chapterURL = URL(string: "https://weebcentral.com/chapters/01J76XYZ3GEXPKYVJZ9MJ3FHMQ")!
        let series = try await adapter.resolveSeries(from: chapterURL)
        #expect(series.seriesName == "Dragon Ball Super")
    }
}

} // extension RemoteComicSourceFetcherTests
