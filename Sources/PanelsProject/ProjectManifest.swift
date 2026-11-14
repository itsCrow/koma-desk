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

    /// Pages as a writer types them: "42", "42-45", "42–45", "pp. 42–45".
    /// Backwards ends are put in order; page 0, junk, or more than two
    /// numbers are nil.
    public static func parsePages(_ input: String) -> ClosedRange<Int>? {
        var s = input.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["pp.", "p."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        let parts = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 1 }),
              let low = numbers.min(), let high = numbers.max()
        else { return nil }
        return low...high
    }
}

/// A short production note on a beat — "green screen", "zoom", "blueprint"
/// — free text plus one of the writer's own curated colors, for scanning a
/// list of beats at a glance.
public struct Tag: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var color: ScriptSwatch

    public init(id: String = ProjectManifest.makeID(), text: String, color: ScriptSwatch) {
        self.id = id
        self.text = text
        self.color = color
    }
}

/// A section of the script the writer has marked off, by hand, in Editor
/// mode — covering exactly the paragraphs it was made on, never more.
public struct Beat: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// "Cold Open", "Turtle School flashback" — never auto-numbered.
    public var title: String
    /// Checked off in Editor mode only; Writer and Voice mode never show or
    /// touch this.
    public var isDone: Bool
    public var date: Date
    /// Production notes — "green screen", "zoom" — shown in Editor mode's
    /// tag rail, never in Writer or Voice.
    public var tags: [Tag]
    /// `nil` draws as the default violet every beat used to share. Set, it's
    /// this beat's own — the rail's number badge and the block in the
    /// script always agree on which.
    public var color: ScriptSwatch?

    public init(id: String = ProjectManifest.makeID(), title: String, isDone: Bool = false,
                date: Date = Date(), tags: [Tag] = [], color: ScriptSwatch? = nil) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.date = date
        self.tags = tags
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case id, title, isDone, date, tags, color
    }

    /// Written by hand for the same reason `ProjectManifest`'s own decoder
    /// is: the synthesized one throws on a missing key rather than falling
    /// back to a default, and a beat saved before tags or a color existed
    /// has neither key at all.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        date = try container.decode(Date.self, forKey: .date)
        tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        color = try container.decodeIfPresent(ScriptSwatch.self, forKey: .color)
    }
}

/// A citation or a page range, split into its parts.
///
/// Stored labels read "Dragon Ball + Super, Ch. 28, pp. 12–17, panel 5",
/// which is right on the clipboard and in an export, where nothing else says
/// what the comic is. In the app the whole thing is long enough to truncate,
/// which loses the pages, the one part that matters. So the parts are kept
/// separate and each view shows what it has room for.
public struct ReferenceLabel: Equatable, Sendable {
    /// "pp. 12–17", "p. 117, panel 3".
    public var pages: String
    /// "Ch. 28", "Vol. 1" — nil when the item says neither.
    public var item: String?
    public var series: String
    /// The whole thing, for the clipboard and for exports.
    public var full: String

    public init(pages: String, item: String?, series: String, full: String) {
        self.pages = pages
        self.item = item
        self.series = series
        self.full = full
    }

    /// One line, with the series left off: "Ch. 28 · pp. 12–17".
    public var short: String {
        guard !pages.isEmpty else { return full }
        return [item, pages].compactMap { $0 }.joined(separator: " · ")
    }

    /// What the pages belong to: "Ch. 28 · Dragon Ball + Super".
    public var detail: String {
        [item, series.isEmpty ? nil : series].compactMap { $0 }.joined(separator: " · ")
    }

    /// "p. 14", "pp. 12–17", with a panel when there is one.
    public static func pagePhrase(_ pages: [Int], panel: Int? = nil) -> String {
        let sorted = Array(Set(pages)).sorted()
        var phrase = ""
        if let first = sorted.first, let last = sorted.last {
            phrase = first == last ? "p. \(first)" : "pp. \(first)–\(last)"
        }
        if let panel {
            phrase += phrase.isEmpty ? "panel \(panel)" : ", panel \(panel)"
        }
        return phrase
    }
}

/// Everything about a project except the script itself. A project is about
/// one or more series; reading positions belong to the library, not to it.
public struct ProjectManifest: Codable, Equatable, Sendable {
    /// 8 since a project can be about more than one series — `series` is a
    /// list. 3 to 7, with one series as a string, are still read, and
    /// upgraded on the next save.
    public static let currentVersion = 8
    /// The oldest format still understood. Older than this is refused rather
    /// than half-read, because its citations point at things by names this
    /// version doesn't know.
    public static let oldestSupportedVersion = 3

    public var version: Int
    public var name: String
    /// The series the script is about — "Berserk", "Dragon Ball + Super" —
    /// in the order they joined the project.
    public var series: [String]
    /// The items cited so far, in the order they were first cited.
    public var items: [ItemRef]
    public var citations: [Citation]
    /// The page ranges the script's blocks of writing point at.
    public var spans: [PageSpan]
    /// The beats the writer has marked off in Editor mode.
    public var beats: [Beat]
    /// A goal for how long the script should run, in words — set once at
    /// creation, referenced later once there's something to check it
    /// against.
    public var targetWordCount: Int?

    public init(name: String, series: [String], items: [ItemRef] = [], citations: [Citation] = [],
                spans: [PageSpan] = [], beats: [Beat] = [], targetWordCount: Int? = nil) {
        self.version = Self.currentVersion
        self.name = name
        self.series = Self.unique(series)
        self.items = items
        self.citations = citations
        self.spans = spans
        self.beats = beats
        self.targetWordCount = targetWordCount
    }

    enum CodingKeys: String, CodingKey {
        case version, name, series, items, citations, spans, beats, targetWordCount
    }

    /// Written by hand because the synthesized decoder does not fall back to a
    /// property's default — it throws. A version-3 project has no `spans` key
    /// at all, and a version-4 one has no `beats` key, and each has to open;
    /// older projects have no `targetWordCount` either. Before version 8,
    /// `series` was one string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        if let list = try? container.decode([String].self, forKey: .series) {
            series = Self.unique(list)
        } else {
            series = [try container.decode(String.self, forKey: .series)]
        }
        items = try container.decodeIfPresent([ItemRef].self, forKey: .items) ?? []
        citations = try container.decodeIfPresent([Citation].self, forKey: .citations) ?? []
        spans = try container.decodeIfPresent([PageSpan].self, forKey: .spans) ?? []
        beats = try container.decodeIfPresent([Beat].self, forKey: .beats) ?? []
        targetWordCount = try container.decodeIfPresent(Int.self, forKey: .targetWordCount)
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

    public func beat(id: String) -> Beat? {
        beats.first { $0.id == id }
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

    /// Adds a beat, or replaces the one already under that id when its title
    /// or done state changes.
    public mutating func store(_ beat: Beat) {
        if let index = beats.firstIndex(where: { $0.id == beat.id }) {
            beats[index] = beat
        } else {
            beats.append(beat)
        }
    }

    /// Unlike a page range, a beat is also forgotten outright when the
    /// writer removes it — there's no "end" to just stop extending.
    public mutating func removeBeat(id: String) {
        beats.removeAll { $0.id == id }
    }

    public func label(for citation: Citation) -> ReferenceLabel {
        ReferenceLabel(pages: ReferenceLabel.pagePhrase(citation.pageNumbers, panel: citation.panel),
                       item: itemLabel(citation.itemID), series: seriesName(of: citation.itemID), full: citation.text)
    }

    public func label(for span: PageSpan) -> ReferenceLabel {
        ReferenceLabel(pages: ReferenceLabel.pagePhrase(span.pageNumbers),
                       item: itemLabel(span.itemID), series: seriesName(of: span.itemID), full: span.text)
    }

    /// The series an item belongs to. An item never registered falls back to
    /// the project's only series, when it has just the one.
    private func seriesName(of itemID: String) -> String {
        item(id: itemID)?.series ?? (series.count == 1 ? series[0] : "")
    }

    /// "Berserk + Vagabond" — every series, for a heading or a list row.
    public var seriesDisplayName: String { series.joined(separator: " + ") }

    /// Adds a series, if it isn't already one of the project's.
    public mutating func addSeries(_ name: String) {
        guard !name.isEmpty, !series.contains(name) else { return }
        series.append(name)
    }

    /// Whether anything in the project points at a comic of this series.
    public func isCited(_ seriesName: String) -> Bool {
        let ids = Set(items.filter { $0.series == seriesName }.map(\.itemID))
        return citations.contains { ids.contains($0.itemID) } || spans.contains { ids.contains($0.itemID) }
    }

    /// Takes a series off the project. Refused, returning false, while a
    /// citation or a page range still points at one of its comics, or when
    /// it is the last series left.
    @discardableResult
    public mutating func removeSeries(_ name: String) -> Bool {
        guard series.contains(name), series.count > 1, !isCited(name) else { return false }
        series.removeAll { $0 == name }
        items.removeAll { $0.series == name }
        return true
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// How a volume or chapter is named on its own, without the series.
    private func itemLabel(_ itemID: String) -> String? {
        guard let ref = item(id: itemID) else { return nil }
        if let chapter = ref.chapter { return "Ch. \(chapter)" }
        if let volume = ref.volume { return "Vol. \(volume)" }
        return ref.title.isEmpty ? nil : ref.title
    }

    /// Adds an item the first time it's cited, and its series, if the
    /// project wasn't about that series yet.
    public mutating func register(_ ref: ItemRef) {
        addSeries(ref.series)
        guard item(id: ref.itemID) == nil else { return }
        items.append(ref)
    }

    /// Short, unambiguous, safe in a URL: six characters of base-36.
    public static func makeID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
