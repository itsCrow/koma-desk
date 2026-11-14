import Foundation

/// Where a block's text sits — apart from what kind of block it is, so
/// changing one never resets the other.
public enum ScriptAlignment: String, Equatable, Sendable {
    case leading, center, trailing
}

/// A curated color, named rather than an arbitrary RGB value, so the file
/// stays simple and every writer sees the same small set — the same idea as
/// `Palette`'s three fixed hues, extended to what the writer picks by hand.
public enum ScriptSwatch: String, CaseIterable, Codable, Equatable, Sendable {
    case yellow, green, blue, pink
}

/// A run of text carrying inline formatting. Plain, unstyled text stays
/// `.text` — this only exists for a run that needs one of these flags.
public struct TextRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var highlight: ScriptSwatch?
    public var textColor: ScriptSwatch?

    public init(text: String, bold: Bool = false, italic: Bool = false,
                highlight: ScriptSwatch? = nil, textColor: ScriptSwatch? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.highlight = highlight
        self.textColor = textColor
    }
}

/// A run within a line of script.
public enum ScriptInline: Equatable, Sendable {
    case text(String)
    /// A citation chip: the id it points at and how it reads.
    case citation(id: String, text: String)
    /// Text with bold, italic, a highlight, or a text-color override.
    case styledText(TextRun)
}

/// One line of script. A line is a block — the editor's paragraph — so the
/// file and the text view agree on where everything is.
public struct ScriptBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        /// An aside for the editor — "hold this panel a beat". Part of the
        /// script file, but never part of what gets read aloud.
        case note
        /// Fountain's `= synopsis`: a short label for the section it sits
        /// in — what this stretch is about. Outline, not narration: never
        /// read aloud. See `FountainLite`.
        case synopsis
    }

    public var kind: Kind
    /// The page range this line is about, if it belongs to one. Consecutive
    /// lines sharing an id read as one block of writing; the id names the
    /// range, and the range itself lives in the project's manifest.
    public var spanID: String?
    /// The beat that starts at this line, if any — a boundary, not a range
    /// like `spanID`. The section it opens runs until the next beat or the
    /// script's end; the beat itself (its title, done or not) lives in the
    /// project's manifest, same as a page range's own record does.
    public var beatID: String?
    /// Left, centered, or right — independent of `kind`.
    public var alignment: ScriptAlignment
    public var inlines: [ScriptInline]

    public init(kind: Kind, span: String? = nil, beat: String? = nil,
                alignment: ScriptAlignment = .leading, inlines: [ScriptInline]) {
        self.kind = kind
        self.spanID = span
        self.beatID = beat
        self.alignment = alignment
        self.inlines = inlines
    }

    public static func paragraph(_ inlines: [ScriptInline], span: String? = nil, beat: String? = nil,
                                  alignment: ScriptAlignment = .leading) -> ScriptBlock {
        ScriptBlock(kind: .paragraph, span: span, beat: beat, alignment: alignment, inlines: inlines)
    }

    public static func heading(level: Int, _ inlines: [ScriptInline], span: String? = nil, beat: String? = nil,
                                alignment: ScriptAlignment = .leading) -> ScriptBlock {
        ScriptBlock(kind: .heading(level: level), span: span, beat: beat, alignment: alignment, inlines: inlines)
    }

    public static func note(_ inlines: [ScriptInline], span: String? = nil, beat: String? = nil,
                             alignment: ScriptAlignment = .leading) -> ScriptBlock {
        ScriptBlock(kind: .note, span: span, beat: beat, alignment: alignment, inlines: inlines)
    }

    public static func synopsis(_ inlines: [ScriptInline], span: String? = nil, beat: String? = nil,
                                 alignment: ScriptAlignment = .leading) -> ScriptBlock {
        ScriptBlock(kind: .synopsis, span: span, beat: beat, alignment: alignment, inlines: inlines)
    }

    public var headingLevel: Int? {
        if case .heading(let level) = kind { return level }
        return nil
    }

    public var isNote: Bool { kind == .note }
    public var isSynopsis: Bool { kind == .synopsis }

    /// The line's words, chips as their text — for labels and outlines.
    public var plainText: String {
        inlines.map { run -> String in
            switch run {
            case .text(let s): return s
            case .styledText(let styled): return styled.text
            case .citation(_, let text): return text
            }
        }.joined()
    }
}

/// The script's file format: Markdown, one block per line, citations as links
/// to `panels://cite/<id>`. Readable and portable without the app; the app
/// renders the links as chips. Parsing and serialising round-trip exactly.
public enum ScriptMarkdown {
    public static let citationScheme = "panels://cite/"

    public static func citationURL(id: String) -> URL {
        URL(string: citationScheme + id)!
    }

    public static func citationID(from url: URL) -> String? {
        let s = url.absoluteString
        guard s.hasPrefix(citationScheme) else { return nil }
        let id = String(s.dropFirst(citationScheme.count))
        return id.isEmpty ? nil : id
    }

    // MARK: - Parse

    public static func parse(_ markdown: String) -> [ScriptBlock] {
        markdown.components(separatedBy: "\n").map(parseLine)
    }

    private static func parseLine(_ line: String) -> ScriptBlock {
        // The span marker sits before everything else, so the rest of the line
        // parses exactly as it would without one.
        var span: String?
        var body = line
        if let marker = parseSpanMarker(line) {
            span = marker.id
            body = String(marker.rest)
        }
        // The beat marker comes next, on the same footing as the span marker
        // — a line can open a beat, a page range, both, or neither.
        var beat: String?
        if let marker = parseBeatMarker(body) {
            beat = marker.id
            body = String(marker.rest)
        }
        // The alignment marker comes next, on the same footing: present only
        // when it isn't the default, so an ordinary line never carries one.
        var alignment = ScriptAlignment.leading
        if let marker = parseAlignMarker(body) {
            alignment = marker.alignment
            body = String(marker.rest)
        }
        // A blockquote is a note: real Markdown, so the file still reads
        // anywhere, and an aside is exactly what a quote block looks like.
        if body.hasPrefix(noteMarker) {
            return .note(parseInlines(String(body.dropFirst(noteMarker.count))), span: span, beat: beat, alignment: alignment)
        }
        // Fountain-lite: `= synopsis`, and a `[[note]]` line — the same note
        // as `> `, written the Fountain way.
        switch FountainLite.classify(Substring(body)) {
        case .synopsis(let text)?:
            return .synopsis(parseInlines(text), span: span, beat: beat, alignment: alignment)
        case .note(let text)?:
            return .note(parseInlines(text), span: span, beat: beat, alignment: alignment)
        case nil:
            break
        }
        var level = 0
        var rest = Substring(body)
        while rest.first == "#", level < 3 { level += 1; rest = rest.dropFirst() }
        if level > 0, rest.first == " " {
            return .heading(level: level, parseInlines(String(rest.dropFirst())), span: span, beat: beat, alignment: alignment)
        }
        return .paragraph(parseInlines(body), span: span, beat: beat, alignment: alignment)
    }

    static let spanOpening = "<span:"
    static let beatOpening = "<beat:"
    static let alignOpening = "<align:"
    static let noteMarker = "> "
    static let synopsisMarker = "= "

    /// `<span:k7m2pq> ` at the very start of a line, and what follows it.
    /// Anything that isn't exactly this shape is ordinary prose.
    static func parseSpanMarker(_ line: String) -> (id: String, rest: Substring)? {
        guard line.hasPrefix(spanOpening) else { return nil }
        let afterOpening = line.index(line.startIndex, offsetBy: spanOpening.count)
        guard let close = line[afterOpening...].firstIndex(of: ">") else { return nil }
        let id = String(line[afterOpening..<close])
        guard !id.isEmpty, id.count <= 16,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        let afterClose = line.index(after: close)
        guard afterClose < line.endIndex, line[afterClose] == " " else { return nil }
        return (id, line[line.index(after: afterClose)...])
    }

    static func spanMarker(id: String) -> String { spanOpening + id + "> " }

    /// `<beat:k7m2pq> ` at the start of a line (after the span marker, if
    /// there is one), and what follows it. Same shape and id grammar as a
    /// span marker, on its own line: unlike a span, a beat marks a single
    /// line, so there's nothing to coalesce.
    static func parseBeatMarker(_ line: String) -> (id: String, rest: Substring)? {
        guard line.hasPrefix(beatOpening) else { return nil }
        let afterOpening = line.index(line.startIndex, offsetBy: beatOpening.count)
        guard let close = line[afterOpening...].firstIndex(of: ">") else { return nil }
        let id = String(line[afterOpening..<close])
        guard !id.isEmpty, id.count <= 16,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        let afterClose = line.index(after: close)
        guard afterClose < line.endIndex, line[afterClose] == " " else { return nil }
        return (id, line[line.index(after: afterClose)...])
    }

    static func beatMarker(id: String) -> String { beatOpening + id + "> " }

    /// `<align:center> ` at the start of a line (after the span marker, if
    /// there is one), and what follows it. Left is the default and is never
    /// written, so an ordinary line stays exactly as it was before alignment
    /// existed.
    static func parseAlignMarker(_ line: String) -> (alignment: ScriptAlignment, rest: Substring)? {
        guard line.hasPrefix(alignOpening) else { return nil }
        let afterOpening = line.index(line.startIndex, offsetBy: alignOpening.count)
        guard let close = line[afterOpening...].firstIndex(of: ">") else { return nil }
        guard let alignment = ScriptAlignment(rawValue: String(line[afterOpening..<close])), alignment != .leading
        else { return nil }
        let afterClose = line.index(after: close)
        guard afterClose < line.endIndex, line[afterClose] == " " else { return nil }
        return (alignment, line[line.index(after: afterClose)...])
    }

    static func alignMarker(_ alignment: ScriptAlignment) -> String { alignOpening + alignment.rawValue + "> " }

    /// Text with `\` escapes, `[text](panels://cite/id)` links, `*`/`**`/`***`
    /// emphasis, and `{hl:name}…{/hl}` / `{fg:name}…{/fg}` color tags. Not a
    /// general Markdown parser — an author-controlled format that only ever
    /// sees well-formed, properly nested tags written by this same app.
    static func parseInlines(_ s: String) -> [ScriptInline] {
        var runs: [ScriptInline] = []
        var text = ""
        var i = s.startIndex
        var bold = false
        var italic = false
        var highlight: ScriptSwatch?
        var textColor: ScriptSwatch?

        func flush() {
            guard !text.isEmpty else { return }
            if bold || italic || highlight != nil || textColor != nil {
                runs.append(.styledText(TextRun(text: text, bold: bold, italic: italic,
                                                 highlight: highlight, textColor: textColor)))
            } else {
                runs.append(.text(text))
            }
            text = ""
        }

        while i < s.endIndex {
            let c = s[i]
            if c == "\\", s.index(after: i) < s.endIndex {
                text.append(s[s.index(after: i)])
                i = s.index(i, offsetBy: 2)
                continue
            }
            if c == "[", let link = parseLink(s, from: i) {
                flush()
                runs.append(.citation(id: link.id, text: link.text))
                i = link.end
                continue
            }
            if c == "*" {
                var j = i
                var count = 0
                while j < s.endIndex, s[j] == "*", count < 3 { j = s.index(after: j); count += 1 }
                flush()
                if count == 2 || count == 3 { bold.toggle() }
                if count == 1 || count == 3 { italic.toggle() }
                i = j
                continue
            }
            if c == "{", let tag = parseTag(s, from: i) {
                flush()
                switch tag.kind {
                case .highlightOpen(let swatch): highlight = swatch
                case .highlightClose: highlight = nil
                case .colorOpen(let swatch): textColor = swatch
                case .colorClose: textColor = nil
                }
                i = tag.end
                continue
            }
            text.append(c)
            i = s.index(after: i)
        }
        flush()
        return runs
    }

    private enum InlineTag {
        case highlightOpen(ScriptSwatch)
        case highlightClose
        case colorOpen(ScriptSwatch)
        case colorClose
    }

    /// `{hl:yellow}`, `{/hl}`, `{fg:blue}` or `{/fg}` starting at `start`, or
    /// nil if what's there isn't one of those four exact shapes — anything
    /// else beginning with `{` is left as the plain text it looks like.
    private static func parseTag(_ s: String, from start: String.Index) -> (kind: InlineTag, end: String.Index)? {
        guard let close = s[start...].firstIndex(of: "}") else { return nil }
        let inner = s[s.index(after: start)..<close]
        let end = s.index(after: close)
        if inner == "/hl" { return (.highlightClose, end) }
        if inner == "/fg" { return (.colorClose, end) }
        if inner.hasPrefix("hl:"), let swatch = ScriptSwatch(rawValue: String(inner.dropFirst(3))) {
            return (.highlightOpen(swatch), end)
        }
        if inner.hasPrefix("fg:"), let swatch = ScriptSwatch(rawValue: String(inner.dropFirst(3))) {
            return (.colorOpen(swatch), end)
        }
        return nil
    }

    /// `[text](panels://cite/id)` starting at `start`, or nil if it isn't one.
    private static func parseLink(_ s: String, from start: String.Index) -> (id: String, text: String, end: String.Index)? {
        var i = s.index(after: start)
        var label = ""
        while i < s.endIndex {
            let c = s[i]
            if c == "\\", s.index(after: i) < s.endIndex {
                label.append(s[s.index(after: i)])
                i = s.index(i, offsetBy: 2)
                continue
            }
            if c == "]" { break }
            label.append(c)
            i = s.index(after: i)
        }
        guard i < s.endIndex, s[i] == "]" else { return nil }
        i = s.index(after: i)
        guard i < s.endIndex, s[i] == "(" else { return nil }
        i = s.index(after: i)
        guard let close = s[i...].firstIndex(of: ")") else { return nil }
        let target = String(s[i..<close])
        guard let url = URL(string: target), let id = citationID(from: url) else { return nil }
        return (id, label, s.index(after: close))
    }

    // MARK: - Serialise

    public static func serialize(_ blocks: [ScriptBlock]) -> String {
        blocks.map(serializeBlock).joined(separator: "\n")
    }

    private static func serializeBlock(_ block: ScriptBlock) -> String {
        var prefix = block.spanID.map(spanMarker(id:)) ?? ""
        if let beat = block.beatID { prefix += beatMarker(id: beat) }
        if block.alignment != .leading { prefix += alignMarker(block.alignment) }
        switch block.kind {
        case .heading(let level):
            return prefix + String(repeating: "#", count: max(1, min(level, 3))) + " " + serializeInlines(block.inlines)
        case .note:
            return prefix + noteMarker + serializeInlines(block.inlines)
        case .synopsis:
            return prefix + synopsisMarker + serializeInlines(block.inlines)
        case .paragraph:
            var body = serializeInlines(block.inlines)
            // A paragraph that happens to start like a heading, a note, a
            // synopsis, a span marker, a beat marker or an alignment marker is
            // escaped so it comes back as the paragraph it is. (A `[[` can't
            // start one: every `[` in prose is escaped already.)
            if body.hasPrefix("#") || body.hasPrefix(noteMarker) || FountainLite.synopsisText(Substring(body)) != nil
                || parseSpanMarker(body) != nil || parseBeatMarker(body) != nil || parseAlignMarker(body) != nil {
                body = "\\" + body
            }
            return prefix + body
        }
    }

    static func serializeInlines(_ runs: [ScriptInline]) -> String {
        runs.map { run in
            switch run {
            case .text(let s):
                return escape(s)
            case .citation(let id, let text):
                return "[" + escape(text, andClosingBracket: true) + "](" + citationScheme + id + ")"
            case .styledText(let run):
                var body = escape(run.text)
                if let color = run.textColor { body = "{fg:\(color.rawValue)}" + body + "{/fg}" }
                if let highlight = run.highlight { body = "{hl:\(highlight.rawValue)}" + body + "{/hl}" }
                let starCount = run.bold && run.italic ? 3 : (run.bold ? 2 : (run.italic ? 1 : 0))
                if starCount > 0 {
                    let stars = String(repeating: "*", count: starCount)
                    body = stars + body + stars
                }
                return body
            }
        }.joined()
    }

    private static func escape(_ s: String, andClosingBracket: Bool = false) -> String {
        var out = ""
        for c in s {
            if c == "\\" || c == "[" || c == "*" || (andClosingBracket && c == "]") { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The citation ids in the order they appear in the script, each once.
    /// A citation's place in the video is where it first appears.
    public static func citationIDs(in markdown: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for block in parse(markdown) {
            for run in block.inlines {
                if case .citation(let id, _) = run, seen.insert(id).inserted {
                    order.append(id)
                }
            }
        }
        return order
    }

    /// The page ranges in the order they first appear, each once.
    public static func spanIDs(in markdown: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for block in parse(markdown) {
            if let id = block.spanID, seen.insert(id).inserted { order.append(id) }
        }
        return order
    }

    /// The beats in the order they appear, each once. A beat's own line is
    /// where it starts, so first-appearance order is already script order.
    public static func beatIDs(in markdown: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for block in parse(markdown) {
            if let id = block.beatID, seen.insert(id).inserted { order.append(id) }
        }
        return order
    }

    /// The page range the line holding a citation belongs to — which pages a
    /// shot sits among, for the editor.
    public static func spanID(containing citationID: String, in markdown: String) -> String? {
        for block in parse(markdown) {
            let holdsIt = block.inlines.contains {
                if case .citation(let found, _) = $0 { return found == citationID }
                return false
            }
            if holdsIt { return block.spanID }
        }
        return nil
    }

    /// The text of the line a citation sits in, without its chips — the
    /// sentence around a shot, for a shot list.
    public static func context(of id: String, in markdown: String) -> String? {
        for block in parse(markdown) {
            let runs = block.inlines
            guard runs.contains(where: { if case .citation(let found, _) = $0 { return found == id }; return false })
            else { continue }
            let text = runs.map { run -> String in
                switch run {
                case .text(let s): return s
                case .styledText(let styled): return styled.text
                case .citation: return " "
                }
            }.joined()
            // Chips leave gaps behind; the sentence should read as one.
            return text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Plain text

    /// What a paste elsewhere does with the notes: leaves them out, since
    /// they are not the narration, or brings them along marked as asides.
    public enum NoteHandling: Equatable, Sendable {
        case omit
        case marked
    }

    /// For pasting somewhere that isn't the app: chips become their text.
    ///
    /// With `spanLabels`, each block of writing carries its page range on its
    /// last line — "… (pp. 12–17)". Without them the ranges are dropped, which
    /// is what a caller wants when the reader already knows.
    public static func plainText(_ blocks: [ScriptBlock], spanLabels: [String: String] = [:],
                                notes: NoteHandling = .omit) -> String {
        // Filtered before anything else: a range's label lands on the last
        // line of its run, and dropping that line later would take the label
        // with it.
        let blocks = blocks.compactMap { block -> ScriptBlock? in
            // A synopsis labels the outline; it's never narration, whatever
            // is done with the notes.
            if block.isSynopsis { return nil }
            guard block.isNote else { return block }
            switch notes {
            case .omit:
                return nil
            case .marked:
                // Marked here rather than later, so nothing downstream has to
                // remember that this line used to be a note.
                var inlines: [ScriptInline] = [.text("[NOTE: ")]
                inlines += block.inlines
                inlines.append(.text("]"))
                return ScriptBlock(kind: .paragraph, span: block.spanID, inlines: inlines)
            }
        }
        return blocks.enumerated().map { index, block in
            var line = block.inlines.map { run -> String in
                switch run {
                case .text(let s): return s
                case .styledText(let styled): return styled.text
                case .citation(_, let text): return text
                }
            }.joined()
            if let id = block.spanID, let label = spanLabels[id], !label.isEmpty {
                let endsTheRun = index == blocks.count - 1 || blocks[index + 1].spanID != id
                if endsTheRun {
                    line += line.isEmpty ? "(\(label))" : " (\(label))"
                }
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Outline

    /// The script's sections, in order: one per heading, each with the
    /// first synopsis written under it and the citations it holds. Anything
    /// before the first heading is a section with no title — present only
    /// if it holds a synopsis or a citation.
    public static func outline(_ blocks: [ScriptBlock]) -> [ScriptSection] {
        var sections: [ScriptSection] = [ScriptSection(title: nil, level: 0, synopsis: nil, citationIDs: [])]
        for block in blocks {
            if let level = block.headingLevel {
                sections.append(ScriptSection(title: block.plainText, level: level, synopsis: nil, citationIDs: []))
                continue
            }
            let last = sections.count - 1
            if block.isSynopsis, sections[last].synopsis == nil {
                sections[last].synopsis = block.plainText
            }
            for run in block.inlines {
                if case .citation(let id, _) = run, !sections[last].citationIDs.contains(id) {
                    sections[last].citationIDs.append(id)
                }
            }
        }
        if sections[0].synopsis == nil, sections[0].citationIDs.isEmpty { sections.removeFirst() }
        return sections
    }

    public static func outline(in markdown: String) -> [ScriptSection] {
        outline(parse(markdown))
    }
}

/// One section of a script's outline: a heading, what it's about, and the
/// shots in it. See `ScriptMarkdown.outline(_:)`.
public struct ScriptSection: Equatable, Sendable {
    /// The heading's text; nil for whatever comes before the first heading.
    public var title: String?
    /// 1–3 for `#`–`###`; 0 for the untitled opening.
    public var level: Int
    /// The first `= synopsis` under the heading.
    public var synopsis: String?
    /// Citations in the section, in order, each once. One cited again in a
    /// later section is listed there too.
    public var citationIDs: [String]

    public init(title: String?, level: Int, synopsis: String?, citationIDs: [String]) {
        self.title = title
        self.level = level
        self.synopsis = synopsis
        self.citationIDs = citationIDs
    }

    /// Each section's shots, counting a citation only where it first
    /// appears — the shot list's numbering runs once through the script, so
    /// a panel cited again later isn't a second shot.
    public static func firstAppearances(in sections: [ScriptSection]) -> [[String]] {
        var seen = Set<String>()
        return sections.map { section in
            section.citationIDs.filter { seen.insert($0).inserted }
        }
    }
}
