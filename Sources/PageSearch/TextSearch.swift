import Foundation

/// One line on one page that contains the query.
public struct SearchHit: Equatable, Sendable {
    /// Zero-based page index.
    public let page: Int
    public let line: TextLine

    public init(page: Int, line: TextLine) {
        self.page = page
        self.line = line
    }
}

/// Every line in the comic containing `query`, in page order.
///
/// Case and accents don't matter, and neither does where in the line the word
/// falls — OCR of lettering is uneven enough that anything stricter would miss
/// real hits. One hit per line, however many times the word appears in it.
public func search(_ query: String, in index: PageTextIndex) -> [SearchHit] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }

    var hits: [SearchHit] = []
    for (page, text) in index.pages.enumerated() {
        guard let text else { continue }
        for line in text.lines
        where line.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            hits.append(SearchHit(page: page, line: line))
        }
    }
    return hits
}
