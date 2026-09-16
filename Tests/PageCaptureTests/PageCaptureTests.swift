import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PageCapture
import ComicArchive

/// Draws a white page with black-bordered panels at the given unit rects.
private func drawPage(width: Int = 700, height: Int = 1000, panels: [CGRect], bridge: CGRect? = nil) -> CGImage {
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
    }

    @Test("Writing embeds the citation, records the manifest, and avoids overwriting")
    func writeRoundTrip() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = CaptureWriter(folder: dir.appendingPathComponent("Berserk"))
        let image = drawPage(width: 100, height: 80, panels: [])
        let record = CaptureRecord(kind: .panel, series: "Berserk", volume: 1, chapter: nil, pages: [117],
                                   panel: 3, region: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                   citation: "Berserk, Vol. 1, p. 117, panel 3", source: "Berserk v01.cbz", file: "")

        let first = try writer.write(image, record: record)
        let second = try writer.write(image, record: record)
        #expect(first.file == "Berserk v01 p117 panel3.png")
        #expect(second.file == "Berserk v01 p117 panel3-2.png")

        let url = writer.folder.appendingPathComponent(first.file)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(png?[kCGImagePropertyPNGDescription] as? String == "Berserk, Vol. 1, p. 117, panel 3")

        let manifest = writer.loadManifest()
        #expect(manifest.count == 2)
        #expect(manifest.map(\.file) == [first.file, second.file])
        #expect(manifest[0].citation == record.citation)

        #expect(!writer.hasPage(for: record))
        var page = record; page.kind = .page; page.panel = nil; page.region = nil
        try writer.write(image, record: page)
        #expect(writer.hasPage(for: record))
    }
}
