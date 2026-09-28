import Foundation

/// Where one chapter's pages come from.
public enum ChapterSource: Sendable, Equatable, Hashable {
    case manifest(manifestURL: URL, chapterKey: String)
    case site(site: String, chapterURL: URL)

    /// Feeds the cache identity — stable for the same chapter, and distinct
    /// across sources so two sites' "chapter 1" never collide.
    var cacheSeed: String {
        switch self {
        case .manifest(let url, let key):
            return "manifest|\(url.absoluteString)|\(key)"
        case .site(let site, let url):
            return "site|\(site)|\(url.absoluteString)"
        }
    }
}
