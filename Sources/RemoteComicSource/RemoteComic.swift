import Foundation

/// An opened remote chapter: pages downloaded once and cached on disk — the
/// network equivalent of `ComicArchive`. Nothing downstream needs to know a
/// page came from here rather than an extracted archive.
public struct RemoteComic: Sendable {
    public let source: ChapterSource
    /// Stable for this chapter, from this source. Keys the download cache.
    public let identity: String
    /// Page images in reading order, already downloaded to disk.
    public let pages: [URL]
    /// Set when some pages failed to download but others were recovered.
    public let warning: String?

    public var pageCount: Int { pages.count }
}
