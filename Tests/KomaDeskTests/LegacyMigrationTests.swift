import Testing
import Foundation
@testable import KomaDesk
import KomaProject

@Suite("Coming across from the Panels name")
struct LegacyMigrationTests {
    private static func scratchPlaces() -> (root: URL, places: LegacyMigration.Locations) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KomaDeskTests-migrate-\(UUID().uuidString)", isDirectory: true)
        return (root, LegacyMigration.Locations(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            documents: root.appendingPathComponent("Documents", isDirectory: true),
            temporary: root.appendingPathComponent("tmp", isDirectory: true)
        ))
    }

    @Test("The library and projects move to their Koma Desk names")
    func movesEverything() throws {
        let fm = FileManager.default
        let (root, places) = Self.scratchPlaces()
        defer { try? fm.removeItem(at: root) }
        let oldLibrary = places.applicationSupport.appendingPathComponent("PanelsMVP/RemotePages/abc", isDirectory: true)
        try fm.createDirectory(at: oldLibrary, withIntermediateDirectories: true)
        let oldProjects = places.documents.appendingPathComponent("Panels Projects", isDirectory: true)
        _ = try ProjectStore.create(at: oldProjects.appendingPathComponent("Eclipse.panelsproject"),
                                    name: "Eclipse", series: ["Berserk"])
        try fm.createDirectory(at: places.temporary.appendingPathComponent("Panels/pages"), withIntermediateDirectories: true)
        let settings = ScratchDefaults()
        defer { settings.remove() }

        LegacyMigration.run(into: settings.defaults, at: places)

        let newProjects = places.documents.appendingPathComponent("Koma Desk Projects", isDirectory: true)
        #expect(fm.fileExists(atPath: places.applicationSupport.appendingPathComponent("KomaDesk/RemotePages/abc").path))
        #expect(!fm.fileExists(atPath: places.applicationSupport.appendingPathComponent("PanelsMVP").path))
        #expect(!fm.fileExists(atPath: oldProjects.path))
        #expect(ProjectStore.list(in: newProjects).map(\.lastPathComponent) == ["Eclipse.komadesk"])
        #expect(try ProjectStore.loadManifest(newProjects.appendingPathComponent("Eclipse.komadesk")).name == "Eclipse")
        #expect(!fm.fileExists(atPath: places.temporary.appendingPathComponent("Panels").path))
        #expect(settings.defaults.bool(forKey: LegacyMigration.doneKey))
    }

    @Test("Nothing already under the new name is overwritten")
    func leavesNewAlone() throws {
        let fm = FileManager.default
        let (root, places) = Self.scratchPlaces()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: places.applicationSupport.appendingPathComponent("PanelsMVP"), withIntermediateDirectories: true)
        try fm.createDirectory(at: places.applicationSupport.appendingPathComponent("KomaDesk"), withIntermediateDirectories: true)
        let settings = ScratchDefaults()
        defer { settings.remove() }

        LegacyMigration.run(into: settings.defaults, at: places)

        #expect(fm.fileExists(atPath: places.applicationSupport.appendingPathComponent("PanelsMVP").path))
    }
}
