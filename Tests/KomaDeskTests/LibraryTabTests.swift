import Testing
import Foundation
@testable import KomaDesk
import ComicLibrary

@Suite("Library tab")
struct LibraryTabTests {
    private func series(_ name: String) -> Series { Series(name: name, items: []) }

    @Test("Recently Read puts what's been read first, most recent first, then the rest by name")
    func recent() {
        let all = ["One Piece", "Berserk", "Dragon Ball", "Akira", "Monster"].map(series)
        let sorted = LibrarySort.recent.sorted(all, recent: ["Dragon Ball", "Berserk", "Gone From Library"])
        #expect(sorted.map(\.name) == ["Dragon Ball", "Berserk", "Akira", "Monster", "One Piece"])
    }

    @Test("Name sorts the way Finder does")
    func name() {
        let sorted = LibrarySort.name.sorted(["vol 10", "Vol 2", "Akira"].map(series), recent: ["vol 10"])
        #expect(sorted.map(\.name) == ["Akira", "Vol 2", "vol 10"])
    }

    @Test("An item is unread, being read, or read — and nearly finished counts as read")
    func readState() {
        #expect(ItemReadState.of(progress: nil, started: false) == .unread)
        #expect(ItemReadState.of(progress: 0.4, started: true) == .reading(0.4))
        #expect(ItemReadState.of(progress: nil, started: true) == .reading(0))
        #expect(ItemReadState.of(progress: 0.95, started: true) == .read)
        #expect(ItemReadState.of(progress: 1, started: true) == .read)
    }

    @Test("Progress through a series counts the items before this one and how far into it")
    func seriesFraction() {
        #expect(Library.seriesFraction(index: 0, itemProgress: nil, count: 10) == 0)
        #expect(Library.seriesFraction(index: 4, itemProgress: 0.5, count: 10) == 0.45)
        #expect(Library.seriesFraction(index: 9, itemProgress: 1, count: 10) == 1)
        #expect(Library.seriesFraction(index: 3, itemProgress: nil, count: 0) == 0)
    }
}
