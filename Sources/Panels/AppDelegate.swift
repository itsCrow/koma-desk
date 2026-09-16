import AppKit
import ComicArchive

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is run straight from `swift run` rather than
        // from inside the .app bundle, which otherwise leaves it agent-like.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Every comic read leaves its extracted pages behind. Trim the oldest
        // ones at launch, while nothing is open and nothing can be in use.
        Task.detached(priority: .background) {
            ComicArchive.pruneCache()
        }
    }

    /// Double-clicking a .cbr or a .panelsproject in Finder, or dropping one
    /// on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let project = urls.first(where: { $0.pathExtension.lowercased() == "panelsproject" }) {
                ReaderModel.shared.openProject(at: project)
            }
            if let comic = urls.first(where: {
                ReaderModel.supportedExtensions.contains($0.pathExtension.lowercased())
            }) {
                ReaderModel.shared.open(comic)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ReaderModel.shared.closeProject()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
