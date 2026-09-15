import AppKit
import SwiftUI

/// The zoomable page canvas.
///
/// This is AppKit rather than SwiftUI on purpose. A two-finger slide is a
/// scroll event, not a drag, so SwiftUI's `DragGesture` never sees it, and
/// `MagnifyGesture` would leave us hand-rolling anchoring, clamping, momentum
/// and rubber-banding. `NSScrollView` already does all of that the way every
/// other Mac app does.
struct ZoomableSpread: NSViewRepresentable {
    /// The spread's pages, already in on-screen order for the reading direction.
    let images: [NSImage]
    /// Called on pan or zoom, so the chrome reappears while the reader is busy.
    let onInteraction: () -> Void

    func makeNSView(context: Context) -> SpreadScrollView {
        let scrollView = SpreadScrollView()
        scrollView.onInteraction = onInteraction
        scrollView.show(images)
        return scrollView
    }

    func updateNSView(_ scrollView: SpreadScrollView, context: Context) {
        scrollView.onInteraction = onInteraction
        scrollView.show(images)
    }
}

// MARK: - Scroll view

final class SpreadScrollView: NSScrollView {
    var onInteraction: (() -> Void)?

    private let pageView = SpreadDocumentView()
    /// The view starts at magnification 1.0 — native pixel size — and the first
    /// layout pass runs before there's a viewport to measure against. Until a
    /// fit actually succeeds, the next one is unconditional.
    private var hasFitted = false

    init() {
        super.init(frame: .zero)

        // The clip view has to be swapped in before the document view; assigning
        // one drops the other.
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = pageView

        drawsBackground = true
        backgroundColor = .black
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

    func show(_ images: [NSImage]) {
        guard !pageView.isShowing(images) else { return }
        pageView.show(images)
        hasFitted = false
        updateMagnificationLimits(resettingToFit: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasFitted = magnification <= minMagnification + 0.0001
        super.setFrameSize(newSize)
        // Resizing the window changes what "fits", so a page left at fit stays
        // at fit rather than drifting off-scale.
        updateMagnificationLimits(resettingToFit: wasFitted)
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

        minMagnification = fit
        maxMagnification = fit * 6
        if resettingToFit || !hasFitted || magnification < fit {
            magnification = fit
        }
        hasFitted = true
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onInteraction?()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onInteraction?()
    }

    override func smartMagnify(with event: NSEvent) {
        super.smartMagnify(with: event)
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
        imageViews = images.map { image in
            let view = NSImageView()
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.animates = false
            addSubview(view)
            return view
        }
        frame = NSRect(origin: .zero, size: Self.naturalSize(of: images))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 0
        for (view, image) in zip(imageViews, images) {
            let size = image.pixelSize
            guard size.height > 0 else { continue }
            let width = size.width * (height / size.height)
            view.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
    }

    /// Facing pages are scaled to a common height so they line up the way they
    /// would in a printed book, even when one side was scanned larger.
    static func naturalSize(of images: [NSImage]) -> NSSize {
        let sizes = images.map(\.pixelSize).filter { $0.width > 0 && $0.height > 0 }
        guard let height = sizes.map(\.height).max() else { return .zero }
        let width = sizes.reduce(0) { $0 + $1.width * (height / $1.height) }
        return NSSize(width: width, height: height)
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
