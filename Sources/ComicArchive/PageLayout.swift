import Foundation
import ImageIO

/// One or two facing pages, always stored in ascending page order regardless of
/// reading direction. Direction is applied at render time only — reordering the
/// underlying pages would desynchronise the page counter and saved position.
public struct Spread: Equatable, Sendable {
    /// Indices into the comic's `pages`.
    public let pageIndices: [Int]

    public init(pageIndices: [Int]) {
        self.pageIndices = pageIndices
    }
}

/// A page's pixel dimensions, read from the image's metadata rather than by
/// decoding it, so measuring a whole comic stays cheap.
public func pagePixelSize(_ url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Double,
          let height = properties[kCGImagePropertyPixelHeight] as? Double,
          width > 0, height > 0
    else { return nil }
    return CGSize(width: width, height: height)
}

/// Whether a page is a double-page scan, which should be shown on its own.
/// Scanlation releases routinely ship the two halves of a centrefold pre-merged
/// into one landscape image.
public func isWidePage(_ size: CGSize?) -> Bool {
    guard let size else { return false }
    return size.width > size.height
}

/// The width-to-height ratio of a two-page spread of this comic, or nil when no
/// page could be measured. The reader shapes its window to this so a spread
/// fills it edge to edge.
///
/// Built on the *median* single-page shape, so one odd scan — a fold-out, a
/// cropped cover — can't skew the whole book. A comic made only of
/// double-width scans is already spread-shaped and is used as it is.
public func spreadAspectRatio(pageSizes: [CGSize?]) -> CGFloat? {
    let measured = pageSizes.compactMap { $0 }.filter { $0.width > 0 && $0.height > 0 }
    guard !measured.isEmpty else { return nil }
    let singles = measured.filter { !isWidePage($0) }
    let spreads = singles.isEmpty
        ? measured.map { $0.width / $0.height }
        : singles.map { 2 * $0.width / $0.height }
    let sorted = spreads.sorted()
    return sorted[sorted.count / 2]
}

/// The width-to-height ratio of one page, for when the reader shows a single
/// page rather than a spread. Same median as `spreadAspectRatio`, without the
/// doubling — a portrait page then fills a portrait window instead of being
/// cropped by a window built for two pages side by side.
public func singlePageAspectRatio(pageSizes: [CGSize?]) -> CGFloat? {
    let measured = pageSizes.compactMap { $0 }.filter { $0.width > 0 && $0.height > 0 }
    guard !measured.isEmpty else { return nil }
    let singles = measured.filter { !isWidePage($0) }
    let ratios = (singles.isEmpty ? measured : singles).map { $0.width / $0.height }.sorted()
    return ratios[ratios.count / 2]
}

/// Pairs ordinary pages two at a time from the first page. A page wider than
/// it is tall is a double-page scan and keeps the window to itself. The only
/// ordinary page shown alone is one with no partner left: the last page of
/// the book, or the page sitting immediately before a double-page scan.
public func buildSpreads(pageCount: Int, isWide: [Bool]) -> [Spread] {
    guard pageCount > 0 else { return [] }
    var spreads: [Spread] = []
    var index = 0
    while index < pageCount {
        let currentIsWide = isWide.indices.contains(index) && isWide[index]
        let nextIsWide = isWide.indices.contains(index + 1) && isWide[index + 1]
        if !currentIsWide, index + 1 < pageCount, !nextIsWide {
            spreads.append(Spread(pageIndices: [index, index + 1]))
            index += 2
        } else {
            spreads.append(Spread(pageIndices: [index]))
            index += 1
        }
    }
    return spreads
}

/// One page per spread, never paired — for the reader's single-page layout.
public func buildSinglePageSpreads(pageCount: Int) -> [Spread] {
    (0..<pageCount).map { Spread(pageIndices: [$0]) }
}

// MARK: - Reading direction

/// Which way the comic reads.
public enum ReadingDirection: String, CaseIterable, Sendable {
    /// Manga: page 1 sits on the right, and the left arrow advances.
    case rightToLeft
    /// Western comics: page 1 sits on the left, and the right arrow advances.
    case leftToRight

    public var flipped: ReadingDirection {
        self == .rightToLeft ? .leftToRight : .rightToLeft
    }
}

/// Which side of the window a spread sits on.
public enum ScreenSide: Sendable {
    case left
    case right
}

/// The spread parked off-screen on the given side, or nil at the ends of the book.
///
/// Reading direction decides which way the book runs past the window, so in
/// manga the spread waiting off to the *left* is the one you haven't read yet —
/// the opposite of a Western comic. Getting this backwards is easy and invisible
/// until you swipe, which is why it lives here rather than in the view.
public func neighbouringSpread(
    from index: Int,
    on side: ScreenSide,
    direction: ReadingDirection,
    spreadCount: Int
) -> Int? {
    let forwards = (side == .left) == (direction == .rightToLeft)
    let candidate = forwards ? index + 1 : index - 1
    return (0..<spreadCount).contains(candidate) ? candidate : nil
}
