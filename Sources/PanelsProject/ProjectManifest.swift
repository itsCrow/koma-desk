import Foundation
import PanelsFormat

/// A comic the project cites: one item of the library — a volume, or a
/// chapter. Referenced by the same id the library uses (filename and size),
/// so the editor's Mac finds it in *their* library, wherever it sits.
public struct ItemRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String { itemID }
    public var itemID: String
    public var filename: String
    public var fileSize: Int
    public var series: String
    public var volume: Int?
    public var chapter: Int?
    /// "Vol. 1", "Ch. 24 · Kame Sen'nin's Training Fee".
    public var title: String

    public init(itemID: String, filename: String, fileSize: Int, series: String,
                volume: Int? = nil, chapter: Int? = nil, title: String) {
        self.itemID = itemID
        self.filename = filename
        self.fileSize = fileSize
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.title = title
    }
}

/// A moment in a comic that the script points at. In the script it's a link,
/// `panels://cite/<id>`; here is everything the link means.
public struct Citation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The library item the page is in.
    public var itemID: String
    /// Zero-based index of the (first) page.
    public var pageIndex: Int
    /// One-based page numbers as cited, ascending.
    public var pageNumbers: [Int]
    public var panel: Int?
    /// A drawn shape, unit coords, top-left origin.
    public var polygon: [PagePoint]?
    /// A dragged rectangle, unit coords, top-left origin.
    public var region: PageRect?
    /// The saved image, relative to the project's captures folder.
    public var captureFile: String?
    /// How the citation reads: "Berserk, Vol. 1, p. 117, panel 3".
    public var text: String
    public var date: Date

    public init(id: String = ProjectManifest.makeID(), itemID: String, pageIndex: Int, pageNumbers: [Int],
                panel: Int? = nil, polygon: [PagePoint]? = nil, region: PageRect? = nil,
                captureFile: String? = nil, text: String, date: Date = Date()) {
        self.id = id
        self.itemID = itemID
        self.pageIndex = pageIndex
        self.pageNumbers = pageNumbers
        self.panel = panel
        self.polygon = polygon
        self.region = region
        self.captureFile = captureFile
        self.text = text
        self.date = date
    }
}

/// A run of writing and the pages it's about. The script holds the id on
/// every line of the run; this is what the id means.
public struct PageSpan: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The library item the pages are in.
    public var itemID: String
    /// Zero-based index of the first page — what the reader navigates to.
    public var firstPageIndex: Int
    /// One-based page numbers as cited, ascending: the ends of the range.
    public var pageNumbers: [Int]
    /// How it reads: "Dragon Ball + Super, Ch. 28, pp. 12\u{2013}17". Precomputed,
    /// like a citation's, so it still reads when the comic isn't on this Mac.
    public var text: String
    public var date: Date

    public init(id: String = ProjectManifest.makeID(), itemID: String, firstPageIndex: Int,
                pageNumbers: [Int], text: String, date: Date = Date()) {
        self.id = id
        self.itemID = itemID
        self.firstPageIndex = firstPageIndex
        self.pageNumbers = pageNumbers
        self.text = text
        self.date = date
    }

    public var firstPage: Int { pageNumbers.first ?? firstPageIndex + 1 }
    public var lastPage: Int { pageNumbers.last ?? firstPage }
}

/// Everything about a project except the script itself. A project is about
/// one series; reading positions belong to the library, not to it.
public struct ProjectManifest: Codable, Equatable, Sendable {
    /// 4 since a run of writing can name the pages it's about — see `PageSpan`.
    /// 3 is still read, and upgraded on the next save.
    public static let currentVersion = 4
    /// The oldest format still understood. Older than this is refused rather
    /// than half-read, because its citations point at things by names this
    /// version doesn't know.
    public static let oldestSupportedVersion = 3

    public var version: Int
    public var name: String
    /// The series the script is about — "Berserk", "Dragon Ball + Super".
    public var series: String
    /// The items cited so far, in the order they were first cited.
    public var items: [ItemRef]
    public var citations: [Citation]
    /// The page ranges the script's blocks of writing point at.
    public var spans: [PageSpan]

    public init(name: String, series: String, items: [ItemRef] = [], citations: [Citation] = [],
                spans: [PageSpan] = []) {
        self.version = Self.currentVersion
        self.name = name
        self.series = series
        self.items = items
        self.citations = citations
        self.spans = spans
    }

    enum CodingKeys: String, CodingKey {
        case version, name, series, items, citations, spans
    }

    /// Written by hand because the synthesized decoder does not fall back to a
    /// property's default — it throws. A version-3 project has no `spans` key
    /// at all, and it has to open.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        series = try container.decode(String.self, forKey: .series)
        items = try container.decodeIfPresent([ItemRef].self, forKey: .items) ?? []
        citations = try container.decodeIfPresent([Citation].self, forKey: .citations) ?? []
        spans = try container.decodeIfPresent([PageSpan].self, forKey: .spans) ?? []
    }

    public func citation(id: String) -> Citation? {
        citations.first { $0.id == id }
    }

    public func item(id: String) -> ItemRef? {
        items.first { $0.itemID == id }
    }

    public func span(id: String) -> PageSpan? {
        spans.first { $0.id == id }
    }

    /// Adds a range, or replaces the one already under that id when its pages
    /// are changed.
    public mutating func store(_ span: PageSpan) {
        if let index = spans.firstIndex(where: { $0.id == span.id }) {
            spans[index] = span
        } else {
            spans.append(span)
        }
    }

    /// Adds an item the first time it's cited.
    public mutating func register(_ ref: ItemRef) {
        guard item(id: ref.itemID) == nil else { return }
        items.append(ref)
    }

    /// Short, unambiguous, safe in a URL: six characters of base-36.
    public static func makeID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
