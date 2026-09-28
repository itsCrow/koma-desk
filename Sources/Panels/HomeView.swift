import SwiftUI

/// The home screen: a floating glass sidebar of destinations (what's being
/// read, the library, projects) over whichever one is picked, all on one
/// dark surface. Fills the window, title bar and all, when nothing is open;
/// lies over the pages as a rounded panel (⇧⌘O) when something is.
struct HomeView: View {
    @Bindable var model: ReaderModel
    let isOverlay: Bool
    /// The title bar's height, when home runs up under it: the scrolling
    /// content stays below the bar, and the sidebar's contents clear the
    /// window's buttons.
    var titlebarInset: CGFloat = 0

    /// How far the sidebar floats in from the panel's edges.
    static let inset: CGFloat = 12
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
            .padding(.leading, Self.sidebarWidth + Self.inset)
            .padding(.top, titlebarInset)

            // Filling the window, the sidebar runs up under the title bar and
            // the window's buttons sit in its glass, the way Tahoe's own
            // sidebars hold them; its contents start below them.
            // Only the sidebar and the background go up there, though: a
            // scroll view reaching under the title bar makes the system draw
            // a band of its own across it.
            HomeSidebar(model: model, topClearance: titlebarInset)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .padding(Self.inset)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
                .padding(.bottom, 10)
            item("Reading Now", icon: "book.fill", tab: .reading)
            item("Library", icon: "books.vertical.fill", tab: .library)
            item("Projects", icon: "doc.text.fill", tab: .projects)
            Spacer(minLength: 0)
        }
        .padding(10)
        .padding(.top, 8 + topClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: Radius.large)
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
