import SwiftUI
import ComicArchive

@main
struct PanelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ReaderModel.shared

    var body: some Scene {
        Window(model.title ?? "Panels", id: "reader") {
            ReaderView(model: model)
                .background(WindowBackgroundConfigurator())
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // A reader has nothing to create.
            CommandGroup(replacing: .newItem) {
                Button("Open Comic…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }

            CommandGroup(after: .newItem) {
                Button("Close Comic") { model.closeComic() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.hasComic)
            }

            CommandMenu("Go") {
                Button("Next Page") { model.goForward() }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(!model.canGoForward)
                Button("Previous Page") { model.goBack() }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(!model.canGoBack)
                Divider()
                Button("First Page") { model.goToStart() }
                    .keyboardShortcut(.home, modifiers: [])
                    .disabled(!model.hasComic)
                Button("Last Page") { model.goToEnd() }
                    .keyboardShortcut(.end, modifiers: [])
                    .disabled(!model.hasComic)
            }

            CommandGroup(after: .toolbar) {
                Picker("Reading Direction", selection: $model.direction) {
                    ForEach(ReadingDirection.allCases, id: \.self) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                Button("Flip Reading Direction") { model.toggleDirection() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

/// Makes the window chrome dark so it doesn't glare beside the black page area.
private struct WindowBackgroundConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
