import Foundation

/// A chapter a series source knows about, and where it sits within the
/// series.
public struct ResolvedChapter: Sendable, Equatable {
    public var chapterURL: URL
    public var chapterKey: String
    public var number: Double?
    public var volume: Int?
    public var title: String?

    public init(chapterURL: URL, chapterKey: String, number: Double? = nil, volume: Int? = nil, title: String? = nil) {
        self.chapterURL = chapterURL
        self.chapterKey = chapterKey
        self.number = number
        self.volume = volume
        self.title = title
    }
}

/// A series and every chapter of it that a source — a manifest or a site
/// adapter — currently knows about.
public struct ResolvedSeries: Sendable, Equatable {
    public var seriesName: String
    public var cover: URL?
    public var chapters: [ResolvedChapter]

    public init(seriesName: String, cover: URL? = nil, chapters: [ResolvedChapter]) {
        self.seriesName = seriesName
        self.cover = cover
        self.chapters = chapters
    }
}

/// One source site Koma Desk knows how to read directly from a link, the way
/// cubari.moe's per-site scrapers do. Adding a new site is one adapter
/// conforming to this, registered in `RemoteComicSource.adapters`.
protocol SiteAdapter: Sendable {
    /// Short and stable — persisted in `LibraryItem`/`RemoteSourceRecord`,
    /// so it must never change once a site ships.
    var id: String { get }
    func canHandle(_ url: URL) -> Bool
    func resolveSeries(from url: URL) async throws -> ResolvedSeries
    func pageImageURLs(chapterURL: URL) async throws -> [URL]
}
