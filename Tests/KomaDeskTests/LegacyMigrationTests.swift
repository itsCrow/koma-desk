import Testing
import Foundation
@testable import KomaDesk
import KomaProject

@Suite("Coming across from the Panels name")
struct LegacyMigrationTests {
    @Test("Library, projects and settings move to their Koma Desk names, and their saved paths follow")
    func movesEverything() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("KomaDeskTests-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let places = LegacyMigration.Locations(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            documents: root.appendingPathComponent("Documents", isDirectory: true),
            temporary: root.appendingPathComponent("tmp", isDirectory: true)
        )
        let oldLibrary = places.applicationSupport.appendingPathComponent("PanelsMVP/RemotePages/abc", isDirectory: true)
        try fm.createDirectory(at: oldLibrary, withIntermediateDirectories: true)
        let oldProjects = places.documents.appendingPathComponent("Panels Projects", isDirectory: true)
        let eclipse = oldProjects.appendingPathComponent("Eclipse.panelsproject")
        _ = try ProjectStore.create(at: eclipse, name: "Eclipse", series: ["Berserk"])
        try fm.createDirectory(at: places.temporary.appendingPathComponent("Panels/pages"), withIntermediateDirectories: true)

        let opened = Date(timeIntervalSince1970: 1_000_000)
        let elsewhere = "/Volumes/Shared/Elsewhere.panelsproject"
        let settings = ScratchDefaults()
        defer { settings.remove() }
        let defaults = settings.defaults
        LegacyMigration.run(legacySettings: [
            "PanelsReadingDirection": "rightToLeft",
            "PanelsProjectRecents": [eclipse.standardizedFileURL.path, elsewhere],
            "PanelsProjectLastOpened": [eclipse.standardizedFileURL.path: opened],
            "NSWindow Frame reader": "1 2 3 4",
        ], into: defaults, at: places)

        let newProjects = places.documents.appendingPathComponent("Koma Desk Projects", isDirectory: true)
        let newEclipse = newProjects.appendingPathComponent("Eclipse.komadesk").standardizedFileURL.path
        #expect(fm.fileExists(atPath: places.applicationSupport.appendingPathComponent("KomaDesk/RemotePages/abc").path))
        #expect(!fm.fileExists(atPath: places.applicationSupport.appendingPathComponent("PanelsMVP").path))
        #expect(!fm.fileExists(atPath: oldProjects.path))
        #expect(ProjectStore.list(in: newProjects).map(\.lastPathComponent) == ["Eclipse.komadesk"])
        #expect(try ProjectStore.loadManifest(URL(fileURLWithPath: newEclipse)).name == "Eclipse")
        #expect(!fm.fileExists(atPath: places.temporary.appendingPathComponent("Panels").path))

        #expect(defaults.string(forKey: "KomaDeskReadingDirection") == "rightToLeft")
        #expect(defaults.string(forKey: "NSWindow Frame reader") == "1 2 3 4")
        // A project outside the folder wasn't renamed, so its path stays as it was.
        #expect(defaults.stringArray(forKey: "KomaDeskProjectRecents") == [newEclipse, elsewhere])
        #expect((defaults.dictionary(forKey: "KomaDeskProjectLastOpened") as? [String: Date]) == [newEclipse: opened])
        #expect(defaults.bool(forKey: LegacyMigration.doneKey))
    }

    @Test("Nothing already under the new name is overwritten")
    func leavesNewAlone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("KomaDeskTests-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let places = LegacyMigration.Locations(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            documents: root.appendingPathComponent("Documents", isDirectory: true),
            temporary: root.appendingPathComponent("tmp", isDirectory: true)
        )
        try fm.createDirectory(at: places.applicationSupport.appendingPathComponent("PanelsMVP"), withIntermediateDirectories: true)
        try fm.createDirectory(at: places.applicationSupport.appendingPathComponent("KomaDesk"), withIntermediateDirectories: true)
        let settings = ScratchDefaults()
        defer { settings.remove() }
        settings.defaults.set("leftToRight", forKey: "KomaDeskReadingDirection")

        LegacyMigration.run(legacySettings: ["PanelsReadingDirection": "rightToLeft"], into: settings.defaults, at: places)

        #expect(fm.fileExists(atPath: places.applicationSupport.appendingPathComponent("PanelsMVP").path))
        #expect(settings.defaults.string(forKey: "KomaDeskReadingDirection") == "leftToRight")
    }
}
