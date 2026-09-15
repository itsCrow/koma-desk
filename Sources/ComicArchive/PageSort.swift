import Foundation

/// Orders page filenames the way a human would.
///
/// Plain lexicographic ordering puts `10.jpg` before `2.jpg`, which shuffles the
/// comic. `.numeric` compares runs of digits as numbers, so `1, 2, 10, 11` come
/// out in that order regardless of zero-padding.
public func naturalPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    switch lhs.compare(rhs, options: [.numeric, .caseInsensitive]) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhs < rhs  // stable tiebreak for case-only differences
    @unknown default: return lhs < rhs
    }
}

/// Sorts archive-relative paths into reading order.
public func sortedNaturally(_ paths: [String]) -> [String] {
    paths.sorted(by: naturalPrecedes)
}
