import Foundation

/// A run within a line of script.
public enum ScriptInline: Equatable, Sendable {
    case text(String)
    /// A citation chip: the id it points at and how it reads.
    case citation(id: String, text: String)
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
    }

    public var kind: Kind
    /// The page range this line is about, if it belongs to one. Consecutive
    /// lines sharing an id read as one block of writing; the id names the
    /// range, and the range itself lives in the project's manifest.
    public var spanID: String?
    public var inlines: [ScriptInline]

    public init(kind: Kind, span: String? = nil, inlines: [ScriptInline]) {
        self.kind = kind
        self.spanID = span
        self.inlines = inlines
    }

    public static func paragraph(_ inlines: [ScriptInline], span: String? = nil) -> ScriptBlock {
        ScriptBlock(kind: .paragraph, span: span, inlines: inlines)
    }

    public static func heading(level: Int, _ inlines: [ScriptInline], span: String? = nil) -> ScriptBlock {
        ScriptBlock(kind: .heading(level: level), span: span, inlines: inlines)
    }

    public static func note(_ inlines: [ScriptInline], span: String? = nil) -> ScriptBlock {
        ScriptBlock(kind: .note, span: span, inlines: inlines)
    }

    public var headingLevel: Int? {
        if case .heading(let level) = kind { return level }
        return nil
    }

    public var isNote: Bool { kind == .note }
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
        // A blockquote is a note: real Markdown, so the file still reads
        // anywhere, and an aside is exactly what a quote block looks like.
        if body.hasPrefix(noteMarker) {
            return .note(parseInlines(String(body.dropFirst(noteMarker.count))), span: span)
        }
        var level = 0
        var rest = Substring(body)
        while rest.first == "#", level < 2 { level += 1; rest = rest.dropFirst() }
        if level > 0, rest.first == " " {
            return .heading(level: level, parseInlines(String(rest.dropFirst())), span: span)
        }
        return .paragraph(parseInlines(body), span: span)
    }

    static let spanOpening = "<span:"
    static let noteMarker = "> "

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

    /// Text with `\` escapes, and `[text](panels://cite/id)` links.
    static func parseInlines(_ s: String) -> [ScriptInline] {
        var runs: [ScriptInline] = []
        var text = ""
        var i = s.startIndex

        func flush() {
            if !text.isEmpty { runs.append(.text(text)); text = "" }
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
            text.append(c)
            i = s.index(after: i)
        }
        flush()
        return runs
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
        let prefix = block.spanID.map(spanMarker(id:)) ?? ""
        switch block.kind {
        case .heading(let level):
            return prefix + String(repeating: "#", count: max(1, min(level, 2))) + " " + serializeInlines(block.inlines)
        case .note:
            return prefix + noteMarker + serializeInlines(block.inlines)
        case .paragraph:
            var body = serializeInlines(block.inlines)
            // A paragraph that happens to start like a heading, a note or a
            // span marker is escaped so it comes back as the paragraph it is.
            if body.hasPrefix("#") || body.hasPrefix(noteMarker) || parseSpanMarker(body) != nil {
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
            }
        }.joined()
    }

    private static func escape(_ s: String, andClosingBracket: Bool = false) -> String {
        var out = ""
        for c in s {
            if c == "\\" || c == "[" || (andClosingBracket && c == "]") { out.append("\\") }
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
                if case .text(let s) = run { return s }
                return " "
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
}
