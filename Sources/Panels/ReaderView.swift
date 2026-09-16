import SwiftUI
import AppKit

struct ReaderView: View {
    @Bindable var model: ReaderModel
    /// The controls panel is up. Pages dim behind it.
    @State private var showsControls = false
    /// After the panel closes on a search, the hits stay painted just long
    /// enough to find the balloon, then fade. A page turn ends it early.
    @State private var lingeringHighlights = false
    @State private var lingerTask: Task<Void, Never>?
    @State private var captureFlashTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let project = model.project, model.showsScript {
                let editor = ScriptPaneView(model: model, project: project)
                switch model.scriptPlacement {
                case .right:
                    HSplitView {
                        pageArea.frame(minWidth: 480).layoutPriority(1)
                        editor.frame(minWidth: 360, idealWidth: 420, maxWidth: 700)
                    }
                case .left:
                    HSplitView {
                        editor.frame(minWidth: 360, idealWidth: 420, maxWidth: 700)
                        pageArea.frame(minWidth: 480).layoutPriority(1)
                    }
                case .bottom:
                    VSplitView {
                        pageArea.frame(minHeight: 300).layoutPriority(1)
                        editor.frame(minHeight: 180, idealHeight: 260, maxHeight: 500)
                    }
                case .top:
                    VSplitView {
                        editor.frame(minHeight: 180, idealHeight: 260, maxHeight: 500)
                        pageArea.frame(minHeight: 300).layoutPriority(1)
                    }
                }
            } else {
                pageArea
            }
        }
        // Height follows from the spread's shape; only the width needs a floor.
        .frame(minWidth: 640, minHeight: 300)
        .navigationTitle(model.title ?? "Panels")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { reading { model.pressedLeftArrow() } }
        .onKeyPress(.rightArrow) { reading { model.pressedRightArrow() } }
        .onKeyPress(.home) { reading { model.goToStart() } }
        .onKeyPress(.end) { reading { model.goToEnd() } }
        .onKeyPress(KeyEquivalent("c")) {
            guard !showsControls, !model.isScriptEditing else { return .ignored }
            model.toggleCapture()
            return .handled
        }
        .onKeyPress(.escape) {
            guard !model.isScriptEditing else { return .ignored }
            // Choosing a page, then capture mode, then a search, then the panel.
            if model.isChoosingPageToSave {
                model.isChoosingPageToSave = false
                return .handled
            }
            if model.isCapturing {
                model.isCapturing = false
                return .handled
            }
            if model.isSearching {
                model.searchQuery = ""
                return .handled
            }
            guard showsControls else { return .ignored }
            setControls(visible: false)
            return .handled
        }
        .onChange(of: model.wantsSearchFocus) { _, wants in
            if wants { setControls(visible: true) }
        }
        .onChange(of: model.isCapturing) { _, capturing in
            // Capturing is done on the bare page.
            if capturing { setControls(visible: false); focused = true }
        }
        .onChange(of: model.isChoosingPageToSave) { _, choosing in
            if choosing { setControls(visible: false); focused = true }
        }
        .onChange(of: model.lastCaptureMessage) { _, message in
            guard message != nil else { return }
            captureFlashTask?.cancel()
            captureFlashTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { model.lastCaptureMessage = nil }
            }
        }
        .onChange(of: model.spreadIndex) {
            // Turning the page with the panel closed means you've moved on.
            if !showsControls { endLinger() }
        }
        .onKeyPress(keys: [.space], phases: .down) { press in
            // Space pages forward through the book; shift-space steps back —
            // unless the writer is typing, when a space is a space.
            guard !model.isScriptEditing else { return .ignored }
            press.modifiers.contains(.shift) ? model.goBack() : model.goForward()
            return .handled
        }
        // Never steer SwiftUI focus from AppKit responder changes: setting the
        // focus state false makes SwiftUI clear the window's first responder —
        // throwing out the text view that just took it — and then hand focus
        // to the last AppKit responder it remembers. The reader takes focus
        // back only on the writer's own actions: a tap on the page, closing
        // the controls, hiding the pane.
        .onChange(of: model.showsScript) { _, shows in
            if !shows { focused = true }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: {
                ReaderModel.supportedExtensions.contains($0.pathExtension.lowercased())
            }) else { return false }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .padding(8)
            }
        }
        .alert(
            "Can’t open this comic",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Pages

    private var pageArea: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.hasComic {
                spread
            } else {
                EmptyStateView { model.presentOpenPanel() }
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            overlays
        }
        .background(WindowConfigurator(
            spreadAspect: model.spreadAspect,
            layoutKey: model.project != nil && model.showsScript ? "script-\(model.scriptPlacement.rawValue)" : "pages"
        ))
    }

    private var spread: some View {
        SpreadStrip(
            model: model,
            spreadIndex: model.spreadIndex,
            direction: model.direction,
            highlights: highlightsOnPages,
            focus: model.focusOutlines,
            isCapturing: model.isCapturing,
            panelsProvider: { url in await model.panels(on: url) },
            onCapture: { url, shape in model.capture(page: url, shape: shape) },
            onEndCapture: { model.isCapturing = false },
            // Swiping or zooming the pages means the reader is reading again.
            onInteraction: { setControls(visible: false) },
            onTap: { focused = true; setControls(visible: !showsControls) }
        )
    }

    // MARK: - Controls

    @ViewBuilder
    private var overlays: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if showsControls, model.hasComic {
                    // Dims the pages, and a click on them puts the panel away.
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { setControls(visible: false) }
                        .transition(.opacity)

                    ReaderControlsPanel(model: model,
                                        height: min(max(260, geometry.size.height * 0.32), 340))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            if showsControls, let title = model.title {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassPanel(cornerRadius: 12)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let warning = model.warning {
                    WarningBanner(text: warning)
                }
                ForEach(model.missingComics, id: \.id) { ref in
                    MissingComicBanner(filename: ref.filename) { model.locateComic(ref) }
                }
                if model.isCapturing {
                    HStack(spacing: 14) {
                        Label("Click to place corners around a panel · click the first corner or press Return to capture · Esc when done",
                              systemImage: "crop")
                        Button {
                            model.savePage()
                        } label: {
                            Label("Save Whole Page", systemImage: "doc.on.doc")
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Save the visible page(s) at full resolution (⌥⇧⌘P)")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassPanel(cornerRadius: 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
            .animation(.easeOut(duration: 0.2), value: model.isCapturing)
        }
        .overlay {
            if model.isChoosingPageToSave {
                PageChooser(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isChoosingPageToSave)
        .overlay(alignment: .bottom) {
            if let message = model.lastCaptureMessage {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassPanel(cornerRadius: 12)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.lastCaptureMessage)
    }

    /// A reader key: handled unless the script pane has the keyboard.
    private func reading(_ action: () -> Void) -> KeyPress.Result {
        guard !model.isScriptEditing else { return .ignored }
        action()
        return .handled
    }

    private func setControls(visible: Bool) {
        guard visible != showsControls else { return }
        withAnimation(.easeOut(duration: 0.22)) { showsControls = visible }
        if visible {
            endLinger()
        } else {
            // The search field takes the keyboard while the panel is up; the
            // arrow keys want it back when the panel goes.
            focused = true
            if model.isSearching { startLinger() }
        }
    }

    /// Search hits are painted on the pages while the panel is up with a
    /// query, and for a moment after it closes. The search itself is kept
    /// until cleared; only the paint is transient.
    private var highlightsOnPages: [URL: [CGRect]] {
        (showsControls && model.isSearching) || lingeringHighlights ? model.highlightsByPage : [:]
    }

    private func startLinger() {
        lingerTask?.cancel()
        lingeringHighlights = true
        lingerTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            lingeringHighlights = false
        }
    }

    private func endLinger() {
        lingerTask?.cancel()
        lingerTask = nil
        lingeringHighlights = false
    }
}

// MARK: - Components

/// Two pages are up and one is to be saved: each becomes a big button.
private struct PageChooser: View {
    @Bindable var model: ReaderModel
    @State private var hovered: Int?

    var body: some View {
        ZStack {
            // Clicking the black around the pages backs out.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { model.isChoosingPageToSave = false }

            HStack(spacing: 0) {
                ForEach(model.visiblePages, id: \.number) { page in
                    Button {
                        model.savePage(page.url)
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 34, weight: .light))
                            Text("Save page \(page.number)")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.accentColor.opacity(hovered == page.number ? 0.28 : 0.12))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(hovered == page.number ? 0.9 : 0.4), lineWidth: 3))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? page.number : (hovered == page.number ? nil : hovered) }
                }
            }
            .padding(.vertical, 40)

            VStack {
                HStack(spacing: 12) {
                    Text("Which page?")
                        .font(.system(size: 14, weight: .semibold))
                    Button("Both") { model.saveVisiblePages() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.18), in: Capsule())
                    Text("Esc to cancel")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassPanel(cornerRadius: 12)
                .padding(.top, 12)
                Spacer()
            }
        }
    }
}

/// A comic the script cites that isn't on this Mac — said plainly, rather
/// than found out when a citation is clicked.
private struct MissingComicBanner: View {
    let filename: String
    let locate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
            Text("“\(filename)” isn’t on this Mac")
                .lineLimit(1)
            Button("Locate…", action: locate)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.white.opacity(0.22), in: Capsule())
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 12)
    }
}

private struct WarningBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.9), in: Capsule())
    }
}

private struct EmptyStateView: View {
    let openAction: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.white.opacity(0.5))
            Text("Open a comic to start reading")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
            Text("Drag a .cbr, .cbz or .cb7 file here")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.4))
            Button("Open Comic…", action: openAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
    }
}
