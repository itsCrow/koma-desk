import SwiftUI
import ComicArchive

@main
struct PanelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ReaderModel.shared

    var body: some Scene {
        Window("Panels", id: "reader") {
            ReaderView(model: model)
        }
        // A two-page spread is about 1.4:1. The old default of 900x512 was
        // nearly 1.9:1, which letterboxed a quarter of the window into black.
        .defaultSize(width: 1280, height: 900)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.requestNewProject() }
                    .keyboardShortcut("n")
                    .disabled(model.library.isEmpty)
                Button("Library and Projects…") { model.showsHome = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.hasComic)
                Button("Open Project…") { model.presentOpenProjectPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Add Folder to Library…") { model.library.presentAddPanel() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Divider()
                Button("Close Project") { model.closeProject() }
                    .disabled(model.project == nil)
                Button("Close Comic") { model.closeComic() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.hasComic)
                Divider()
                Button("Rescan Library") { model.library.rescan() }
                Button("Set Projects Folder…") { model.projects.chooseRoot() }
                Button("Reveal Projects Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.projects.root])
                }
            }

            CommandMenu("Script") {
                Button(model.project == nil ? "Copy Citation" : "Insert Citation") { model.copyCitation() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!model.hasComic)
                Button(model.showsScript ? "Hide Script" : "Show Script") { model.showsScript.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(model.project == nil)
                Button(model.showsShotList ? "Show Writing" : "Show Shot List") { model.showsShotList.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(model.project == nil)
                Picker("Script Position", selection: $model.scriptPlacement) {
                    ForEach(ScriptPlacement.allCases, id: \.self) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                .disabled(model.project == nil)
                Divider()
                Button("Heading 1") { model.format(.heading(1)) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    .disabled(model.project == nil)
                Button("Heading 2") { model.format(.heading(2)) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(model.project == nil)
                Button("Body Text") { model.format(.body) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(model.project == nil)
                Divider()
                Button("Copy Script for Google Docs") { model.copyScriptAsPlainText() }
                    .disabled(model.project == nil)
                Button("Export Shots…") { model.exportShots() }
                    .disabled(model.project == nil)
                Button("Clean Up Unused Captures") { model.cleanUpUnusedCaptures() }
                    .disabled(model.project == nil)
                Button("Reveal Project in Finder") { model.revealProject() }
                    .disabled(model.project == nil)
            }

            CommandMenu("Tools") {
                // Captures are a project's shots, so they need one open.
                Button(model.isCapturing ? "Stop Drawing" : "Draw Around a Panel") { model.toggleCapture() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canCapture)
                Button("Save Whole Page") { model.savePage() }
                    .keyboardShortcut("p", modifiers: [.command, .shift, .option])
                    .disabled(!model.canCapture)
                Divider()
                Button("Reveal Captures in Finder") { model.revealCaptures() }
                    .disabled(model.project == nil)
            }

            CommandMenu("Go") {
                Button("Find in Comic…") { model.requestSearch() }
                    .keyboardShortcut("f")
                    .disabled(!model.hasComic)
                Divider()
                // Bare keys as menu shortcuts are claimed before a text view
                // sees them, so they're withdrawn while the writer types.
                Button("Next Page") { model.goForward() }
                    .keyboardShortcut(model.isScriptEditing ? nil : KeyboardShortcut(.downArrow, modifiers: []))
                    .disabled(!model.canGoForward)
                Button("Previous Page") { model.goBack() }
                    .keyboardShortcut(model.isScriptEditing ? nil : KeyboardShortcut(.upArrow, modifiers: []))
                    .disabled(!model.canGoBack)
                Divider()
                Button("First Page") { model.goToStart() }
                    .keyboardShortcut(model.isScriptEditing ? nil : KeyboardShortcut(.home, modifiers: []))
                    .disabled(!model.hasComic)
                Button("Last Page") { model.goToEnd() }
                    .keyboardShortcut(model.isScriptEditing ? nil : KeyboardShortcut(.end, modifiers: []))
                    .disabled(!model.hasComic)
                Divider()
                Button("Next \(model.itemNoun)") { model.nextItem() }
                    .keyboardShortcut(.downArrow, modifiers: [.option])
                    .disabled(!model.hasNextItem)
                Button("Previous \(model.itemNoun)") { model.previousItem() }
                    .keyboardShortcut(.upArrow, modifiers: [.option])
                    .disabled(!model.hasPreviousItem)
                Divider()
                Button("Back to Series") { model.showSeriesPage() }
                    .disabled(model.series == nil)
            }

            CommandGroup(after: .toolbar) {
                Button(model.showsContents ? "Hide Contents" : "Show Contents") { model.showsContents.toggle() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(!model.hasContents)
                Divider()
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
/// Sits as the background of the *page area*, so it can measure what the
/// window holds besides pages — the toolbar above, the script pane beside.
struct WindowConfigurator: NSViewRepresentable {
    /// Width-to-height of a two-page spread of the open comic, or nil when
    /// nothing is open.
    let spreadAspect: CGFloat?
    /// Anything that changes what surrounds the page area — the script pane
    /// shown or hidden — so the window is re-shaped.
    let layoutKey: String

    /// The pages never get squeezed below this by a pane.
    static let minimumPageWidth: CGFloat = 640

    /// Stands in front of SwiftUI's own window delegate, forwarding everything
    /// except resizing, which it constrains to the comic's shape.
    ///
    /// `NSWindow.contentAspectRatio` can't be used for this: the toolbar takes
    /// a strip off the top of the content view, so the *page area* below it
    /// only has the right shape if the height allows for that strip — which
    /// isn't a fixed ratio.
    final class Coordinator: NSObject, NSWindowDelegate {
        /// SwiftUI's own delegate, which everything but resizing goes to.
        ///
        /// Held strongly on purpose. NSWindow caches which delegate methods
        /// exist at the moment the delegate is set; if SwiftUI's object were
        /// allowed to go away while this one still claimed its methods, the
        /// forward would land nowhere and AppKit would throw
        /// "unrecognized selector" on the next resize — which is exactly what
        /// crashed the app when a new project made the script pane appear.
        var forwardTo: NSWindowDelegate?
        var aspect: CGFloat?
        /// Height of the chrome inside the content view, above the pages.
        var chromeInset: CGFloat = 0
        /// Width of the content view beside the page area: the script pane.
        var sideInset: CGFloat = 0
        var appliedAspect: CGFloat?
        var appliedLayoutKey = ""
        /// True while our own setFrame is in flight, so the page area's
        /// resize doesn't trigger another.
        var isReshaping = false

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwardTo?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            forwardTo?.responds(to: selector) == true ? forwardTo : nil
        }

        // The callbacks a resize actually produces, implemented outright so
        // they never depend on forwarding.
        func windowDidResize(_ notification: Notification) { forwardTo?.windowDidResize?(notification) }
        func windowWillStartLiveResize(_ notification: Notification) { forwardTo?.windowWillStartLiveResize?(notification) }
        func windowDidEndLiveResize(_ notification: Notification) { forwardTo?.windowDidEndLiveResize?(notification) }
        func windowDidMove(_ notification: Notification) { forwardTo?.windowDidMove?(notification) }
        func windowDidBecomeKey(_ notification: Notification) { forwardTo?.windowDidBecomeKey?(notification) }
        func windowDidResignKey(_ notification: Notification) { forwardTo?.windowDidResignKey?(notification) }
        func windowDidBecomeMain(_ notification: Notification) { forwardTo?.windowDidBecomeMain?(notification) }
        func windowDidResignMain(_ notification: Notification) { forwardTo?.windowDidResignMain?(notification) }
        func windowDidChangeScreen(_ notification: Notification) { forwardTo?.windowDidChangeScreen?(notification) }
        func windowDidChangeOcclusionState(_ notification: Notification) { forwardTo?.windowDidChangeOcclusionState?(notification) }
        func windowWillEnterFullScreen(_ notification: Notification) { forwardTo?.windowWillEnterFullScreen?(notification) }
        func windowDidEnterFullScreen(_ notification: Notification) { forwardTo?.windowDidEnterFullScreen?(notification) }
        func windowWillExitFullScreen(_ notification: Notification) { forwardTo?.windowWillExitFullScreen?(notification) }
        func windowDidExitFullScreen(_ notification: Notification) { forwardTo?.windowDidExitFullScreen?(notification) }
        func windowWillClose(_ notification: Notification) { forwardTo?.windowWillClose?(notification) }
        func windowShouldClose(_ sender: NSWindow) -> Bool { forwardTo?.windowShouldClose?(sender) ?? true }

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
            let pageWidth = max(content.width - sideInset, 200)
            let size = NSSize(width: content.width, height: pageWidth / aspect + chromeInset)
            return window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reports its own resizes: dragging the split divider changes the page
    /// area without any window resize, and the window has to follow.
    final class ReportingView: NSView {
        var onResize: (() -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            if changed { onResize?() }
        }
    }

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        let coordinator = context.coordinator
        view.onResize = { [weak view, weak coordinator] in
            guard let view, let coordinator, let window = view.window else { return }
            DispatchQueue.main.async { follow(window, from: view, coordinator) }
        }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.titlebarAppearsTransparent = true
            shape(window, from: view, coordinator)
        }
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            shape(window, from: view, coordinator)
        }
    }

    /// The page area's surroundings, measured from where this view sits.
    private func measure(_ window: NSWindow, from view: NSView, _ coordinator: Coordinator) {
        guard let content = window.contentView else { return }
        let pageArea = view.convert(view.bounds, to: content)
        coordinator.chromeInset = max(content.bounds.height - pageArea.height, 0)
        coordinator.sideInset = max(content.bounds.width - pageArea.width, 0)
    }

    /// Locks the page area to the spread's shape and resizes the window to
    /// match, so a two-page spread fills it edge to edge with no letterbox
    /// either side. With the shape fixed, dragging a corner scales the pages
    /// rather than uncovering black.
    private func shape(_ window: NSWindow, from view: NSView, _ coordinator: Coordinator) {
        guard coordinator.appliedAspect != spreadAspect || coordinator.appliedLayoutKey != layoutKey else { return }
        let layoutChanged = coordinator.appliedLayoutKey != layoutKey && !coordinator.appliedLayoutKey.isEmpty
        coordinator.appliedAspect = spreadAspect
        coordinator.appliedLayoutKey = layoutKey

        if window.delegate !== coordinator {
            // SwiftUI installed a delegate of its own since we last looked:
            // that's the one to forward to now.
            if let current = window.delegate { coordinator.forwardTo = current }
            window.delegate = coordinator
        }
        let previousSide = coordinator.sideInset
        let previousChrome = coordinator.chromeInset
        measure(window, from: view, coordinator)
        coordinator.aspect = spreadAspect

        guard let aspect = spreadAspect, aspect > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        // A pane appearing takes its width from the pages until the window
        // grows to make room; a pane going away leaves the pages that room.
        // Either way the pages keep the size they had. On the first pass the
        // saved frame may date from a session without the pane, so the pages
        // are only guaranteed the reader's own minimum width.
        // A pane above or below shows up as chrome; the shaped height already
        // accounts for it, so only the width needs adjusting here.
        _ = previousChrome
        let content = window.contentRect(forFrameRect: window.frame)
        let widthDelta: CGFloat
        if layoutChanged {
            widthDelta = coordinator.sideInset - previousSide
        } else {
            widthDelta = max(0, Self.minimumPageWidth - (content.width - coordinator.sideInset))
        }
        coordinator.isReshaping = true
        window.setFrame(frame(for: window, width: window.frame.width + widthDelta, aspect: aspect, coordinator),
                        display: true, animate: true)
        coordinator.isReshaping = false
    }

    /// The page area changed size on its own — the divider moved. Re-measure
    /// and, if the pages no longer have the spread's shape, fix the window.
    private func follow(_ window: NSWindow, from view: NSView, _ coordinator: Coordinator) {
        guard !coordinator.isReshaping, let aspect = coordinator.aspect, aspect > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        measure(window, from: view, coordinator)
        let target = coordinator.shaped(window.frame.size, for: window, aspect: aspect)
        guard abs(target.height - window.frame.height) > 1 else { return }
        coordinator.isReshaping = true
        var frame = window.frame
        frame.origin.y = frame.maxY - target.height
        frame.size = target
        window.setFrame(frame, display: true, animate: false)
        coordinator.isReshaping = false
    }

    /// The window's current width, at the spread's shape, kept on screen and
    /// anchored at its top-left so it doesn't wander.
    private func frame(for window: NSWindow, width: CGFloat, aspect: CGFloat, _ coordinator: Coordinator) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        var width = width
        if let visible { width = min(width, visible.width) }
        var size = coordinator.shaped(NSSize(width: width, height: window.frame.height), for: window, aspect: aspect)
        if let visible, size.height > visible.height {
            // Too tall for the screen: find the width whose shaped height fits.
            let overflow = size.height - visible.height
            size = coordinator.shaped(
                NSSize(width: width - overflow * aspect, height: window.frame.height),
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
