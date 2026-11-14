import Foundation

/// Keeps each comic's text on disk so the OCR pass only ever runs once.
///
/// Lives in Application Support, not beside the extracted pages: the
/// extraction cache prunes itself, and minutes of OCR are far too expensive to
/// redo because a cache got trimmed.
public struct TextIndexStore: Sendable {
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("KomaDesk/TextIndex", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = TextIndexStore.defaultDirectory) {
        self.directory = directory
    }

    private func file(for identity: String) -> URL {
        directory.appendingPathComponent(identity).appendingPathExtension("json")
    }

    /// The stored index for a comic, if there is one and it still matches the
    /// comic's page count — a re-download with a different page count starts over.
    public func load(identity: String, pageCount: Int) -> PageTextIndex? {
        guard let data = try? Data(contentsOf: file(for: identity)),
              let index = try? JSONDecoder().decode(PageTextIndex.self, from: data),
              index.pageCount == pageCount
        else { return nil }
        return index
    }

    public func save(_ index: PageTextIndex, identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: file(for: identity), options: .atomic)
    }
}
