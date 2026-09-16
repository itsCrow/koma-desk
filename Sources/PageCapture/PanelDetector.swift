import Foundation
import ImageIO
import CoreGraphics

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

    /// Panels as unit rects with a top-left origin, in reading order: rows
    /// top to bottom, then right-to-left for manga, left-to-right otherwise.
    public static func panels(in pageURL: URL, rightToLeft: Bool) -> [CGRect] {
        guard let source = CGImageSourceCreateWithURL(pageURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: analysisPixelSize,
              ] as CFDictionary)
        else { return [] }
        return panels(in: image, rightToLeft: rightToLeft)
    }

    public static func panels(in image: CGImage, rightToLeft: Bool) -> [CGRect] {
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
        struct Box { var x0: Int; var y0: Int; var x1: Int; var y1: Int }
        var boxes: [Box] = []
        var next: Int32 = 1
        for start in 0..<(w * h) where label[start] == 0 {
            var box = Box(x0: w, y0: h, x1: 0, y1: 0)
            stack.append(start)
            while let i = stack.popLast() {
                guard label[i] == 0 else { continue }
                label[i] = next
                let x = i % w, y = i / w
                box.x0 = min(box.x0, x); box.x1 = max(box.x1, x)
                box.y0 = min(box.y0, y); box.y1 = max(box.y1, y)
                if x > 0 { stack.append(i - 1) }
                if x < w - 1 { stack.append(i + 1) }
                if y > 0 { stack.append(i - w) }
                if y < h - 1 { stack.append(i + w) }
            }
            next += 1
            boxes.append(box)
        }

        // 3. Keep lumps big enough to be panels — not page numbers, not stray
        //    sound effects — and drop any that sit inside a bigger one.
        let minArea = Double(w * h) * 0.015
        var kept = boxes.filter {
            let bw = $0.x1 - $0.x0 + 1, bh = $0.y1 - $0.y0 + 1
            return Double(bw * bh) >= minArea && bw > w / 12 && bh > h / 16
        }
        kept.sort { ($0.x1 - $0.x0) * ($0.y1 - $0.y0) > ($1.x1 - $1.x0) * ($1.y1 - $1.y0) }
        var result: [Box] = []
        for box in kept where !result.contains(where: {
            box.x0 >= $0.x0 - 2 && box.y0 >= $0.y0 - 2 && box.x1 <= $0.x1 + 2 && box.y1 <= $0.y1 + 2
        }) {
            result.append(box)
        }

        // 4. Reading order. Boxes whose tops are within a twentieth of the
        //    page share a row.
        result.sort { a, b in
            abs(a.y0 - b.y0) > h / 20 ? a.y0 < b.y0 : (rightToLeft ? a.x0 > b.x0 : a.x0 < b.x0)
        }
        return result.map {
            CGRect(x: Double($0.x0) / Double(w), y: Double($0.y0) / Double(h),
                   width: Double($0.x1 - $0.x0 + 1) / Double(w), height: Double($0.y1 - $0.y0 + 1) / Double(h))
        }
    }
}
