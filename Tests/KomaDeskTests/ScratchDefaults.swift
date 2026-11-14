import Foundation

/// A settings domain of a test's own. Removed when the test is done, or its
/// file stays in ~/Library/Preferences for good.
struct ScratchDefaults {
    let name = "KomaDeskTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func remove() { UserDefaults.standard.removePersistentDomain(forName: name) }
}
