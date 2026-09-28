import Foundation

/// The generic "any source" format: a URL to one of these describes a whole
/// series, with every chapter's pages already resolved to direct image
/// URLs. Analogous to cubari.moe's gist format, but chapters are an ordered
/// array rather than a dictionary keyed by chapter number — an array
/// sidesteps the ordering ambiguity numeric string keys have across JSON
/// implementations.
///
///     {
///       "formatVersion": 1,
///       "title": "Example Manga",
///       "cover": "https://example.com/cover.jpg",
///       "chapters": [
///         { "id": "5", "number": 5, "title": "The Training Begins",
///           "pages": ["https://example.com/manga/ch5/001.jpg", "…"] }
///       ]
///     }
struct ChapterManifest: Decodable {
    struct Chapter: Decodable {
        var id: String?
        var title: String?
        var volume: Int?
        /// A `Double` tolerates scanlation numbering like chapter 12.5.
        var number: Double?
        /// Absolute, already-ordered image URLs. No relative-URL resolution
        /// in this format version.
        var pages: [URL]
    }

    static let supportedFormatVersion = 1

    var formatVersion: Int
    var title: String
    var artist: String?
    var author: String?
    var cover: URL?
    var chapters: [Chapter]
}

extension ChapterManifest.Chapter {
    /// What this chapter is called in `ChapterSource.manifest`, and from
    /// there in `LibraryItem.id` — stable across re-fetches as long as the
    /// manifest doesn't renumber or reuse it. Falls back to its position so
    /// two chapters lacking both an id and a number don't collide.
    func key(atIndex index: Int) -> String {
        id ?? number.map { String($0) } ?? "index-\(index)"
    }
}
