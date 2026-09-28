import CryptoKit
import Foundation

/// Where a library item's pages come from.
public enum ItemSource: Codable, Equatable, Sendable {
    case local
    case manifest(manifestURL: URL, chapterKey: String)
    case site(site: String, chapterURL: URL)
}

/// One readable file in the library: a volume of a series, or a chapter of
/// one of its arcs.
public struct LibraryItem: Codable, Equatable, Sendable, Identifiable {
    /// Filename and size for a local file — the same file wherever it's
    /// moved to. A hash of where it comes from for a remote item, since
    /// there's no local file to key off until its pages are cached.
    public let id: String
    /// Where it was last seen: a local file for `.local`; the chapter or
    /// manifest link otherwise.
    public var url: URL
    /// Where its pages come from.
    public var source: ItemSource
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
        self.source = .local
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.title = title
        self.arc = arc
        self.fileSize = fileSize
    }

    /// A chapter read from the web: a manifest, or a known site.
    public init(remote source: ItemSource, series: String, volume: Int?, chapter: Int?,
                title: String, arc: String?, displayURL: URL) {
        self.id = LibraryItem.makeRemoteID(source)
        self.url = displayURL
        self.source = source
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.title = title
        self.arc = arc
        self.fileSize = 0
    }

    public static func makeID(filename: String, fileSize: Int) -> String {
        "\(filename)|\(fileSize)"
    }

    /// A remote item's id: a hash of where it comes from, not a filename and
    /// size. Two libraries that add the same URL get the same id, so a
    /// shared script's citations resolve the same way wherever it's opened.
    public static func makeRemoteID(_ source: ItemSource) -> String {
        let seed: String
        switch source {
        case .local:
            seed = ""
        case .manifest(let url, let key):
            seed = "manifest|\(url.absoluteString)|\(key)"
        case .site(let site, let url):
            seed = "site|\(site)|\(url.absoluteString)"
        }
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
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

// MARK: - Codable

extension LibraryItem {
    private enum CodingKeys: String, CodingKey {
        case id, url, source, series, volume, chapter, title, arc, fileSize
    }

    /// Written by hand because the synthesized decoder does not fall back to
    /// a property's default — it throws. Every item on disk before `source`
    /// existed has no `source` key at all, and it has to open as `.local`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        source = try container.decodeIfPresent(ItemSource.self, forKey: .source) ?? .local
        series = try container.decode(String.self, forKey: .series)
        volume = try container.decodeIfPresent(Int.self, forKey: .volume)
        chapter = try container.decodeIfPresent(Int.self, forKey: .chapter)
        title = try container.decode(String.self, forKey: .title)
        arc = try container.decodeIfPresent(String.self, forKey: .arc)
        fileSize = try container.decode(Int.self, forKey: .fileSize)
    }
}
