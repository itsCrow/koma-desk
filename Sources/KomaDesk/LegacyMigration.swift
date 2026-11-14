import Foundation
import KomaProject

/// Brings a copy of the app from before it was Koma Desk across, once, before
/// anything reads its settings or folders: the library and downloaded pages,
/// the projects folder and each project in it, and the settings under their
/// old names. A step only moves what's there to a place that's still free,
/// so nothing already under the new name is ever overwritten.
enum LegacyMigration {
    static let legacyDomain = "com.mida.PanelsMVP"
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
        run(legacySettings: defaults.persistentDomain(forName: legacyDomain) ?? [:], into: defaults, at: .current)
    }

    static func run(legacySettings: [String: Any], into defaults: UserDefaults, at places: Locations) {
        moveIfFree(places.applicationSupport.appendingPathComponent("PanelsMVP", isDirectory: true),
                   to: places.applicationSupport.appendingPathComponent("KomaDesk", isDirectory: true))

        var paths = PathMap()
        let root: URL
        if let custom = legacySettings["PanelsProjectsRoot"] as? String {
            // A folder the writer chose — likely shared — stays where it is.
            root = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let old = places.documents.appendingPathComponent("Panels Projects", isDirectory: true)
            root = places.documents.appendingPathComponent("Koma Desk Projects", isDirectory: true)
            if moveIfFree(old, to: root) { paths.folders[old.standardizedFileURL.path] = root.standardizedFileURL.path }
        }
        paths.projects = renameProjects(in: root)

        for (key, value) in legacySettings {
            let newKey = key.hasPrefix("Panels") ? "KomaDesk" + key.dropFirst("Panels".count) : key
            guard defaults.object(forKey: newKey) == nil else { continue }
            defaults.set(paths.migrating(value, forKey: newKey), forKey: newKey)
        }

        // Pages extracted from comic files; rebuilt on demand under the new name.
        try? FileManager.default.removeItem(at: places.temporary.appendingPathComponent("Panels", isDirectory: true))
        defaults.set(true, forKey: doneKey)
    }

    /// Where each moved folder and renamed project went, by standardized path,
    /// so the recents and last-opened dates saved against the old paths follow.
    struct PathMap {
        var folders: [String: String] = [:]
        var projects: [String: String] = [:]

        func migrated(_ path: String) -> String {
            var path = path
            for (from, to) in folders where path.hasPrefix(from + "/") {
                path = to + path.dropFirst(from.count)
            }
            return projects[path] ?? path
        }

        func migrating(_ value: Any, forKey key: String) -> Any {
            switch key {
            case "KomaDeskProjectRecents":
                return (value as? [String])?.map(migrated) ?? value
            case "KomaDeskProjectLastOpened":
                guard let dates = value as? [String: Any] else { return value }
                return Dictionary(dates.map { (migrated($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            default:
                return value
            }
        }
    }

    /// Renames every `.panelsproject` directly in `root` to `.komadesk`, unless
    /// a project already has that name. Returns old path → new path.
    static func renameProjects(in root: URL) -> [String: String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var renamed: [String: String] = [:]
        for entry in entries where entry.pathExtension.lowercased() == ProjectStore.legacyPackageExtension {
            let old = root.appendingPathComponent(entry.lastPathComponent)
            let new = old.deletingPathExtension().appendingPathExtension(ProjectStore.packageExtension)
            // Spelled out while `old` still exists: standardizing resolves
            // /private differently for a path that's gone.
            let (oldPath, newPath) = (old.standardizedFileURL.path, new.standardizedFileURL.path)
            if moveIfFree(old, to: new) { renamed[oldPath] = newPath }
        }
        return renamed
    }

    @discardableResult
    private static func moveIfFree(_ from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return false }
        return (try? fm.moveItem(at: from, to: to)) != nil
    }
}
