import AppKit
import SwiftUI
import VisionKit
import PageCapture

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

    typealias CaptureHandlers = (
        panels: @MainActor (URL) async -> [DetectedPanel],
        capture: (URL, CaptureShape) -> Void,
        end: () -> Void
    )
    var captureHandlers: CaptureHandlers? {
        didSet { pageView.captureHandlers = captureHandlers }
    }
    private(set) var isCapturing = false

    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
        pageView.setCapturing(capturing)
    }



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

    /// Shapes to outline after a jump, keyed by page file.
    func setFocus(_ byPage: [URL: [[CGPoint]]]) {
        pageView.setFocus(pageURLs.map { byPage[$0] ?? [] })
    }

    func show(_ images: [NSImage]) {
        guard !pageView.isShowing(images) else { return }
        pageView.show(images, urls: pageURLs)
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
        // In capture mode a click is a capture (or nothing), never a tap.
        guard !isCapturing, let start = mouseDownPoint, event.clickCount == 1 else { return }
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
    private var pendingFocus: [[[CGPoint]]] = []
    /// One per page, on top: the system's Live Text, so lettering can be
    /// selected and copied like text anywhere else on the Mac.
    private var liveTextViews: [ImageAnalysisOverlayView] = []
    private var analysisTasks: [Task<Void, Never>] = []
    /// One per page, topmost: takes clicks and drags as captures while the
    /// reader is capturing, and stays out of the way otherwise.
    private var captureViews: [CaptureOverlayView] = []
    private var pageURLs: [URL] = []
    private var isCapturing = false
    var captureHandlers: SpreadScrollView.CaptureHandlers? {
        didSet { captureViews.forEach { $0.handlers = captureHandlers } }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func isShowing(_ candidates: [NSImage]) -> Bool {
        // PageCache hands back the same instance for a given page, so identity
        // is enough and saves rebuilding the views on every SwiftUI update.
        images.count == candidates.count
            && zip(images, candidates).allSatisfy { $0 === $1 }
    }

    func show(_ images: [NSImage], urls: [URL] = []) {
        self.images = images
        self.pageURLs = urls
        analysisTasks.forEach { $0.cancel() }
        analysisTasks = []
        imageViews.forEach { $0.removeFromSuperview() }
        highlightViews.forEach { $0.removeFromSuperview() }
        liveTextViews.forEach { $0.removeFromSuperview() }
        captureViews.forEach { $0.removeFromSuperview() }
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
        liveTextViews = zip(images, imageViews).map { image, imageView in
            let overlay = ImageAnalysisOverlayView()
            NotificationCenter.default.addObserver(forName: .panelsClearPageTextSelection, object: nil, queue: .main) { [weak overlay] _ in
                MainActor.assumeIsolated { overlay?.resetSelection() }
            }
            overlay.trackingImageView = imageView
            overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
            // No floating Live Text button in the corner of every page.
            overlay.isSupplementaryInterfaceHidden = true
            addSubview(overlay)
            return overlay
        }
        captureViews = images.indices.map { index in
            let overlay = CaptureOverlayView()
            overlay.pageURL = urls.indices.contains(index) ? urls[index] : nil
            overlay.handlers = captureHandlers
            addSubview(overlay)
            return overlay
        }
        setHighlights(pendingHighlights)
        setFocus(pendingFocus)
        setCapturing(isCapturing)
        frame = NSRect(origin: .zero, size: Self.naturalSize(of: images))
        needsLayout = true

        // Analyses arrive whenever they're ready; a page shown again gets its
        // cached one straight away.
        for (index, image) in images.enumerated() {
            let url = urls.indices.contains(index) ? urls[index] : nil
            let overlay = liveTextViews[index]
            analysisTasks.append(Task { @MainActor in
                guard let analysis = await LiveTextAnalyses.shared.analysis(of: image, for: url),
                      !Task.isCancelled, overlay.superview === self
                else { return }
                overlay.analysis = analysis
            })
        }
    }

    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
        captureViews.forEach { $0.isActive = capturing }
    }

    /// Outlines per page, aligned with `images`.
    func setFocus(_ polygonsPerPage: [[[CGPoint]]]) {
        pendingFocus = polygonsPerPage
        for (view, polygons) in zip(highlightViews, polygonsPerPage) { view.polygons = polygons }
        for view in highlightViews.dropFirst(polygonsPerPage.count) { view.polygons = [] }
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
            liveTextViews[index].frame = frame
            captureViews[index].frame = frame
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

extension Notification.Name {
    /// Posted when something else wants the keyboard: Live Text's selection
    /// view holds on to first responder for as long as it has a selection, so
    /// the selection has to go first.
    static let panelsClearPageTextSelection = Notification.Name("PanelsClearPageTextSelection")
}

/// Live Text analyses, one per page, so a page shown twice is analysed once.
final class LiveTextAnalyses: @unchecked Sendable {
    static let shared = LiveTextAnalyses()

    private let analyzer = ImageAnalyzer()
    private let cache = NSCache<NSURL, ImageAnalysis>()

    private init() {
        cache.countLimit = 60
    }

    func analysis(of image: NSImage, for url: URL?) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        if let url, let hit = cache.object(forKey: url as NSURL) { return hit }
        let configuration = ImageAnalyzer.Configuration([.text])
        guard let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration)
        else { return nil }
        if let url { cache.setObject(analysis, forKey: url as NSURL) }
        return analysis
    }
}

/// Capture mode on one page: draw a shape around what you want.
///
/// A click places a corner; a line follows the mouse from the last one; the
/// next click places the next corner. Clicking the first corner again, or
/// pressing Return, closes the shape and captures it. A drag draws a
/// rectangle instead. Delete removes the last corner; Escape cancels.
/// Inert — invisible and untouchable — when not active, so Live Text and
/// paging behave as usual.
private final class CaptureOverlayView: NSView {
    var pageURL: URL?
    var handlers: SpreadScrollView.CaptureHandlers?

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            reset()
            // Warms panel detection so a finished shape can be numbered.
            if isActive { detectPanels() } else { detection?.cancel() }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private var detection: Task<Void, Never>?
    private var dragStart: NSPoint?
    private var marquee: NSRect?
    /// Corners placed so far, in view coordinates.
    private var lasso: [NSPoint] = []
    private var mouseAt: NSPoint?
    private var tracking: NSTrackingArea?
    private weak var previousResponder: NSResponder?

    /// How close to the first corner a click has to land to close the shape.
    private let closeRadius: CGFloat = 9

    override var isFlipped: Bool { true }

    /// Only while a shape is being drawn: Return, Delete and Escape belong to it.
    override var acceptsFirstResponder: Bool { isActive && !lasso.isEmpty }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive && bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        if isActive { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func reset() {
        dragStart = nil
        marquee = nil
        cancelLasso()
    }

    private func detectPanels() {
        detection?.cancel()
        guard let pageURL, let handlers else { return }
        detection = Task { @MainActor in
            _ = await handlers.panels(pageURL)
        }
    }

    // MARK: Mouse

    private func unit(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActive else { return }
        mouseAt = convert(event.locationInWindow, from: nil)
        if !lasso.isEmpty { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return super.mouseDown(with: event) }
        dragStart = convert(event.locationInWindow, from: nil)
        marquee = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard isActive, lasso.isEmpty, let start = dragStart else { return }
        let now = convert(event.locationInWindow, from: nil)
        marquee = NSRect(x: min(start.x, now.x), y: min(start.y, now.y),
                         width: abs(now.x - start.x), height: abs(now.y - start.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isActive, let start = dragStart, let pageURL else { return }
        defer { dragStart = nil; needsDisplay = true }
        let end = convert(event.locationInWindow, from: nil)
        let travelled = hypot(end.x - start.x, end.y - start.y)

        if !lasso.isEmpty {
            // Another corner — or the first one again, which closes the shape.
            if let first = lasso.first, lasso.count >= 3, hypot(end.x - first.x, end.y - first.y) <= closeRadius {
                closeLasso()
            } else {
                lasso.append(end)
                mouseAt = end
            }
        } else if travelled >= 4 {
            defer { marquee = nil }
            guard let marquee, marquee.width > 8, marquee.height > 8 else { return }
            let rect = CGRect(x: marquee.minX / bounds.width, y: marquee.minY / bounds.height,
                              width: marquee.width / bounds.width, height: marquee.height / bounds.height)
            handlers?.capture(pageURL, .rect(rect))
        } else {
            // First corner. Take the keyboard for the rest of the shape.
            lasso = [end]
            mouseAt = end
            previousResponder = window?.firstResponder
            window?.makeFirstResponder(self)
        }
    }

    // MARK: Lasso

    private func closeLasso() {
        defer { cancelLasso() }
        guard lasso.count >= 3, let pageURL else { return }
        handlers?.capture(pageURL, .polygon(lasso.map(unit)))
    }

    private func cancelLasso() {
        guard !lasso.isEmpty else { return }
        lasso = []
        mouseAt = nil
        if window?.firstResponder === self {
            window?.makeFirstResponder(previousResponder)
        }
        previousResponder = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            closeLasso()
        case 51, 117:  // Delete, Forward Delete
            if !lasso.isEmpty {
                lasso.removeLast()
                if lasso.isEmpty { cancelLasso() }
                needsDisplay = true
            }
        case 53:  // Escape
            if lasso.isEmpty { handlers?.end() } else { cancelLasso() }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    /// A line that reads on paper and on ink alike: a white halo under a
    /// coloured stroke.
    private func strokeVisible(_ path: NSBezierPath, width: CGFloat, color: NSColor, dashed: Bool = false) {
        if dashed { path.setLineDash([width * 3, width * 3], count: 2, phase: 0) }
        path.lineWidth = width * 3
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let size = bounds.size
        let accent = NSColor.systemOrange
        let line = max(size.height * 0.002, 1.5)

        if let marquee {
            let path = NSBezierPath(rect: marquee)
            accent.withAlphaComponent(0.15).setFill()
            path.fill()
            strokeVisible(path, width: line, color: accent)
        }

        guard let first = lasso.first else { return }

        // Placed edges.
        let path = NSBezierPath()
        path.move(to: first)
        for point in lasso.dropFirst() { path.line(to: point) }
        strokeVisible(path, width: line, color: accent)

        // The edge being drawn, following the mouse.
        if let mouseAt, let last = lasso.last {
            let rubber = NSBezierPath()
            rubber.move(to: last)
            rubber.line(to: mouseAt)
            strokeVisible(rubber, width: line, color: accent.withAlphaComponent(0.7))
        }

        // How it would close.
        if lasso.count >= 3, let last = lasso.last {
            let closing = NSBezierPath()
            closing.move(to: last)
            closing.line(to: first)
            strokeVisible(closing, width: line * 0.8, color: accent.withAlphaComponent(0.5), dashed: true)
        }

        // Corners: filled dots with a white ring, the first one larger — click
        // it to close.
        let dot = max(line * 2.5, 4)
        for (index, point) in lasso.enumerated() {
            let r = index == 0 && lasso.count >= 3 ? closeRadius : dot
            let ring = NSBezierPath(ovalIn: NSRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            NSColor.white.setFill()
            ring.fill()
            let inner = NSBezierPath(ovalIn: NSRect(x: point.x - r * 0.6, y: point.y - r * 0.6, width: r * 1.2, height: r * 1.2))
            accent.setFill()
            inner.fill()
        }
    }
}

/// Draws search hits over a page. Sits over the image view at the same frame,
/// so it scales and pans with the page for free.
private final class HighlightOverlayView: NSView {
    /// Vision's boxes: unit rects with the origin at the image's bottom-left.
    /// Clearing them fades the paint out rather than snapping it away.
    var boxes: [CGRect] = [] {
        didSet { if boxes != oldValue { refresh() } }
    }
    /// Cited shapes to outline after a jump: unit coords, top-left origin.
    var polygons: [[CGPoint]] = [] {
        didSet { if polygons != oldValue { refresh() } }
    }

    /// What's on screen — lags the inputs while a fade is running.
    private var drawn: [CGRect] = []
    private var drawnPolygons: [[CGPoint]] = []

    private func refresh() {
        if boxes.isEmpty && polygons.isEmpty {
            fadeOut()
        } else {
            drawn = boxes
            drawnPolygons = polygons
            alphaValue = 1
            needsDisplay = true
        }
    }

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
                guard let self, self.boxes.isEmpty, self.polygons.isEmpty else { return }
                self.drawn = []
                self.drawnPolygons = []
                self.needsDisplay = true
            }
        })
    }

    override var isFlipped: Bool { true }

    /// Never in the way of a click, a scroll or a swipe.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.size
        for polygon in drawnPolygons where polygon.count >= 3 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: polygon[0].x * size.width, y: polygon[0].y * size.height))
            for p in polygon.dropFirst() { path.line(to: NSPoint(x: p.x * size.width, y: p.y * size.height)) }
            path.close()
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            path.lineWidth = max(size.height * 0.003, 2) * 3
            NSColor.white.withAlphaComponent(0.85).setStroke()
            path.stroke()
            path.lineWidth = max(size.height * 0.003, 2)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        guard !drawn.isEmpty else { return }
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
