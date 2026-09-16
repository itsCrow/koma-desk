import Foundation
import ImageIO
import CoreGraphics

/// Cuts a region out of a page at the page's own resolution — straight from the
/// file, never from whatever is on screen.
public enum PageCropper {
    public enum Failure: Error { case unreadable, emptyRegion }

    /// `unitRect` has a top-left origin; nil means the whole page.
    public static func crop(_ pageURL: URL, unitRect: CGRect?) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(pageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary)
        else { throw Failure.unreadable }
        guard let unitRect else { return image }

        let w = Double(image.width), h = Double(image.height)
        let rect = CGRect(
            x: (unitRect.minX * w).rounded(.down),
            y: (unitRect.minY * h).rounded(.down),
            width: (unitRect.width * w).rounded(.up),
            height: (unitRect.height * h).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            throw Failure.emptyRegion
        }
        return cropped
    }
}
