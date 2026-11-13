import Testing
import Foundation
@testable import ComicLibrary

@Suite("Merging a refreshed chapter list")
struct RemoteSeriesMergeTests {
    private func chapter(_ number: Int, title: String = "") -> LibraryItem {
        let url = URL(string: "https://weebcentral.com/chapters/\(number)")!
        return LibraryItem(
            remote: .site(site: "weebcentral", chapterURL: url),
            series: "One Piece", volume: nil, chapter: number, title: title, arc: nil, displayURL: url
        )
    }

    @Test("A chapter at the end of the source list is a new release")
    func appendsANewRelease() {
        let existing = [chapter(1), chapter(2)]
        let incoming = [chapter(1), chapter(2), chapter(3)]

        let merged = RemoteSeriesMerge.merge(existing: existing, incoming: incoming)

        #expect(merged.items.map(\.chapter) == [1, 2, 3])
        #expect(merged.newItems.map(\.chapter) == [3])
        #expect(merged.items[0].id == existing[0].id)
        #expect(merged.items[1].id == existing[1].id)
    }

    @Test("A chapter that appears between two already saved lands between them")
    func insertsInReadingOrder() {
        let existing = [chapter(1), chapter(3)]
        let incoming = [chapter(1), chapter(2), chapter(3)]

        let merged = RemoteSeriesMerge.merge(existing: existing, incoming: incoming)

        #expect(merged.items.map(\.chapter) == [1, 2, 3])
        #expect(merged.newItems.map(\.chapter) == [2])
        #expect(merged.items[0].id == existing[0].id)
        #expect(merged.items[2].id == existing[1].id)
    }

    @Test("A chapter already saved keeps its item, title included")
    func keepsTheSavedItem() {
        let saved = chapter(1, title: "Romance Dawn")
        let incoming = chapter(1, title: "Something Else")

        let merged = RemoteSeriesMerge.merge(existing: [saved], incoming: [incoming])

        #expect(merged.newItems.isEmpty)
        #expect(merged.items[0].id == saved.id)
        #expect(merged.items[0].title == "Romance Dawn")
    }

    @Test("A chapter the source left out stays next to its neighbors")
    func keepsOmittedChapters() {
        let existing = [chapter(1), chapter(2), chapter(4)]
        let incoming = [chapter(1), chapter(4)]

        let merged = RemoteSeriesMerge.merge(existing: existing, incoming: incoming)

        #expect(merged.items.map(\.chapter) == [1, 2, 4])
        #expect(merged.newItems.isEmpty)
        #expect(merged.items.map(\.id) == [existing[0].id, existing[1].id, existing[2].id])
    }

    @Test("An empty reply leaves the saved chapters where they are")
    func emptyReplyKeepsTheSavedList() {
        let existing = [chapter(2), chapter(1)]

        let merged = RemoteSeriesMerge.merge(existing: existing, incoming: [])

        #expect(merged.items.map(\.id) == existing.map(\.id))
        #expect(merged.newItems.isEmpty)
    }

    @Test("The same chapter listed twice is saved once")
    func dropsDuplicateIncoming() {
        let incoming = [chapter(1), chapter(1), chapter(2)]

        let merged = RemoteSeriesMerge.merge(existing: [], incoming: incoming)

        #expect(merged.items.map(\.chapter) == [1, 2])
        #expect(merged.newItems.map(\.chapter) == [1, 2])
    }
}
