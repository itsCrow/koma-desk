import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PanelsFormat
@testable import PageCapture
import ComicArchive

/// Draws a white page with black-bordered panels at the given unit rects, and
/// optionally black-bordered polygons (unit coords, top-left origin).
private func drawPage(width: Int = 700, height: Int = 1000, panels: [CGRect], polygons: [[CGPoint]] = [],
                      strokes: [CGRect] = [], bridge: CGRect? = nil) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(gray: 0, alpha: 1)
    context.setLineWidth(6)
    // Unit rects are top-left origin; CGContext is bottom-left.
    for panel in panels {
        let rect = CGRect(x: panel.minX * Double(width), y: (1 - panel.maxY) * Double(height),
                          width: panel.width * Double(width), height: panel.height * Double(height))
        context.stroke(rect.insetBy(dx: 3, dy: 3))
        // Some grey art inside, so the interior isn't bare paper.
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
    }
    for polygon in polygons {
        let path = CGMutablePath()
        path.addLines(between: polygon.map { CGPoint(x: $0.x * Double(width), y: (1 - $0.y) * Double(height)) })
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fillPath()
        context.addPath(path)
        context.strokePath()
    }
    // Thick strokes with nothing inside: a sound effect, not a panel.
    for stroke in strokes {
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: stroke.minX * Double(width), y: (1 - stroke.maxY) * Double(height),
                            width: stroke.width * Double(width), height: stroke.height * Double(height)))
    }
    if let bridge {
        // A thin line crossing a gutter, like a speech bubble's outline.
        context.setLineWidth(1)
        context.stroke(CGRect(x: bridge.minX * Double(width), y: (1 - bridge.maxY) * Double(height),
                              width: bridge.width * Double(width), height: bridge.height * Double(height)))
    }
    return context.makeImage()!
}

private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.02) -> Bool {
    abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
        && abs(a.maxX - b.maxX) < tolerance && abs(a.maxY - b.maxY) < tolerance
}

@Suite("Panel detection")
struct PanelDetectorTests {
    @Test("Three panels in a row come back in reading order, both directions")
    func rowOrder() {
        let left = CGRect(x: 0.05, y: 0.1, width: 0.25, height: 0.4)
        let middle = CGRect(x: 0.37, y: 0.1, width: 0.25, height: 0.4)
        let right = CGRect(x: 0.69, y: 0.1, width: 0.25, height: 0.4)
        let page = drawPage(panels: [middle, right, left])

        let ltr = PanelDetector.panels(in: page, rightToLeft: false)
        #expect(ltr.count == 3)
        #expect(zip(ltr, [left, middle, right]).allSatisfy { close($0, $1) })

        let rtl = PanelDetector.panels(in: page, rightToLeft: true)
        #expect(zip(rtl, [right, middle, left]).allSatisfy { close($0, $1) })
    }

    @Test("A panel spanning two rows is one panel, not two halves")
    func spanningPanel() {
        // Two small panels stacked on the left, one tall one on the right.
        let topLeft = CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.25)
        let bottomLeft = CGRect(x: 0.05, y: 0.35, width: 0.4, height: 0.25)
        let tall = CGRect(x: 0.5, y: 0.05, width: 0.45, height: 0.55)
        let found = PanelDetector.panels(in: drawPage(panels: [topLeft, bottomLeft, tall]), rightToLeft: false)
        #expect(found.count == 3)
        #expect(found.contains { close($0, tall) })
    }

    @Test("A hairline crossing a gutter doesn't fuse the panels it touches")
    func bridge() {
        let top = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.4)
        let bottom = CGRect(x: 0.05, y: 0.5, width: 0.9, height: 0.4)
        let bubble = CGRect(x: 0.3, y: 0.35, width: 0.2, height: 0.25)
        let found = PanelDetector.panels(in: drawPage(panels: [top, bottom], bridge: bubble), rightToLeft: false)
        #expect(found.count == 2)
    }

    @Test("Page numbers and stray marks are not panels")
    func ignoresSmallMarks() {
        let only = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6)
        let mark = CGRect(x: 0.45, y: 0.9, width: 0.04, height: 0.03)
        let found = PanelDetector.panels(in: drawPage(panels: [only, mark]), rightToLeft: false)
        #expect(found.count == 1)
    }

    @Test("A rectangle's outline is four corners and counts as rectangular")
    func rectangleOutline() {
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
        let found = PanelDetector.detect(in: drawPage(panels: [rect]), rightToLeft: false)
        #expect(found.count == 1)
        let panel = found[0]
        #expect(panel.isRectangular)
        #expect(panel.outline.count >= 4 && panel.outline.count <= 8)
        // Every outline point sits on the box's edge.
        for p in panel.outline {
            let onVertical = abs(p.x - panel.box.minX) < 0.01 || abs(p.x - panel.box.maxX) < 0.01
            let onHorizontal = abs(p.y - panel.box.minY) < 0.01 || abs(p.y - panel.box.maxY) < 0.01
            #expect(onVertical || onHorizontal)
        }
    }

    @Test("A trapezoid keeps its slanted edge and is not rectangular")
    func trapezoidOutline() {
        // Wide at the top, narrow at the bottom: the classic diagonal gutter.
        let trapezoid = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.7, y: 0.6), CGPoint(x: 0.3, y: 0.6)]
        let found = PanelDetector.detect(in: drawPage(panels: [], polygons: [trapezoid]), rightToLeft: false)
        #expect(found.count == 1)
        let panel = found[0]
        #expect(!panel.isRectangular)
        #expect(panel.outline.count >= 4 && panel.outline.count <= 8)
        // Shoelace area of the outline matches the trapezoid's, not its box's.
        func area(_ pts: [CGPoint]) -> Double {
            var sum = 0.0
            for i in pts.indices { let j = (i + 1) % pts.count; sum += pts[i].x * pts[j].y - pts[j].x * pts[i].y }
            return abs(sum) / 2
        }
        let expected = area(trapezoid), boxArea = panel.box.width * panel.box.height
        #expect(abs(area(panel.outline) - expected) / expected < 0.06)
        #expect(area(panel.outline) < boxArea * 0.85)
    }

    @Test("A stroke floating in the margin is not a panel")
    func fragmentDropped() {
        let panel = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.4)
        // A big L-shaped sound effect: large box, few pixels.
        let strokes = [CGRect(x: 0.1, y: 0.05, width: 0.02, height: 0.35),
                       CGRect(x: 0.1, y: 0.38, width: 0.5, height: 0.02)]
        let found = PanelDetector.detect(in: drawPage(panels: [panel], strokes: strokes), rightToLeft: false)
        #expect(found.count == 1)
        #expect(close(found[0].box, panel))
    }

    @Test("Berserk v01 page 119 has six panels, when the file is here")
    func realPage() throws {
        guard let path = ProcessInfo.processInfo.environment["PANELS_TEST_CBR"],
              path.contains("Berserk v01")
        else {
            withKnownIssue("Set PANELS_TEST_CBR to Berserk v01 to check detection on a real page.") { Issue.record("skipped") }
            return
        }
        let comic = try ComicArchive.open(URL(fileURLWithPath: path))
        let found = PanelDetector.panels(in: comic.pages[116], rightToLeft: true)
        #expect(found.count == 6)
    }
}

@Suite("Cropping and writing")
struct WriterTests {
    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    @Test("A crop is the exact pixels of the region")
    func cropExact() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("page.png")
        Self.writePNG(drawPage(width: 400, height: 600, panels: []), to: page)

        let crop = try PageCropper.crop(page, unitRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        #expect(crop.width == 200 && crop.height == 150)
        let whole = try PageCropper.crop(page, unitRect: nil)
        #expect(whole.width == 400 && whole.height == 600)
        #expect(throws: PageCropper.Failure.self) {
            _ = try PageCropper.crop(page, unitRect: CGRect(x: 2, y: 2, width: 0.1, height: 0.1))
        }
    }

    @Test("A polygon crop is transparent outside the shape and opaque inside")
    func polygonCrop() throws {
        // A mid-grey page, so opaque pixels are unmistakable.
        let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        let page = context.makeImage()!

        // A right triangle in the page's top-left quarter (unit, top-left origin).
        let triangle = [CGPoint(x: 0.0, y: 0.0), CGPoint(x: 0.5, y: 0.0), CGPoint(x: 0.0, y: 0.5)]
        let crop = try PageCropper.crop(page, polygon: triangle)
        #expect(crop.width == 200 && crop.height == 300)

        func alpha(atX x: Int, y: Int) -> UInt8 {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Draw the crop offset so pixel (x, y) — top-left origin — lands on the 1x1 context.
            ctx.draw(crop, in: CGRect(x: -x, y: -(crop.height - 1 - y), width: crop.width, height: crop.height))
            return px[3]
        }
        #expect(alpha(atX: 10, y: 10) == 255)      // inside, near the right angle
        #expect(alpha(atX: 190, y: 290) == 0)     // the far corner, outside the hypotenuse
        #expect(alpha(atX: 150, y: 20) == 255)    // inside, along the top
        #expect(alpha(atX: 150, y: 150) == 0)     // just past the hypotenuse

        #expect(throws: PageCropper.Failure.self) {
            _ = try PageCropper.crop(page, polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        }
    }

    @Test("Names follow the citation and never collide")
    func names() throws {
        let panel = CaptureRecord(kind: .panel, series: "Berserk", volume: 1, chapter: nil, pages: [117],
                                  panel: 3, region: .zero, citation: "", source: "", file: "")
        #expect(CaptureWriter.filename(for: panel) == "Berserk v01 p117 panel3.png")
        let chapter = CaptureRecord(kind: .region, series: "Dragon Ball + Super", volume: nil, chapter: 52,
                                    pages: [4, 5], panel: nil, region: .zero, citation: "", source: "", file: "")
        #expect(CaptureWriter.filename(for: chapter) == "Dragon Ball + Super ch052 p4-5 crop.png")
        let odd = CaptureRecord(kind: .page, series: "What: Is/This?", volume: nil, chapter: nil, pages: [1],
                                panel: nil, region: nil, citation: "", source: "", file: "")
        #expect(CaptureWriter.filename(for: odd) == "What- Is-This- p1 page.png")
        // A series whose name is an MS-DOS device would make a file Windows
        // cannot create, and the editor's unzip would fail saying nothing useful.
        let reserved = CaptureRecord(kind: .page, series: "AUX", volume: nil, chapter: nil, pages: [1],
                                     panel: nil, region: nil, citation: "", source: "", file: "")
        #expect(CaptureWriter.filename(for: reserved) == "AUX p1 page.png")
        let shape = CaptureRecord(kind: .shape, series: "Berserk", volume: 1, chapter: nil, pages: [117],
                                  panel: nil, region: .zero, polygon: [.zero], citation: "", source: "", file: "")
        #expect(CaptureWriter.filename(for: shape) == "Berserk v01 p117 shape.png")
    }

    @Test("Writing embeds the citation, records the manifest, and avoids overwriting")
    func writeRoundTrip() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = CaptureWriter(folder: dir.appendingPathComponent("Berserk"))
        let image = drawPage(width: 100, height: 80, panels: [])
        let record = CaptureRecord(kind: .panel, series: "Berserk", volume: 1, chapter: nil, pages: [117],
                                   panel: 3, region: PageRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                   citation: "Berserk, Vol. 1, p. 117, panel 3", source: "Berserk v01.cbz", file: "")

        let first = try writer.write(image, record: record)
        // The same shot again is the same picture: reused, not written twice.
        let second = try writer.write(image, record: record)
        #expect(first.record.file == "Berserk v01 p117 panel3.png")
        #expect(!first.reused)
        #expect(second.record.file == first.record.file)
        #expect(second.reused)

        let url = writer.folder.appendingPathComponent(first.record.file)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(png?[kCGImagePropertyPNGDescription] as? String == "Berserk, Vol. 1, p. 117, panel 3")

        let manifest = writer.loadManifest()
        #expect(manifest.count == 1)
        #expect(manifest.map(\.file) == [first.record.file])
        #expect(manifest[0].citation == record.citation)

        #expect(!writer.hasPage(for: record))
        var page = record; page.kind = .page; page.panel = nil; page.region = nil
        try writer.write(image, record: page)
        #expect(writer.hasPage(for: record))
    }

    @Test("Different shapes on one page are different pictures, and both are kept")
    func differentShapesSamePage() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = CaptureWriter(folder: dir)
        let image = drawPage(width: 60, height: 60, panels: [])

        func shape(_ points: [PagePoint]) -> CaptureRecord {
            CaptureRecord(kind: .shape, series: "Berserk", volume: 1, chapter: nil, pages: [204],
                          panel: nil, region: .zero, polygon: points, citation: "c", source: "b.cbz", file: "")
        }
        let one = try writer.write(image, record: shape([.zero, PagePoint(x: 1, y: 0), PagePoint(x: 0, y: 1)]))
        let two = try writer.write(image, record: shape([.zero, PagePoint(x: 1, y: 0), PagePoint(x: 1, y: 1)]))
        #expect(!one.reused && !two.reused)
        #expect(one.record.file != two.record.file)
        #expect(writer.loadManifest().count == 2)
    }

    @Test("A record whose file has gone is written afresh, not handed back")
    func staleRecordNotReused() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = CaptureWriter(folder: dir)
        let image = drawPage(width: 40, height: 40, panels: [])
        let record = CaptureRecord(kind: .page, series: "Berserk", volume: 1, chapter: nil, pages: [9],
                                   panel: nil, region: nil, citation: "c", source: "b.cbz", file: "")

        let first = try writer.write(image, record: record)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(first.record.file))
        #expect(writer.existingCapture(matching: record) == nil)

        let again = try writer.write(image, record: record)
        #expect(!again.reused)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(again.record.file).path))
    }

    @Test("Pruning drops records whose file has gone and keeps the rest")
    func prune() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = CaptureWriter(folder: dir)
        let image = drawPage(width: 30, height: 30, panels: [])
        func page(_ number: Int) -> CaptureRecord {
            CaptureRecord(kind: .page, series: "B", volume: 1, chapter: nil, pages: [number],
                          panel: nil, region: nil, citation: "c", source: "b.cbz", file: "")
        }
        let kept = try writer.write(image, record: page(1))
        let gone = try writer.write(image, record: page(2))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(gone.record.file))

        #expect(writer.pruneMissingRecords() == 1)
        #expect(writer.loadManifest().map(\.file) == [kept.record.file])
        #expect(writer.pruneMissingRecords() == 0)
    }
}
