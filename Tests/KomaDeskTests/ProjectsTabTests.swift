import Testing
import Foundation
@testable import KomaDesk
import KomaProject

@Suite("Projects tab")
@MainActor
struct ProjectsTabTests {
    private func summary(_ name: String, opened: TimeInterval? = nil, edited: TimeInterval? = nil) -> ProjectSummary {
        ProjectSummary(url: URL(fileURLWithPath: "/tmp/\(name).komadesk"), name: name, series: ["Berserk"],
                       items: [], citationCount: 0, edited: edited.map(Date.init(timeIntervalSince1970:)),
                       lastOpened: opened.map(Date.init(timeIntervalSince1970:)), picture: nil, isElsewhere: false)
    }

    @Test("Recent puts the last worked on first, opened before saved, and breaks ties by name")
    func recent() {
        let a = summary("Alpha", edited: 100)
        let b = summary("Bravo", opened: 300)
        let c = summary("Charlie", opened: 50, edited: 500)   // opened counts, not saved
        let d = summary("Delta", edited: 100)
        #expect(ProjectsSort.recent.sorted([a, c, d, b], words: [:]).map(\.name) == ["Bravo", "Alpha", "Delta", "Charlie"])
    }

    @Test("Name sorts the way Finder does, numbers and all")
    func name() {
        let names = ["Part 10", "part 2", "Eclipse"].map { summary($0) }
        #expect(ProjectsSort.name.sorted(names, words: [:]).map(\.name) == ["Eclipse", "part 2", "Part 10"])
    }

    @Test("Words puts the longest first, and anything not yet counted last")
    func words() {
        let a = summary("Alpha"), b = summary("Bravo"), c = summary("Charlie"), d = summary("Delta")
        let counts = [a.url: 200, b.url: 900, d.url: 200]
        #expect(ProjectsSort.words.sorted([c, a, d, b], words: counts).map(\.name) == ["Bravo", "Alpha", "Delta", "Charlie"])
    }

    @Test("A project about several series is listed once, under all of them together")
    func multiSeriesGrouping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KomaDeskTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = ScratchDefaults()
        defer { settings.remove() }
        let library = ProjectLibrary(root: root, defaults: settings.defaults)
        _ = try library.create(named: "Swords", series: ["Berserk", "Vagabond"])
        _ = try library.create(named: "Eclipse", series: ["Berserk"])

        let groups = library.groupedBySeries
        #expect(Set(groups.map(\.series)) == ["Berserk", "Berserk + Vagabond"])
        #expect(groups.flatMap(\.projects).count == 2)

        // A series' own page shows every project that includes it.
        let aboutBerserk = library.summaries.filter { $0.series.contains("Berserk") }.map(\.name)
        let aboutVagabond = library.summaries.filter { $0.series.contains("Vagabond") }.map(\.name)
        #expect(Set(aboutBerserk) == ["Swords", "Eclipse"])
        #expect(aboutVagabond == ["Swords"])
    }

    @Test("A summary carries the word goal and how many beats are done")
    func summaryStats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KomaDeskTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = ScratchDefaults()
        defer { settings.remove() }
        let library = ProjectLibrary(root: root, defaults: settings.defaults)
        let url = try library.create(named: "Eclipse", series: ["Berserk"], targetWordCount: 2000)
        var loaded = try ProjectStore.load(url)
        loaded.manifest.beats = [Beat(title: "Cold open", isDone: true), Beat(title: "The brand"), Beat(title: "After", isDone: true)]
        loaded.script = "> A note, not narration.\nGuts raises the sword.\n# Heading here"
        try ProjectStore.save(loaded, to: url)
        library.refresh()

        let found = try #require(library.summaries.first { $0.name == "Eclipse" })
        #expect(found.targetWordCount == 2000)
        #expect(found.beatsDone == 2)
        #expect(found.beatsTotal == 3)
    }

    @Test("A preview counts the narration, not the notes")
    func previewWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KomaDeskTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = ScratchDefaults()
        defer { settings.remove() }
        let library = ProjectLibrary(root: root, defaults: settings.defaults)
        let url = try library.create(named: "Eclipse", series: ["Berserk"])
        var loaded = try ProjectStore.load(url)
        loaded.script = "> A note, not narration.\nGuts raises the sword.\n# Heading here"
        try ProjectStore.save(loaded, to: url)
        let preview = await ProjectPreview.load(url)
        #expect(preview.words == 6)
        #expect(preview.blocks.count == 3)
    }
}
