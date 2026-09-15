import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is run straight from `swift run` rather than
        // from inside the .app bundle, which otherwise leaves it agent-like.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Double-clicking a .cbr in Finder, or dropping one on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: {
            ReaderModel.supportedExtensions.contains($0.pathExtension.lowercased())
        }) else { return }
        MainActor.assumeIsolated {
            ReaderModel.shared.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
