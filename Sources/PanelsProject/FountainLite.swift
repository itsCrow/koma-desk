import Foundation

/// Fountain-lite: the few Fountain (fountain.io) marks a script can use for
/// its structure, on top of the Markdown the script is written in.
///
/// The script is voice-over for a video essay about comics, not a
/// screenplay, so this takes Fountain's outlining marks and nothing else:
///
/// | Line                | Means                                   | Stored as        |
/// |---------------------|-----------------------------------------|------------------|
/// | `# Act`, `## Beat`  | a section — an act, a major beat        | itself (it's a Markdown heading too) |
/// | `= Short label`     | a synopsis: what the section is about   | `= Short label`  |
/// | `[[A note]]`        | a note to the editor, not narration     | `> A note` — the script's existing note |
///
/// A synopsis is never read aloud (Voice mode hides it, plain-text copies
/// leave it out) and labels its section in the shot list and its export.
/// A `[[note]]` line is the same note the script already had, written the
/// Fountain way; it's saved in the script's own `> ` form, so there is one
/// kind of note, not two.
///
/// Everything else in Fountain is deliberately *not* recognised, because it
/// would misread a Markdown script: `>` is a transition in Fountain but a
/// note here; an ALL-CAPS line is a character cue there but ordinary
/// shouted lettering here; `.`, `!`, `@`, `~`, `INT./EXT.`, `===` page
/// breaks, `/* boneyard */`, `_underline_` and title-page `Key: value`
/// lines all stay plain narration. So does a `[[note]]` in the middle of a
/// line — only a line that is *entirely* a note counts.
///
/// Hook for later: reading or writing real `.fountain` files (to trade
/// scripts with Highland, Slugline or Beat) is a different job — full
/// screenplay grammar at the edge of the app. That belongs in an
/// import/export step, e.g. on SwiftFountain (MIT), not in this parser.
public enum FountainLite {
    /// What a line's own text (after the span, beat and alignment markers)
    /// is, as far as Fountain-lite is concerned.
    public enum Line: Equatable, Sendable {
        /// `= text`: the synopsis text.
        case synopsis(String)
        /// `[[text]]` filling the whole line: the note's text.
        case note(String)
    }

    /// `= text` or `=text`, but not `==`/`===` (a Fountain page break, or a
    /// Markdown underline) and not `=` alone.
    public static func synopsisText(_ line: Substring) -> Substring? {
        guard line.first == "=" else { return nil }
        var rest = line.dropFirst()
        guard let next = rest.first, next != "=" else { return nil }
        if next == " " { rest = rest.dropFirst() }
        return rest.isEmpty ? nil : rest
    }

    /// `[[text]]` and nothing else on the line, surrounding spaces aside.
    public static func wholeLineNote(_ line: Substring) -> Substring? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[["), trimmed.hasSuffix("]]"), trimmed.count > 4 else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2)
        // "[[a]] and [[b]]" is two inline notes with prose between, not one.
        guard !inner.contains("]]"), !inner.contains("[[") else { return nil }
        let text = inner.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Substring(text)
    }

    public static func classify(_ line: Substring) -> Line? {
        if let text = synopsisText(line) { return .synopsis(String(text)) }
        if let text = wholeLineNote(line) { return .note(String(text)) }
        return nil
    }

    /// Plain text from somewhere else — an outline drafted in Notes, a
    /// Fountain file's structure — as script blocks: `#` headings, `=`
    /// synopses, `[[notes]]` and `> ` notes become what they say, and every
    /// other line is kept exactly as typed. Unlike `ScriptMarkdown.parse`,
    /// nothing inline is interpreted: a `*` or a `[` from outside the app
    /// is just a character.
    public static func blocks(fromPlainText text: String) -> [ScriptBlock] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                let body = Substring(line)
                if let classified = classify(body) {
                    switch classified {
                    case .synopsis(let text): return .synopsis([.text(text)])
                    case .note(let text): return .note([.text(text)])
                    }
                }
                if body.hasPrefix(ScriptMarkdown.noteMarker) {
                    return .note([.text(String(body.dropFirst(ScriptMarkdown.noteMarker.count)))])
                }
                var level = 0
                var rest = body
                while rest.first == "#", level < 3 { level += 1; rest = rest.dropFirst() }
                if level > 0, rest.first == " " {
                    return .heading(level: level, [.text(String(rest.dropFirst()))])
                }
                return .paragraph(line.isEmpty ? [] : [.text(line)])
            }
    }

    /// Whether plain text has any Fountain-lite structure worth converting
    /// on the way in — otherwise a paste is just words.
    public static func hasStructure(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let body = Substring(line)
            if classify(body) != nil { return true }
            if body.hasPrefix(ScriptMarkdown.noteMarker) { return true }
            return body.hasPrefix("# ") || body.hasPrefix("## ") || body.hasPrefix("### ")
        }
    }
}
