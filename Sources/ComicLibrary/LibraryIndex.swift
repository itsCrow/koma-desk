import Foundation

/// Everything the library remembers between launches.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public var version: Int
    /// Folders (or single files) being watched.
    public var roots: [URL]
    public var series: [Series]
    /// Reading position (spread index) per item.
    public var positions: [String: Int]
    /// The item last read in each series, by series name.
    public var lastRead: [String: String]
    /// Series in the order they were last read, most recent first.
    public var recentSeries: [String]
    /// Cover image filename per item, in the covers folder.
    public var covers: [String: String]

    public init(roots: [URL] = [], series: [Series] = [], positions: [String: Int] = [:],
                lastRead: [String: String] = [:], recentSeries: [String] = [], covers: [String: String] = [:]) {
        self.version = 1
        self.roots = roots
        self.series = series
        self.positions = positions
        self.lastRead = lastRead
        self.recentSeries = recentSeries
        self.covers = covers
    }

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

    public func series(named name: String) -> Series? { series.first { $0.name == name } }

    public func item(id: String) -> LibraryItem? {
        for s in series { if let item = s.item(id: id) { return item } }
        return nil
    }

    public func series(containing item: LibraryItem) -> Series? { series(named: item.series) }
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
