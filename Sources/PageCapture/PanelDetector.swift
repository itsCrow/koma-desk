import Foundation
import ImageIO
import CoreGraphics

/// A panel found on a page.
public struct DetectedPanel: Equatable, Sendable {
    /// Bounding box, as a unit rect with a top-left origin.
    public let box: CGRect
    /// How much of the box the panel's own pixels fill. A plain rectangle is
    /// near 1; a balloon breaking out of the border, a bleed with no border,
    /// or a diagonal edge pulls it down.
    public let fill: Double
    /// The panel's real outline as a closed polygon, unit coords, top-left
    /// origin, simplified to a few points per edge.
    public let outline: [CGPoint]

    /// A rectangle is cropped as one — opaque, smaller, no mask needed.
    public var isRectangular: Bool { fill >= 0.92 }

    public init(box: CGRect, fill: Double, outline: [CGPoint]) {
        self.box = box
        self.fill = fill
        self.outline = outline
    }
}

/// Finds the panels on a page.
///
/// Comic panels sit in paper-white gutters that run out to the page margin.
/// Flood the white in from the margin and every connected region left over is
/// a panel — border, art and all. That handles panels spanning rows and
/// L-shaped layouts, which cutting along full-width gutters never can. It
/// runs on a ~1400px reduction: fine enough that a narrow gutter or a speech
/// bubble's outline doesn't fuse two panels, cheap enough to be instant.
public enum PanelDetector {
    public static let analysisPixelSize = 1400
    /// Below this the region is a stray — a sound effect in the margin, art
    /// left behind by a borderless bleed — not a panel.
    public static let minimumFill = 0.3

    /// Panel boxes only, in reading order.
    public static func panels(in pageURL: URL, rightToLeft: Bool) -> [CGRect] {
        detect(in: pageURL, rightToLeft: rightToLeft).map(\.box)
    }

    public static func panels(in image: CGImage, rightToLeft: Bool) -> [CGRect] {
        detect(in: image, rightToLeft: rightToLeft).map(\.box)
    }

    /// Panels in reading order: rows top to bottom, then right-to-left for
    /// manga, left-to-right otherwise.
    public static func detect(in pageURL: URL, rightToLeft: Bool) -> [DetectedPanel] {
        guard let source = CGImageSourceCreateWithURL(pageURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: analysisPixelSize,
              ] as CFDictionary)
        else { return [] }
        return detect(in: image, rightToLeft: rightToLeft)
    }

    public static func detect(in image: CGImage, rightToLeft: Bool) -> [DetectedPanel] {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return [] }
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(
            data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Paper is anything this light; ink and tone are darker.
        let paper: UInt8 = 215
        // 0 = unvisited, -1 = gutter/margin, >0 = a panel's id.
        var label = [Int32](repeating: 0, count: w * h)
        var stack: [Int] = []
        stack.reserveCapacity(w * h / 8)

        // The gutter flood may cross a hairline — a speech bubble's outline, a
        // stray stroke — but not a panel border. At this size a border is
        // four pixels or more and an outline under two, so: ink with paper on
        // at least three of its eight sides is thin enough to pass through.
        func passable(_ i: Int) -> Bool {
            if gray[i] >= paper { return true }
            let x = i % w, y = i / w
            guard x > 0, x < w - 1, y > 0, y < h - 1 else { return false }
            var paperAround = 0
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    if gray[i + dy * w + dx] >= paper { paperAround += 1 }
                }
            }
            return paperAround >= 3
        }

        // 1. Flood the paper connected to the page edge.
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let i = stack.popLast() {
            guard label[i] == 0, passable(i) else { continue }
            label[i] = -1
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }

        // 2. Everything else, in connected lumps.
        struct Lump { var id: Int32; var x0: Int; var y0: Int; var x1: Int; var y1: Int; var count: Int }
        var lumps: [Lump] = []
        var next: Int32 = 1
        for start in 0..<(w * h) where label[start] == 0 {
            var lump = Lump(id: next, x0: w, y0: h, x1: 0, y1: 0, count: 0)
            stack.append(start)
            while let i = stack.popLast() {
                guard label[i] == 0 else { continue }
                label[i] = next
                let x = i % w, y = i / w
                lump.x0 = min(lump.x0, x); lump.x1 = max(lump.x1, x)
                lump.y0 = min(lump.y0, y); lump.y1 = max(lump.y1, y)
                lump.count += 1
                if x > 0 { stack.append(i - 1) }
                if x < w - 1 { stack.append(i + 1) }
                if y > 0 { stack.append(i - w) }
                if y < h - 1 { stack.append(i + w) }
            }
            next += 1
            lumps.append(lump)
        }

        // 3. Keep lumps big and solid enough to be panels — not page numbers,
        //    not a sound effect floating in the margin — and drop any sitting
        //    inside a bigger one.
        let minArea = Double(w * h) * 0.015
        var kept = lumps.filter {
            let bw = $0.x1 - $0.x0 + 1, bh = $0.y1 - $0.y0 + 1
            return Double(bw * bh) >= minArea && bw > w / 12 && bh > h / 16
                && Double($0.count) / Double(bw * bh) >= minimumFill
        }
        kept.sort { ($0.x1 - $0.x0) * ($0.y1 - $0.y0) > ($1.x1 - $1.x0) * ($1.y1 - $1.y0) }
        var result: [Lump] = []
        for lump in kept where !result.contains(where: {
            lump.x0 >= $0.x0 - 2 && lump.y0 >= $0.y0 - 2 && lump.x1 <= $0.x1 + 2 && lump.y1 <= $0.y1 + 2
        }) {
            result.append(lump)
        }

        // 4. Reading order. Lumps whose tops are within a twentieth of the
        //    page share a row.
        result.sort { a, b in
            abs(a.y0 - b.y0) > h / 20 ? a.y0 < b.y0 : (rightToLeft ? a.x0 > b.x0 : a.x0 < b.x0)
        }

        return result.map { lump in
            let bw = lump.x1 - lump.x0 + 1, bh = lump.y1 - lump.y0 + 1
            let outline = traceOutline(of: lump.id, in: label, width: w, height: h,
                                       x0: lump.x0, y0: lump.y0, x1: lump.x1, y1: lump.y1)
            return DetectedPanel(
                box: CGRect(x: Double(lump.x0) / Double(w), y: Double(lump.y0) / Double(h),
                            width: Double(bw) / Double(w), height: Double(bh) / Double(h)),
                fill: Double(lump.count) / Double(bw * bh),
                outline: simplify(outline, tolerance: 2).map {
                    CGPoint(x: $0.x / Double(w), y: $0.y / Double(h))
                }
            )
        }
    }

    // MARK: - Outline

    /// Walks the outer edge of one lump and returns it as a closed polygon in
    /// pixel coordinates (each point the outer corner of its boundary pixel).
    /// Moore-neighbour tracing, clockwise, from the lump's top-left pixel.
    private static func traceOutline(
        of id: Int32, in label: [Int32], width w: Int, height h: Int,
        x0: Int, y0: Int, x1: Int, y1: Int
    ) -> [CGPoint] {
        func inside(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < w && y >= 0 && y < h && label[y * w + x] == id
        }
        // Top-left pixel of the lump: the start, whose west neighbour is outside.
        var start: (x: Int, y: Int)?
        scan: for y in y0...y1 {
            for x in x0...x1 where inside(x, y) {
                start = (x, y)
                break scan
            }
        }
        guard let start else { return [] }

        // Clockwise from west, as (dx, dy) in a top-left-origin image.
        let dirs = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        var path: [CGPoint] = []
        var current = start
        var backtrack = 0  // index into dirs of the neighbour we came from; west for the start
        var firstMove: Int?
        let limit = 2 * (x1 - x0 + y1 - y0 + 2) * 4 + 16

        repeat {
            path.append(CGPoint(x: Double(current.x) + 0.5, y: Double(current.y) + 0.5))
            var moved = false
            for k in 0..<8 {
                let d = (backtrack + k) % 8
                let nx = current.x + dirs[d].0, ny = current.y + dirs[d].1
                if inside(nx, ny) {
                    if firstMove == nil { firstMove = d }
                    else if current == start, d == firstMove { return path }  // back where we began, going the same way
                    // Next time, start looking from the neighbour just before this one,
                    // seen from the new pixel: that's the pixel we're leaving.
                    backtrack = (d + 6) % 8
                    current = (nx, ny)
                    moved = true
                    break
                }
            }
            if !moved { return path }  // a single isolated pixel
        } while path.count < limit
        return path
    }

    /// Douglas–Peucker. Keeps corners, drops the stair-steps of a traced edge.
    static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var farthest = a
            var maxDistance = 0.0
            for i in (a + 1)..<b {
                let d = distance(from: points[i], toSegment: points[a], points[b])
                if d > maxDistance { maxDistance = d; farthest = i }
            }
            if maxDistance > tolerance {
                keep[farthest] = true
                stack.append((a, farthest))
                stack.append((farthest, b))
            }
        }
        var result = points.indices.filter { keep[$0] }.map { points[$0] }
        // Traced paths return to their start; a polygon doesn't need it twice.
        if result.count > 1, result.first == result.last { result.removeLast() }
        return result
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
