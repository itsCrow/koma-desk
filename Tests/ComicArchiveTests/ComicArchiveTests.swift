import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import ComicArchive

// MARK: - Page ordering

@Suite("Natural page ordering")
struct PageSortTests {
    @Test("Unpadded numbers sort as numbers, not text")
    func unpadded() {
        // The failure this guards against: plain sorting gives 1, 10, 11, 2.
        #expect(sortedNaturally(["2.jpg", "10.jpg", "1.jpg", "11.jpg"])
                == ["1.jpg", "2.jpg", "10.jpg", "11.jpg"])
    }

    @Test("Zero-padded numbers keep their order")
    func padded() {
        #expect(sortedNaturally(["010.jpg", "002.jpg", "001.jpg"])
                == ["001.jpg", "002.jpg", "010.jpg"])
    }

    @Test("Mixed prefixes and extensions")
    func prefixed() {
        #expect(sortedNaturally(["page10.png", "p1.jpg", "page2.png"])
                == ["p1.jpg", "page2.png", "page10.png"])
    }

    @Test("Nested folders stay grouped in order")
    func nested() {
        #expect(sortedNaturally(["ch2/1.jpg", "ch10/1.jpg", "ch1/2.jpg", "ch1/10.jpg"])
                == ["ch1/2.jpg", "ch1/10.jpg", "ch2/1.jpg", "ch10/1.jpg"])
    }
}

// MARK: - Entry filtering

@Suite("Archive entry sanitising")
struct SanitizeTests {
    @Test("Keeps ordinary image entries")
    func keepsImages() {
        #expect(ComicArchive.sanitize("001.jpg") == "001.jpg")
        #expect(ComicArchive.sanitize("Chapter 1/002.PNG") == "Chapter 1/002.PNG")
    }

    @Test("Drops non-image entries")
    func dropsNonImages() {
        #expect(ComicArchive.sanitize("ComicInfo.xml") == nil)
        #expect(ComicArchive.sanitize("readme.txt") == nil)
        #expect(ComicArchive.sanitize("folder") == nil)
    }

    @Test("Drops macOS and Windows junk")
    func dropsJunk() {
        #expect(ComicArchive.sanitize("__MACOSX/._001.jpg") == nil)
        #expect(ComicArchive.sanitize(".DS_Store") == nil)
        #expect(ComicArchive.sanitize("._001.jpg") == nil)
        #expect(ComicArchive.sanitize("Thumbs.db") == nil)
    }

    @Test("Rejects path traversal and absolute paths")
    func rejectsTraversal() {
        // A crafted archive must not be able to write outside the cache folder.
        #expect(ComicArchive.sanitize("../evil.jpg") == nil)
        #expect(ComicArchive.sanitize("a/../../evil.jpg") == nil)
        #expect(ComicArchive.sanitize("/tmp/evil.jpg") == nil)
        #expect(ComicArchive.sanitize("..\\evil.jpg") == nil)
    }

    @Test("Normalises Windows separators")
    func windowsSeparators() {
        #expect(ComicArchive.sanitize("Chapter 1\\003.jpg") == "Chapter 1/003.jpg")
    }
}

// MARK: - End-to-end extraction

@Suite("Opening archives", .serialized)
struct OpenTests {
    /// Writes a solid-colour PNG of the given size. Distinct sizes let a test
    /// prove which page landed where.
    static func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func pixelSize(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    static func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("A .cbz round-trips to ordered pages")
    func cbzRoundTrip() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let staging = scratch.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Deliberately unpadded so ordering is actually exercised, and each page
        // gets a unique width so we can identify it after extraction.
        let widths = [100, 110, 120, 130]
        for (index, width) in zip([1, 2, 10, 11], widths) {
            try Self.writePNG(width: width, height: 200,
                              to: staging.appendingPathComponent("\(index).png"))
        }
        // Junk that must not become a page.
        try "not an image".write(to: staging.appendingPathComponent("ComicInfo.xml"),
                                 atomically: true, encoding: .utf8)

        let cbz = scratch.appendingPathComponent("Test.cbz")
        let status = try Self.run("/usr/bin/zip", ["-q", "-r", cbz.path, "."], in: staging)
        #expect(status == 0)

        let comic = try ComicArchive.open(cbz)
        #expect(comic.pageCount == 4)
        #expect(comic.warning == nil)
        #expect(comic.title == "Test")
        #expect(comic.pages.map(\.lastPathComponent) == ["1.png", "2.png", "10.png", "11.png"])
        for (page, expectedWidth) in zip(comic.pages, widths) {
            #expect(Self.pixelSize(of: page)?.0 == expectedWidth)
        }
    }

    @Test("Reopening the same file reuses the extraction cache")
    func cacheReuse() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let staging = scratch.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.writePNG(width: 100, height: 200, to: staging.appendingPathComponent("1.png"))

        let cbz = scratch.appendingPathComponent("Cached.cbz")
        #expect(try Self.run("/usr/bin/zip", ["-q", "-r", cbz.path, "."], in: staging) == 0)

        let first = try ComicArchive.open(cbz)
        let second = try ComicArchive.open(cbz)
        #expect(first.pages == second.pages)
    }

    @Test("A file of zeroes reports an unreadable archive rather than crashing")
    func zeroedFile() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Mirrors the partially-downloaded .cbr files in ~/Downloads, whose
        // headers are entirely zero bytes.
        let broken = scratch.appendingPathComponent("Broken.cbr")
        try Data(repeating: 0, count: 64 * 1024).write(to: broken)

        #expect(throws: ArchiveError.self) {
            _ = try ComicArchive.open(broken)
        }
    }

    @Test("An archive with no images reports no pages")
    func noImages() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let staging = scratch.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "nothing here".write(to: staging.appendingPathComponent("notes.txt"),
                                 atomically: true, encoding: .utf8)

        let cbz = scratch.appendingPathComponent("Empty.cbz")
        #expect(try Self.run("/usr/bin/zip", ["-q", "-r", cbz.path, "."], in: staging) == 0)

        #expect(throws: ArchiveError.self) {
            _ = try ComicArchive.open(cbz)
        }
    }

    @Test("A truncated archive still yields the pages that survived")
    func truncatedArchive() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let staging = scratch.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for index in 1...6 {
            try Self.writePNG(width: 400, height: 600,
                              to: staging.appendingPathComponent("\(index).png"))
        }
        let full = scratch.appendingPathComponent("Full.cbz")
        // Stored, not deflated, so cutting the file cleanly severs later entries.
        #expect(try Self.run("/usr/bin/zip", ["-q", "-r", "-0", full.path, "."], in: staging) == 0)

        let data = try Data(contentsOf: full)
        let truncated = scratch.appendingPathComponent("Truncated.cbz")
        try data.prefix(data.count / 2).write(to: truncated)

        // Either some pages survive with a warning, or none do and we throw —
        // both are acceptable. What must never happen is a crash or a silent
        // empty success.
        do {
            let comic = try ComicArchive.open(truncated)
            #expect(comic.pageCount > 0)
            #expect(comic.pageCount < 6)
            #expect(comic.warning != nil)
        } catch is ArchiveError {
            // Acceptable: nothing was recoverable.
        }
    }

    @Test("Reads a real .cbr when one is supplied via PANELS_TEST_CBR")
    func realRAR() throws {
        guard let path = ProcessInfo.processInfo.environment["PANELS_TEST_CBR"] else {
            withKnownIssue("Set PANELS_TEST_CBR to a valid .cbr to exercise the RAR reader.") {
                Issue.record("skipped")
            }
            return
        }
        let comic = try ComicArchive.open(URL(fileURLWithPath: path))
        #expect(comic.pageCount > 0)
        #expect(comic.warning == nil)
        for page in comic.pages {
            #expect(Self.pixelSize(of: page) != nil, "page \(page.lastPathComponent) did not decode")
        }
    }
}
