import AppKit
import ComicArchive
import RemoteComicSource

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True while a file handed over by Finder is being opened.
    ///
    /// Handing this app a file makes AppKit close the reader's window on the
    /// way in — it expects a document-based app, where a document window would
    /// take its place. This one has a single plain window, so nothing replaces
    /// it, and the app would take that for the last window closing and quit
    /// before the comic ever appeared. Verified by stubbing the open handler to
    /// do nothing at all: the window still closed.
    @MainActor private var isOpeningHandedFile = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is run straight from `swift run` rather than
        // from inside the .app bundle, which otherwise leaves it agent-like.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { Lettering.installCopyMonitor(model: ReaderModel.shared) }

        // Chapters imported from a link stay until the user removes the series.
        // Anything still in the old temporary folder is brought across first.
        RemoteComicSource.migrateLegacyCacheIfNeeded()

        // A local comic's pages are extracted from a file the user already has.
        // Those copies are trimmed so opening a lot of volumes doesn't fill the disk.
        Task.detached(priority: .background) {
            ComicArchive.pruneCache()
        }
    }

    /// Double-clicking a .cbr, a folder or a .panelsproject in Finder, or
    /// dropping one on the Dock icon. Comics join the library on the way in.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            isOpeningHandedFile = true
            defer {
                // Once now, and once after SwiftUI has finished rebuilding the
                // scene it just tore down — the first call lands too early to
                // have a window to show.
                showReaderWindow()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    self.showReaderWindow()
                    try? await Task.sleep(for: .seconds(3))
                    self.isOpeningHandedFile = false
                }
            }
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

    /// The one reader window, brought back whatever AppKit has done to it.
    @MainActor
    private func showReaderWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Clicking the Dock icon with the window closed brings it back rather
    /// than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !hasVisibleWindows { showReaderWindow() }
        }
        return true
    }

    /// Closing the window quits, as it should — except mid-open, when the
    /// close is AppKit's doing rather than the reader's.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !isOpeningHandedFile }
    }
}
