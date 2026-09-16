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
        let coordinator = context.coordinator
        textView.onHoverChip = { [weak coordinator] chip, rect in coordinator?.hover(chip, at: rect) }
        textView.onHoverSpan = { [weak coordinator] id, rect in coordinator?.hoverSpan(id, at: rect) }
        textView.onClickSpan = { [weak coordinator] id in coordinator?.goToSpan(id) }
        textView.markdown = { [weak coordinator] range in coordinator?.markdown(of: range) ?? "" }
        textView.attributedString = { [weak coordinator] markdown in coordinator?.render(markdown) ?? NSAttributedString() }
        textView.delegate = context.coordinator
        textView.updateDragTypeRegistration()
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
        if let command = project.pendingSpanCommand {
            coordinator.applySpan(command)
            project.pendingSpanCommand = nil
        }
        if let id = project.pendingReveal {
            coordinator.reveal(id)
            project.pendingReveal = nil
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

        func render(_ markdown: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let blocks = ScriptMarkdown.parse(markdown)
            for (index, block) in blocks.enumerated() {
                let style: ScriptStyle.Paragraph
                switch block.kind {
                case .heading(let level): style = level == 1 ? .heading1 : .heading2
                case .paragraph: style = .body
                }
                let start = result.length
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
                // The newline carries the span too, so typing at the end of a
                // block continues it rather than falling out of it.
                if let span = block.spanID, result.length > start {
                    result.addAttribute(ScriptStyle.spanKey, value: span,
                                        range: NSRange(location: start, length: result.length - start))
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
            return markdown(of: storage)
        }

        /// A range of the text as Markdown — what a copy or a drag carries.
        func markdown(of range: NSRange) -> String {
            guard let storage = textView?.textStorage, range.location != NSNotFound,
                  range.location + range.length <= storage.length else { return "" }
            return markdown(of: storage.attributedSubstring(from: range))
        }

        private func markdown(of storage: NSAttributedString) -> String {
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
                // Deliberately the first character, not "the first one found":
                // a fragment pasted into the middle of a paragraph must not
                // pull the whole paragraph into its block.
                var span: String?
                if content.length > 0 {
                    span = storage.attribute(ScriptStyle.spanKey, at: content.location, effectiveRange: nil) as? String
                } else if lineRange.length > 0 {
                    span = storage.attribute(ScriptStyle.spanKey, at: lineRange.location, effectiveRange: nil) as? String
                }
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
                blocks.append(level > 0 ? .heading(level: level, runs, span: span) : .paragraph(runs, span: span))
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
            rebuildPastedChips()
            restyleForeignText()
            normalizeSpans()
            project.script = serialise()
        }

        /// Makes every character of a paragraph agree about which block of
        /// writing it belongs to, taking the answer from the paragraph's first
        /// character. Editing can leave a paragraph half in and half out — a
        /// paste drops the attribute, an inserted chip arrives without it — and
        /// the file format has no way to say that. Runs before every save, so a
        /// hole is repaired within one keystroke instead of being written out.
        private func normalizeSpans() {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
            let string = storage.string as NSString
            var fixes: [(NSRange, String?)] = []
            var location = 0
            while location < string.length {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                let wanted = storage.attribute(ScriptStyle.spanKey, at: paragraph.location, effectiveRange: nil) as? String
                var uniform = true
                storage.enumerateAttribute(ScriptStyle.spanKey, in: paragraph, options: []) { value, _, stop in
                    if (value as? String) != wanted { uniform = false; stop.pointee = true }
                }
                if !uniform { fixes.append((paragraph, wanted)) }
                location = paragraph.location + max(paragraph.length, 1)
            }
            guard !fixes.isEmpty else { return }
            isLoading = true
            storage.beginEditing()
            for (range, wanted) in fixes {
                storage.removeAttribute(ScriptStyle.spanKey, range: range)
                if let wanted { storage.addAttribute(ScriptStyle.spanKey, value: wanted, range: range) }
            }
            storage.endEditing()
            isLoading = false
        }

        /// The block of writing the character at `location` belongs to.
        func spanID(at location: Int) -> String? {
            guard let storage = textView?.textStorage, storage.length > 0 else { return nil }
            let index = min(max(location, 0), storage.length - 1)
            return storage.attribute(ScriptStyle.spanKey, at: index, effectiveRange: nil) as? String
        }

        /// Text that arrived with someone else's attributes — a paste that
        /// slipped past the plain-text preference — is given the script's.
        private func restyleForeignText() {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
            var ranges: [NSRange] = []
            storage.enumerateAttribute(ScriptStyle.paragraphKey, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
                if value == nil { ranges.append(range) }
            }
            guard !ranges.isEmpty else { return }
            isLoading = true
            storage.beginEditing()
            for range in ranges {
                // The paragraph's style, from wherever in it is already styled.
                let paragraph = (storage.string as NSString).paragraphRange(for: range)
                var style = ScriptStyle.Paragraph.body
                storage.enumerateAttribute(ScriptStyle.paragraphKey, in: paragraph, options: []) { value, _, stop in
                    if let raw = value as? String, let found = ScriptStyle.Paragraph(rawValue: raw) { style = found; stop.pointee = true }
                }
                var attributes = ScriptStyle.attributes(for: style)
                // setAttributes replaces everything, so the block this
                // paragraph belongs to has to be carried across by hand.
                if let span = storage.attribute(ScriptStyle.spanKey, at: paragraph.location, effectiveRange: nil) as? String {
                    attributes[ScriptStyle.spanKey] = span
                }
                storage.enumerateAttribute(.attachment, in: range, options: []) { value, sub, _ in
                    attributes[.attachment] = value
                    attributes[.link] = (value as? CitationAttachment)?.citationID.map { ScriptMarkdown.citationURL(id: $0) }
                    storage.setAttributes(attributes.compactMapValues { $0 }, range: sub)
                }
            }
            storage.endEditing()
            isLoading = false
            textView.typingAttributes = ScriptStyle.attributes(for: currentStyle())
        }

        /// Text that came through the pasteboard — a paste, a drag — brings
        /// its attachments back as plain NSTextAttachments; the citation link
        /// on them survives, though. Anything like that becomes a chip again.
        private func rebuildPastedChips() {
            guard let textView, let storage = textView.textStorage else { return }
            var replacements: [(NSRange, NSAttributedString)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
                guard let attachment = value as? NSTextAttachment, !(attachment is CitationAttachment) else { return }
                let link = storage.attribute(.link, at: range.location, effectiveRange: nil)
                let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
                guard let url, let id = ScriptMarkdown.citationID(from: url) else { return }
                let style = ScriptStyle.Paragraph(rawValue: storage.attribute(ScriptStyle.paragraphKey, at: range.location, effectiveRange: nil) as? String ?? "") ?? .body
                let text = project.citation(id: id)?.text ?? "citation"
                let span = storage.attribute(ScriptStyle.spanKey, at: range.location, effectiveRange: nil) as? String
                let rebuilt = NSMutableAttributedString(attributedString: chip(id: id, text: text, style: style))
                if let span {
                    rebuilt.addAttribute(ScriptStyle.spanKey, value: span,
                                         range: NSRange(location: 0, length: rebuilt.length))
                }
                replacements.append((range, rebuilt))
            }
            guard !replacements.isEmpty else { return }
            let selection = textView.selectedRange()
            isLoading = true
            storage.beginEditing()
            for (range, chip) in replacements.reversed() {
                storage.replaceCharacters(in: range, with: chip)
            }
            storage.endEditing()
            isLoading = false
            textView.setSelectedRange(selection)
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
            // A chip dropped into a block of writing belongs to that block.
            if let span = spanID(at: range.location) {
                piece.addAttribute(ScriptStyle.spanKey, value: span,
                                   range: NSRange(location: 0, length: piece.length))
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
            var attributes = ScriptStyle.attributes(for: style)
            // Formatting a paragraph must not drop it out of its block, nor
            // end a block that is still being written.
            if paragraph.location < storage.length,
               let span = storage.attribute(ScriptStyle.spanKey, at: paragraph.location, effectiveRange: nil) as? String {
                attributes[ScriptStyle.spanKey] = span
            }
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

        /// Puts a page range on the writing, takes one off, or stops one here.
        func applySpan(_ command: SpanCommand) {
            guard let textView, let storage = textView.textStorage else { return }
            switch command {
            case .start(let span):
                let range = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
                guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
                storage.addAttribute(ScriptStyle.spanKey, value: span.id, range: range)
                textView.didChangeText()
                // Carried by the typing attributes, so the block keeps growing
                // as the writer keeps writing.
                textView.typingAttributes[ScriptStyle.spanKey] = span.id
                textView.window?.makeFirstResponder(textView)
                publishSpanAtCursor()
            case .end:
                textView.typingAttributes.removeValue(forKey: ScriptStyle.spanKey)
                publishSpanAtCursor()
            case .remove:
                let location = textView.selectedRange().location
                let probe = min(location, max(storage.length - 1, 0))
                guard let id = spanID(at: location),
                      let run = (textView as? ScriptTextView)?.spanRuns().first(where: {
                          $0.id == id && NSLocationInRange(probe, $0.range)
                      })
                else { return }
                guard textView.shouldChangeText(in: run.range, replacementString: nil) else { return }
                storage.removeAttribute(ScriptStyle.spanKey, range: run.range)
                textView.didChangeText()
                textView.typingAttributes.removeValue(forKey: ScriptStyle.spanKey)
                publishSpanAtCursor()
            }
        }

        /// Tells the reader which block of writing the cursor sits in, so one
        /// command can start a range or end it. Guarded, because this fires on
        /// every arrow key and an @Observable write would redraw the world.
        func publishSpanAtCursor() {
            let id = textView?.typingAttributes[ScriptStyle.spanKey] as? String
            if model.spanAtCursor != id { model.spanAtCursor = id }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishSpanAtCursor()
        }

        func goToSpan(_ id: String) {
            model.jump(toSpan: id)
        }

        /// The range a block is about, shown the way a chip's citation is.
        func hoverSpan(_ id: String?, at rect: NSRect) {
            previewTask?.cancel()
            guard let id, let textView, let span = project.manifest.span(id: id) else {
                preview?.close()
                preview = nil
                return
            }
            previewTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self else { return }
                self.preview?.close()
                let popover = NSPopover()
                popover.behavior = .applicationDefined
                popover.animates = false
                popover.appearance = NSAppearance(named: .darkAqua)
                popover.contentViewController = NSHostingController(rootView: SpanPreview(text: span.text))
                let anchor = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)
                popover.show(relativeTo: anchor, of: textView, preferredEdge: .minY)
                self.preview = popover
            }
        }

        private func currentStyle() -> ScriptStyle.Paragraph {
            guard let textView else { return .body }
            let raw = textView.typingAttributes[ScriptStyle.paragraphKey] as? String
            return ScriptStyle.Paragraph(rawValue: raw ?? "") ?? .body
        }

        /// Scrolls to a citation's chip and selects it, so a shot picked from
        /// the list shows where it sits in the writing.
        func reveal(_ id: String) {
            guard let textView, let storage = textView.textStorage else { return }
            var found: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
                if (value as? CitationAttachment)?.citationID == id {
                    found = range
                    stop.pointee = true
                }
            }
            guard let found else { return }
            textView.setSelectedRange(found)
            textView.scrollRangeToVisible(found)
            textView.showFindIndicator(for: found)
        }

        // MARK: Hover preview

        private var preview: NSPopover?
        private var previewTask: Task<Void, Never>?

        /// A beat after the mouse settles on a chip, its citation and capture
        /// appear beside it; they go when the mouse does.
        func hover(_ chip: CitationAttachment?, at rect: NSRect) {
            previewTask?.cancel()
            guard let chip, let id = chip.citationID, let textView else {
                preview?.close()
                preview = nil
                return
            }
            previewTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self else { return }
                self.preview?.close()
                let popover = NSPopover()
                popover.behavior = .applicationDefined
                popover.animates = false
                popover.appearance = NSAppearance(named: .darkAqua)
                popover.contentViewController = NSHostingController(rootView: CitationPreview(
                    text: chip.citationText,
                    image: self.thumbnail(for: id),
                    pages: self.project.citation(id: id)?.pageNumbers ?? []
                ))
                popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
                self.preview = popover
            }
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

/// What a block of writing is about, while the mouse is over it.
private struct SpanPreview: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.pages")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Text view

/// Says when it has the keyboard, so the reader's own keys — space to turn
/// the page, the arrows — stay out of the way while the writer types.
final class ScriptTextView: NSTextView {
    /// The selection as script Markdown. Chips have no bytes of their own,
    /// so RTF loses them; Markdown carries them exactly — and it's what
    /// drags, copies and pastes travel as, within the pane.
    static let markdownType = NSPasteboard.PasteboardType("com.mida.panels.script-markdown")

    var onFocusChange: ((Bool) -> Void)?
    var markdown: ((NSRange) -> String)?
    var attributedString: ((String) -> NSAttributedString)?
    /// The chip under the mouse and where it is, or nil when there isn't one.
    var onHoverChip: ((CitationAttachment?, NSRect) -> Void)?
    /// The block of writing under the mouse and where it is.
    var onHoverSpan: ((String?, NSRect) -> Void)?
    /// The writer clicked a block's margin rule: go to its first page.
    var onClickSpan: ((String) -> Void)?

    private var hoverTracking: NSTrackingArea?
    private weak var hoveredChip: CitationAttachment?
    private var hoveredSpan: String? {
        didSet { if hoveredSpan != oldValue { needsDisplay = true } }
    }

    // MARK: Blocks of writing

    /// Each maximal run of consecutive paragraphs sharing a page range. The
    /// id names a range; a run of paragraphs is what's drawn as one block, so
    /// a paragraph dragged out of the middle simply leaves two blocks.
    func spanRuns() -> [(id: String, range: NSRange)] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let string = storage.string as NSString
        var runs: [(id: String, range: NSRange)] = []
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            if let id = storage.attribute(ScriptStyle.spanKey, at: paragraph.location, effectiveRange: nil) as? String {
                if var last = runs.last, last.id == id,
                   last.range.location + last.range.length == paragraph.location {
                    last.range.length += paragraph.length
                    runs[runs.count - 1] = last
                } else {
                    runs.append((id, paragraph))
                }
            }
            location = paragraph.location + max(paragraph.length, 1)
        }
        return runs
    }

    /// The box to draw around a run, in view coordinates.
    private func box(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        // A run ends with the newline that separates it from what follows;
        // measuring that would add an empty line to the box.
        var measured = range
        let string = self.string as NSString
        while measured.length > 0,
              string.character(at: measured.location + measured.length - 1) == 0x0A {
            measured.length -= 1
        }
        // Never ask about glyphs that haven't been laid out yet — this runs
        // inside a draw pass.
        let laid = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(for: textContainer),
                                                actualGlyphRange: nil)
        measured = NSIntersectionRange(measured, laid)
        guard measured.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: measured, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        // Full width, so it reads as a block rather than hugging the ragged
        // right edge of the prose.
        let padding = textContainer.lineFragmentPadding
        rect.origin.x = padding
        rect.size.width = max(textContainer.size.width - padding * 2, 0)
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return rect.insetBy(dx: -5, dy: -3)
    }

    /// The margin rule for a block — the click target, kept off the text so
    /// clicking the words still places the caret.
    private func rule(beside box: NSRect) -> NSRect {
        NSRect(x: 7, y: box.minY + 2, width: 3, height: max(box.height - 4, 0))
    }

    /// The whole left inset is the hit region; the rule is just what's drawn.
    private func ruleHitBox(beside box: NSRect) -> NSRect {
        NSRect(x: 0, y: box.minY, width: max(textContainerOrigin.x, 12), height: box.height)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for run in spanRuns() {
            guard let box = box(for: run.range), box.intersects(rect) else { continue }
            let hovered = run.id == hoveredSpan
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            ScriptStyle.spanFill(hovered: hovered).setFill()
            path.fill()
            ScriptStyle.spanStroke(hovered: hovered).setStroke()
            path.lineWidth = 1
            path.stroke()
            let rule = NSBezierPath(roundedRect: rule(beside: box), xRadius: 1.5, yRadius: 1.5)
            NSColor.systemOrange.withAlphaComponent(hovered ? 1 : 0.6).setFill()
            rule.fill()
        }
    }

    /// The block under a point, and the box it's drawn in.
    func span(at point: NSPoint) -> (id: String, box: NSRect)? {
        for run in spanRuns() {
            guard let box = box(for: run.range) else { continue }
            if box.contains(point) || ruleHitBox(beside: box).contains(point) { return (run.id, box) }
        }
        return nil
    }

    private func spanRule(at point: NSPoint) -> String? {
        for run in spanRuns() {
            guard let box = box(for: run.range) else { continue }
            if ruleHitBox(beside: box).contains(point) { return run.id }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        // Chips sit inside blocks, so a chip under the mouse wins.
        if let (chip, rect) = chip(at: point) {
            if chip !== hoveredChip {
                hoveredChip = chip
                onHoverChip?(chip, rect)
            }
            if hoveredSpan != nil { hoveredSpan = nil; onHoverSpan?(nil, .zero) }
            return
        }
        if hoveredChip != nil {
            hoveredChip = nil
            onHoverChip?(nil, .zero)
        }
        let found = span(at: point)
        if found?.id != hoveredSpan {
            hoveredSpan = found?.id
            onHoverSpan?(found?.id, found?.box ?? .zero)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredSpan != nil {
            hoveredSpan = nil
            onHoverSpan?(nil, .zero)
        }
        if hoveredChip != nil {
            hoveredChip = nil
            onHoverChip?(nil, .zero)
        }
    }

    /// The chip whose glyph is under `point`, in view coordinates.
    private func chip(at point: NSPoint) -> (CitationAttachment, NSRect)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard rect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              let chip = storage.attribute(.attachment, at: index, effectiveRange: nil) as? CitationAttachment
        else { return nil }
        return (chip, rect)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownType] + super.writablePasteboardTypes
    }

    /// Our own Markdown first; then plain text ahead of RTF, so anything
    /// from elsewhere — Live Text off a page, a web page — arrives as words
    /// in the script's own style, not in its source's black-on-white.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownType, .string] + super.readablePasteboardTypes.filter { $0 != .string }
    }

    /// A drop is restricted to these — AppKit's own fixed list, which does not
    /// grow from `readablePasteboardTypes`. Without this the Markdown is on
    /// the pasteboard but never chosen, RTF is, and a chip's RTF is its URL.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownType, .string] + super.acceptableDragTypes.filter { $0 != .string }
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == Self.markdownType, let markdown = markdown?(selectedRange()) {
            pboard.setString(markdown, forType: type)
            return true
        }
        return super.writeSelection(to: pboard, type: type)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // Whatever type AppKit settled on, the Markdown is the faithful one
        // when it's there.
        if let markdown = pboard.string(forType: Self.markdownType),
           let piece = attributedString?(markdown) {
            let range = rangeForUserTextChange
            guard range.location != NSNotFound, shouldChangeText(in: range, replacementString: piece.string) else { return false }
            textStorage?.replaceCharacters(in: range, with: piece)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func mouseDown(with event: NSEvent) {
        // A selection on a page keeps its own view first responder; let go
        // of it before this view asks for the keyboard.
        NotificationCenter.default.post(name: .panelsClearPageTextSelection, object: nil)
        let point = convert(event.locationInWindow, from: nil)
        // The margin rule goes to the pages. Clicking the words never does —
        // that has to keep placing the caret.
        if let id = spanRule(at: point) {
            onClickSpan?(id)
            return
        }
        if event.modifierFlags.contains(.command), let found = span(at: point) {
            onClickSpan?(found.id)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for run in spanRuns() {
            guard let box = box(for: run.range) else { continue }
            addCursorRect(ruleHitBox(beside: box), cursor: .pointingHand)
        }
    }

    override func becomeFirstResponder() -> Bool {
        NotificationCenter.default.post(name: .panelsClearPageTextSelection, object: nil)
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
    static var backgroundColor: Color { Color(nsColor: background) }
    static var headerBackground: Color { Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1)) }
    static let paragraphKey = NSAttributedString.Key("panels.paragraph")
    /// The page range a line belongs to. Carried on every character of the
    /// line including its newline, so a block of writing survives editing.
    static let spanKey = NSAttributedString.Key("panels.span")

    /// Orange, so a block of writing about a range never reads as a citation
    /// chip, which is the accent colour.
    static func spanFill(hovered: Bool) -> NSColor {
        NSColor.systemOrange.withAlphaComponent(hovered ? 0.20 : 0.10)
    }
    static func spanStroke(hovered: Bool) -> NSColor {
        NSColor.systemOrange.withAlphaComponent(hovered ? 0.75 : 0.35)
    }

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
    /// A footnote-sized marker: sits in the line like a character.
    private static let size = NSSize(width: 21, height: 15)

    private var chip: CitationAttachment? { attachment as? CitationAttachment }

    init(attachment: CitationAttachment) {
        super.init(textCell: "")
        self.attachment = attachment
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cellSize() -> NSSize { Self.size }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 1, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.setFill()
        path.fill()

        let name = chip?.thumbnail == nil ? "doc.text" : "photo"
        guard let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return }
        let iconSize = NSSize(width: 11, height: 11)
        let iconRect = NSRect(x: rect.midX - iconSize.width / 2, y: rect.midY - iconSize.height / 2,
                              width: iconSize.width, height: iconSize.height)
        NSGraphicsContext.current?.saveGraphicsState()
        NSColor.white.set()
        let tinted = icon.copy() as! NSImage
        tinted.isTemplate = true
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func wantsToTrackMouse() -> Bool { true }

    /// A click jumps; a drag picks the chip up and moves it. Which one this
    /// is only becomes clear once the mouse moves or lets go, so the cell
    /// follows the mouse itself from here.
    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?,
                             atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let textView = controlView as? NSTextView, let window = textView.window else { return true }
        let start = theEvent.locationInWindow
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return true }
            switch next.type {
            case .leftMouseUp:
                // A click: the text view tells its delegate, which jumps.
                return true
            case .leftMouseDragged:
                let travelled = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
                guard travelled >= 4 else { continue }
                // A drag: select just the chip and hand it to the text view's
                // own drag-and-drop, which moves it to wherever it's dropped.
                textView.setSelectedRange(NSRange(location: charIndex, length: 1))
                _ = textView.dragSelection(with: next, offset: .zero, slideBack: true)
                return false
            default:
                continue
            }
        }
    }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, untilMouseUp flag: Bool) -> Bool {
        true
    }
}

/// What a chip stands for, shown beside it on hover.
private struct CitationPreview: View {
    let text: String
    let image: NSImage?
    let pages: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            Text("Click to open the page · drag to move")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(12)
        .frame(minWidth: 180, alignment: .leading)
    }
}
