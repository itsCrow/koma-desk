import AppKit
import SwiftUI
import ComicArchive

/// The reader's page canvas: the current spread with its neighbours parked just
/// off-screen, so a page turn can be dragged across rather than swapped.
struct SpreadStrip: NSViewRepresentable {
    let model: ReaderModel
    /// Read so SwiftUI re-runs `updateNSView` when the page or direction moves,
    /// rather than relying on the body happening to observe them elsewhere.
    let spreadIndex: Int
    let direction: ReadingDirection
    /// Called as the reader pans, zooms or swipes, so the chrome reappears.
    let onInteraction: () -> Void

    func makeNSView(context: Context) -> SpreadStripView {
        let strip = SpreadStripView()
        strip.onInteraction = onInteraction
        strip.synchronise(with: model)
        return strip
    }

    func updateNSView(_ strip: SpreadStripView, context: Context) {
        strip.onInteraction = onInteraction
        strip.synchronise(with: model)
    }
}

// MARK: - Strip

final class SpreadStripView: NSView {
    var onInteraction: (() -> Void)?

    /// Black space between spreads, so a page edge is visible arriving.
    private static let gutter: CGFloat = 12
    private static let slideDuration: CFTimeInterval = 0.22

    private var centrePanel: SpreadScrollView?
    private var leftPanel: SpreadScrollView?
    private var rightPanel: SpreadScrollView?

    /// How far the strip has been dragged, in panels. +1 means the panel that
    /// was off to the left has been pulled fully into view.
    private var offset: CGFloat = 0 {
        didSet { positionPanels() }
    }

    private weak var model: ReaderModel?
    private var builtDirection: ReadingDirection?
    private var isSwiping = false

    private var displayLink: CADisplayLink?
    private var slideFrom: CGFloat = 0
    private var slideTo: CGFloat = 0
    private var slideStart: CFTimeInterval = 0
    private var slideCompletion: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    // MARK: - Keeping up with the model

    func synchronise(with model: ReaderModel) {
        self.model = model

        guard model.hasComic else {
            teardown()
            return
        }

        // Flipping direction re-orders the pages inside every spread and swaps
        // which neighbour is on which side, so nothing on screen survives it.
        guard builtDirection == model.direction else {
            rebuild(at: model.spreadIndex, in: model)
            return
        }

        let target = model.spreadIndex
        if let centre = centrePanel, centre.isShowing(spreadAt: target, in: model) {
            ensureNeighbourPanels()
            return
        }

        // A turn arriving mid-slide collapses the one in flight rather than
        // queueing behind it, so a held-down arrow key can't build a backlog.
        if isAnimating { finishSlideNow() }

        // One step away means it can be slid to; anything further (Home, End,
        // a restored reading position) just snaps.
        if !isSwiping, let centre = centrePanel {
            for side in [ScreenSide.left, .right]
            where neighbouringSpread(from: centre.spreadIndex, on: side,
                                     direction: model.direction,
                                     spreadCount: model.spreads.count) == target {
                slide(revealing: side, in: model)
                return
            }
        }

        rebuild(at: target, in: model)
    }

    private func teardown() {
        finishSlideNow()
        for panel in [leftPanel, centrePanel, rightPanel] { panel?.removeFromSuperview() }
        leftPanel = nil
        centrePanel = nil
        rightPanel = nil
        builtDirection = nil
        offset = 0
    }

    private func rebuild(at index: Int, in model: ReaderModel) {
        teardown()
        builtDirection = model.direction
        centrePanel = makePanel(forSpreadAt: index, in: model)
        ensureNeighbourPanels()
    }

    /// Builds whichever neighbours are missing, so a swipe never has to wait.
    private func ensureNeighbourPanels() {
        guard let model, let centre = centrePanel else { return }
        if leftPanel == nil {
            leftPanel = neighbour(of: centre, on: .left, in: model)
                .flatMap { makePanel(forSpreadAt: $0, in: model) }
        }
        if rightPanel == nil {
            rightPanel = neighbour(of: centre, on: .right, in: model)
                .flatMap { makePanel(forSpreadAt: $0, in: model) }
        }
        positionPanels()
    }

    private func neighbour(
        of panel: SpreadScrollView, on side: ScreenSide, in model: ReaderModel
    ) -> Int? {
        neighbouringSpread(
            from: panel.spreadIndex,
            on: side,
            direction: model.direction,
            spreadCount: model.spreads.count
        )
    }

    private func makePanel(forSpreadAt index: Int, in model: ReaderModel) -> SpreadScrollView? {
        let pages = model.orderedPages(forSpreadAt: index)
        guard !pages.isEmpty else { return nil }

        let panel = SpreadScrollView()
        panel.spreadIndex = index
        panel.pageURLs = pages.map(\.url)
        panel.swipeCoordinator = self
        panel.onInteraction = { [weak self] in self?.onInteraction?() }
        addSubview(panel)

        if let images = model.cachedImages(forSpreadAt: index) {
            panel.show(images)
        } else {
            // Cold — prefetching usually beats us to it, but never assume.
            loadImages(into: panel, from: model)
        }
        return panel
    }

    private func loadImages(into panel: SpreadScrollView, from model: ReaderModel) {
        let urls = panel.pageURLs
        Task { @MainActor in
            var images: [NSImage] = []
            for url in urls {
                guard let image = await model.image(for: url) else { continue }
                images.append(image)
            }
            // The panel may have been recycled away while we waited on the disk.
            guard panel.superview === self, panel.pageURLs == urls, !images.isEmpty else { return }
            panel.show(images)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        positionPanels()
    }

    private func positionPanels() {
        let step = bounds.width + Self.gutter
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        centrePanel?.frame = frame(forSlot: 0, step: step)
        leftPanel?.frame = frame(forSlot: -1, step: step)
        rightPanel?.frame = frame(forSlot: 1, step: step)
        CATransaction.commit()
    }

    private func frame(forSlot slot: CGFloat, step: CGFloat) -> NSRect {
        NSRect(x: (slot + offset) * step, y: 0, width: bounds.width, height: bounds.height)
    }

    // MARK: - Swipe

    /// Called by a panel that has run out of room to pan. Returns true when the
    /// strip takes the gesture over.
    func beginSwipe(with event: NSEvent) -> Bool {
        guard !isSwiping, !isAnimating else { return false }
        ensureNeighbourPanels()
        guard leftPanel != nil || rightPanel != nil else { return false }

        isSwiping = true
        // Clamped to zero on a side with nothing to show, which is what gives
        // the damped resist at the first and last page.
        event.trackSwipeEvent(
            options: .lockDirection,
            dampenAmountThresholdMin: rightPanel != nil ? -1 : 0,
            max: leftPanel != nil ? 1 : 0
        ) { [weak self] amount, _, isComplete, _ in
            guard let self else { return }
            // Every intermediate value moves the strip — this is what makes the
            // page follow your fingers instead of snapping at the end.
            self.offset = amount
            self.onInteraction?()

            guard isComplete else { return }
            self.isSwiping = false
            if amount > 0.5 {
                self.commit(revealing: .left)
            } else if amount < -0.5 {
                self.commit(revealing: .right)
            } else {
                self.offset = 0
            }
        }
        return true
    }

    /// Finishes a swipe: promotes the revealed panel, then lets the model catch up.
    private func commit(revealing side: ScreenSide) {
        guard promote(revealing: side) else {
            offset = 0
            return
        }
        // Order matters. The strip already shows the new spread, so when the
        // model change comes back round through synchronise there is nothing
        // left to do and no second animation.
        switch side {
        case .left: model?.pressedLeftArrow()
        case .right: model?.pressedRightArrow()
        }
    }

    /// Makes the revealed panel the centre one.
    ///
    /// Its slot moves by exactly one step while `offset` falls back by exactly
    /// one step, so its position on screen is unchanged — the promotion is
    /// invisible by construction rather than by timing.
    @discardableResult
    private func promote(revealing side: ScreenSide) -> Bool {
        guard let incoming = (side == .left ? leftPanel : rightPanel) else { return false }
        let outgoing = centrePanel
        centrePanel = incoming

        switch side {
        case .left:
            rightPanel?.removeFromSuperview()
            rightPanel = outgoing
            leftPanel = nil
        case .right:
            leftPanel?.removeFromSuperview()
            leftPanel = outgoing
            rightPanel = nil
        }

        offset = 0
        ensureNeighbourPanels()
        return true
    }

    // MARK: - Slide animation for keyboard and button turns

    private var isAnimating: Bool { displayLink != nil }

    private func slide(revealing side: ScreenSide, in model: ReaderModel) {
        ensureNeighbourPanels()
        guard (side == .left ? leftPanel : rightPanel) != nil else {
            rebuild(at: model.spreadIndex, in: model)
            return
        }
        startSlide(to: side == .left ? 1 : -1) { [weak self] in
            self?.promote(revealing: side)
        }
    }

    private func startSlide(to destination: CGFloat, completion: @escaping () -> Void) {
        finishSlideNow()
        slideFrom = offset
        slideTo = destination
        slideStart = CACurrentMediaTime()
        slideCompletion = completion

        let link = displayLink(target: self, selector: #selector(stepSlide))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepSlide() {
        let elapsed = CACurrentMediaTime() - slideStart
        let progress = min(elapsed / Self.slideDuration, 1)
        guard progress < 1 else {
            finishSlideNow()
            return
        }
        let eased = 1 - pow(1 - progress, 3)
        offset = slideFrom + (slideTo - slideFrom) * CGFloat(eased)
    }

    /// Jumps a slide straight to its end. Also how an interrupted slide is
    /// resolved, so the strip is never left stranded between panels.
    private func finishSlideNow() {
        guard let link = displayLink else { return }
        link.invalidate()
        displayLink = nil
        offset = slideTo
        let completion = slideCompletion
        slideCompletion = nil
        completion?()
    }
}
