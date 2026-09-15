import AppKit
import SwiftUI

// MARK: - Scroll view

/// One spread's worth of pages: zoomable, pannable, and aware that once it has
/// nothing left to pan the gesture belongs to the strip that owns it.
final class SpreadScrollView: NSScrollView {
    var onInteraction: (() -> Void)?

    /// Which spread this panel is showing, so the strip can tell its panels
    /// apart as they're recycled.
    var spreadIndex = 0
    /// The pages on show, in screen order. Also identifies the panel's contents
    /// across a reading-direction flip, which reverses them.
    var pageURLs: [URL] = []

    weak var swipeCoordinator: SpreadStripView?

    private let pageView = SpreadDocumentView()
    /// Whether the page sits at its fitted scale — true until the reader zooms
    /// it. Tracked outright rather than inferred from magnification, because
    /// AppKit clamps magnification as the limits move during a window resize
    /// and the inference misfires mid-way, leaving a page stranded half-zoomed.
    private var isFitted = true

    init() {
        super.init(frame: .zero)

        // The clip view has to be swapped in before the document view; assigning
        // one drops the other.
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = pageView

        // The strip paints the black behind everything. A panel drawing its own
        // would cover the neighbour it overlaps.
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        allowsMagnification = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keystrokes belong to the reader, not the scroll view — otherwise clicking
    /// a page would hand it first responder and the arrow keys would scroll it
    /// instead of turning the page.
    override var acceptsFirstResponder: Bool { false }

    /// How much width the page actually takes up on screen right now, which is
    /// what the strip spaces panels by. Spacing by the window's width instead
    /// would put a letterbox bar from each panel either side of the gutter.
    var displayedContentWidth: CGFloat {
        guard bounds.width > 0 else { return 0 }
        let onScreen = pageView.frame.width * magnification
        return min(max(onScreen, 1), bounds.width)
    }

    /// Whether this panel already shows the given spread, pages and all. The
    /// page check matters because flipping reading direction reverses them
    /// without changing the spread index.
    func isShowing(spreadAt index: Int, in model: ReaderModel) -> Bool {
        spreadIndex == index && pageURLs == model.orderedPages(forSpreadAt: index).map(\.url)
    }

    /// Search hits to draw, keyed by page file; only this panel's pages matter.
    func setHighlights(_ byPage: [URL: [CGRect]]) {
        pageView.setHighlights(pageURLs.map { byPage[$0] ?? [] })
    }

    func show(_ images: [NSImage]) {
        guard !pageView.isShowing(images) else { return }
        pageView.show(images)
        isFitted = true
        updateMagnificationLimits(resettingToFit: true)
    }

    /// Back to the fitted scale. A page leaving the centre gets this, so that if
    /// the reader swipes back to it, it arrives fitted like any other page.
    func resetToFit() {
        isFitted = true
        updateMagnificationLimits(resettingToFit: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Resizing the window changes what "fits", so a page left at fit stays
        // at fit rather than drifting off-scale.
        updateMagnificationLimits(resettingToFit: isFitted)
    }

    /// Magnification 1.0 means native pixel size, and a comic page is far larger
    /// than the window — so "fitted" is a fraction of it. Pinning
    /// `minMagnification` to the fitted scale is what stops the page shrinking
    /// away into the middle of a black void.
    private func updateMagnificationLimits(resettingToFit: Bool) {
        let content = pageView.frame.size
        let viewport = contentView.frame.size
        guard content.width > 0, content.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return }

        let fit = min(viewport.width / content.width, viewport.height / content.height)
        guard fit > 0, fit.isFinite else { return }

        // Max before min: raising the floor above the ceiling makes AppKit
        // clamp in an order we don't control.
        maxMagnification = fit * 6
        minMagnification = fit
        if resettingToFit || magnification < fit {
            magnification = fit
        }
        if magnification <= fit + 0.0001 { isFitted = true }
    }

    // MARK: - Click

    private var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    /// A click that didn't move is a tap. Anything that travelled was the
    /// start of something else and is left alone.
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        super.mouseUp(with: event)
        guard let start = mouseDownPoint, event.clickCount == 1 else { return }
        let end = event.locationInWindow
        guard hypot(end.x - start.x, end.y - start.y) < 4 else { return }
        swipeCoordinator?.onTap?()
    }

    // MARK: - Swipe

    /// Required for the full gesture stream that `trackSwipeEvent` needs.
    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }

    override func scrollWheel(with event: NSEvent) {
        if shouldYieldToStrip(for: event), swipeCoordinator?.beginSwipe(with: event) == true {
            return
        }
        super.scrollWheel(with: event)
        onInteraction?()
    }

    /// A horizontal two-finger swipe belongs to the strip, but only once this
    /// page has nothing left to show in that direction — the same way Safari
    /// pans a wide page before it goes back.
    private func shouldYieldToStrip(for event: NSEvent) -> Bool {
        // Honours the "Swipe between pages" setting in System Settings.
        NSEvent.isSwipeTrackingFromScrollEventsEnabled
            && event.phase == .began
            && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            && hasNothingLeftToPan(towards: event.scrollingDeltaX)
    }

    /// Whether the page is already as far over as it goes in the swipe's
    /// direction. A fitted page has no room at all, so it always qualifies.
    private func hasNothingLeftToPan(towards deltaX: CGFloat) -> Bool {
        let visible = documentVisibleRect
        let content = pageView.frame
        guard content.width > visible.width + 0.5 else { return true }
        guard deltaX != 0 else { return false }
        // A positive delta drags the page right, uncovering what's further left.
        return deltaX > 0
            ? visible.minX <= 0.5
            : visible.maxX >= content.width - 0.5
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        noteUserZoom()
    }

    override func smartMagnify(with event: NSEvent) {
        super.smartMagnify(with: event)
        noteUserZoom()
    }

    /// The reader's own zoom is the only thing that un-fits a page. It also
    /// changes how wide the page sits, and so where its neighbours go — and
    /// only this reports that: a re-fit caused by the strip resizing the
    /// panel must not call back into the strip.
    private func noteUserZoom() {
        isFitted = magnification <= minMagnification + 0.0001
        swipeCoordinator?.contentWidthChanged()
        onInteraction?()
    }
}

// MARK: - Centring

/// Keeps a page centred when it's smaller than the window. `NSClipView` pins
/// content to a corner otherwise, so a fitted page would sit off to one side.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let content = documentView.frame

        if content.width < rect.width {
            rect.origin.x = (content.width - rect.width) / 2
        }
        if content.height < rect.height {
            rect.origin.y = (content.height - rect.height) / 2
        }
        return rect
    }
}

// MARK: - Page layout

/// Draws the spread's pages side by side at native resolution. The scroll view
/// scales this down to fit and back up as the reader zooms, so zooming in
/// reveals real detail rather than magnifying a downscaled copy.
private final class SpreadDocumentView: NSView {
    private var images: [NSImage] = []
    private var imageViews: [NSImageView] = []
    /// One per page, over its image view, drawing the search hits.
    private var highlightViews: [HighlightOverlayView] = []
    private var pendingHighlights: [[CGRect]] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func isShowing(_ candidates: [NSImage]) -> Bool {
        // PageCache hands back the same instance for a given page, so identity
        // is enough and saves rebuilding the views on every SwiftUI update.
        images.count == candidates.count
            && zip(images, candidates).allSatisfy { $0 === $1 }
    }

    func show(_ images: [NSImage]) {
        self.images = images
        imageViews.forEach { $0.removeFromSuperview() }
        highlightViews.forEach { $0.removeFromSuperview() }
        imageViews = images.map { image in
            let view = NSImageView()
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.animates = false
            addSubview(view)
            return view
        }
        highlightViews = images.map { _ in
            let view = HighlightOverlayView()
            addSubview(view)
            return view
        }
        setHighlights(pendingHighlights)
        frame = NSRect(origin: .zero, size: Self.naturalSize(of: images))
        needsLayout = true
    }

    /// Boxes per page, aligned with `images`. Kept if the pages haven't been
    /// shown yet, and applied when they are.
    func setHighlights(_ boxesPerPage: [[CGRect]]) {
        pendingHighlights = boxesPerPage
        for (view, boxes) in zip(highlightViews, boxesPerPage) { view.boxes = boxes }
        for view in highlightViews.dropFirst(boxesPerPage.count) { view.boxes = [] }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 0
        for (index, width) in Self.scaledWidths(of: images, at: height).enumerated() {
            let frame = NSRect(x: x, y: 0, width: width, height: height)
            imageViews[index].frame = frame
            highlightViews[index].frame = frame
            x += width
        }
    }

    /// Facing pages are scaled to a common height so they line up the way they
    /// would in a printed book, even when one side was scanned larger. They
    /// sit flush: the only seam between them is the pages' own margins.
    static func naturalSize(of images: [NSImage]) -> NSSize {
        let sizes = images.map(\.pixelSize).filter { $0.width > 0 && $0.height > 0 }
        guard let height = sizes.map(\.height).max() else { return .zero }
        return NSSize(width: scaledWidths(of: images, at: height).reduce(0, +), height: height)
    }

    private static func scaledWidths(of images: [NSImage], at height: CGFloat) -> [CGFloat] {
        images.map { image in
            let size = image.pixelSize
            guard size.height > 0 else { return 0 }
            return size.width * (height / size.height)
        }
    }

}

/// Draws search hits over a page. Sits over the image view at the same frame,
/// so it scales and pans with the page for free.
private final class HighlightOverlayView: NSView {
    /// Vision's boxes: unit rects with the origin at the image's bottom-left.
    /// Clearing them fades the paint out rather than snapping it away.
    var boxes: [CGRect] = [] {
        didSet {
            guard boxes != oldValue else { return }
            if boxes.isEmpty {
                fadeOut()
            } else {
                drawn = boxes
                alphaValue = 1
                needsDisplay = true
            }
        }
    }

    /// What's on screen — lags `boxes` while a fade is running.
    private var drawn: [CGRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Animation completions land on the main thread; the compiler
            // just can't see it.
            MainActor.assumeIsolated {
                guard let self, self.boxes.isEmpty else { return }
                self.drawn = []
                self.needsDisplay = true
            }
        })
    }

    override var isFlipped: Bool { true }

    /// Never in the way of a click, a scroll or a swipe.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !drawn.isEmpty else { return }
        let size = bounds.size
        for box in drawn {
            // This view is flipped; Vision's y runs the other way.
            let rect = NSRect(
                x: box.minX * size.width,
                y: (1 - box.maxY) * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            ).insetBy(dx: -size.width * 0.004, dy: -size.height * 0.003)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.2, yRadius: rect.height * 0.2)
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 0.38).setFill()
            path.fill()
            NSColor(calibratedRed: 1, green: 0.75, blue: 0, alpha: 0.9).setStroke()
            path.lineWidth = max(size.height * 0.0015, 1)
            path.stroke()
        }
    }
}

private extension NSImage {
    /// True pixel dimensions. `size` is in points and honours the file's DPI
    /// metadata, which comic scans routinely set to something other than 72.
    var pixelSize: NSSize {
        guard let rep = representations.first else { return size }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
