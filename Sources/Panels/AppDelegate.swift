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

    /// Double-clicking a .cbr, a folder or a .panelsproject in Finder, or
    /// dropping one on the Dock icon. Comics join the library on the way in.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let model = ReaderModel.shared
            if let project = urls.first(where: { $0.pathExtension.lowercased() == "panelsproject" }) {
                model.openProject(at: project)
            }
            for url in urls where url.pathExtension.lowercased() != "panelsproject" {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory || ReaderModel.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    model.addToLibrary(url)
                }
            }
        }
    }

    /// Files added to a watched folder, or a project dropped into the shared
    /// folder from Finder, show up when the app comes to the front.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            ReaderModel.shared.projects.refresh()
            ReaderModel.shared.library.rescan()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ReaderModel.shared.closeProject()
            ReaderModel.shared.library.saveNow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
