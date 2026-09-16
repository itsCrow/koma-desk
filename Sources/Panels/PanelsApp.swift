import SwiftUI
import ComicArchive

@main
struct PanelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ReaderModel.shared

    var body: some Scene {
        Window("Panels", id: "reader") {
            ReaderView(model: model)
                .background(WindowConfigurator(spreadAspect: model.spreadAspect))
        }
        // A two-page spread is about 1.4:1. The old default of 900x512 was
        // nearly 1.9:1, which letterboxed a quarter of the window into black.
        .defaultSize(width: 1280, height: 900)
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

            CommandGroup(after: .pasteboard) {
                Button("Copy Citation") { model.copyCitation() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!model.hasComic)
            }

            CommandMenu("Go") {
                Button("Find in Comic…") { model.requestSearch() }
                    .keyboardShortcut("f")
                    .disabled(!model.hasComic)
                Divider()
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

/// The window behaviour SwiftUI has no modifier for: chrome dark enough not to
/// glare beside the black page area, and a window shaped like the comic.
private struct WindowConfigurator: NSViewRepresentable {
    /// Width-to-height of a two-page spread of the open comic, or nil when
    /// nothing is open.
    let spreadAspect: CGFloat?

    /// Stands in front of SwiftUI's own window delegate, forwarding everything
    /// except resizing, which it constrains to the comic's shape.
    ///
    /// `NSWindow.contentAspectRatio` can't be used for this: the toolbar takes
    /// a strip off the top of the content view, so the *page area* below it
    /// only has the right shape if the height allows for that strip — which
    /// isn't a fixed ratio.
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var forwardTo: NSWindowDelegate?
        var aspect: CGFloat?
        /// Height of the chrome inside the content view, above the pages.
        var chromeInset: CGFloat = 0
        var appliedAspect: CGFloat?

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwardTo?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            forwardTo?.responds(to: selector) == true ? forwardTo : nil
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            guard let aspect, !sender.styleMask.contains(.fullScreen) else {
                return forwardTo?.windowWillResize?(sender, to: frameSize) ?? frameSize
            }
            return shaped(frameSize, for: sender, aspect: aspect)
        }

        /// The frame at this width whose page area has the spread's shape.
        @MainActor
        func shaped(_ frameSize: NSSize, for window: NSWindow, aspect: CGFloat) -> NSSize {
            let content = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
            let size = NSSize(width: content.width, height: content.width / aspect + chromeInset)
            return window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.titlebarAppearsTransparent = true
            shape(window, from: view, coordinator)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            shape(window, from: view, coordinator)
        }
    }

    /// Locks the page area to the spread's shape and resizes the window to
    /// match, so a two-page spread fills it edge to edge with no letterbox
    /// either side. With the shape fixed, dragging a corner scales the pages
    /// rather than uncovering black.
    private func shape(_ window: NSWindow, from view: NSView, _ coordinator: Coordinator) {
        guard coordinator.appliedAspect != spreadAspect else { return }
        coordinator.appliedAspect = spreadAspect

        if window.delegate !== coordinator {
            coordinator.forwardTo = window.delegate
            window.delegate = coordinator
        }
        // This view is the reader's background, so its frame *is* the page
        // area; whatever the content view has above it is chrome.
        if let content = window.contentView {
            let pageArea = view.convert(view.bounds, to: content)
            coordinator.chromeInset = max(content.bounds.height - pageArea.height, 0)
        }
        coordinator.aspect = spreadAspect

        guard let aspect = spreadAspect, aspect > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(frame(for: window, aspect: aspect, coordinator), display: true, animate: true)
    }

    /// The window's current width, at the spread's shape, kept on screen and
    /// anchored at its top-left so it doesn't wander.
    private func frame(for window: NSWindow, aspect: CGFloat, _ coordinator: Coordinator) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        var size = coordinator.shaped(window.frame.size, for: window, aspect: aspect)
        if let visible, size.height > visible.height {
            // Too tall for the screen: find the width whose shaped height fits.
            let overflow = size.height - visible.height
            let content = window.contentRect(forFrameRect: window.frame)
            size = coordinator.shaped(
                NSSize(width: window.frame.width - overflow * aspect, height: content.height),
                for: window, aspect: aspect
            )
        }
        var frame = NSRect(origin: window.frame.origin, size: size)
        frame.origin.y = window.frame.maxY - frame.height
        if let visible {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }
}
