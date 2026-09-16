import Foundation
import PanelsFormat

/// One line of lettering read off a page.
public struct TextLine: Codable, Sendable, Equatable {
    public let text: String
    /// Where on the page, as Vision reports it: a unit rect with its origin at
    /// the **bottom-left** of the image, unlike everything else here. Stored
    /// that way, so any other text recogniser has to match the convention or
    /// every saved index shifts.
    public let box: PageRect

    public init(text: String, box: PageRect) {
        self.text = text
        self.box = box
    }
}

/// Everything read off one page.
public struct PageText: Codable, Sendable, Equatable {
    public let lines: [TextLine]

    public init(lines: [TextLine]) {
        self.lines = lines
    }
}

/// The text of a whole comic, page by page. A page that hasn't been read yet is
/// nil, so an index can be saved half-done and picked up again later.
public struct PageTextIndex: Codable, Sendable, Equatable {
    public var pages: [PageText?]

    public init(pageCount: Int) {
        pages = Array(repeating: nil, count: pageCount)
    }

    public var pageCount: Int { pages.count }
    public var indexedPages: Int { pages.lazy.filter { $0 != nil }.count }
    public var isComplete: Bool { pages.allSatisfy { $0 != nil } }

    /// Pages still to be read, in order.
    public var unreadPages: [Int] {
        pages.indices.filter { pages[$0] == nil }
    }
}
