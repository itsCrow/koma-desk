import Foundation

/// A run within a line of script.
public enum ScriptInline: Equatable, Sendable {
    case text(String)
    /// A citation chip: the id it points at and how it reads.
    case citation(id: String, text: String)
}

/// One line of script. A line is a block — the editor's paragraph — so the
/// file and the text view agree on where everything is.
public enum ScriptBlock: Equatable, Sendable {
    case heading(level: Int, [ScriptInline])
    case paragraph([ScriptInline])

    public var inlines: [ScriptInline] {
        switch self {
        case .heading(_, let runs), .paragraph(let runs): return runs
        }
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
        var level = 0
        var rest = Substring(line)
        while rest.first == "#", level < 2 { level += 1; rest = rest.dropFirst() }
        if level > 0, rest.first == " " {
            return .heading(level: level, parseInlines(String(rest.dropFirst())))
        }
        return .paragraph(parseInlines(line))
    }

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
        switch block {
        case .heading(let level, let runs):
            return String(repeating: "#", count: max(1, min(level, 2))) + " " + serializeInlines(runs)
        case .paragraph(let runs):
            let body = serializeInlines(runs)
            // A paragraph that happens to start like a heading is escaped so
            // it comes back as a paragraph.
            return body.hasPrefix("#") ? "\\" + body : body
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

    /// For pasting somewhere that isn't the app: chips become their text.
    public static func plainText(_ blocks: [ScriptBlock]) -> String {
        blocks.map { block in
            block.inlines.map { run -> String in
                switch run {
                case .text(let s): return s
                case .citation(_, let text): return text
                }
            }.joined()
        }.joined(separator: "\n")
    }
}
