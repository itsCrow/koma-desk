import Foundation

/// Fitting a freshly resolved chapter list into the chapters already saved
/// for a series. The source's order is the reading order. A chapter already
/// here keeps the item the library has (its id, so a reading position still
/// points at it). A chapter the source didn't mention this time stays too —
/// a short or failed-looking reply must not throw away chapters already
/// downloaded.
public enum RemoteSeriesMerge {
    public struct Result: Equatable, Sendable {
        public var items: [LibraryItem]
        public var newItems: [LibraryItem]

        public init(items: [LibraryItem], newItems: [LibraryItem]) {
            self.items = items
            self.newItems = newItems
        }
    }

    public static func merge(existing: [LibraryItem], incoming: [LibraryItem]) -> Result {
        // Nothing came back. Keep the saved list exactly, rather than
        // rebuilding it and risking a shuffle.
        guard !incoming.isEmpty else {
            return Result(items: existing, newItems: [])
        }

        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [LibraryItem] = []
        var newItems: [LibraryItem] = []
        var seen = Set<String>()

        for item in incoming {
            guard seen.insert(item.id).inserted else { continue }
            if let known = existingByID[item.id] {
                items.append(known)
            } else {
                items.append(item)
                newItems.append(item)
            }
        }

        let carried = existing.filter { !seen.contains($0.id) }
        for orphan in carried {
            let index = insertionIndex(for: orphan, in: items)
            items.insert(orphan, at: index)
            seen.insert(orphan.id)
        }

        return Result(items: items, newItems: newItems)
    }

    /// Where a chapter the source omitted belongs: before the first saved
    /// chapter with a higher number, so it stays between its neighbors.
    private static func insertionIndex(for orphan: LibraryItem, in items: [LibraryItem]) -> Int {
        guard let number = orphan.chapter ?? orphan.volume else { return items.endIndex }
        return items.firstIndex { item in
            let other = item.chapter ?? item.volume ?? Int.max
            return other > number
        } ?? items.endIndex
    }
}
