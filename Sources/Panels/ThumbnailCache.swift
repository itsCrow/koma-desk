import AppKit
import ImageIO

/// Small versions of every page, for the overview strip in the controls panel.
///
/// Decoded at thumbnail size straight from the file — ImageIO never inflates the
/// full-resolution scan — so scrolling through a 200-page volume stays light.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    /// Longest side, in pixels. Twice the on-screen size for Retina.
    static let maxPixelSize = 320

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let made = await Task.detached(priority: .utility) {
            Self.decode(url).map(LoadedPage.init)
        }.value?.image
        if let made { cache.setObject(made, forKey: url as NSURL) }
        return made
    }

    private static func decode(_ url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
