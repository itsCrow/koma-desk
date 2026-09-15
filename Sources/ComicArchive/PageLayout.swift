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

/// Whether a page is a double-page scan, which should be shown on its own.
///
/// Reads pixel dimensions from the image's metadata rather than decoding it, so
/// scanning a whole comic stays cheap. Scanlation releases routinely ship the
/// two halves of a centrefold pre-merged into one landscape image.
public func isWidePage(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Double,
          let height = properties[kCGImagePropertyPixelHeight] as? Double,
          height > 0
    else { return false }
    return width > height
}

/// Pairs pages the way a physical comic falls: the cover stands alone, then
/// pages face each other two at a time. A page that is wider than it is tall is
/// a double-page scan and gets the window to itself — and so does the page
/// before it, since there is nothing left to face.
public func buildSpreads(pageCount: Int, isWide: [Bool]) -> [Spread] {
    guard pageCount > 0 else { return [] }
    var spreads: [Spread] = [Spread(pageIndices: [0])]
    var index = 1
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
