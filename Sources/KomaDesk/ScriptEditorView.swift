import AppKit
import SwiftUI
import KomaProject

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
        textView.spanLabel = { [weak coordinator] id in coordinator?.spanLabelText(for: id) }
        textView.onClickSpan = { [weak coordinator] id in coordinator?.goToSpan(id) }
        textView.onContextMenuItems = { [weak coordinator] location in coordinator?.contextMenuItems(at: location) ?? [] }
        textView.onClickBeat = { [weak coordinator] id in coordinator?.toggleBeatDone(id: id) }
        textView.beatInfo = { [weak coordinator] id in coordinator?.beatInfo(for: id) }
        textView.onGeometryChange = { tops, height in
            model.beatBoxTops = tops
            model.scriptContentHeight = height
        }
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
        context.coordinator.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
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
        if coordinator.mode != model.scriptMode {
            coordinator.setMode(model.scriptMode)
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
        if let command = project.pendingInlineCommand {
            coordinator.applyInline(command)
            project.pendingInlineCommand = nil
        }
        if let change = project.pendingBeatColorChange {
            coordinator.setBeatColor(id: change.beatID, color: change.color)
            project.pendingBeatColorChange = nil
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
        /// So the beat rail can be told how far the script is scrolled —
        /// see `scrollBoundsChanged(_:)`.
        weak var scrollView: NSScrollView?
        var loadedProjectURL: URL?
        /// True while the view is being filled from the script, so the change
        /// notification doesn't write the script back to itself.
        private var isLoading = false
        private var thumbnails: [String: NSImage] = [:]
        /// Writer, Voice, or Editor — see `setMode`.
        private(set) var mode: ScriptMode = .writer

        init(project: Project, model: ReaderModel) {
            self.project = project
            self.model = model
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// The rail mirrors the script's own scroll position — see
        /// `BeatTagsRail`. A closure-based observer token can't be touched
        /// from a nonisolated `deinit` on a `@MainActor` class, so this uses
        /// target/selector instead, matched by the plain `removeObserver`
        /// above.
        @objc func scrollBoundsChanged(_ notification: Notification) {
            model.scriptScrollOffset = scrollView?.contentView.bounds.origin.y ?? 0
        }

        func load() {
            guard let textView else { return }
            isLoading = true
            defer { isLoading = false }
            (textView as? ScriptTextView)?.showsBeatBlocks = (mode == .editor)
            textView.textStorage?.setAttributedString(render(project.script, mode: mode))
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            loadedProjectURL = project.url
        }

        /// Voice swaps in a version of the script with the notes, citation
        /// chips and page-range highlighting stripped out — the asides and
        /// working marks a writer needs but a reader doesn't. Editor keeps
        /// all of that (full fidelity, same as Writer's own render), but is
        /// just as read-only, and draws each beat as a block the same way a
        /// page range draws one — see `ScriptTextView.beatRuns()`. Both are
        /// read-only for the same reason a stripped or annotated `render`
        /// never adds `spanKey` or a chip where the real script wouldn't
        /// have one: saving that back over the real script would be a
        /// silent, permanent edit.
        func setMode(_ newMode: ScriptMode) {
            guard let textView else { return }
            mode = newMode
            textView.isEditable = (newMode == .writer)
            (textView as? ScriptTextView)?.showsBeatBlocks = (newMode == .editor)
            isLoading = true
            textView.textStorage?.setAttributedString(render(project.script, mode: newMode))
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            isLoading = false
            // A whole-document replace only invalidates the new content's own
            // region; a margin rule drawn against the old, longer layout can
            // sit outside it and never get painted over. Force the lot.
            textView.needsLayout = true
            textView.needsDisplay = true
        }

        // MARK: Markdown → text

        func render(_ markdown: String, mode: ScriptMode = .writer) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let parsed = ScriptMarkdown.parse(markdown)
            // Voice strips the writer's own working marks; Writer and Editor
            // both keep everything — Editor is read-only, not stripped-down.
            let blocks = mode == .voice ? parsed.filter {
                // Notes and synopses are both the writer's, not the voice's.
                if case .note = $0.kind { return false }
                if case .synopsis = $0.kind { return false }
                return true
            } : parsed
            for (index, block) in blocks.enumerated() {
                let style: ScriptStyle.Paragraph
                switch block.kind {
                case .heading(1): style = .heading1
                case .heading(2): style = .heading2
                case .heading: style = .heading3
                case .note: style = .note
                case .synopsis: style = .synopsis
                case .paragraph: style = .body
                }
                let baseAttributes = ScriptStyle.attributes(for: style, alignment: block.alignment)
                let start = result.length
                for run in block.inlines {
                    switch run {
                    case .text(let s):
                        result.append(NSAttributedString(string: s, attributes: baseAttributes))
                    case .styledText(let styled):
                        let attributes = ScriptStyle.applyingInlineStyle(
                            bold: styled.bold, italic: styled.italic,
                            highlight: styled.highlight, textColor: styled.textColor, to: baseAttributes)
                        result.append(NSAttributedString(string: styled.text, attributes: attributes))
                    case .citation(let id, let text):
                        // Voice shows the writing, not its working notes —
                        // the chip is a reference mark, not prose.
                        if mode != .voice {
                            result.append(chip(id: id, text: text, style: style, alignment: block.alignment))
                        }
                    }
                }
                if index < blocks.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
                }
                // The newline carries the span too, so typing at the end of a
                // block continues it rather than falling out of it. Voice
                // never attaches one, which is what keeps its text free of
                // the page-range highlighting too.
                if mode != .voice, result.length > start {
                    if let span = block.spanID {
                        result.addAttribute(ScriptStyle.spanKey, value: span,
                                            range: NSRange(location: start, length: result.length - start))
                    }
                    // Attached in Writer too, though Writer never draws
                    // anything for it — see `Coordinator`'s doc comment on
                    // why the marker has to survive a keystroke invisibly.
                    if let beat = block.beatID {
                        result.addAttribute(ScriptStyle.beatKey, value: beat,
                                            range: NSRange(location: start, length: result.length - start))
                    }
                }
            }
            return result
        }

        private func chip(id: String, text: String, style: ScriptStyle.Paragraph,
                           alignment: ScriptAlignment = .leading) -> NSAttributedString {
            let attachment = CitationAttachment.make(id: id, text: text, thumbnail: thumbnail(for: id))
            let chip = NSMutableAttributedString(attachment: attachment)
            var attributes = ScriptStyle.attributes(for: style, alignment: alignment)
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
                var kind = ScriptBlock.Kind.paragraph
                // Deliberately the first character, not "the first one found":
                // a fragment pasted into the middle of a paragraph must not
                // pull the whole paragraph into its block.
                var span: String?
                var beat: String?
                var alignment = ScriptAlignment.leading
                if content.length > 0 {
                    span = storage.attribute(ScriptStyle.spanKey, at: content.location, effectiveRange: nil) as? String
                    beat = storage.attribute(ScriptStyle.beatKey, at: content.location, effectiveRange: nil) as? String
                    alignment = ScriptStyle.alignment(of: storage.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle)
                } else if lineRange.length > 0 {
                    span = storage.attribute(ScriptStyle.spanKey, at: lineRange.location, effectiveRange: nil) as? String
                    beat = storage.attribute(ScriptStyle.beatKey, at: lineRange.location, effectiveRange: nil) as? String
                    alignment = ScriptStyle.alignment(of: storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle)
                }
                storage.enumerateAttributes(in: content, options: []) { attributes, range, _ in
                    if let attachment = attributes[.attachment] as? CitationAttachment, let id = attachment.citationID {
                        runs.append(.citation(id: id, text: attachment.citationText))
                    } else {
                        let text = string.substring(with: range)
                        if !text.isEmpty {
                            let bold = attributes[ScriptStyle.boldKey] as? Bool ?? false
                            let italic = attributes[ScriptStyle.italicKey] as? Bool ?? false
                            let highlight = (attributes[ScriptStyle.highlightKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
                            let textColor = (attributes[ScriptStyle.textColorKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
                            if bold || italic || highlight != nil || textColor != nil {
                                runs.append(.styledText(TextRun(text: text, bold: bold, italic: italic,
                                                                 highlight: highlight, textColor: textColor)))
                            } else if case .text(let previous) = runs.last {
                                runs[runs.count - 1] = .text(previous + text)
                            } else {
                                runs.append(.text(text))
                            }
                        }
                    }
                    // The first run that isn't plain body decides the line's
                    // kind, the way the heading level used to.
                    if kind == .paragraph, let raw = attributes[ScriptStyle.paragraphKey] as? String,
                       let style = ScriptStyle.Paragraph(rawValue: raw) {
                        switch style {
                        case .heading1: kind = .heading(level: 1)
                        case .heading2: kind = .heading(level: 2)
                        case .heading3: kind = .heading(level: 3)
                        case .note: kind = .note
                        case .synopsis: kind = .synopsis
                        case .body: break
                        }
                    }
                }
                blocks.append(ScriptBlock(kind: kind, span: span, beat: beat, alignment: alignment, inlines: runs))
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
            guard !isLoading, mode == .writer else { return }
            rebuildPastedChips()
            restyleForeignText()
            normalizeSpans()
            normalizeBeats()
            project.script = serialise()
            runTypingFollowUps()
            // A span's box and its margin rule are entirely custom-painted,
            // computed together from the live layout — but AppKit invalidates
            // display by glyph, and the rule sits in the left margin, outside
            // any glyph. Typing a new line inside a block correctly redraws
            // the block's text and the box behind it; the rule's own strip,
            // for whatever vertical extent just got added, isn't glyph-
            // adjacent to anything, so it can be skipped and left too short
            // next to a box that's already grown. Force the repaint on every
            // edit rather than trust AppKit to find it on its own.
            textView?.needsLayout = true
            textView?.needsDisplay = true
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

        /// Same repair as `normalizeSpans()`, for a beat — reading `beatKey`
        /// instead of `spanKey`. A beat can cover more than one paragraph
        /// (whatever was selected when it was made), so this is exactly
        /// `normalizeSpans()`'s logic, not a special case of it.
        private func normalizeBeats() {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
            let string = storage.string as NSString
            var fixes: [(NSRange, String?)] = []
            var location = 0
            while location < string.length {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                let wanted = storage.attribute(ScriptStyle.beatKey, at: paragraph.location, effectiveRange: nil) as? String
                var uniform = true
                storage.enumerateAttribute(ScriptStyle.beatKey, in: paragraph, options: []) { value, _, stop in
                    if (value as? String) != wanted { uniform = false; stop.pointee = true }
                }
                if !uniform { fixes.append((paragraph, wanted)) }
                location = paragraph.location + max(paragraph.length, 1)
            }
            guard !fixes.isEmpty else { return }
            isLoading = true
            storage.beginEditing()
            for (range, wanted) in fixes {
                storage.removeAttribute(ScriptStyle.beatKey, range: range)
                if let wanted { storage.addAttribute(ScriptStyle.beatKey, value: wanted, range: range) }
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
                let alignment = ScriptStyle.alignment(of: storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
                let text = project.citation(id: id)?.text ?? "citation"
                let span = storage.attribute(ScriptStyle.spanKey, at: range.location, effectiveRange: nil) as? String
                let rebuilt = NSMutableAttributedString(attributedString: chip(id: id, text: text, style: style, alignment: alignment))
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
            guard let textView, mode == .writer else { return }
            let style = currentStyle()
            let alignment = currentAlignment()
            let piece = NSMutableAttributedString(attributedString: chip(id: citation.id, text: citation.text, style: style, alignment: alignment))
            let range = textView.selectedRange()
            // A space after the chip unless one is already there, so typing
            // carries straight on.
            let text = textView.string as NSString
            let next = range.location + range.length
            if next >= text.length || text.character(at: next) != 0x20 {
                piece.append(NSAttributedString(string: " ", attributes: ScriptStyle.attributes(for: style, alignment: alignment)))
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
            guard let textView, let storage = textView.textStorage, mode == .writer else { return }
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: textView.selectedRange())
            guard textView.shouldChangeText(in: paragraph, replacementString: nil) else { return }

            if case .alignment(let alignment) = command {
                applyAlignment(alignment, to: paragraph, storage: storage, textView: textView)
                textView.didChangeText()
                publishSpanAtCursor()
                publishSelectionFormatting()
                return
            }

            let style: ScriptStyle.Paragraph
            switch command {
            case .heading(1): style = .heading1
            case .heading(2): style = .heading2
            case .heading: style = .heading3
            case .note: style = .note
            case .synopsis: style = .synopsis
            case .body: style = .body
            case .alignment: return // handled above
            }
            // An empty script has no character to read the alignment off —
            // asking for index 0 of nothing throws — so it's the cursor's.
            let paragraphStyle = storage.length > 0
                ? storage.attribute(.paragraphStyle, at: min(paragraph.location, storage.length - 1), effectiveRange: nil)
                : textView.typingAttributes[.paragraphStyle]
            let alignment = ScriptStyle.alignment(of: paragraphStyle as? NSParagraphStyle)
            let attributes = ScriptStyle.attributes(for: style, alignment: alignment)
            // A style command can act on more than one paragraph at once —
            // the toolbar's style menu isn't limited to the cursor's own
            // paragraph the way the keyboard shortcuts are. Each paragraph in
            // the selection keeps its own block, or lack of one: reading the
            // span from a single point and stamping it across the whole
            // selection was fine when that selection was always one uniform
            // paragraph, but wipes out — or wrongly spreads — spans the
            // moment more than one paragraph, with different spans (or none),
            // is selected at once.
            storage.enumerateAttributes(in: paragraph, options: []) { existing, range, _ in
                var applied = attributes
                // Inline formatting already on this stretch of the paragraph
                // survives changing the paragraph's own kind — a bolded
                // phrase stays bold whether its line is a heading or not.
                let bold = existing[ScriptStyle.boldKey] as? Bool ?? false
                let italic = existing[ScriptStyle.italicKey] as? Bool ?? false
                let highlight = (existing[ScriptStyle.highlightKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
                let textColor = (existing[ScriptStyle.textColorKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
                applied = ScriptStyle.applyingInlineStyle(bold: bold, italic: italic, highlight: highlight,
                                                           textColor: textColor, to: applied)
                if let span = existing[ScriptStyle.spanKey] { applied[ScriptStyle.spanKey] = span }
                if let attachment = existing[.attachment] {
                    applied[.attachment] = attachment
                    if let id = (attachment as? CitationAttachment)?.citationID {
                        applied[.link] = ScriptMarkdown.citationURL(id: id)
                    }
                }
                storage.setAttributes(applied, range: range)
            }
            textView.didChangeText()
            // Typing attributes reflect the cursor's own paragraph, not
            // whatever the selection's first paragraph happened to be.
            var typingAttributes = attributes
            if let span = spanID(at: textView.selectedRange().location) {
                typingAttributes[ScriptStyle.spanKey] = span
            }
            textView.typingAttributes = typingAttributes
            publishSpanAtCursor()
            publishSelectionFormatting()
        }

        /// Alignment is its own axis — it never touches `Kind`, `spanID`, or
        /// any inline styling already on the paragraph, only the paragraph
        /// style's own `.alignment`.
        private func applyAlignment(_ alignment: ScriptAlignment, to paragraph: NSRange,
                                     storage: NSTextStorage, textView: NSTextView) {
            storage.enumerateAttribute(.paragraphStyle, in: paragraph, options: []) { value, range, _ in
                let base = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
                guard let mutable = base.mutableCopy() as? NSMutableParagraphStyle else { return }
                mutable.alignment = alignment.nsTextAlignment
                storage.addAttribute(.paragraphStyle, value: mutable, range: range)
            }
            if let current = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle,
               let mutable = current.mutableCopy() as? NSMutableParagraphStyle {
                mutable.alignment = alignment.nsTextAlignment
                textView.typingAttributes[.paragraphStyle] = mutable
            }
        }

        /// Inline formatting for the current selection — bold, italic, a
        /// highlight, a text-color override — unlike `apply(_:)`, which
        /// always acts on the whole paragraph at the cursor.
        func applyInline(_ command: InlineCommand) {
            guard let textView, let storage = textView.textStorage, mode == .writer else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else {
                applyInlineToTypingAttributes(command)
                return
            }
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }

            // A toggle looks at whether the WHOLE selection already has the
            // trait — a mixed or empty selection turns it on for all of it,
            // same as every rich text editor.
            var allBold = true
            var allItalic = true
            if case .toggleBold = command {
                storage.enumerateAttribute(ScriptStyle.boldKey, in: range, options: []) { value, _, stop in
                    if (value as? Bool) != true { allBold = false; stop.pointee = true }
                }
            }
            if case .toggleItalic = command {
                storage.enumerateAttribute(ScriptStyle.italicKey, in: range, options: []) { value, _, stop in
                    if (value as? Bool) != true { allItalic = false; stop.pointee = true }
                }
            }

            storage.enumerateAttributes(in: range, options: []) { existing, sub, _ in
                // Chips are atomic — formatting never touches them.
                guard existing[.attachment] == nil else { return }
                var bold = existing[ScriptStyle.boldKey] as? Bool ?? false
                var italic = existing[ScriptStyle.italicKey] as? Bool ?? false
                var highlight = (existing[ScriptStyle.highlightKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
                var textColor = (existing[ScriptStyle.textColorKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
                switch command {
                case .toggleBold: bold = !allBold
                case .toggleItalic: italic = !allItalic
                case .setHighlight(let swatch): highlight = swatch
                case .setTextColor(let swatch): textColor = swatch
                }
                // Rebuilt from this run's own paragraph base, so turning a
                // trait off actually returns to normal rather than getting
                // stuck once it's been applied.
                let styleName = existing[ScriptStyle.paragraphKey] as? String
                let baseStyle = styleName.flatMap(ScriptStyle.Paragraph.init(rawValue:)) ?? .body
                let alignment = ScriptStyle.alignment(of: existing[.paragraphStyle] as? NSParagraphStyle)
                var base = ScriptStyle.attributes(for: baseStyle, alignment: alignment)
                if let span = existing[ScriptStyle.spanKey] { base[ScriptStyle.spanKey] = span }
                let applied = ScriptStyle.applyingInlineStyle(bold: bold, italic: italic, highlight: highlight,
                                                               textColor: textColor, to: base)
                storage.setAttributes(applied, range: sub)
            }
            textView.didChangeText()
            publishSelectionFormatting()
        }

        /// The cursor has no selection — the toggle changes what's typed
        /// next instead of any existing text.
        private func applyInlineToTypingAttributes(_ command: InlineCommand) {
            guard let textView else { return }
            var bold = textView.typingAttributes[ScriptStyle.boldKey] as? Bool ?? false
            var italic = textView.typingAttributes[ScriptStyle.italicKey] as? Bool ?? false
            var highlight = (textView.typingAttributes[ScriptStyle.highlightKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
            var textColor = (textView.typingAttributes[ScriptStyle.textColorKey] as? String).flatMap(ScriptSwatch.init(rawValue:))
            switch command {
            case .toggleBold: bold.toggle()
            case .toggleItalic: italic.toggle()
            case .setHighlight(let swatch): highlight = swatch
            case .setTextColor(let swatch): textColor = swatch
            }
            let styleName = textView.typingAttributes[ScriptStyle.paragraphKey] as? String
            let baseStyle = styleName.flatMap(ScriptStyle.Paragraph.init(rawValue:)) ?? .body
            let alignment = ScriptStyle.alignment(of: textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            var base = ScriptStyle.attributes(for: baseStyle, alignment: alignment)
            if let span = textView.typingAttributes[ScriptStyle.spanKey] { base[ScriptStyle.spanKey] = span }
            textView.typingAttributes = ScriptStyle.applyingInlineStyle(bold: bold, italic: italic, highlight: highlight,
                                                                         textColor: textColor, to: base)
            publishSelectionFormatting()
        }

        /// The alignment the cursor is currently typing at — read off the
        /// paragraph style the same way `currentStyle()` reads the kind.
        private func currentAlignment() -> ScriptAlignment {
            guard let textView else { return .leading }
            return ScriptStyle.alignment(of: textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        }

        /// Puts a page range on the writing, takes one off, or stops one here.
        func applySpan(_ command: SpanCommand) {
            guard let textView, let storage = textView.textStorage, mode == .writer else { return }
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
                publishSelectionFormatting()
            case .end:
                textView.typingAttributes.removeValue(forKey: ScriptStyle.spanKey)
                publishSpanAtCursor()
                publishSelectionFormatting()
            case .remove:
                removeSpan(at: textView.selectedRange().location)
            case .link(let span, let selection):
                // The selection the request was made for, clamped: a sheet
                // stood between asking and answering, and the text may have
                // moved under it.
                let asked = selection ?? textView.selectedRange()
                let location = min(asked.location, storage.length)
                let chosen = NSRange(location: location, length: min(asked.length, storage.length - location))
                let range = (storage.string as NSString).paragraphRange(for: chosen)
                guard range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) else { return }
                storage.addAttribute(ScriptStyle.spanKey, value: span.id, range: range)
                textView.didChangeText()
                // Whatever the caret now sits in is what it carries, the way
                // any move into a block works — nothing more than that.
                if let current = spanID(at: textView.selectedRange().location) {
                    textView.typingAttributes[ScriptStyle.spanKey] = current
                }
                textView.window?.makeFirstResponder(textView)
                textView.needsDisplay = true
                publishSpanAtCursor()
                publishSelectionFormatting()
            }
        }

        /// Takes the range off the whole block the paragraph at `location`
        /// belongs to.
        private func removeSpan(at location: Int) {
            guard let textView, let storage = textView.textStorage else { return }
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
            publishSelectionFormatting()
        }

        // MARK: Linking writing to pages

        private struct SpanMenuTarget {
            enum Action { case linkOnScreen, linkToPage, open, change, remove }
            let action: Action
            let spanID: String?
            let selection: NSRange
            let location: Int
        }

        /// What a right-click offers. Editor mode keeps its beat items; Writer
        /// mode offers to link the selected writing to pages, and to open,
        /// change or remove the range of the block under the click.
        func contextMenuItems(at location: Int) -> [NSMenuItem] {
            switch mode {
            case .editor: return beatMenuItems(at: location)
            case .voice: return []
            case .writer: break
            }
            guard let textView else { return [] }
            let selection = textView.selectedRange()
            var items: [NSMenuItem] = []
            if selection.length > 0 {
                let onScreen = model.pagesOnScreenPhrase
                let linkHere = spanMenuItem(
                    title: onScreen.map { "Link to Pages on Screen (\($0))" } ?? "Link to Pages on Screen",
                    target: SpanMenuTarget(action: .linkOnScreen, spanID: nil, selection: selection, location: location))
                linkHere.isEnabled = onScreen != nil
                items.append(linkHere)
                items.append(spanMenuItem(title: "Link to Page…", target: SpanMenuTarget(
                    action: .linkToPage, spanID: nil, selection: selection, location: location)))
            }
            // The paragraph under the click, whether or not it's selected.
            let string = (textView.string as NSString)
            let probe = min(location, max(string.length - 1, 0))
            if string.length > 0, let id = spanID(at: probe), let span = project.manifest.span(id: id) {
                if !items.isEmpty { items.append(.separator()) }
                let label = project.manifest.label(for: span).short
                items.append(spanMenuItem(title: "Open \(label)", target: SpanMenuTarget(
                    action: .open, spanID: id, selection: selection, location: probe)))
                items.append(spanMenuItem(title: "Change Pages…", target: SpanMenuTarget(
                    action: .change, spanID: id, selection: selection, location: probe)))
                items.append(spanMenuItem(title: "Remove Page Range", target: SpanMenuTarget(
                    action: .remove, spanID: id, selection: selection, location: probe)))
            }
            return items
        }

        private func spanMenuItem(title: String, target: SpanMenuTarget) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(spanMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
            return item
        }

        @objc private func spanMenuAction(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? SpanMenuTarget else { return }
            switch target.action {
            case .linkOnScreen:
                model.linkSelectionToPagesOnScreen(selection: target.selection)
            case .linkToPage:
                model.beginLinkingPages(selection: target.selection)
            case .open:
                if let id = target.spanID { model.jump(toSpan: id) }
            case .change:
                if let id = target.spanID { model.beginLinkingPages(changing: id) }
            case .remove:
                removeSpan(at: target.location)
            }
        }

        // MARK: Beats

        /// A beat starts entirely inside Editor mode — a right-click, a
        /// title — so unlike a page range there's no `pending*` command for
        /// `Project` to carry across from the reader side; the coordinator
        /// already has everything it needs.
        ///
        /// Works on `project.script` directly rather than the live text
        /// storage: Editor mode is always rebuilt whole on a change (never
        /// edited a keystroke at a time — it's read-only), so going by way
        /// of the parsed blocks is both simpler and exactly as correct.
        /// Covers exactly `blockRange` — whatever was selected when "New
        /// Beat Here" was chosen — never more.
        func createBeat(title: String, blockRange: ClosedRange<Int>) {
            var blocks = ScriptMarkdown.parse(project.script)
            guard !blocks.isEmpty else { return }
            // Built from separate bounds, not `lower...upper` directly:
            // constructing a `ClosedRange` with `lower > upper` traps, and
            // that's exactly the shape a stale range could be in.
            let lower = max(blockRange.lowerBound, 0)
            let upper = min(blockRange.upperBound, blocks.count - 1)
            guard lower <= upper else { return }
            let clamped = lower...upper
            let beat = Beat(title: title)
            project.manifest.store(beat)
            for index in clamped { blocks[index].beatID = beat.id }
            project.script = ScriptMarkdown.serialize(blocks)
            setMode(.editor)
        }

        /// A beat can span more than one paragraph, so every block carrying
        /// its id is cleared — not just the first one found.
        func removeBeat(id: String) {
            var blocks = ScriptMarkdown.parse(project.script)
            var changed = false
            for index in blocks.indices where blocks[index].beatID == id {
                blocks[index].beatID = nil
                changed = true
            }
            if changed { project.script = ScriptMarkdown.serialize(blocks) }
            project.manifest.removeBeat(id: id)
            setMode(.editor)
        }

        /// Editor mode only — Writer and Voice never show or touch this.
        /// Nothing about the script changes, so a redraw is enough; no need
        /// to rebuild the text storage or lose the selection the way a
        /// marker change does.
        func toggleBeatDone(id: String) {
            guard var beat = project.manifest.beat(id: id) else { return }
            beat.isDone.toggle()
            project.manifest.store(beat)
            textView?.needsDisplay = true
        }

        private func renameBeat(id: String) {
            guard var beat = project.manifest.beat(id: id), let title = promptForTitle(current: beat.title) else { return }
            beat.title = title
            project.manifest.store(beat)
            textView?.needsDisplay = true
        }

        /// The rail's number badge sets this via `project.pendingBeatColorChange`
        /// — the one beat mutation that starts outside the text view.
        func setBeatColor(id: String, color: ScriptSwatch?) {
            guard var beat = project.manifest.beat(id: id) else { return }
            beat.color = color
            project.manifest.store(beat)
            textView?.needsDisplay = true
        }

        /// One text-entry surface for both naming a new beat and renaming an
        /// existing one.
        private func promptForTitle(current: String?) -> String? {
            let alert = NSAlert()
            alert.messageText = current == nil ? "New Beat" : "Rename Beat"
            alert.addButton(withTitle: current == nil ? "Create" : "Rename")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = current ?? ""
            field.placeholderString = "Beat title"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        private struct BeatMenuTarget {
            enum Action { case create, toggle, rename, remove }
            let action: Action
            let beatID: String?
            let blockRange: ClosedRange<Int>
        }

        /// The index into `ScriptMarkdown.parse(project.script)` that
        /// `location` falls on — counted directly from newlines rather than
        /// read off an attribute, since an empty paragraph (a blank line
        /// between beats, or between any two blocks) carries no attribute at
        /// all to read: `render(_:mode:)` only ever attaches one where
        /// `result.length > start`, which an empty block never satisfies. A
        /// blank line is exactly where a right-click naturally lands when
        /// dragging a selection down to the next paragraph, so this has to
        /// work there too.
        private func blockIndex(at location: Int) -> Int? {
            guard let storage = textView?.textStorage, storage.length > 0 else { return nil }
            let string = storage.string as NSString
            let probe = min(max(location, 0), string.length)
            var index = 0
            for i in 0..<probe where string.character(at: i) == 0x0A { index += 1 }
            return index
        }

        /// The block indices covered by the current selection, for "New Beat
        /// Here" — whatever's highlighted becomes the beat. With no
        /// selection (just a cursor, or a right-click with nothing dragged),
        /// falls back to the single paragraph under the click.
        private func selectedBlockRange(fallback: Int) -> ClosedRange<Int> {
            guard let textView, textView.selectedRange().length > 0 else { return fallback...fallback }
            let selection = textView.selectedRange()
            guard let startIndex = blockIndex(at: selection.location),
                  let endIndex = blockIndex(at: selection.location + selection.length - 1)
            else { return fallback...fallback }
            return min(startIndex, endIndex)...max(startIndex, endIndex)
        }

        /// The right-click menu items for the block at `location`: "New Beat
        /// Here" when it doesn't already open one — covering the current
        /// selection, if there is one — or "Mark Done"/"Rename Beat…"/
        /// "Remove Beat" when it does. Empty outside Editor mode — every
        /// beat action is exclusively an Editor-mode one.
        func beatMenuItems(at location: Int) -> [NSMenuItem] {
            guard mode == .editor, let blockIndex = blockIndex(at: location) else { return [] }
            let blocks = ScriptMarkdown.parse(project.script)
            guard blocks.indices.contains(blockIndex) else { return [] }

            guard let beatID = blocks[blockIndex].beatID, let beat = project.manifest.beat(id: beatID) else {
                let range = selectedBlockRange(fallback: blockIndex)
                return [beatMenuItem(title: "New Beat Here", target: BeatMenuTarget(action: .create, beatID: nil, blockRange: range))]
            }
            let range = blockIndex...blockIndex
            return [
                beatMenuItem(title: beat.isDone ? "Mark Beat Not Done" : "Mark Beat Done",
                            target: BeatMenuTarget(action: .toggle, beatID: beatID, blockRange: range)),
                beatMenuItem(title: "Rename Beat…",
                            target: BeatMenuTarget(action: .rename, beatID: beatID, blockRange: range)),
                beatMenuItem(title: "Remove Beat",
                            target: BeatMenuTarget(action: .remove, beatID: beatID, blockRange: range)),
            ]
        }

        private func beatMenuItem(title: String, target: BeatMenuTarget) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(beatMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
            return item
        }

        @objc private func beatMenuAction(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? BeatMenuTarget else { return }
            switch target.action {
            case .create:
                if let title = promptForTitle(current: nil) { createBeat(title: title, blockRange: target.blockRange) }
            case .toggle:
                if let id = target.beatID { toggleBeatDone(id: id) }
            case .rename:
                if let id = target.beatID { renameBeat(id: id) }
            case .remove:
                if let id = target.beatID { removeBeat(id: id) }
            }
        }

        /// Tells the reader which block of writing the cursor sits in, so one
        /// command can start a range or end it. Guarded, because this fires on
        /// every arrow key and an @Observable write would redraw the world.
        func publishSpanAtCursor() {
            let id = textView?.typingAttributes[ScriptStyle.spanKey] as? String
            if model.spanAtCursor != id { model.spanAtCursor = id }
            let note = currentStyle() == .note
            if model.isWritingNote != note { model.isWritingNote = note }
        }

        /// The formatting at the cursor or across the selection, for the
        /// formatting toolbar's pressed/active state — the representative
        /// attributes are the selection's first character, or the typing
        /// attributes when there's no selection, the same idea as
        /// `currentStyle()`.
        func publishSelectionFormatting() {
            guard let textView else { return }
            let range = textView.selectedRange()
            let attributes: [NSAttributedString.Key: Any]
            if range.length > 0, let storage = textView.textStorage, range.location < storage.length {
                attributes = storage.attributes(at: range.location, effectiveRange: nil)
            } else {
                attributes = textView.typingAttributes
            }
            let styleName = attributes[ScriptStyle.paragraphKey] as? String
            let style = styleName.flatMap(ScriptStyle.Paragraph.init(rawValue:)) ?? .body
            let formatting = ScriptSelectionFormatting(
                bold: attributes[ScriptStyle.boldKey] as? Bool ?? false,
                italic: attributes[ScriptStyle.italicKey] as? Bool ?? false,
                alignment: ScriptStyle.alignment(of: attributes[.paragraphStyle] as? NSParagraphStyle),
                style: style,
                highlight: (attributes[ScriptStyle.highlightKey] as? String).flatMap(ScriptSwatch.init(rawValue:)),
                textColor: (attributes[ScriptStyle.textColorKey] as? String).flatMap(ScriptSwatch.init(rawValue:)))
            if model.selectionFormatting != formatting { model.selectionFormatting = formatting }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishSpanAtCursor()
            publishSelectionFormatting()
            let selected = (textView?.selectedRange().length ?? 0) > 0
            if model.hasScriptSelection != selected { model.hasScriptSelection = selected }
        }

        /// Return on an empty note ends it rather than making another one —
        /// the way a list or a blockquote lets go in every editor. Return in a
        /// heading or a synopsis always lets go: each is one line, a label,
        /// and what's written under it is narration — including a `= ` typed
        /// straight under a heading, which only converts on a plain line. And a
        /// keystroke at the start of a plain line, or a closing `]`, has the
        /// line checked for Fountain-lite marks — see `convertTypedLine(at:)`.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            if let replacement = replacementString, replacement != "\n", !replacement.isEmpty {
                noteTypedLine(for: affectedCharRange, replacement: replacement)
            }
            if replacementString == "\n",
               [.synopsis, .heading1, .heading2, .heading3].contains(paragraphStyle(at: affectedCharRange.location)) {
                endsLabelLine = true
                return true
            }
            guard replacementString == "\n", currentStyle() == .note,
                  let storage = textView.textStorage
            else { return true }
            let string = storage.string as NSString
            var content = string.paragraphRange(for: affectedCharRange)
            if content.length > 0, string.character(at: content.location + content.length - 1) == 0x0A {
                content.length -= 1
            }
            // Only when there's nothing in it: a note with words carries on.
            guard content.length == 0 else { return true }
            apply(.body)
            return false
        }

        func goToSpan(_ id: String) {
            model.jump(toSpan: id)
        }

        /// How a block's range reads on its own edge. The chapter is worth
        /// saying only when it isn't the one on screen — inside it, the
        /// pages are the whole story.
        func spanLabelText(for id: String) -> String? {
            guard let span = project.manifest.span(id: id) else { return nil }
            return labelText(project.manifest.label(for: span), isCurrent: span.itemID == model.item?.id)
        }

        /// A beat's title, done state, color, and whether it's the one to
        /// work on next — for its own card and block, read live off the
        /// manifest on every draw, so a check, a rename, or a new color
        /// shows up the next time it's drawn without a re-render.
        func beatInfo(for id: String) -> BeatDisplayInfo? {
            guard let beat = project.manifest.beat(id: id) else { return nil }
            let nextUpID = project.beatsInScriptOrder.first { !$0.isDone }?.id
            return BeatDisplayInfo(title: beat.title, isDone: beat.isDone, color: beat.color, isNextUp: id == nextUpID)
        }

        private func labelText(_ label: ReferenceLabel, isCurrent: Bool) -> String {
            isCurrent ? (label.pages.isEmpty ? label.full : label.pages) : label.short
        }

        // MARK: Convert as you type

        /// A paragraph to check once the keystroke that touched it has
        /// landed, by the location of its start.
        private var typedLineToCheck: Int?
        /// Return was just pressed in a heading or a synopsis: the new line
        /// is narration.
        private var endsLabelLine = false

        /// Marks the paragraph for a check when the keystroke could complete
        /// a line's marks: within its first few characters (`=`, `#`, and
        /// the space after them), or a `]` (the end of `[[note]]`). Only a
        /// plain paragraph — one already a synopsis, heading or note is what
        /// it's going to be.
        private func noteTypedLine(for range: NSRange, replacement: String) {
            guard mode == .writer, let storage = textView?.textStorage else { return }
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
            guard paragraphStyle(at: range.location) == .body else { return }
            if range.location - paragraph.location <= 3 || replacement.hasSuffix("]") {
                typedLineToCheck = paragraph.location
            }
        }

        /// The paragraph style of the paragraph holding `location`: from its
        /// own text when it has any, the typing attributes when it's empty.
        private func paragraphStyle(at location: Int) -> ScriptStyle.Paragraph {
            guard let storage = textView?.textStorage else { return .body }
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
            let hasText = paragraph.length > 0 && string.character(at: paragraph.location) != 0x0A
            guard hasText else { return currentStyle() }
            let raw = storage.attribute(ScriptStyle.paragraphKey, at: paragraph.location, effectiveRange: nil) as? String
            return ScriptStyle.Paragraph(rawValue: raw ?? "") ?? .body
        }

        /// Called after every edit: the follow-ups a keystroke asked for. The
        /// conversion waits for the next turn of the run loop so it's its own
        /// undo step — ⌘Z brings back the `= ` exactly as typed.
        private func runTypingFollowUps() {
            if endsLabelLine {
                endsLabelLine = false
                if let textView {
                    var attributes = ScriptStyle.attributes(for: .body)
                    if let span = textView.typingAttributes[ScriptStyle.spanKey] { attributes[ScriptStyle.spanKey] = span }
                    textView.typingAttributes = attributes
                    publishSelectionFormatting()
                }
            }
            if let location = typedLineToCheck {
                typedLineToCheck = nil
                DispatchQueue.main.async { [weak self] in self?.convertTypedLine(at: location) }
            }
        }

        /// Turns the plain paragraph at `location` into what its marks say —
        /// `= ` a synopsis, `# ` a heading, `[[…]]` a note — by taking the
        /// marks off and applying the same style Format ▸ Synopsis (or
        /// Heading, or Note) does. The rule itself is `FountainLite.typedLine`,
        /// the file format's own.
        func convertTypedLine(at location: Int) {
            guard mode == .writer, let textView, let storage = textView.textStorage,
                  location <= storage.length, paragraphStyle(at: location) == .body else { return }
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            if content.length > 0, string.character(at: content.location + content.length - 1) == 0x0A { content.length -= 1 }
            guard let typed = FountainLite.typedLine(Substring(string.substring(with: content))) else { return }

            let cursor = textView.selectedRange()
            let trailing = NSRange(location: content.location + content.length - typed.trailing, length: typed.trailing)
            let leading = NSRange(location: content.location, length: typed.leading)
            for marks in [trailing, leading] where marks.length > 0 {
                guard textView.shouldChangeText(in: marks, replacementString: "") else { return }
                storage.replaceCharacters(in: marks, with: "")
                textView.didChangeText()
            }
            // The cursor stays with the words it was among.
            let removedBefore = cursor.location >= content.location + content.length ? typed.leading + typed.trailing
                : max(0, min(cursor.location - content.location, typed.leading))
            textView.setSelectedRange(NSRange(location: max(content.location, cursor.location - removedBefore), length: 0))
            switch typed.kind {
            case .synopsis: apply(.synopsis)
            case .heading(let level): apply(.heading(level))
            case .note: apply(.note)
            }
        }

        /// Backspace at the very start of a synopsis lets go of it: the line
        /// is narration again, words intact. The same way out a list item
        /// gives in any editor — nobody is trapped in a style they typed.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.deleteBackward(_:)), mode == .writer else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let paragraph = (textView.string as NSString).paragraphRange(for: selection)
            guard selection.location == paragraph.location, paragraphStyle(at: selection.location) == .synopsis else { return false }
            apply(.body)
            return true
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
                let label = self.project.citation(id: id).map { self.project.manifest.label(for: $0) }
                    ?? ReferenceLabel(pages: "", item: nil, series: "", full: chip.citationText)
                popover.contentViewController = NSHostingController(rootView: CitationPreview(
                    label: label,
                    image: self.thumbnail(for: id)
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

/// What a beat's block and the rail's row both need to draw it correctly —
/// bundled together since `Coordinator.beatInfo(for:)` recomputes all of it
/// fresh on every draw anyway.
struct BeatDisplayInfo {
    let title: String
    let isDone: Bool
    let color: ScriptSwatch?
    /// The first not-done beat in script order — the one to work on next,
    /// drawn brighter than the rest. A finished beat is never dimmed for
    /// being finished; only this one stands out, for being next.
    let isNextUp: Bool
}

// MARK: - Text view

/// Says when it has the keyboard, so the reader's own keys — space to turn
/// the page, the arrows — stay out of the way while the writer types.
final class ScriptTextView: NSTextView {
    /// The selection as script Markdown. Chips have no bytes of their own,
    /// so RTF loses them; Markdown carries them exactly — and it's what
    /// drags, copies and pastes travel as, within the pane.
    static let markdownType = NSPasteboard.PasteboardType("com.mida.komadesk.script-markdown")

    var onFocusChange: ((Bool) -> Void)?
    var markdown: ((NSRange) -> String)?
    var attributedString: ((String) -> NSAttributedString)?
    /// The chip under the mouse and where it is, or nil when there isn't one.
    var onHoverChip: ((CitationAttachment?, NSRect) -> Void)?
    /// The writer clicked a block's margin rule: go to its first page.
    var onClickSpan: ((String) -> Void)?
    /// How a block's page range reads — the view knows ids, not ranges.
    var spanLabel: ((String) -> String?)?
    /// The right-click menu items for whatever's under the click — beat
    /// items in Editor mode, linking writing to pages in Writer mode.
    var onContextMenuItems: ((Int) -> [NSMenuItem])?
    /// The writer clicked a beat's margin rule: toggle it done.
    var onClickBeat: ((String) -> Void)?
    /// A beat's title, done state, color, and next-up status — the view
    /// knows ids, not beats.
    var beatInfo: ((String) -> BeatDisplayInfo?)?
    /// Beats only ever draw as blocks in Editor mode — `beatKey` is attached
    /// invisibly in Writer mode too (see `Coordinator`'s doc comment), and
    /// without this flag they'd draw there as well.
    var showsBeatBlocks = false {
        didSet {
            guard showsBeatBlocks != oldValue else { return }
            needsDisplay = true
            publishGeometry()
        }
    }
    /// Each visible beat's top, in this view's own content coordinates, plus
    /// the content's total height — how the beat rail places its rows at the
    /// same height as their beat, instead of just stacking them. Fired after
    /// every layout pass, and once more whenever `showsBeatBlocks` flips, since
    /// switching into Editor mode doesn't itself trigger a fresh layout.
    var onGeometryChange: ((_ beatTops: [String: CGFloat], _ contentHeight: CGFloat) -> Void)?

    private var hoverTracking: NSTrackingArea?
    private weak var hoveredChip: CitationAttachment?
    private var hoveredSpan: String? {
        didSet { if hoveredSpan != oldValue { needsDisplay = true } }
    }
    private var hoveredBeat: String? {
        didSet { if hoveredBeat != oldValue { needsDisplay = true } }
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

    /// Each maximal run of consecutive paragraphs sharing a beat — exactly
    /// `spanRuns()`'s own logic, reading `beatKey` instead of `spanKey`. A
    /// beat covers only the paragraphs it was actually marked on (the
    /// selection at the moment it was created), never anything past that.
    /// Empty outside Editor mode, so nothing about a beat ever draws in
    /// Writer or Voice even though the attribute is there.
    func beatRuns() -> [(id: String, range: NSRange)] {
        guard showsBeatBlocks, let storage = textStorage, storage.length > 0 else { return [] }
        let string = storage.string as NSString
        var runs: [(id: String, range: NSRange)] = []
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            if let id = storage.attribute(ScriptStyle.beatKey, at: paragraph.location, effectiveRange: nil) as? String {
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

    /// Tells the beat rail where things stand — the same `box(for:)` geometry
    /// `drawBackground` paints with, so the rail can never disagree with what's
    /// actually on screen.
    private func publishGeometry() {
        guard let onGeometryChange else { return }
        var tops: [String: CGFloat] = [:]
        for run in beatRuns() {
            tops[run.id] = box(for: run.range)?.minY
        }
        onGeometryChange(tops, frame.height)
    }

    override func layout() {
        super.layout()
        publishGeometry()
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

    /// A beat's own margin rule sits further in than a page range's, so a
    /// paragraph covered by both shows two bars side by side rather than one
    /// hiding the other.
    private func beatRule(beside box: NSRect) -> NSRect {
        NSRect(x: 13, y: box.minY + 2, width: 3, height: max(box.height - 4, 0))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawNoteBars(in: rect)
        for run in spanRuns() {
            guard let box = box(for: run.range), box.intersects(rect) else { continue }
            let hovered = isShowingCard(run.id)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            ScriptStyle.spanFill().setFill()
            path.fill()
            ScriptStyle.spanStroke(hovered: hovered).setStroke()
            path.lineWidth = 1
            path.stroke()
            let rule = NSBezierPath(roundedRect: rule(beside: box), xRadius: 1.5, yRadius: 1.5)
            Palette.pageRange.withAlphaComponent(hovered ? 1 : 0.6).setFill()
            rule.fill()
        }
        // Same treatment, in the beat's own color — default violet, or
        // whichever the writer picked in the rail — a block the same shape
        // as a page range's, so the two read as the same kind of thing
        // (something marked off) even where they cover different text. A
        // finished beat is never dimmed for being finished — only the one
        // that's next up draws brighter, so the standout signal is "here's
        // what to do next," not "here's what you already did."
        for run in beatRuns() {
            guard let box = box(for: run.range), box.intersects(rect) else { continue }
            let hovered = isShowingBeatCard(run.id)
            let info = beatInfo?(run.id)
            let isNextUp = info?.isNextUp ?? false
            let accent = info?.color.map { Palette.textTint($0) } ?? Palette.beat
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            ScriptStyle.beatFill(accent: accent, hovered: hovered, isNextUp: isNextUp).setFill()
            path.fill()
            ScriptStyle.beatStroke(accent: accent, hovered: hovered, isNextUp: isNextUp).setStroke()
            path.lineWidth = isNextUp ? 1.5 : 1
            path.stroke()
            let rule = NSBezierPath(roundedRect: beatRule(beside: box), xRadius: 1.5, yRadius: 1.5)
            let ruleAlpha: CGFloat = isNextUp ? 1 : (hovered ? 0.85 : 0.6)
            accent.withAlphaComponent(ruleAlpha).setFill()
            rule.fill()
        }
    }

    /// Each run of consecutive note paragraphs, so a note of several lines
    /// reads as one aside rather than a stack of bars.
    private func noteRuns() -> [NSRange] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let string = storage.string as NSString
        var runs: [NSRange] = []
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let raw = storage.attribute(ScriptStyle.paragraphKey, at: paragraph.location, effectiveRange: nil) as? String
            if ScriptStyle.Paragraph(rawValue: raw ?? "") == .note {
                if var last = runs.last, last.location + last.length == paragraph.location {
                    last.length += paragraph.length
                    runs[runs.count - 1] = last
                } else {
                    runs.append(paragraph)
                }
            }
            location = paragraph.location + max(paragraph.length, 1)
        }
        return runs
    }

    /// A bar down the side of an aside, in the room `headIndent` leaves for it.
    private func drawNoteBars(in rect: NSRect) {
        guard let textContainer else { return }
        for run in noteRuns() {
            guard let box = box(for: run), box.intersects(rect) else { continue }
            let x = textContainerOrigin.x + textContainer.lineFragmentPadding + 1
            let bar = NSRect(x: x, y: box.minY + 3, width: 2.5, height: max(box.height - 6, 0))
            ScriptStyle.noteColour.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
        }
    }

    /// Whether this block should be showing its range rather than its writing.
    private func isShowingCard(_ id: String) -> Bool {
        id == hoveredSpan
    }

    private func isShowingBeatCard(_ id: String) -> Bool {
        id == hoveredBeat
    }

    /// The writing is drawn by the text system on top of `drawBackground`, so
    /// the card has to come after it — over the words rather than behind them.
    ///
    /// That's the whole idea: while you're looking for the range you aren't
    /// reading the block, so the block's own area is free to say what it's
    /// about. Nothing is taken from the layout for information wanted only
    /// now and then.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for run in spanRuns() where isShowingCard(run.id) {
            guard let box = box(for: run.range), box.intersects(dirtyRect) else { continue }
            drawCard(for: run.id, on: box)
        }
        for run in beatRuns() where isShowingBeatCard(run.id) {
            guard let box = box(for: run.range), box.intersects(dirtyRect) else { continue }
            drawBeatCard(for: run.id, on: box)
        }
    }

    private func drawCard(for id: String, on box: NSRect) {
        guard let text = spanLabel?(id), !text.isEmpty else { return }
        drawInfoCard(title: text, hint: "Click to open these pages", accent: Palette.pageRange, on: box)
    }

    private func drawBeatCard(for id: String, on box: NSRect) {
        guard let info = beatInfo?(id) else { return }
        let hint = info.isDone ? "Done — right-click to rename or remove" : "Right-click to mark done, rename, or remove"
        let accent = info.color.map { Palette.textTint($0) } ?? Palette.beat
        drawInfoCard(title: info.title, hint: hint, accent: accent, on: box)
    }

    /// The hover card for a block — a page range's or a beat's, same shape,
    /// different colour and words.
    private func drawInfoCard(title: String, hint: String, accent: NSColor, on box: NSRect) {
        let card = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        // Opaque: half-hidden writing showed through and fought the block for
        // attention, which is the opposite of the point. The card's own
        // bounds are what say which block this is.
        ScriptStyle.background.setFill()
        card.fill()
        accent.withAlphaComponent(0.16).setFill()
        card.fill()
        accent.withAlphaComponent(0.9).setStroke()
        card.lineWidth = 1
        card.stroke()

        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: accent,
        ])
        let hintText = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])
        let inset: CGFloat = 16
        let width = max(box.width - inset * 2, 0)
        guard width > 20 else { return }
        let titleSize = titleText.size()

        // A one-line block has room for the title alone; crowding the hint
        // in would clip them both.
        guard box.height >= titleSize.height + hintText.size().height + 20 else {
            titleText.draw(with: NSRect(x: box.minX + inset, y: box.midY - titleSize.height / 2,
                                        width: width, height: titleSize.height),
                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        titleText.draw(with: NSRect(x: box.minX + inset, y: box.minY + 10, width: width, height: titleSize.height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        hintText.draw(with: NSRect(x: box.minX + inset, y: box.minY + 12 + titleSize.height,
                                   width: width, height: hintText.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The block under a point, and the box it's drawn in.
    func span(at point: NSPoint) -> (id: String, box: NSRect)? {
        for run in spanRuns() {
            guard let box = box(for: run.range) else { continue }
            if box.contains(point) || ruleHitBox(beside: box).contains(point) { return (run.id, box) }
        }
        return nil
    }

    /// The block whose margin rule is under the point, and the rule itself.
    /// Hovering the words does nothing: the mouse spends all its time there
    /// while writing, and a popover that follows it flickers.
    private func spanRule(at point: NSPoint) -> (id: String, rule: NSRect)? {
        for run in spanRuns() {
            guard let box = box(for: run.range) else { continue }
            if ruleHitBox(beside: box).contains(point) { return (run.id, rule(beside: box)) }
        }
        return nil
    }

    /// Same idea as `spanRule(at:)`, for a beat — empty outside Editor mode
    /// since `beatRuns()` already is.
    private func beatRule(at point: NSPoint) -> (id: String, rule: NSRect)? {
        for run in beatRuns() {
            guard let box = box(for: run.range) else { continue }
            if ruleHitBox(beside: box).contains(point) { return (run.id, beatRule(beside: box)) }
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
            hoveredSpan = nil
            hoveredBeat = nil
            return
        }
        if hoveredChip != nil {
            hoveredChip = nil
            onHoverChip?(nil, .zero)
        }
        // The hit region is the whole left margin for both, so a paragraph
        // covered by both a page range and a beat favours the range — its
        // click already does something (jump to the pages); a beat's is
        // still reachable by right-click either way.
        if let found = spanRule(at: point) {
            hoveredSpan = found.id
            hoveredBeat = nil
        } else {
            hoveredSpan = nil
            hoveredBeat = beatRule(at: point)?.id
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredSpan = nil
        hoveredBeat = nil
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
        if let markdown = pboard.string(forType: Self.markdownType) {
            return insertMarkdown(markdown)
        }
        // Plain text from elsewhere with Fountain-lite structure in it — an
        // outline drafted in Notes, the text of a .fountain file — keeps its
        // sections, synopses and notes. Plain prose stays plain words, and
        // nothing inline is read as markup either way.
        if let text = pboard.string(forType: .string), FountainLite.hasStructure(text) {
            return insertMarkdown(ScriptMarkdown.serialize(FountainLite.blocks(fromPlainText: text)))
        }
        return super.readSelection(from: pboard, type: type)
    }

    /// Script Markdown in at the selection, rendered the way the editor
    /// renders the file.
    private func insertMarkdown(_ markdown: String) -> Bool {
        guard let piece = attributedString?(markdown) else { return false }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound, shouldChangeText(in: range, replacementString: piece.string) else { return false }
        textStorage?.replaceCharacters(in: range, with: piece)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // A selection on a page keeps its own view first responder; let go
        // of it before this view asks for the keyboard.
        NotificationCenter.default.post(name: .komaDeskClearPageTextSelection, object: nil)
        let point = convert(event.locationInWindow, from: nil)
        // The margin rule goes to the pages, or toggles a beat done. Clicking
        // the words never does either — that has to keep placing the caret.
        if let found = spanRule(at: point) {
            onClickSpan?(found.id)
            return
        }
        if let found = beatRule(at: point) {
            onClickBeat?(found.id)
            return
        }
        if event.modifierFlags.contains(.command), let found = span(at: point) {
            onClickSpan?(found.id)
            return
        }
        super.mouseDown(with: event)
    }

    /// Adds the script's own items — beats in Editor mode, page links in
    /// Writer mode — ahead of AppKit's right-click menu (spelling,
    /// substitutions) when there's something to add.
    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        guard let onContextMenuItems else { return base }
        let point = convert(event.locationInWindow, from: nil)
        let items = onContextMenuItems(characterIndexForInsertion(at: point))
        guard !items.isEmpty else { return base }
        let menu = base ?? NSMenu()
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for run in spanRuns() {
            guard let box = box(for: run.range) else { continue }
            addCursorRect(ruleHitBox(beside: box), cursor: .pointingHand)
        }
        for run in beatRuns() {
            guard let box = box(for: run.range) else { continue }
            addCursorRect(ruleHitBox(beside: box), cursor: .pointingHand)
        }
    }

    override func becomeFirstResponder() -> Bool {
        NotificationCenter.default.post(name: .komaDeskClearPageTextSelection, object: nil)
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

extension ScriptAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

enum ScriptStyle {
    static let background = NSColor(calibratedWhite: 0.12, alpha: 1)
    static var backgroundColor: Color { Color(nsColor: background) }
    static var headerBackground: Color { Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1)) }
    static let paragraphKey = NSAttributedString.Key("panels.paragraph")
    /// The page range a line belongs to. Carried on every character of the
    /// line including its newline, so a block of writing survives editing.
    static let spanKey = NSAttributedString.Key("panels.span")
    /// The beat a line opens, if any — carried the same way `spanKey` is, on
    /// every mode's render, though only Editor mode ever draws it. Attached
    /// invisibly everywhere else so it survives an edit in Writer mode.
    static let beatKey = NSAttributedString.Key("panels.beat")
    /// Whether the writer explicitly asked for bold/italic here — kept apart
    /// from the font's own traits, since a note's font is already italic on
    /// its own account and that must never read back as the writer's choice.
    static let boldKey = NSAttributedString.Key("panels.bold")
    static let italicKey = NSAttributedString.Key("panels.italic")
    /// Which curated swatch a run's highlight/text-color is — the actual
    /// `.backgroundColor`/`.foregroundColor` is what draws, this is what
    /// round-trips to the file.
    static let highlightKey = NSAttributedString.Key("panels.highlight")
    static let textColorKey = NSAttributedString.Key("panels.textColor")

    /// Vermillion, so a block of writing about a range never reads as a
    /// citation chip, which is gold.
    static func spanFill() -> NSColor {
        Palette.pageRange.withAlphaComponent(0.10)
    }
    static func spanStroke(hovered: Bool) -> NSColor {
        Palette.pageRange.withAlphaComponent(hovered ? 0.75 : 0.35)
    }

    /// Same shape as `spanFill()`/`spanStroke(hovered:)`, in whichever
    /// colour this particular beat draws with — its own, or the default
    /// violet every beat used to share — so a beat's block draws exactly
    /// like a page range's, just in a colour that reads as a different
    /// thing when both cover the same text. A finished beat draws at the
    /// same strength as any other — completing one isn't a reason for it to
    /// go dull. Only the beat that's next up draws brighter than baseline.
    static func beatFill(accent: NSColor, hovered: Bool, isNextUp: Bool) -> NSColor {
        let alpha: CGFloat = isNextUp ? 0.18 : (hovered ? 0.14 : 0.10)
        return accent.withAlphaComponent(alpha)
    }
    static func beatStroke(accent: NSColor, hovered: Bool, isNextUp: Bool) -> NSColor {
        let alpha: CGFloat = isNextUp ? 1.0 : (hovered ? 0.75 : 0.35)
        return accent.withAlphaComponent(alpha)
    }

    enum Paragraph: String {
        case body, heading1, heading2, heading3, note, synopsis
    }

    /// Notes are azure: the chips are gold and page ranges are vermillion, so
    /// an aside needs a third voice of its own.
    static let noteColour = Palette.note
    /// The bar a note sits behind, and the room made for it by `headIndent`.
    static let noteIndent: CGFloat = 14

    static func attributes(for style: Paragraph, alignment: ScriptAlignment = .leading) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        switch style {
        case .body: font = .systemFont(ofSize: 15)
        case .heading1: font = .systemFont(ofSize: 22, weight: .bold)
        case .heading2: font = .systemFont(ofSize: 17, weight: .semibold)
        case .heading3: font = .systemFont(ofSize: 16, weight: .semibold)
        case .note:
            let base = NSFont.systemFont(ofSize: 13)
            font = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        case .synopsis:
            // A label for the section above it, not a line to read: small
            // and quiet, but upright, so it doesn't pass for a note.
            font = .systemFont(ofSize: 12, weight: .medium)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style == .body || style == .note ? 4 : 2
        paragraph.paragraphSpacing = style == .body || style == .note ? 8 : 6
        paragraph.alignment = alignment.nsTextAlignment
        if style == .note {
            // Room for the bar, on every line of the note.
            paragraph.firstLineHeadIndent = noteIndent
            paragraph.headIndent = noteIndent
        }
        let colour: NSColor
        switch style {
        case .note: colour = noteColour
        case .synopsis: colour = NSColor.white.withAlphaComponent(0.5)
        case .body: colour = NSColor.white.withAlphaComponent(0.92)
        default: colour = .white
        }
        return [
            .font: font,
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
            paragraphKey: style.rawValue,
        ]
    }

    /// The alignment a paragraph style actually carries, read back the same
    /// way `paragraphKey` recovers which named style a run is.
    static func alignment(of paragraphStyle: NSParagraphStyle?) -> ScriptAlignment {
        switch paragraphStyle?.alignment {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    /// Layers bold, italic, a highlight and a text-color override onto a
    /// paragraph's base attributes — what turns a plain run into a styled
    /// one, in `render(_:)` and wherever the writer changes a selection.
    static func applyingInlineStyle(bold: Bool, italic: Bool, highlight: ScriptSwatch?, textColor: ScriptSwatch?,
                                     to base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = base
        if bold || italic {
            var font = (attributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 15)
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attributes[.font] = font
        }
        attributes[boldKey] = bold
        attributes[italicKey] = italic
        if let highlight {
            attributes[.backgroundColor] = Palette.highlightFill(highlight)
            attributes[highlightKey] = highlight.rawValue
        } else {
            attributes[.backgroundColor] = nil
            attributes[highlightKey] = nil
        }
        if let textColor {
            attributes[.foregroundColor] = Palette.textTint(textColor)
            attributes[textColorKey] = textColor.rawValue
        } else {
            attributes[textColorKey] = nil
        }
        return attributes
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
        Palette.citation.setFill()
        path.fill()

        let name = chip?.thumbnail == nil ? "doc.text" : "photo"
        guard let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return }
        let iconSize = NSSize(width: 11, height: 11)
        let iconRect = NSRect(x: rect.midX - iconSize.width / 2, y: rect.midY - iconSize.height / 2,
                              width: iconSize.width, height: iconSize.height)
        // Dark on the gold fill — the chip is bright enough that white washed out.
        NSGraphicsContext.current?.saveGraphicsState()
        let tinted = icon.copy() as! NSImage
        tinted.isTemplate = true
        tinted.lockFocus()
        Palette.onCitation.set()
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
    let label: ReferenceLabel
    let image: NSImage?

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
            VStack(alignment: .leading, spacing: 2) {
                Text(label.pages.isEmpty ? label.full : label.pages)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                if !label.detail.isEmpty {
                    Text(label.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Click to open the page · drag to move")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
    }
}
