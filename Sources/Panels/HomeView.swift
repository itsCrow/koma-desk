import SwiftUI

/// The home screen: a sidebar of destinations (what's being read, the
/// library, projects) beside whichever one is picked, all on one dark
/// surface. Fills the window, title bar and all, when nothing is open;
/// lies over the pages as a rounded panel (⇧⌘O) when something is.
struct HomeView: View {
    @Bindable var model: ReaderModel
    let isOverlay: Bool
    /// The title bar's height, when home runs up under it: the scrolling
    /// content stays below the bar, and the sidebar's contents clear the
    /// window's buttons.
    var titlebarInset: CGFloat = 0

    static let sidebarWidth: CGFloat = 200

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The content runs the full height; only its leading edge makes
            // room for the sidebar.
            Group {
                switch model.homeTab {
                case .reading:
                    ReadingNowView(model: model)
                case .library:
                    LibraryView(model: model)
                case .projects:
                    ProjectsBrowserView(model: model, seriesFilter: nil)
                }
            }
            .id(model.homeTab)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, Self.sidebarWidth)
            .padding(.top, titlebarInset)

            // A column, not a card: flush with the left, top and bottom of
            // the window, with the window's buttons sitting in its top.
            // Only the sidebar and the background go up there, though: a
            // scroll view reaching under the title bar makes the system draw
            // a band of its own across it.
            HomeSidebar(model: model, topClearance: titlebarInset)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
        }
        .animation(.smooth(duration: 0.3), value: model.homeTab)
        .overlay(alignment: .topTrailing) {
            if isOverlay {
                Button { model.showsHome = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .glassCapsule()
                }
                .buttonStyle(.plain)
                .help("Back to the pages (Esc)")
                .padding(.trailing, 22)
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.homeBackground)
        .clipShape(RoundedRectangle(cornerRadius: isOverlay ? Radius.window : 0))
        .onAppear {
            model.projects.refresh()
            model.library.rescan()
        }
    }
}

/// The sidebar's destinations, and a search across all of them. The
/// selection is one capsule that slides from item to item, rather than a
/// fill that blinks from one row to the next.
private struct HomeSidebar: View {
    @Bindable var model: ReaderModel
    /// Room above the search field for the window's own buttons.
    let topClearance: CGFloat
    @Namespace private var selection
    @FocusState private var searchFocused: Bool
    /// 0 until the writer chooses, which stays open. 1 open, 2 closed.
    /// A Bool would come back false the first time, before any choice.
    @AppStorage("PanelsProjectsSidebarExpanded") private var projectsDisclosure = 0

    private var projectsOpen: Bool { projectsDisclosure != 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
                .padding(.bottom, 10)
            item("Reading Now", icon: "book.fill", tab: .reading)
            item("Library", icon: "books.vertical.fill", tab: .library)
            projectsSection
            Spacer(minLength: 0)
        }
        .padding(10)
        .padding(.top, 8 + topClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.035))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
        }
        .onChange(of: model.wantsHomeSearchFocus) { _, wants in
            guard wants else { return }
            searchFocused = true
            model.wantsHomeSearchFocus = false
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            TextField("Search", text: $model.homeSearch, prompt: Text("Search").foregroundStyle(Palette.textTertiary))
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($searchFocused)
                .onExitCommand { model.homeSearch = ""; searchFocused = false }
            if !model.homeSearch.isEmpty {
                Button { model.homeSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassCapsule()
        // Glass gives no sign it has the keyboard; this does.
        .overlay(Capsule().strokeBorder(searchFocused ? Palette.selectionStroke : .clear, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private func item(_ title: String, icon: String, tab: HomeTab) -> some View {
        let selected = model.homeTab == tab
        return Button {
            model.homeTab = tab
            if tab == .library {
                model.browsingSeries = nil
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: selected)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if selected {
                    Capsule()
                        .fill(Palette.surfaceSelected)
                        .overlay(Capsule().strokeBorder(Palette.selectionStroke, lineWidth: 1))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.homeTab)
    }

    /// Projects, with a disclosure for the few most recently opened. The
    /// arrow is its own button so choosing the tab doesn't fold the list.
    private var projectsSection: some View {
        let selected = model.homeTab == .projects
        let recent = recentProjects
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Button {
                    model.homeTab = .projects
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .symbolRenderingMode(.hierarchical)
                            .symbolEffect(.bounce, value: selected)
                            .frame(width: 18)
                        Text("Projects")
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    .padding(.leading, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !model.projects.summaries.isEmpty {
                    Button {
                        withAnimation(.smooth(duration: 0.22)) {
                            projectsDisclosure = projectsOpen ? 2 : 1
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.textTertiary)
                            .rotationEffect(.degrees(projectsOpen ? 0 : -90))
                            .frame(width: 22, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .help(projectsOpen ? "Hide recent projects" : "Show recent projects")
                }
            }
            .padding(.trailing, model.projects.summaries.isEmpty ? 12 : 0)
            .background {
                if selected {
                    Capsule()
                        .fill(Palette.surfaceSelected)
                        .overlay(Capsule().strokeBorder(Palette.selectionStroke, lineWidth: 1))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.homeTab)

            if projectsOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { summary in
                        RecentProjectRow(
                            summary: summary,
                            words: model.projects.previews[summary.url]?.words,
                            isCurrent: model.project?.url.standardizedFileURL == summary.url.standardizedFileURL
                        ) {
                            model.switchTo(summary.url)
                        }
                        .task(id: summary.url.path + (summary.edited?.description ?? "")) {
                            await model.projects.loadPreview(for: summary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// A handful, most recently worked on first. A search narrows them the
    /// same way it narrows the rest of home.
    private var recentProjects: [ProjectSummary] {
        let sorted = ProjectsSort.recent.sorted(model.projects.summaries, words: [:])
        let matched = sorted.filter { HomeSearch.matches(model.homeSearch, $0.name, $0.series) }
        return Array(matched.prefix(5))
    }
}

/// One recent project under the sidebar's Projects item. A dot sits where
/// the title starts: grey, or the accent once a word goal that was set has
/// been reached. The title fades before the time, which keeps a fixed
/// column so the ages line up.
private struct RecentProjectRow: View {
    let summary: ProjectSummary
    /// Narration words, once the script has been read. Nil until then.
    let words: Int?
    let isCurrent: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .overlay(alignment: .leading) {
                        Text(summary.name)
                            .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                            .foregroundStyle(isCurrent || hovered ? Palette.textPrimary : Palette.textSecondary)
                            .fixedSize()
                    }
                    .clipped()
                    .mask { fadeMask }
                if let age = CompactAge.label(for: summary) {
                    Text(age)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            .padding(.leading, 40)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? Palette.surfaceHover : .clear)
                    .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(help)
    }

    /// Grey, unless this project was given a word goal and the script has
    /// reached it. The accent is the same one the word-goal ring draws with.
    private var dot: Color {
        guard let target = summary.targetWordCount, target > 0, let words, words >= target else {
            return Color.white.opacity(0.28)
        }
        return Palette.accent
    }

    /// Opaque across the title, then a short fade so a long name disappears
    /// before the time instead of running into it. A short name never reaches
    /// the fade.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            Color.black.frame(maxWidth: .infinity)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var help: String {
        guard let date = summary.lastOpened ?? summary.edited else { return summary.name }
        let verb = summary.lastOpened == nil ? "Edited" : "Opened"
        let when = date.formatted(.relative(presentation: .named))
        return "\(summary.name) — \(verb) \(when)"
    }
}

/// "14h", "3d" — how long ago a project was last opened, or saved if it
/// never has been opened here.
enum CompactAge {
    static func label(for summary: ProjectSummary, now: Date = Date()) -> String? {
        guard let date = summary.lastOpened ?? summary.edited else { return nil }
        return string(since: date, now: now)
    }

    static func string(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }
        let months = days / 30
        if months < 12 { return "\(months)mo" }
        return "\(max(days / 365, 1))y"
    }
}

/// A comic's first page, small, from the library's cover cache.
struct CoverView: View {
    @Bindable var model: ReaderModel
    let itemID: String?
    /// True fills the whole cell edge to edge (cropping the cover as
    /// needed), with no matte behind it — for a card that IS the cover, the
    /// way a photo grid works. False (the default) letterboxes the cover
    /// inside a small inset, for thumbnails that sit above their own label.
    var fill: Bool = false

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    // Without an explicit fill here, this view's own
                    // reported size can end up smaller than what the parent
                    // actually offered it — which then leaves any overlay
                    // anchored to *this* view's edges instead of the whole
                    // card's, drifting from one cover's aspect ratio to the
                    // next instead of lining up card to card.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06))
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            } else {
                PagePlaceholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: itemID) {
            guard let itemID, let item = model.library.item(id: itemID) else { image = nil; return }
            image = await model.library.cover(for: item)
        }
    }
}

/// A page with no cover of its own: a plain folded-corner card, the way a
/// blank document icon suggests "a file" without pretending to show one.
struct PagePlaceholder: View {
    var body: some View {
        GeometryReader { geo in
            let fold = min(geo.size.width, geo.size.height) * 0.26
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.62))
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width - fold, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width, y: fold))
                    path.addLine(to: CGPoint(x: geo.size.width - fold, y: fold))
                    path.closeSubpath()
                }
                .fill(Color(white: 0.47))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
