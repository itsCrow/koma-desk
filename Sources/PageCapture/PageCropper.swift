import Foundation
import ImageIO
import CoreGraphics

/// Cuts a region out of a page at the page's own resolution — straight from the
/// file, never from whatever is on screen.
public enum PageCropper {
    public enum Failure: Error { case unreadable, emptyRegion }

    /// `unitRect` has a top-left origin; nil means the whole page.
    public static func crop(_ pageURL: URL, unitRect: CGRect?) throws -> CGImage {
        let image = try load(pageURL)
        guard let unitRect else { return image }
        let rect = pixelRect(unitRect, in: image)
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            throw Failure.emptyRegion
        }
        return cropped
    }

    /// The polygon's bounding box, with everything outside the polygon
    /// transparent. Unit coords, top-left origin.
    public static func crop(_ pageURL: URL, polygon: [CGPoint]) throws -> CGImage {
        let image = try load(pageURL)
        return try crop(image, polygon: polygon)
    }

    public static func crop(_ image: CGImage, polygon: [CGPoint]) throws -> CGImage {
        guard polygon.count >= 3 else { throw Failure.emptyRegion }
        let w = Double(image.width), h = Double(image.height)

        // Image pixel space, top-left origin.
        let points = polygon.map { CGPoint(x: $0.x * w, y: $0.y * h) }
        let bounds = pixelRect(points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                                   .applying(CGAffineTransform(scaleX: 1 / w, y: 1 / h)), in: image)
        guard bounds.width >= 1, bounds.height >= 1 else { throw Failure.emptyRegion }

        guard let context = CGContext(
            data: nil, width: Int(bounds.width), height: Int(bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.unreadable }

        // CGContext has a bottom-left origin: flip, then shift so the box's
        // corner is the context's corner.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)

        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        context.addPath(path)
        context.clip()

        // The image is drawn in the same flipped space, so it lands upright.
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let result = context.makeImage() else { throw Failure.unreadable }
        return result
    }

    private static func load(_ pageURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(pageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary)
        else { throw Failure.unreadable }
        return image
    }

    /// A unit rect as whole pixels of the image, clamped to it.
    private static func pixelRect(_ unitRect: CGRect, in image: CGImage) -> CGRect {
        let w = Double(image.width), h = Double(image.height)
        let x0 = (unitRect.minX * w).rounded(.down), y0 = (unitRect.minY * h).rounded(.down)
        let x1 = (unitRect.maxX * w).rounded(.up), y1 = (unitRect.maxY * h).rounded(.up)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }
}
