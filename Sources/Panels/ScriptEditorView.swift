import AppKit
import SwiftUI
import PanelsProject

/// The script pane: a plain text view whose citations are chips.
///
/// The Markdown in `Project.script` is the source of truth. It's rendered
/// into the text view on load, and every edit is serialised straight back —
/// so the file on disk is never more than a second behind the keys.
struct ScriptEditorView: NSViewRepresentable {
    let project: Project
    let model: ReaderModel

    func makeCoordinator() -> Coordinator { Coordinator(project: project, model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = ScriptTextView(frame: .zero)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        let model = model
        textView.onFocusChange = { editing in model.isScriptEditing = editing }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = ScriptStyle.background
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 22, height: 24)
        textView.typingAttributes = ScriptStyle.attributes(for: .body)
        textView.linkTextAttributes = [:]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ScriptStyle.background
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        context.coordinator.load()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.project = project
        coordinator.model = model
        if coordinator.loadedProjectURL != project.url {
            coordinator.load()
        }
        if let citation = project.pendingInsertion {
            coordinator.insert(citation)
            project.pendingInsertion = nil
        }
        if let command = project.pendingCommand {
            coordinator.apply(command)
            project.pendingCommand = nil
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var project: Project
        var model: ReaderModel
        weak var textView: NSTextView?
        var loadedProjectURL: URL?
        /// True while the view is being filled from the script, so the change
        /// notification doesn't write the script back to itself.
        private var isLoading = false
        private var thumbnails: [String: NSImage] = [:]

        init(project: Project, model: ReaderModel) {
            self.project = project
            self.model = model
        }

        func load() {
            guard let textView else { return }
            isLoading = true
            defer { isLoading = false }
            textView.textStorage?.setAttributedString(render(project.script))
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            loadedProjectURL = project.url
        }

        // MARK: Markdown → text

        private func render(_ markdown: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let blocks = ScriptMarkdown.parse(markdown)
            for (index, block) in blocks.enumerated() {
                let style: ScriptStyle.Paragraph
                switch block {
                case .heading(let level, _): style = level == 1 ? .heading1 : .heading2
                case .paragraph: style = .body
                }
                for run in block.inlines {
                    switch run {
                    case .text(let s):
                        result.append(NSAttributedString(string: s, attributes: ScriptStyle.attributes(for: style)))
                    case .citation(let id, let text):
                        result.append(chip(id: id, text: text, style: style))
                    }
                }
                if index < blocks.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: ScriptStyle.attributes(for: style)))
                }
            }
            return result
        }

        private func chip(id: String, text: String, style: ScriptStyle.Paragraph) -> NSAttributedString {
            let attachment = CitationAttachment.make(id: id, text: text, thumbnail: thumbnail(for: id))
            let chip = NSMutableAttributedString(attachment: attachment)
            var attributes = ScriptStyle.attributes(for: style)
            attributes[.link] = ScriptMarkdown.citationURL(id: id)
            chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
            return chip
        }

        private func thumbnail(for citationID: String) -> NSImage? {
            if let cached = thumbnails[citationID] { return cached }
            guard let citation = project.citation(id: citationID), let file = citation.captureFile,
                  let image = NSImage(contentsOf: project.capturesFolder.appendingPathComponent(file))
            else { return nil }
            thumbnails[citationID] = image
            return image
        }

        // MARK: Text → Markdown

        private func serialise() -> String {
            guard let storage = textView?.textStorage else { return project.script }
            var blocks: [ScriptBlock] = []
            let string = storage.string as NSString
            var location = 0
            while location <= string.length {
                let lineRange = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
                var content = lineRange
                if content.length > 0, string.character(at: content.location + content.length - 1) == 0x0A {
                    content.length -= 1
                }
                var runs: [ScriptInline] = []
                var level = 0
                storage.enumerateAttributes(in: content, options: []) { attributes, range, _ in
                    if let attachment = attributes[.attachment] as? CitationAttachment, let id = attachment.citationID {
                        runs.append(.citation(id: id, text: attachment.citationText))
                    } else {
                        let text = string.substring(with: range)
                        if !text.isEmpty {
                            if case .text(let previous) = runs.last {
                                runs[runs.count - 1] = .text(previous + text)
                            } else {
                                runs.append(.text(text))
                            }
                        }
                    }
                    if level == 0, let style = attributes[ScriptStyle.paragraphKey] as? String {
                        level = style == ScriptStyle.Paragraph.heading1.rawValue ? 1
                              : style == ScriptStyle.Paragraph.heading2.rawValue ? 2 : 0
                    }
                }
                blocks.append(level > 0 ? .heading(level: level, runs) : .paragraph(runs))
                if lineRange.length == 0 || content.length == lineRange.length { break }
                location = lineRange.location + lineRange.length
                if location == string.length {
                    // A trailing newline means one more, empty, paragraph.
                    blocks.append(.paragraph([]))
                    break
                }
            }
            return ScriptMarkdown.serialize(blocks)
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading else { return }
            project.script = serialise()
        }

        // MARK: Insertion and formatting

        func insert(_ citation: Citation) {
            guard let textView else { return }
            let style = currentStyle()
            let piece = NSMutableAttributedString(attributedString: chip(id: citation.id, text: citation.text, style: style))
            let range = textView.selectedRange()
            // A space after the chip unless one is already there, so typing
            // carries straight on.
            let text = textView.string as NSString
            let next = range.location + range.length
            if next >= text.length || text.character(at: next) != 0x20 {
                piece.append(NSAttributedString(string: " ", attributes: ScriptStyle.attributes(for: style)))
            }
            guard textView.shouldChangeText(in: range, replacementString: piece.string) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: piece)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
            textView.window?.makeFirstResponder(textView)
        }

        func apply(_ command: ScriptCommand) {
            guard let textView, let storage = textView.textStorage else { return }
            let style: ScriptStyle.Paragraph
            switch command {
            case .heading(1): style = .heading1
            case .heading: style = .heading2
            case .body: style = .body
            }
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: textView.selectedRange())
            guard textView.shouldChangeText(in: paragraph, replacementString: nil) else { return }
            let attributes = ScriptStyle.attributes(for: style)
            storage.enumerateAttribute(.attachment, in: paragraph, options: []) { value, range, _ in
                var applied = attributes
                if value != nil {
                    applied[.attachment] = value
                    if let id = (value as? CitationAttachment)?.citationID {
                        applied[.link] = ScriptMarkdown.citationURL(id: id)
                    }
                }
                storage.setAttributes(applied, range: range)
            }
            textView.didChangeText()
            textView.typingAttributes = attributes
        }

        private func currentStyle() -> ScriptStyle.Paragraph {
            guard let textView else { return .body }
            let raw = textView.typingAttributes[ScriptStyle.paragraphKey] as? String
            return ScriptStyle.Paragraph(rawValue: raw ?? "") ?? .body
        }

        // MARK: Clicks

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, let id = ScriptMarkdown.citationID(from: url) else { return false }
            model.jump(toCitation: id)
            return true
        }

        func textView(_ textView: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            guard let attachment = cell.attachment as? CitationAttachment, let id = attachment.citationID else { return }
            model.jump(toCitation: id)
        }
    }
}

// MARK: - Text view

/// Says when it has the keyboard, so the reader's own keys — space to turn
/// the page, the arrows — stay out of the way while the writer types.
final class ScriptTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }
}

// MARK: - Style

enum ScriptStyle {
    static let background = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let paragraphKey = NSAttributedString.Key("panels.paragraph")

    enum Paragraph: String {
        case body, heading1, heading2
    }

    static func attributes(for style: Paragraph) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        switch style {
        case .body: font = .systemFont(ofSize: 15)
        case .heading1: font = .systemFont(ofSize: 22, weight: .bold)
        case .heading2: font = .systemFont(ofSize: 17, weight: .semibold)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style == .body ? 4 : 2
        paragraph.paragraphSpacing = style == .body ? 8 : 6
        return [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(style == .body ? 0.92 : 1),
            .paragraphStyle: paragraph,
            paragraphKey: style.rawValue,
        ]
    }
}

// MARK: - Chip

/// A citation in the text: one atomic character that draws as a chip.
final class CitationAttachment: NSTextAttachment {
    var citationID: String?
    var citationText = ""
    var thumbnail: NSImage?

    /// The cell is AppKit UI, so it's made on the main actor after the
    /// attachment exists rather than inside the attachment's own init.
    @MainActor
    static func make(id: String, text: String, thumbnail: NSImage?) -> CitationAttachment {
        let attachment = CitationAttachment(data: nil, ofType: nil)
        attachment.citationID = id
        attachment.citationText = text
        attachment.thumbnail = thumbnail
        attachment.attachmentCell = CitationChipCell(attachment: attachment)
        return attachment
    }
}

private final class CitationChipCell: NSTextAttachmentCell {
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let thumbnailHeight: CGFloat = 40
    private static let padding: CGFloat = 8

    private var chip: CitationAttachment? { attachment as? CitationAttachment }

    init(attachment: CitationAttachment) {
        super.init(textCell: "")
        self.attachment = attachment
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var textSize: NSSize {
        (chip?.citationText ?? "").size(withAttributes: [.font: Self.font])
    }

    private var thumbnailWidth: CGFloat {
        guard let image = chip?.thumbnail, image.size.height > 0 else { return 0 }
        return min(Self.thumbnailHeight * image.size.width / image.size.height, 90)
    }

    override func cellSize() -> NSSize {
        let hasThumbnail = thumbnailWidth > 0
        let height = hasThumbnail ? Self.thumbnailHeight + 6 : textSize.height + 8
        let width = Self.padding + (hasThumbnail ? thumbnailWidth + 8 : 14) + textSize.width + Self.padding
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func cellBaselineOffset() -> NSPoint {
        let hasThumbnail = thumbnailWidth > 0
        return NSPoint(x: 0, y: hasThumbnail ? -(Self.thumbnailHeight + 6) * 0.62 : -6)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x = cellFrame.minX + Self.padding
        if let image = chip?.thumbnail, thumbnailWidth > 0 {
            let rect = NSRect(x: x, y: cellFrame.minY + 3, width: thumbnailWidth, height: Self.thumbnailHeight)
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.current?.restoreGraphicsState()
            NSGraphicsContext.current?.saveGraphicsState()
            x += thumbnailWidth + 8
        } else {
            let icon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            let iconRect = NSRect(x: x, y: cellFrame.midY - 6, width: 12, height: 12)
            NSColor.white.withAlphaComponent(0.85).set()
            icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
            x += 14
        }
        let text = chip?.citationText ?? ""
        let size = textSize
        text.draw(at: NSPoint(x: x, y: cellFrame.midY - size.height / 2),
                  withAttributes: [.font: Self.font, .foregroundColor: NSColor.white])
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, untilMouseUp flag: Bool) -> Bool {
        // Report the click; the text view's delegate does the jumping.
        true
    }
}
