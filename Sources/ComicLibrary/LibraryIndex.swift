import Foundation

/// Everything the library remembers between launches.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public var version: Int
    /// Folders (or single files) being watched.
    public var roots: [URL]
    /// What `LibraryScanner.scan(roots:)` found — replaced wholesale on
    /// every rescan, so nothing that should survive a rescan belongs here.
    public var series: [Series]
    /// Series added from the web. A directory rescan never touches this.
    public var remoteSeries: [Series]
    /// Web sources the user has added, so they can be re-checked for new
    /// chapters.
    public var remoteSources: [RemoteSourceRecord]
    /// Reading position (spread index) per item.
    public var positions: [String: Int]
    /// How many spreads an item has, learned the first time it's opened —
    /// what turns a bare position into an actual read-percentage.
    public var spreadCounts: [String: Int]
    /// The item last read in each series, by series name.
    public var lastRead: [String: String]
    /// Series in the order they were last read, most recent first.
    public var recentSeries: [String]
    /// Cover image filename per item, in the covers folder.
    public var covers: [String: String]

    public init(roots: [URL] = [], series: [Series] = [], remoteSeries: [Series] = [],
                remoteSources: [RemoteSourceRecord] = [], positions: [String: Int] = [:],
                spreadCounts: [String: Int] = [:],
                lastRead: [String: String] = [:], recentSeries: [String] = [], covers: [String: String] = [:]) {
        self.version = 2
        self.roots = roots
        self.series = series
        self.remoteSeries = remoteSeries
        self.remoteSources = remoteSources
        self.positions = positions
        self.spreadCounts = spreadCounts
        self.lastRead = lastRead
        self.recentSeries = recentSeries
        self.covers = covers
    }

    /// Every series the library knows: scanned from disk, and added from
    /// the web.
    public var allSeries: [Series] { series + remoteSeries }

    /// Marks `item` as the one being read in its series, and its series as
    /// the most recently read.
    public mutating func noteRead(_ item: LibraryItem) {
        lastRead[item.series] = item.id
        recentSeries.removeAll { $0 == item.series }
        recentSeries.insert(item.series, at: 0)
    }

    /// The item to pick up in a series: the one last read there, or the first.
    public func continueItem(in series: Series) -> LibraryItem? {
        lastRead[series.name].flatMap { series.item(id: $0) } ?? series.items.first
    }

    public func series(named name: String) -> Series? { allSeries.first { $0.name == name } }

    public func item(id: String) -> LibraryItem? {
        for s in allSeries { if let item = s.item(id: id) { return item } }
        return nil
    }

    public func series(containing item: LibraryItem) -> Series? { series(named: item.series) }
}

// MARK: - Codable

extension LibraryIndex {
    private enum CodingKeys: String, CodingKey {
        case version, roots, series, remoteSeries, remoteSources, positions, spreadCounts, lastRead, recentSeries, covers
    }

    /// Written by hand so a `library.json` saved before remote sources or
    /// spread counts existed — which have none of these keys — still opens,
    /// with empty defaults rather than a decode failure.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        roots = try container.decode([URL].self, forKey: .roots)
        series = try container.decode([Series].self, forKey: .series)
        remoteSeries = try container.decodeIfPresent([Series].self, forKey: .remoteSeries) ?? []
        remoteSources = try container.decodeIfPresent([RemoteSourceRecord].self, forKey: .remoteSources) ?? []
        positions = try container.decode([String: Int].self, forKey: .positions)
        spreadCounts = try container.decodeIfPresent([String: Int].self, forKey: .spreadCounts) ?? [:]
        lastRead = try container.decode([String: String].self, forKey: .lastRead)
        recentSeries = try container.decode([String].self, forKey: .recentSeries)
        covers = try container.decode([String: String].self, forKey: .covers)
    }
}

/// The index on disk.
public enum LibraryStore {
    public static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PanelsMVP", isDirectory: true)
    }

    public static func indexURL(in folder: URL = defaultFolder) -> URL { folder.appendingPathComponent("library.json") }
    public static func coversFolder(in folder: URL = defaultFolder) -> URL { folder.appendingPathComponent("Covers", isDirectory: true) }

    public static func load(from folder: URL = defaultFolder) -> LibraryIndex {
        guard let data = try? Data(contentsOf: indexURL(in: folder)),
              let index = try? decoder.decode(LibraryIndex.self, from: data)
        else { return LibraryIndex() }
        return index
    }

    public static func save(_ index: LibraryIndex, to folder: URL = defaultFolder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(index).write(to: indexURL(in: folder), options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    private static var decoder: JSONDecoder { JSONDecoder() }
}
