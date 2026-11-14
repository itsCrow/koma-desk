import AppKit
import Foundation
import Observation
import KomaProject
import PageCapture

/// The open project: the script, its citations, and where they point. Saves
/// itself a second after the last change, and on close.
@Observable
@MainActor
final class Project {
    let url: URL
    var manifest: ProjectManifest {
        didSet { if manifest != oldValue { scheduleSave() } }
    }
    /// The script as Markdown — the file on disk, and the editor's truth.
    var script: String {
        didSet { if script != oldValue { scheduleSave() } }
    }

    /// A chip the editor should insert at the cursor. Set by the reader when
    /// a citation is made; cleared by the editor once it's in.
    var pendingInsertion: Citation?
    /// A formatting command for the editor's current paragraph.
    var pendingCommand: ScriptCommand?
    /// A citation the editor should scroll to and select.
    var pendingReveal: String?
    /// A page-range change for the editor to apply to the writing.
    var pendingSpanCommand: SpanCommand?
    /// An inline formatting change — bold, italic, highlight, text color —
    /// for the editor to apply to the current selection.
    var pendingInlineCommand: InlineCommand?
    /// A beat's color, changed from the tag rail. Unlike a beat's other
    /// mutations — done, rename, create, remove — this one starts outside
    /// the text view (a SwiftUI popover, not a click inside the script), so
    /// it needs the same pending-command handoff the page-range/formatting
    /// commands above already use to reach the live editor.
    var pendingBeatColorChange: BeatColorChange?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var name: String { manifest.name }
    var capturesFolder: URL { ProjectStore.capturesFolder(of: url) }

    init(url: URL, loaded: ProjectStore.Loaded) {
        self.url = url
        self.manifest = loaded.manifest
        self.script = loaded.script
    }

    static func create(at url: URL, series: [String]) throws -> Project {
        let name = url.deletingPathExtension().lastPathComponent
        return Project(url: url, loaded: try ProjectStore.create(at: url, name: name, series: series))
    }

    static func open(_ url: URL) throws -> Project {
        Project(url: url, loaded: try ProjectStore.load(url))
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? ProjectStore.save(.init(manifest: manifest, script: script), to: url)
    }

    // MARK: - Items and citations

    /// Notes an item of the library the script cites, the first time it does.
    func register(_ ref: ItemRef) {
        manifest.register(ref)
    }

    func add(_ citation: Citation) {
        manifest.citations.append(citation)
    }

    func citation(id: String) -> Citation? {
        manifest.citation(id: id)
    }

    /// The citations in the order they appear in the script — the order the
    /// video runs, which is not the order they were made in.
    var citationsInScriptOrder: [Citation] {
        let byID = Dictionary(manifest.citations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScriptMarkdown.citationIDs(in: script).compactMap { byID[$0] }
    }

    /// The script's sections — its headings, with their synopses — and the
    /// shots in each, numbered once through the whole script. Empty when the
    /// script has no headings: then there's nothing to group by.
    var shotSections: [(section: ScriptSection, shots: [(number: Int, citation: Citation)])] {
        let sections = ScriptMarkdown.outline(in: script)
        guard sections.contains(where: { $0.title != nil }) else { return [] }
        let byID = Dictionary(manifest.citations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var number = 0
        return zip(sections, ScriptSection.firstAppearances(in: sections)).map { section, ids in
            let shots = ids.compactMap { byID[$0] }.map { citation -> (number: Int, citation: Citation) in
                number += 1
                return (number, citation)
            }
            return (section, shots)
        }
    }

    /// The page ranges in the order their blocks appear in the script.
    var spansInScriptOrder: [PageSpan] {
        let byID = Dictionary(manifest.spans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScriptMarkdown.spanIDs(in: script).compactMap { byID[$0] }
    }

    /// The range a shot sits among, if its line belongs to a block.
    func span(containing citationID: String) -> PageSpan? {
        ScriptMarkdown.spanID(containing: citationID, in: script).flatMap { manifest.span(id: $0) }
    }

    /// Page ranges nothing in the script points at any more.
    var unusedSpans: [PageSpan] {
        let used = Set(ScriptMarkdown.spanIDs(in: script))
        return manifest.spans.filter { !used.contains($0.id) }
    }

    /// The beats in the order their marker lines appear in the script.
    var beatsInScriptOrder: [Beat] {
        let byID = Dictionary(manifest.beats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScriptMarkdown.beatIDs(in: script).compactMap { byID[$0] }
    }

    /// Beats whose marker line is no longer anywhere in the script — deleted
    /// along with its paragraph, rather than through the "Remove Beat" menu.
    var unusedBeats: [Beat] {
        let used = Set(ScriptMarkdown.beatIDs(in: script))
        return manifest.beats.filter { !used.contains($0.id) }
    }

    /// Citations no longer anywhere in the script. Deleting a chip leaves the
    /// citation behind, so without this they pile up unseen.
    var unusedCitations: [Citation] {
        let used = Set(ScriptMarkdown.citationIDs(in: script))
        return manifest.citations.filter { !used.contains($0.id) }
    }

    /// Forgets a citation and sends its capture to the Trash — recoverable,
    /// rather than gone.
    func removeCitation(id: String) {
        let doomed = manifest.citations.first { $0.id == id }.flatMap(captureURL(for:))
        manifest.citations.removeAll { $0.id == id }
        if let doomed, !isCaptureInUse(doomed.lastPathComponent) {
            try? FileManager.default.trashItem(at: doomed, resultingItemURL: nil)
        }
    }

    /// Whether any citation still in the script points at this file.
    private func isCaptureInUse(_ filename: String) -> Bool {
        citationsInScriptOrder.contains { $0.captureFile == filename }
    }

    /// Capture files the script has no use for: those belonging to citations
    /// whose chip was deleted, and those belonging to no citation at all —
    /// whole pages saved automatically beside panels, before that stopped.
    var unusedCaptureFiles: [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: capturesFolder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let needed = Set(citationsInScriptOrder.compactMap(\.captureFile))
        return entries.filter { $0.pathExtension.lowercased() == "png" && !needed.contains($0.lastPathComponent) }
    }

    var unusedCaptureBytes: Int64 {
        unusedCaptureFiles.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Sends every unused capture to the Trash and forgets the citations that
    /// are no longer in the script. Returns what went.
    @discardableResult
    func cleanUpUnusedCaptures() -> (files: Int, bytes: Int64) {
        let doomed = unusedCaptureFiles
        let bytes = unusedCaptureBytes
        var trashed = 0
        for url in doomed {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { trashed += 1 }
        }
        let used = Set(ScriptMarkdown.citationIDs(in: script))
        manifest.citations.removeAll { !used.contains($0.id) }
        // Ranges own no files, so they cost nothing to keep — but a range the
        // writing no longer points at is just as dead as an unused citation,
        // and this is the one moment the writer has asked for a tidy-up.
        let usedSpans = Set(ScriptMarkdown.spanIDs(in: script))
        manifest.spans.removeAll { !usedSpans.contains($0.id) }
        // Same for beats: a marker line deleted along with its paragraph
        // leaves an orphaned record behind otherwise.
        let usedBeats = Set(ScriptMarkdown.beatIDs(in: script))
        manifest.beats.removeAll { !usedBeats.contains($0.id) }
        // The writer keeps its own manifest of everything it ever wrote; it
        // should describe what the folder now holds.
        CaptureWriter(folder: capturesFolder).pruneMissingRecords()
        return (trashed, bytes)
    }

    /// How a block of writing starts — enough to recognise which passage a
    /// range belongs to in an export.
    func opening(of spanID: String, limit: Int = 90) -> String? {
        for block in ScriptMarkdown.parse(script) where block.spanID == spanID {
            let text = block.inlines.map { run -> String in
                switch run {
                case .text(let s): return s
                case .styledText(let styled): return styled.text
                case .citation: return " "
                }
            }.joined()
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            return text.count <= limit ? text : String(text.prefix(limit)) + "…"
        }
        return nil
    }

    /// The sentence a citation sits in.
    func context(of id: String) -> String? {
        ScriptMarkdown.context(of: id, in: script)
    }

    func captureURL(for citation: Citation) -> URL? {
        citation.captureFile.map { capturesFolder.appendingPathComponent($0) }
    }

    /// The script with chips as plain text, for pasting somewhere else. Each
    /// block of writing keeps its page range, so the ranges survive the trip
    /// into Google Docs.
    var plainTextScript: String {
        plainTextScript(notes: .omit)
    }

    /// The script as plain text. Notes are left out by default: this is what
    /// gets read aloud, and an aside to the editor isn't part of it.
    func plainTextScript(notes: ScriptMarkdown.NoteHandling) -> String {
        let labels = Dictionary(manifest.spans.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return ScriptMarkdown.plainText(ScriptMarkdown.parse(script), spanLabels: labels, notes: notes)
    }

    /// The asides, in the order they appear.
    var notesInScriptOrder: [String] {
        ScriptMarkdown.parse(script).filter(\.isNote).map { block in
            block.inlines.map { run -> String in
                switch run {
                case .text(let s): return s
                case .styledText(let styled): return styled.text
                case .citation(_, let text): return text
                }
            }.joined().trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}

/// Formatting the writer can apply to the paragraph at the cursor.
enum ScriptCommand: Equatable {
    case heading(Int)
    case body
    /// An aside for the editor rather than something to read aloud.
    case note
    /// A short label for the section it's in — Fountain's `= synopsis`.
    case synopsis
    /// Left, centered, or right — independent of the paragraph's kind.
    case alignment(ScriptAlignment)
}

/// Inline formatting the writer can apply to the current selection — a
/// different shape of command from `ScriptCommand`, which always acts on the
/// whole paragraph at the cursor.
enum InlineCommand: Equatable {
    case toggleBold
    case toggleItalic
    /// `nil` clears the highlight from the selection.
    case setHighlight(ScriptSwatch?)
    /// `nil` returns the selection to its paragraph's own color.
    case setTextColor(ScriptSwatch?)
}

/// What the cursor or selection is currently formatted as — what the
/// formatting toolbar's buttons show as pressed.
struct ScriptSelectionFormatting: Equatable {
    var bold = false
    var italic = false
    var alignment: ScriptAlignment = .leading
    var style: ScriptStyle.Paragraph = .body
    var highlight: ScriptSwatch?
    var textColor: ScriptSwatch?
}

/// What to do to the page range around the writing at the cursor.
enum SpanCommand: Equatable {
    /// Put this range on the selection, and on whatever is typed next.
    case start(PageSpan)
    /// Stop the range here: what's typed next belongs to no block.
    case end
    /// Take the range off the block at the cursor entirely.
    case remove
    /// Put this range on every paragraph `selection` touches — the current
    /// selection when nil — and nothing more: writing already there, linked
    /// after the fact, not a block that grows as the writer types on.
    case link(PageSpan, selection: NSRange?)
}

/// A beat's new color, from the rail's number-badge popover — `nil` resets
/// it to the default violet every beat draws with until it's given one.
struct BeatColorChange: Equatable {
    let beatID: String
    let color: ScriptSwatch?
}

import UniformTypeIdentifiers

extension UTType {
    /// The project package, as declared in Info.plist.
    static let komaDeskProject = UTType(exportedAs: "com.mida.komadesk.project", conformingTo: .package)
    /// `.panelsproject`, from before the app was Koma Desk.
    static let legacyProject = UTType(importedAs: "com.mida.panels.project", conformingTo: .package)
}
