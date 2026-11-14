import Foundation

/// A point on a page: unit coordinates, so 0…1 across and 0…1 down,
/// independent of how big the scan is.
///
/// This exists rather than `CGPoint` because these values are *written to
/// disk*. Apple's Foundation encodes a `CGPoint` as a bare two-element array
/// and a `CGRect` as a nested pair of them — `[[0.38, 0.72], [0.27, 0.22]]` —
/// which says nothing about which number is which, and is a guess for anything
/// reading a project that wasn't written in Swift. Named keys cost a few bytes
/// and make the format readable by whatever comes next.
///
/// The origin is top-left unless the type using it says otherwise.
public struct PagePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PagePoint(x: 0, y: 0)
}

/// A rectangle on a page, in the same unit coordinates as `PagePoint`.
public struct PageRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = PageRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { min(x, x + width) }
    public var minY: Double { min(y, y + height) }
    public var maxX: Double { max(x, x + width) }
    public var maxY: Double { max(y, y + height) }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The smallest rectangle holding every one of `points` — the bounding box
    /// of a drawn shape.
    public init?(bounding points: [PagePoint]) {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func contains(_ point: PagePoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// The four corners, clockwise from the top-left.
    public var corners: [PagePoint] {
        [PagePoint(x: minX, y: minY), PagePoint(x: maxX, y: minY),
         PagePoint(x: maxX, y: maxY), PagePoint(x: minX, y: maxY)]
    }
}

// MARK: - Core Graphics

// Drawing and cropping speak CGRect, so the bridge is here rather than at
// every call site. It is the only Apple-only code in this target, and a
// non-Apple build simply doesn't compile it.
#if canImport(CoreGraphics)
import CoreGraphics

extension PagePoint {
    public init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

extension PageRect {
    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension Array where Element == PagePoint {
    public var cgPoints: [CGPoint] { map(\.cgPoint) }
}

extension Array where Element == CGPoint {
    public var pagePoints: [PagePoint] { map(PagePoint.init) }
}
#endif
