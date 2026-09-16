import SwiftUI
import ComicArchive

/// The glass panel that rises from the bottom when the reader clicks a page:
/// an overview of every page with the current spread raised, a progress bar,
/// and the position in the book. Everything is sized from the panel's own
/// height, so it keeps its proportions in any window.
struct ReaderControlsPanel: View {
    @Bindable var model: ReaderModel
    /// The panel's height; the reader decides it from the window.
    let height: CGFloat
    @FocusState private var searchFocused: Bool
    /// Shown for a moment after the citation is copied.
    @State private var copiedCitation: String?
    @State private var copiedTask: Task<Void, Never>?

    /// Everything that doesn't scale with the thumbnails: the stack's own rows,
    /// gaps and padding (121), plus what the strip needs around a thumbnail —
    /// headroom for the raised spread, the gap, and the page number (22).
    private static let chrome: CGFloat = 121 + 22
    private static let currentScale: CGFloat = 1.12
    private static let cornerRadius: CGFloat = 24

    /// Sized from the room left over, so no gap can open up below the strip.
    /// Divided by the raised scale so the current spread still fits.
    private var thumbnailHeight: CGFloat {
        max(96, (height - Self.chrome) / Self.currentScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: 36)
                .padding(.bottom, 12)

            HStack(spacing: 0) {
                edgeArrow("chevron.left", enabled: leftEnabled) { model.pressedLeftArrow() }
                if model.isOverviewExpanded {
                    pageGrid
                } else {
                    overview
                }
                edgeArrow("chevron.right", enabled: rightEnabled) { model.pressedRightArrow() }
            }
            .frame(maxHeight: .infinity)

            progressBar
                .padding(.top, 14)

            footer
                .frame(height: 18)
                .padding(.top, 10)
        }
        .padding(14)
        .frame(height: height)
        .onAppear { if model.wantsSearchFocus { takeSearchFocus() } }
        .onChange(of: model.wantsSearchFocus) { _, wants in if wants { takeSearchFocus() } }
        .glassPanel(cornerRadius: Self.cornerRadius)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField
            if model.isIndexing {
                Text("Reading text… \(model.indexedPageCount) of \(model.pages.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                cornerButton("doc.on.doc", help: "Save Page (⌥⇧⌘P)") { model.savePage() }
                cornerButton("crop", help: "Draw Around a Panel (⇧⌘P)") { model.toggleCapture() }
                cornerButton("quote.opening", help: "Copy Citation") { copyCitation() }
                cornerButton(
                    model.isOverviewExpanded ? "arrow.down.right.and.arrow.up.left"
                                             : "arrow.up.left.and.arrow.down.right",
                    help: model.isOverviewExpanded ? "Collapse" : "Expand to all pages"
                ) {
                    withAnimation(.easeOut(duration: 0.22)) { model.isOverviewExpanded.toggle() }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let copiedCitation {
                Text("Copied “\(copiedCitation)”")
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .transition(.opacity)
            } else if model.isSearching {
                Text(searchSummary)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Page \(model.currentPageNumber) of \(model.pages.count)")
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .font(.system(size: 13))
    }

    // MARK: - Corner tools

    private func cornerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copyCitation() {
        guard let citation = model.copyCitation() else { return }
        copiedTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { copiedCitation = citation }
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { copiedCitation = nil }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            TextField("Search", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .onExitCommand { model.searchQuery = ""; searchFocused = false }
            if model.isSearching {
                Button { model.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Plain fill, not glass: glass on glass muddies.
        .background(.white.opacity(0.12), in: Capsule())
        .frame(minWidth: 200, maxWidth: 280)
    }

    private func takeSearchFocus() {
        searchFocused = true
        model.wantsSearchFocus = false
    }

    private var searchSummary: String {
        let hits = model.searchHits.count
        guard hits > 0 else {
            return model.isIndexing ? "No matches yet" : "No matches"
        }
        let pages = model.pagesWithHits
        return "\(hits) hit\(hits == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s")"
    }

    // MARK: - Page overview

    private var overview: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Pages of one spread sit close together; spreads sit apart.
                LazyHStack(alignment: .bottom, spacing: 26) {
                    // Only pages with hits while a search is active.
                    ForEach(model.overviewSpreads, id: \.self) { index in
                        spreadThumbnail(at: index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 8)
                // Only what the raised spread needs — the chevrons have their
                // own room now, so nothing else is being padded around.
                .padding(.top, thumbnailHeight * (Self.currentScale - 1) + 4)
            }
            .onAppear { proxy.scrollTo(model.spreadIndex, anchor: .center) }
            .onChange(of: model.spreadIndex) { _, index in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    // MARK: - Expanded grid

    /// Every page at once, scrolling down — the panel filling the page area.
    private var pageGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 18, alignment: .top)],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(model.overviewPages, id: \.self) { page in
                        gridCell(page: page).id(page)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(currentPageIndex, anchor: .center) }
            .onChange(of: model.spreadIndex) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(currentPageIndex, anchor: .center) }
            }
        }
    }

    private var currentPageIndex: Int {
        model.currentSpread?.pageIndices.first ?? 0
    }

    private func gridCell(page: Int) -> some View {
        let isCurrent = model.currentSpread?.pageIndices.contains(page) ?? false
        return Button {
            model.goToPage(page)
        } label: {
            VStack(spacing: 6) {
                GridPageThumbnail(url: model.pages[page])
                    .overlay(alignment: .topTrailing) { hitBadge(forPageIndex: page) }
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        }
                    }
                Text("\(page + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isCurrent ? .black : .white.opacity(0.5))
                    .frame(minWidth: 20)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isCurrent ? Color.accentColor : .clear, in: Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func hitBadge(forPageIndex page: Int) -> some View {
        if let count = model.hitsByPage[page], count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(red: 1, green: 0.85, blue: 0.1), in: Capsule())
                .padding(3)
        }
    }

    private func spreadThumbnail(at index: Int) -> some View {
        let isCurrent = index == model.spreadIndex
        return Button {
            model.goTo(spread: index)
        } label: {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(model.orderedPages(forSpreadAt: index), id: \.number) { page in
                    VStack(spacing: 5) {
                        PageThumbnail(url: page.url, height: thumbnailHeight)
                            .overlay(alignment: .topTrailing) {
                                if let count = model.hitsByPage[page.number - 1], count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color(red: 1, green: 0.85, blue: 0.1), in: Capsule())
                                        .padding(3)
                                }
                            }
                        // Every page numbered — the spread being read just
                        // stands out. Blanks here read as a bug.
                        Text("\(page.number)")
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.45))
                    }
                }
            }
            .scaleEffect(isCurrent ? Self.currentScale : 1, anchor: .bottom)
            .animation(.spring(duration: 0.3), value: isCurrent)
        }
        .buttonStyle(.plain)
    }

    private func edgeArrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.3))
                .frame(width: 30, height: 30)
                .background(.white.opacity(enabled ? 0.14 : 0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .disabled(!enabled)
    }

    /// The left arrow advances in manga order and retreats in Western order,
    /// so which arrow is live flips with the reading direction.
    private var leftEnabled: Bool {
        model.direction == .rightToLeft ? model.canGoForward : model.canGoBack
    }

    private var rightEnabled: Bool {
        model.direction == .rightToLeft ? model.canGoBack : model.canGoForward
    }

    // MARK: - Progress

    private var progressBar: some View {
        GeometryReader { geometry in
            let fraction = model.spreads.isEmpty
                ? 0 : CGFloat(model.spreadIndex + 1) / CGFloat(model.spreads.count)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Thumbnail

/// A page in the grid: sized by the column, height following the page.
private struct GridPageThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.1)
                    .aspectRatio(0.7, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

/// A page at thumbnail size — nothing added around it; a page is white on its own.
private struct PageThumbnail: View {
    let url: URL
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // A page-shaped placeholder holds the layout still while decoding.
                Color.white.opacity(0.12)
                    .aspectRatio(0.7, contentMode: .fit)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass where the system has it, the nearest material where it
    /// doesn't. Deployment target is macOS 14; the effect arrived in 26.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
