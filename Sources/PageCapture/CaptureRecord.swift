import Foundation
import KomaFormat

/// One thing captured for the editor: what it is, where it came from, and
/// where it went. Kept in `captures.json` beside the files, so a script's
/// worth of captures can later be turned into something else — a contact
/// sheet, a Premiere sequence.
public struct CaptureRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A detected panel, by click. Cropped to its outline when it isn't a rectangle.
        case panel
        /// A dragged rectangle.
        case region
        /// A drawn shape.
        case shape
        /// The whole page.
        case page
    }

    public var kind: Kind
    public var series: String
    public var volume: Int?
    public var chapter: Int?
    /// Page numbers on screen when captured, ascending.
    public var pages: [Int]
    public var panel: Int?
    /// Where on the page, as a unit rect with a top-left origin. Nil for a page.
    public var region: PageRect?
    /// The exact outline, when the capture was masked to one. Everything
    /// outside it is transparent in the file.
    public var polygon: [PagePoint]?
    public var citation: String
    /// The comic file this came from.
    public var source: String
    /// The written file, relative to the captures folder.
    public var file: String
    public var date: Date

    /// Whether these two describe the same picture: the same region of the
    /// same page of the same comic. Not the date, the filename or the citation
    /// text, which all follow from the rest.
    ///
    /// Geometry is what separates a genuine duplicate from a coincidence of
    /// naming: two different shapes drawn on one page want the same filename
    /// but are different pictures, while a page saved twice has no geometry
    /// either time and is the same picture.
    public func isSameShot(as other: CaptureRecord) -> Bool {
        kind == other.kind
            && source == other.source
            && series == other.series
            && volume == other.volume
            && chapter == other.chapter
            && pages == other.pages
            && panel == other.panel
            && region == other.region
            && polygon == other.polygon
    }

    public init(kind: Kind, series: String, volume: Int?, chapter: Int?, pages: [Int],
                panel: Int?, region: PageRect?, polygon: [PagePoint]? = nil, citation: String,
                source: String, file: String, date: Date = Date()) {
        self.kind = kind
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.pages = pages
        self.panel = panel
        self.region = region
        self.polygon = polygon
        self.citation = citation
        self.source = source
        self.file = file
        self.date = date
    }
}
