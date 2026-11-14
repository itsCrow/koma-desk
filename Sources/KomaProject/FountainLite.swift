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

    /// What a line typed in the editor is asking to become, the moment its
    /// marks are complete — the editor's convert-as-you-type, from the same
    /// rules the file uses. `= ` and `# `…`### ` count as soon as the space
    /// after them is typed, before any words (the words are what comes
    /// next); `[[note]]` counts when its closing `]]` is. Only at the very
    /// start of the line: `=` or `#` further along is just a character.
    public enum Typed: Equatable, Sendable {
        case synopsis
        case heading(level: Int)
        case note
    }

    /// The typed line's kind, and how many characters of marks to take off
    /// its start and its end once it becomes that kind.
    public static func typedLine(_ line: Substring) -> (kind: Typed, leading: Int, trailing: Int)? {
        if line.hasPrefix(synopsisMarkerTyped), !line.hasPrefix("==") {
            return (.synopsis, synopsisMarkerTyped.count, 0)
        }
        for level in 1...3 where line.hasPrefix(String(repeating: "#", count: level) + " ") {
            return (.heading(level: level), level + 1, 0)
        }
        // Exactly `[[…]]`, as typed — no surrounding spaces to account for.
        if line.hasPrefix("[["), line.hasSuffix("]]"), line.count > 4,
           let text = wholeLineNote(line), !text.isEmpty,
           !line.dropFirst(2).dropLast(2).hasPrefix(" "), !line.dropFirst(2).dropLast(2).hasSuffix(" ") {
            return (.note, 2, 2)
        }
        return nil
    }

    private static let synopsisMarkerTyped = "= "

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
