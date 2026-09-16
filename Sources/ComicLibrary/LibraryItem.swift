import Foundation

/// One readable file in the library: a volume of a series, or a chapter of
/// one of its arcs.
public struct LibraryItem: Codable, Equatable, Sendable, Identifiable {
    /// Filename and size — the same file wherever it's moved to.
    public let id: String
    /// Where it was last seen.
    public var url: URL
    public let series: String
    public let volume: Int?
    public let chapter: Int?
    /// A chapter's title where the filename gives one; otherwise the filename.
    public let title: String
    /// The folder between the series and the file, when there is one and it
    /// isn't just the series' own folder.
    public let arc: String?
    public let fileSize: Int

    public init(url: URL, series: String, volume: Int?, chapter: Int?, title: String, arc: String?, fileSize: Int) {
        self.id = LibraryItem.makeID(filename: url.lastPathComponent, fileSize: fileSize)
        self.url = url
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.title = title
        self.arc = arc
        self.fileSize = fileSize
    }

    public static func makeID(filename: String, fileSize: Int) -> String {
        "\(filename)|\(fileSize)"
    }

    /// "Vol. 1", "Ch. 24", or the title when it's neither.
    public var label: String {
        if let volume { return "Vol. \(volume)" }
        if let chapter { return "Ch. \(chapter)" }
        return title
    }

    /// What to call it in a list: "Vol. 1", or "Ch. 24 · Kame Sen'nin's Training Fee".
    public var displayName: String {
        if let volume { return "Vol. \(volume)" }
        if let chapter { return title.isEmpty ? "Ch. \(chapter)" : "Ch. \(chapter) · \(title)" }
        return title
    }
}

/// A series: everything the library has of it, in reading order.
public struct Series: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public var items: [LibraryItem]

    public init(name: String, items: [LibraryItem]) {
        self.name = name
        self.items = items
    }

    /// Items grouped by arc, in order; a nil arc for items that sit directly
    /// in the series.
    public var arcs: [(name: String?, items: [LibraryItem])] {
        var groups: [(name: String?, items: [LibraryItem])] = []
        for item in items {
            if let last = groups.indices.last, groups[last].name == item.arc {
                groups[last].items.append(item)
            } else {
                groups.append((item.arc, [item]))
            }
        }
        return groups
    }

    public var hasArcs: Bool { items.contains { $0.arc != nil } }
    public var volumeCount: Int { items.filter { $0.volume != nil && $0.chapter == nil }.count }
    public var chapterCount: Int { items.filter { $0.chapter != nil }.count }

    /// "40 volumes", "18 arcs · 69 chapters", "3 items".
    public var summary: String {
        var parts: [String] = []
        if hasArcs {
            let arcCount = Set(items.compactMap(\.arc)).count
            parts.append("\(arcCount) arc\(arcCount == 1 ? "" : "s")")
        }
        if volumeCount > 0 { parts.append("\(volumeCount) volume\(volumeCount == 1 ? "" : "s")") }
        if chapterCount > 0 { parts.append("\(chapterCount) chapter\(chapterCount == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("\(items.count) item\(items.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    public func item(id: String) -> LibraryItem? { items.first { $0.id == id } }
    public func index(of item: LibraryItem) -> Int? { items.firstIndex { $0.id == item.id } }
}
