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

/// Everything about a project except the script itself. A project is about
/// one series; reading positions belong to the library, not to it.
public struct ProjectManifest: Codable, Equatable, Sendable {
    /// 3 since citation geometry gained named keys — see `PagePoint`.
    public static let currentVersion = 3

    public var version: Int
    public var name: String
    /// The series the script is about — "Berserk", "Dragon Ball + Super".
    public var series: String
    /// The items cited so far, in the order they were first cited.
    public var items: [ItemRef]
    public var citations: [Citation]

    public init(name: String, series: String, items: [ItemRef] = [], citations: [Citation] = []) {
        self.version = Self.currentVersion
        self.name = name
        self.series = series
        self.items = items
        self.citations = citations
    }

    public func citation(id: String) -> Citation? {
        citations.first { $0.id == id }
    }

    public func item(id: String) -> ItemRef? {
        items.first { $0.itemID == id }
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
