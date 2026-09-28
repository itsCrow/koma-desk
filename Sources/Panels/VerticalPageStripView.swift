import SwiftUI
import AppKit
import PageCapture

/// The reader's vertical layout: every spread of the current item, stacked
/// top to bottom and scrolled continuously — no swipe-turning, but the same
/// `PageLayout` (one page or two facing pages per spread) as the horizontal
/// reader. Each spread is a real `SpreadScrollView`, the same view the
/// horizontal reader uses — pinch-zoom, pan, Live Text selection, the
/// citation lasso, and search-hit highlighting all come with it, maintained
/// in exactly one place rather than rebuilt for this layout.
struct VerticalPageStripView: View {
    @Bindable var model: ReaderModel
    /// Search hits to draw over each page, keyed by page file.
    let highlights: [URL: [CGRect]]
    /// Shapes to outline after a jump, keyed by page file.
    let focus: [URL: [[CGPoint]]]
    let isCapturing: Bool
    let panelsProvider: @MainActor (URL) async -> [DetectedPanel]
    let onCapture: (URL, CaptureShape) -> Void
    let onEndCapture: () -> Void

    /// One entry per spread, identified by its first page's URL rather than
    /// its position — position-based identity would let SwiftUI reuse a
    /// row (and the `SpreadScrollView` under it) across a chapter change,
    /// showing the old page for a beat while the new one loads.
    private var spreadRows: [(id: URL, index: Int)] {
        model.spreads.indices.compactMap { index in
            guard let first = model.spreads[index].pageIndices.first,
                  model.pages.indices.contains(first)
            else { return nil }
            return (id: model.pages[first], index: index)
        }
    }

    /// The row id matching wherever the model currently says the reader is —
    /// same scheme `spreadRows` uses, so it's always a valid scroll target.
    private var currentRowID: URL? {
        guard model.spreads.indices.contains(model.spreadIndex),
              let first = model.spreads[model.spreadIndex].pageIndices.first,
              model.pages.indices.contains(first)
        else { return nil }
        return model.pages[first]
    }

    /// Set right before a row's own `onAppear` writes `spreadIndex` from
    /// where the reader has scrolled to. `spreadIndex` changing is also how
    /// the keyboard, Space, Home/End, and the Overview panel's chevrons
    /// navigate — none of which touch the scroll position themselves — so
    /// this is what tells the difference between "the reader scrolled,
    /// which set this" (nothing to do) and "something else moved the target,
    /// the scroll position needs to catch up" (scroll to it). Consumed by
    /// the very next `spreadIndex` change, whichever it turns out to be.
    @State private var isSyncingFromScroll = false

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if model.hasPreviousItem {
                            ChapterContinueCard(model: model, direction: .previous)
                        }
                        ForEach(spreadRows, id: \.id) { row in
                            VerticalPageRow(
                                model: model, spreadIndex: row.index, pageHeight: proxy.size.height,
                                highlights: highlights, focus: focus, isCapturing: isCapturing,
                                panelsProvider: panelsProvider, onCapture: onCapture, onEndCapture: onEndCapture,
                                onAppearAtSpread: noteVisibleSpread
                            )
                        }
                        if model.hasNextItem {
                            ChapterContinueCard(model: model, direction: .next)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                // A plain ScrollView keeps whatever pixel offset it had —
                // switching chapters from the bottom card left it scrolled
                // to where the old chapter's end used to be, which usually
                // isn't the new chapter's start. Land on the model's own
                // idea of the current page instead, the same way the
                // horizontal reader always shows exactly `spreadIndex`.
                // Watches `pages` itself, not `model.item?.id` — the item
                // changes immediately when a new chapter starts loading,
                // before its pages/spreads exist yet; `pages` only changes
                // once the load actually finishes and there's something
                // real to scroll to. Kept alongside the `spreadIndex` watch
                // below rather than replaced by it, since a new chapter can
                // legitimately start at the same spread *number* as where
                // the old one left off — that wouldn't register as a
                // `spreadIndex` change at all, only as a `pages` change.
                .onChange(of: model.pages) { _, _ in
                    if let target = currentRowID { scrollProxy.scrollTo(target, anchor: .top) }
                }
                // Keyboard, Space, Home/End and the Overview panel's
                // chevrons all move `spreadIndex` directly and expect the
                // page to follow, the same way the horizontal reader always
                // shows exactly `spreadIndex` — a plain `ScrollView` has no
                // way to know that on its own.
                .onChange(of: model.spreadIndex) { _, _ in
                    guard !isSyncingFromScroll else {
                        isSyncingFromScroll = false
                        return
                    }
                    if let target = currentRowID { scrollProxy.scrollTo(target, anchor: .top) }
                }
                .onAppear {
                    if let target = currentRowID { scrollProxy.scrollTo(target, anchor: .top) }
                }
            }
        }
        .background(Color.black)
    }

    private func noteVisibleSpread(_ index: Int) {
        guard model.spreadIndex != index else { return }
        isSyncingFromScroll = true
        model.spreadIndex = index
    }
}

/// One spread (one page, or two facing pages under Two-Page Spread), loaded
/// on demand through the same cache the horizontal reader uses, and
/// reported as "on screen" the moment it appears — which is what keeps
/// reading position, prefetching, and the "continue reading" list all
/// working the same as they already do for the horizontal reader.
private struct VerticalPageRow: View {
    let model: ReaderModel
    let spreadIndex: Int
    /// Matches a page to the same scale Single Page mode already shows it
    /// at — fit to the reading area's height, not stretched to fill the
    /// window's width the way an actual webtoon page (drawn for exactly
    /// that) would be. `SpreadScrollView` does that fitting itself, the same
    /// way it already does for a horizontal spread.
    let pageHeight: CGFloat
    let highlights: [URL: [CGRect]]
    let focus: [URL: [[CGPoint]]]
    let isCapturing: Bool
    let panelsProvider: @MainActor (URL) async -> [DetectedPanel]
    let onCapture: (URL, CaptureShape) -> Void
    let onEndCapture: () -> Void
    let onAppearAtSpread: (Int) -> Void

    @State private var urls: [URL] = []
    @State private var images: [NSImage] = []

    var body: some View {
        VerticalPageCell(
            urls: urls, images: images, highlights: highlights, focus: focus, isCapturing: isCapturing,
            panelsProvider: panelsProvider, onCapture: onCapture, onEndCapture: onEndCapture
        )
        .frame(maxWidth: .infinity)
        .frame(height: pageHeight)
        // `orderedPages` already applies reading direction within the
        // spread — a manga pair still reads right-to-left in a vertical
        // scroll, only the turning becomes scrolling.
        .task(id: spreadIndex) {
            let ordered = model.orderedPages(forSpreadAt: spreadIndex).map(\.url)
            urls = ordered
            images = []
            var loaded: [NSImage] = []
            for url in ordered {
                guard let image = await model.image(for: url) else { continue }
                loaded.append(image)
            }
            // The row may have scrolled away and been given a different
            // spread while this was loading.
            guard urls == ordered else { return }
            images = loaded
        }
        .onAppear {
            onAppearAtSpread(spreadIndex)
        }
    }
}

/// Wraps one `SpreadScrollView` — the horizontal reader's per-spread view,
/// used here with one or two images the same way it already handles any
/// horizontal spread. No `swipeCoordinator`: there's no carousel to hand a
/// swipe to, so it just behaves like an ordinary zoomable, pannable scroll
/// view showing whatever it's given.
private struct VerticalPageCell: NSViewRepresentable {
    let urls: [URL]
    let images: [NSImage]
    let highlights: [URL: [CGRect]]
    let focus: [URL: [[CGPoint]]]
    let isCapturing: Bool
    let panelsProvider: @MainActor (URL) async -> [DetectedPanel]
    let onCapture: (URL, CaptureShape) -> Void
    let onEndCapture: () -> Void

    func makeNSView(context: Context) -> SpreadScrollView {
        let view = SpreadScrollView()
        applyState(to: view)
        return view
    }

    func updateNSView(_ view: SpreadScrollView, context: Context) {
        applyState(to: view)
    }

    private func applyState(to view: SpreadScrollView) {
        view.pageURLs = urls
        view.captureHandlers = (panels: panelsProvider, capture: onCapture, end: onEndCapture)
        view.setHighlights(highlights)
        view.setFocus(focus)
        view.setCapturing(isCapturing)
        // `show` already no-ops when it's the same images, so calling it on
        // every update costs nothing once a spread has loaded.
        if images.count == urls.count, !images.isEmpty {
            view.show(images)
        }
    }
}

/// A card at the top or bottom of the scroll, in place of an automatic
/// carry-on-scrolling handoff — chapter continuation is a deliberate tap
/// here rather than something that can fire just by a card scrolling past,
/// the way an auto-continue would risk doing on a short chapter that never
/// needed a real scroll to reach either end.
private struct ChapterContinueCard: View {
    let model: ReaderModel
    let direction: Direction

    enum Direction { case previous, next }

    var body: some View {
        Button(action: go) {
            HStack(spacing: 8) {
                if direction == .previous {
                    Image(systemName: "arrow.up")
                }
                Text(label)
                if direction == .next {
                    Image(systemName: "arrow.down")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(.white.opacity(0.06))
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        guard let index = model.currentItemIndex else { return "Continue" }
        let neighbour = direction == .previous ? index - 1 : index + 1
        guard model.seriesItems.indices.contains(neighbour) else { return "Continue" }
        let name = model.seriesItems[neighbour].label
        return direction == .previous ? "Previous \(model.itemNoun): \(name)" : "Next \(model.itemNoun): \(name)"
    }

    private func go() {
        switch direction {
        case .previous: model.previousItem(landingAtEnd: true)
        case .next: model.nextItem()
        }
    }
}
