import AppKit
import Foundation

/// An NSImage crossing a concurrency boundary. AppKit predates Sendable and
/// NSImage isn't marked as such, but a freshly decoded image that only this
/// cache touches is safe to hand to the main actor.
struct LoadedPage: @unchecked Sendable {
    let image: NSImage
}

/// Decodes page images off the main actor and keeps the ones near the current
/// spread around, so turning a page doesn't stutter.
final class PageCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, NSImage>()

    init(limit: Int = 12) {
        cache.countLimit = limit
    }

    func load(_ url: URL) -> LoadedPage? {
        if let hit = cache.object(forKey: url as NSURL) {
            return LoadedPage(image: hit)
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return LoadedPage(image: image)
    }

    /// A page only if it's already decoded. Building the incoming panel of a
    /// swipe has to happen within the frame, so it asks for what's on hand
    /// rather than waiting on a decode.
    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Warms the cache for pages the reader is about to need.
    func prefetch(_ urls: [URL]) {
        for url in urls where cache.object(forKey: url as NSURL) == nil {
            _ = load(url)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
