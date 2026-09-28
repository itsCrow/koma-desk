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
        interactive
        .dropDestination(for: URL.self) { urls, _ in dropped(urls) } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                // White over a dark ring, so it shows on a white page too.
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).inset(by: 1).strokeBorder(Palette.accent, lineWidth: 4))
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
        .sheet(isPresented: $model.wantsNewProject) {
            NewProjectSheet(model: model)
        }
        .sheet(item: $model.linkingPages) { request in
            LinkPagesSheet(model: model, request: request)
        }
        .sheet(isPresented: $model.isImportingLink) {
            ImportLinkSheet(model: model)
        }
    }

    /// The contents beside the pages, then the pages with the script pane
    /// wherever it's been put.
    @ViewBuilder
    private var layout: some View {
        if model.isFocusedWriting, let project = model.project, model.showsScript {
            // The comic (and its contents sidebar) set aside entirely —
            // this pane is the whole window while it's up.
            ScriptPaneView(model: model, project: project)
                .transition(.opacity)
        } else {
        HStack(spacing: 0) {
            // The series' contents, when there's more than one thing in it.
            if let series = model.series, model.hasContents, model.showsContents {
                SeriesContentsView(model: model, series: series)
                    .frame(width: 240)
                Divider().overlay(.white.opacity(0.1))
            }
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
            .layoutPriority(1)
        }
        .transition(.opacity)
        }
    }

    /// The layout with the reader's keys and focus on it.
    private var interactive: some View {
        layout
        .animation(.easeOut(duration: 0.2), value: model.showsContents)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: model.isFocusedWriting)
        // Height follows from the spread's shape; only the width needs a floor.
        .frame(minWidth: 640, minHeight: 300)
        .navigationTitle(model.title ?? "Panels")
        .hiddenToolbarBackground()
        // The app's own accent for SwiftUI's controls, not the user's system
        // accent — see `Palette.accent`.
        .tint(Palette.accent)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { reading { model.pressedLeftArrow() } }
        .onKeyPress(.rightArrow) { reading { model.pressedRightArrow() } }
        .onKeyPress(.home) { reading { model.goToStart() } }
        .onKeyPress(.end) { reading { model.goToEnd() } }
        .onKeyPress(KeyEquivalent("c")) {
            guard !showsControls, !textHasKeyboard else { return .ignored }
            model.toggleCapture()
            return .handled
        }
        .onKeyPress(.escape) { pressedEscape() }
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
            guard !textHasKeyboard else { return .ignored }
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
    }

    /// Esc backs out of one thing at a time: home, then choosing a page,
    /// capture mode, a search, the panel.
    private func pressedEscape() -> KeyPress.Result {
        guard !textHasKeyboard else { return .ignored }
        // Home, then choosing a page, capture mode, a search, the panel.
        if model.showsHome, model.hasComic {
            withAnimation(.easeOut(duration: 0.2)) { model.showsHome = false }
            return .handled
        }
        if model.isChoosingPageToSave {
            model.isChoosingPageToSave = false
            return .handled
        }
        if model.isOverviewExpanded {
            withAnimation(.easeOut(duration: 0.22)) { model.isOverviewExpanded = false }
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

    /// Folders and comics dropped on the window join the library; a comic
    /// then opens.
    private func dropped(_ urls: [URL]) -> Bool {
        let accepted = urls.filter { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isDirectory || ReaderModel.supportedExtensions.contains(url.pathExtension.lowercased())
        }
        guard !accepted.isEmpty else { return false }
        for url in accepted { model.addToLibrary(url) }
        return true
    }

    // MARK: - Pages

    private var pageArea: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.hasComic {
                spread
            } else {
                // Nothing open: the library and the projects are the front door.
                // Home runs up under the title bar — one surface to the top
                // edge — and is told how tall the bar is, to keep its
                // scrolling content below it.
                GeometryReader { geo in
                    HomeView(model: model, isOverlay: false, titlebarInset: geo.safeAreaInsets.top)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }

            if model.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    if let progress = model.remoteFetchProgress {
                        Text("Downloading page \(progress.done) of \(progress.total)…")
                            .font(.callout)
                            .foregroundStyle(.white)
                    }
                }
            }

            if model.hasComic, model.hasContents, !model.showsContents {
                ContentsTab { withAnimation(.easeOut(duration: 0.2)) { model.showsContents = true } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }

            overlays
        }
        .background(WindowConfigurator(
            spreadAspect: model.spreadAspect,
            layoutKey: (model.hasContents && model.showsContents ? "contents+" : "")
                + (model.project != nil && model.showsScript ? "script-\(model.scriptPlacement.rawValue)" : "pages")
        ))
    }

    @ViewBuilder
    private var spread: some View {
        if model.readingOrientation == .vertical {
            VerticalPageStripView(
                model: model,
                highlights: highlightsOnPages,
                focus: model.focusOutlines,
                isCapturing: model.isCapturing,
                panelsProvider: { url in await model.panels(on: url) },
                onCapture: { url, shape in model.capture(page: url, shape: shape) },
                onEndCapture: { model.isCapturing = false }
            )
        } else {
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

                    ReaderControlsPanel(
                        model: model,
                        height: model.isOverviewExpanded
                            ? max(260, geometry.size.height - 32)
                            : min(max(260, geometry.size.height * 0.32), 340)
                    )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let warning = model.warning {
                    WarningBanner(text: warning)
                }
                if model.hasComic, let missing = model.missingSeries {
                    MissingSeriesBanner(series: missing) { model.library.presentAddPanel() }
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
        .overlay {
            if model.showsHome, model.hasComic {
                ZStack {
                    Color.black.opacity(0.45)
                        .contentShape(Rectangle())
                        .onTapGesture { model.showsHome = false }
                    HomeView(model: model, isOverlay: true)
                        .padding(28)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showsHome)
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

    /// Whether some text field has the keyboard — the script, the search
    /// field, a project's name. The reader's keys then keep out of the way:
    /// a space in a name is a space.
    private var textHasKeyboard: Bool {
        model.isScriptEditing || NSApp.keyWindow?.firstResponder is NSText
    }

    /// A reader key: handled unless a text field has the keyboard.
    private func reading(_ action: () -> Void) -> KeyPress.Result {
        guard !textHasKeyboard else { return .ignored }
        action()
        return .handled
    }

    private func setControls(visible: Bool) {
        guard visible != showsControls else { return }
        if !visible { model.isOverviewExpanded = false }
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
                        // Dark wash, white edge over a dark ring: the page is
                        // often white paper, and white alone would vanish on it.
                        .background(Color.black.opacity(hovered == page.number ? 0.45 : 0.25))
                        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 5))
                        .overlay(Rectangle().inset(by: 1).strokeBorder(Color.white.opacity(hovered == page.number ? 0.95 : 0.5), lineWidth: 3))
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

/// The project's series isn't in the library — the editor's Mac, before
/// they've added the folder. Said plainly, rather than found out when a
/// citation is clicked.
private struct MissingSeriesBanner: View {
    let series: String
    let add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
            Text("This project is about \(series), which isn’t in your library")
                .lineLimit(1)
            Button("Add Folder…", action: add)
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

extension View {
    /// SwiftUI gives the window a toolbar of its own — for the title, even
    /// hidden — and draws its background as a band across the top, over
    /// whatever runs up under the title bar. Nothing here lives in that band.
    @ViewBuilder
    func hiddenToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
