import Foundation

/// One thing captured for the editor: what it is, where it came from, and
/// where it went. Kept in `captures.json` beside the files, so a script's
/// worth of captures can later be turned into something else — a contact
/// sheet, a Premiere sequence.
public struct CaptureRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case panel, region, page
    }

    public var kind: Kind
    public var series: String
    public var volume: Int?
    public var chapter: Int?
    /// Page numbers on screen when captured, ascending.
    public var pages: [Int]
    public var panel: Int?
    /// Where on the page, as a unit rect with a top-left origin. Nil for a page.
    public var region: CGRect?
    public var citation: String
    /// The comic file this came from.
    public var source: String
    /// The written file, relative to the captures folder.
    public var file: String
    public var date: Date

    public init(kind: Kind, series: String, volume: Int?, chapter: Int?, pages: [Int],
                panel: Int?, region: CGRect?, citation: String, source: String, file: String,
                date: Date = Date()) {
        self.kind = kind
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.pages = pages
        self.panel = panel
        self.region = region
        self.citation = citation
        self.source = source
        self.file = file
        self.date = date
    }
}
