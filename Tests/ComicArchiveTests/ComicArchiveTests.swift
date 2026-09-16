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

// MARK: - Spread pairing

@Suite("Spread pairing")
struct SpreadTests {
    /// Convenience: no page is a double-page scan.
    static func narrow(_ count: Int) -> [Bool] { Array(repeating: false, count: count) }

    @Test("The cover stands alone, then pages pair up")
    func coverAlone() {
        let spreads = buildSpreads(pageCount: 5, isWide: Self.narrow(5))
        #expect(spreads.map(\.pageIndices) == [[0], [1, 2], [3, 4]])
    }

    @Test("A trailing odd page finishes alone")
    func trailingOdd() {
        let spreads = buildSpreads(pageCount: 4, isWide: Self.narrow(4))
        #expect(spreads.map(\.pageIndices) == [[0], [1, 2], [3]])
    }

    @Test("A double-page scan gets the window to itself")
    func wideAlone() {
        // Page index 3 is a merged centrefold.
        var wide = Self.narrow(6)
        wide[3] = true
        let spreads = buildSpreads(pageCount: 6, isWide: wide)
        // Index 2 can't pair with the wide page, so it falls solo too.
        #expect(spreads.map(\.pageIndices) == [[0], [1, 2], [3], [4, 5]])
    }

    @Test("The page before a double-page scan is not paired with it")
    func pageBeforeWide() {
        var wide = Self.narrow(5)
        wide[2] = true
        let spreads = buildSpreads(pageCount: 5, isWide: wide)
        #expect(spreads.map(\.pageIndices) == [[0], [1], [2], [3, 4]])
    }

    @Test("Consecutive double-page scans each stand alone")
    func consecutiveWide() {
        var wide = Self.narrow(4)
        wide[1] = true
        wide[2] = true
        let spreads = buildSpreads(pageCount: 4, isWide: wide)
        #expect(spreads.map(\.pageIndices) == [[0], [1], [2], [3]])
    }

    @Test("A one-page comic is a single spread, and an empty one has none")
    func degenerate() {
        #expect(buildSpreads(pageCount: 1, isWide: [false]).map(\.pageIndices) == [[0]])
        #expect(buildSpreads(pageCount: 0, isWide: []).isEmpty)
    }

    @Test("Mismatched isWide array doesn't trip the bounds checks")
    func shortFlags() {
        // Defensive: the flags come from a separate scan and could lag behind.
        let spreads = buildSpreads(pageCount: 4, isWide: [])
        #expect(spreads.map(\.pageIndices) == [[0], [1, 2], [3]])
    }

    @Test("Real comic layout: Berserk v01, 219 pages with 9 merged centrefolds")
    func berserkVolumeOne() {
        // Measured from ~/Downloads/Berserk v01 (2003) (Digital) (danke-Empire).cbz:
        // 219 pages, nine 3620x2560 centrefolds at these indices.
        var wide = Self.narrow(219)
        for index in [8, 21, 58, 83, 94, 127, 150, 163, 180] { wide[index] = true }

        let spreads = buildSpreads(pageCount: 219, isWide: wide)

        #expect(spreads.count == 115)
        #expect(spreads[0].pageIndices == [0])
        // Page index 7 is orphaned by the centrefold at 8.
        #expect(spreads[4].pageIndices == [7])
        #expect(spreads[5].pageIndices == [8])
        #expect(spreads.last?.pageIndices == [217, 218])
        // Every page appears exactly once, in order — no page lost or repeated.
        #expect(spreads.flatMap(\.pageIndices) == Array(0..<219))
        // Each centrefold is alone.
        for index in [8, 21, 58, 83, 94, 127, 150, 163, 180] {
            #expect(spreads.contains { $0.pageIndices == [index] })
        }
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

// MARK: - Spread shape

@Suite("Spread aspect ratio")
struct SpreadAspectTests {
    static let page = CGSize(width: 1810, height: 2560)
    static let centrefold = CGSize(width: 3620, height: 2560)

    @Test("Two portrait pages side by side")
    func twoPages() throws {
        let ratio = try #require(spreadAspectRatio(pageSizes: [Self.page, Self.page, Self.page]))
        #expect(abs(ratio - 2 * 1810 / 2560) < 0.0001)
    }

    @Test("A merged centrefold doesn't widen the spread; it already is one")
    func centrefoldIgnored() throws {
        let ratio = try #require(spreadAspectRatio(pageSizes: [Self.page, Self.centrefold, Self.page]))
        #expect(abs(ratio - 2 * 1810 / 2560) < 0.0001)
    }

    @Test("A comic that is nothing but double-width scans keeps its own shape")
    func allCentrefolds() throws {
        let ratio = try #require(spreadAspectRatio(pageSizes: [Self.centrefold, Self.centrefold]))
        #expect(abs(ratio - 3620 / 2560) < 0.0001)
    }

    @Test("One oddly cropped page can't skew the book")
    func medianResistsOutliers() throws {
        let narrow = CGSize(width: 900, height: 2560)
        let ratio = try #require(spreadAspectRatio(pageSizes: [narrow, Self.page, Self.page, Self.page, Self.page]))
        #expect(abs(ratio - 2 * 1810 / 2560) < 0.0001)
    }

    @Test("Unmeasurable pages are skipped, and no pages means no shape")
    func degenerate() throws {
        let ratio = try #require(spreadAspectRatio(pageSizes: [nil, Self.page, nil]))
        #expect(abs(ratio - 2 * 1810 / 2560) < 0.0001)
        #expect(spreadAspectRatio(pageSizes: []) == nil)
        #expect(spreadAspectRatio(pageSizes: [nil, nil]) == nil)
    }
}

// MARK: - Neighbouring spreads

@Suite("Off-screen neighbours")
struct NeighbourTests {
    @Test("In a Western comic the previous spread waits on the left")
    func leftToRight() {
        #expect(neighbouringSpread(from: 5, on: .left,
                                   direction: .leftToRight, spreadCount: 10) == 4)
        #expect(neighbouringSpread(from: 5, on: .right,
                                   direction: .leftToRight, spreadCount: 10) == 6)
    }

    @Test("In manga the sides swap: the next spread waits on the left")
    func rightToLeft() {
        // The flip that's easy to get backwards and invisible until you swipe.
        #expect(neighbouringSpread(from: 5, on: .left,
                                   direction: .rightToLeft, spreadCount: 10) == 6)
        #expect(neighbouringSpread(from: 5, on: .right,
                                   direction: .rightToLeft, spreadCount: 10) == 4)
    }

    @Test("There is nothing beyond either end of the book")
    func ends() {
        // First spread, whichever way the book runs.
        #expect(neighbouringSpread(from: 0, on: .left,
                                   direction: .leftToRight, spreadCount: 3) == nil)
        #expect(neighbouringSpread(from: 0, on: .right,
                                   direction: .rightToLeft, spreadCount: 3) == nil)
        // Last spread.
        #expect(neighbouringSpread(from: 2, on: .right,
                                   direction: .leftToRight, spreadCount: 3) == nil)
        #expect(neighbouringSpread(from: 2, on: .left,
                                   direction: .rightToLeft, spreadCount: 3) == nil)
    }

    @Test("A comic with no spreads has no neighbours")
    func empty() {
        #expect(neighbouringSpread(from: 0, on: .left,
                                   direction: .leftToRight, spreadCount: 0) == nil)
        #expect(neighbouringSpread(from: 0, on: .right,
                                   direction: .leftToRight, spreadCount: 0) == nil)
    }

    @Test("Flipping direction swaps which spread is on which side")
    func flipIsSymmetric() {
        for index in 1..<9 {
            for direction in ReadingDirection.allCases {
                #expect(neighbouringSpread(from: index, on: .left,
                                           direction: direction, spreadCount: 10)
                        == neighbouringSpread(from: index, on: .right,
                                              direction: direction.flipped, spreadCount: 10))
            }
        }
    }
}

// MARK: - Cache pruning

@Suite("Cache pruning")
struct PruneTests {
    /// Builds a cache directory of roughly `kilobytes`, stamped as read at `age`
    /// seconds ago.
    static func makeExtraction(
        _ name: String, kilobytes: Int, agedSeconds: Int, in root: URL
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: kilobytes * 1024)
            .write(to: directory.appendingPathComponent("page.bin"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-Double(agedSeconds))],
            ofItemAtPath: directory.path
        )
        return directory
    }

    @Test("Least recently read comics are dropped first")
    func dropsOldest() throws {
        let root = try OpenTests.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = try Self.makeExtraction("fresh", kilobytes: 100, agedSeconds: 10, in: root)
        let middle = try Self.makeExtraction("middle", kilobytes: 100, agedSeconds: 100, in: root)
        let stale = try Self.makeExtraction("stale", kilobytes: 100, agedSeconds: 1000, in: root)

        // Room for roughly two of the three.
        ComicArchive.pruneCache(in: root, budget: 250 * 1024)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("A comic under the budget is never touched")
    func keepsEverythingUnderBudget() throws {
        let root = try OpenTests.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let only = try Self.makeExtraction("only", kilobytes: 100, agedSeconds: 10, in: root)
        ComicArchive.pruneCache(in: root, budget: 4 << 20)
        #expect(FileManager.default.fileExists(atPath: only.path))
    }

    @Test("The most recent comic survives even if it alone exceeds the budget")
    func keepsNewestRegardless() throws {
        let root = try OpenTests.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        // Otherwise the comic you just opened could be deleted out from under you.
        let huge = try Self.makeExtraction("huge", kilobytes: 500, agedSeconds: 1, in: root)
        ComicArchive.pruneCache(in: root, budget: 1024)
        #expect(FileManager.default.fileExists(atPath: huge.path))
    }

    @Test("A missing cache directory is not an error")
    func missingRoot() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelsTests-absent-\(UUID().uuidString)")
        ComicArchive.pruneCache(in: absent, budget: 1024)
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

    @Test("A zero-byte entry is skipped without truncating the comic")
    func emptyEntry() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let staging = scratch.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.writePNG(width: 100, height: 200, to: staging.appendingPathComponent("1.png"))
        // A stray empty placeholder between two real pages. This must not end
        // the extraction — doing so would silently drop page 3 and cry damage.
        try Data().write(to: staging.appendingPathComponent("2.png"))
        try Self.writePNG(width: 120, height: 200, to: staging.appendingPathComponent("3.png"))

        let cbz = scratch.appendingPathComponent("Holey.cbz")
        #expect(try Self.run("/usr/bin/zip", ["-q", "-r", cbz.path, "."], in: staging) == 0)

        let comic = try ComicArchive.open(cbz)
        #expect(comic.pageCount == 2)
        #expect(comic.warning == nil)
        #expect(comic.pages.map(\.lastPathComponent) == ["1.png", "3.png"])
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

// MARK: - Identity and citation

@Suite("Comic identity from filenames")
struct IdentityTests {
    private func identity(_ path: String) -> ComicIdentity {
        ComicIdentity(fileURL: URL(fileURLWithPath: path))
    }

    @Test("A scan-group volume: series, volume and year, tags dropped")
    func volumeRelease() {
        let id = identity("/x/Berserk v01 (2003) (Digital) (danke-Empire).cbz")
        #expect(id.series == "Berserk")
        #expect(id.volume == 1)
        #expect(id.year == 2003)
        #expect(id.chapter == nil)
    }

    @Test("A chapter file takes its series from the folder, skipping the arc")
    func chapterFromFolder() {
        let id = identity("/Users/x/Downloads/Dragon Ball + Super [Complete Manga]/18 Galactic Patrol Prisoner Arc/Chapter 052 - Goku and Vegeta's Training.cbr")
        #expect(id.series == "Dragon Ball + Super")
        #expect(id.chapter == 52)
        #expect(id.chapterTitle == "Goku and Vegeta's Training")
        #expect(id.volume == nil)
    }

    @Test("Other common shapes")
    func otherShapes() {
        #expect(identity("/x/One Piece Vol. 105.cbz").volume == 105)
        #expect(identity("/x/One Piece Vol. 105.cbz").series == "One Piece")
        #expect(identity("/x/One Piece c1044 - Title.cbz").chapter == 1044)
        #expect(identity("/x/One Piece c1044 - Title.cbz").chapterTitle == "Title")
        #expect(identity("/x/Akira 03.cbz").volume == 3)
        #expect(identity("/x/Akira 03.cbz").series == "Akira")
    }

    @Test("An unparseable name stands as the title, and nothing else is invented")
    func fallback() {
        let id = identity("/x/Some Weird Name.cbz")
        #expect(id.series == "Some Weird Name")
        #expect(id.volume == nil && id.chapter == nil && id.year == nil)
    }

    @Test("Citations: volume, chapter, single page, spread")
    func citations() {
        #expect(ComicIdentity(series: "Berserk", volume: 1).citation(pages: [117]) == "Berserk, Vol. 1, p. 117")
        #expect(ComicIdentity(series: "Berserk", volume: 1).citation(pages: [117, 116]) == "Berserk, Vol. 1, pp. 116–117")
        #expect(ComicIdentity(series: "Dragon Ball + Super", chapter: 52).citation(pages: [4]) == "Dragon Ball + Super, Ch. 52, p. 4")
        #expect(ComicIdentity(series: "Odd").citation(pages: []) == "Odd")
    }
}
