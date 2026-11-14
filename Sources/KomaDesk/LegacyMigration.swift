import Foundation
import KomaProject

/// Brings a copy of the app from before it was Koma Desk across, once, before
/// anything reads its folders: the library and downloaded pages, and the
/// projects folder and each project in it. A step only moves what's there to
/// a place that's still free, so nothing already under the new name is ever
/// overwritten. Settings stay behind: they lived under another app's ID.
enum LegacyMigration {
    static let doneKey = "KomaDeskMigratedFromPanels"

    struct Locations {
        var applicationSupport: URL
        var documents: URL
        var temporary: URL

        static var current: Locations {
            let fm = FileManager.default
            return Locations(
                applicationSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                documents: fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                temporary: fm.temporaryDirectory
            )
        }
    }

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        run(into: defaults, at: .current)
    }

    static func run(into defaults: UserDefaults, at places: Locations) {
        moveIfFree(places.applicationSupport.appendingPathComponent("PanelsMVP", isDirectory: true),
                   to: places.applicationSupport.appendingPathComponent("KomaDesk", isDirectory: true))

        let root = places.documents.appendingPathComponent("Koma Desk Projects", isDirectory: true)
        moveIfFree(places.documents.appendingPathComponent("Panels Projects", isDirectory: true), to: root)
        renameProjects(in: root)

        // Pages extracted from comic files; rebuilt on demand under the new name.
        try? FileManager.default.removeItem(at: places.temporary.appendingPathComponent("Panels", isDirectory: true))
        defaults.set(true, forKey: doneKey)
    }

    /// Renames every `.panelsproject` directly in `root` to `.komadesk`, unless
    /// a project already has that name.
    static func renameProjects(in root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension.lowercased() == ProjectStore.legacyPackageExtension {
            moveIfFree(entry, to: entry.deletingPathExtension().appendingPathExtension(ProjectStore.packageExtension))
        }
    }

    @discardableResult
    private static func moveIfFree(_ from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return false }
        return (try? fm.moveItem(at: from, to: to)) != nil
    }
}
