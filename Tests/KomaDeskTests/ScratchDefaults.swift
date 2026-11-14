import Foundation

/// A settings domain of a test's own. Named by a path in the temporary folder,
/// so its file lands there rather than in ~/Library/Preferences, where the
/// settings service writes an emptied file back after it's deleted.
struct ScratchDefaults {
    let name = FileManager.default.temporaryDirectory
        .appendingPathComponent("KomaDeskTests-\(UUID().uuidString)").path
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func remove() {
        UserDefaults.standard.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}
