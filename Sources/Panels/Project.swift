import AppKit
import Foundation
import Observation
import PanelsProject

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

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var name: String { manifest.name }
    var capturesFolder: URL { ProjectStore.capturesFolder(of: url) }

    init(url: URL, loaded: ProjectStore.Loaded) {
        self.url = url
        self.manifest = loaded.manifest
        self.script = loaded.script
    }

    static func create(at url: URL) throws -> Project {
        let name = url.deletingPathExtension().lastPathComponent
        return Project(url: url, loaded: try ProjectStore.create(at: url, name: name))
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

    // MARK: - Comics and citations

    /// The project's reference for a comic file, added if it's new.
    @discardableResult
    func comicRef(for fileURL: URL, title: String) -> ComicRef {
        let path = fileURL.standardizedFileURL.path
        if var known = manifest.comic(for: fileURL) {
            if known.path != path, let index = manifest.comics.firstIndex(where: { $0.id == known.id }) {
                known.path = path
                manifest.comics[index] = known
            }
            return known
        }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let ref = ComicRef(title: title, path: path, filename: fileURL.lastPathComponent, fileSize: size)
        manifest.comics.append(ref)
        return ref
    }

    func add(_ citation: Citation) {
        manifest.citations.append(citation)
    }

    func citation(id: String) -> Citation? {
        manifest.citation(id: id)
    }

    /// Where a referenced comic is now: its recorded path, or beside the
    /// project, or in a `comics` folder inside it.
    func locate(_ ref: ComicRef) -> URL? {
        let beside = url.deletingLastPathComponent()
        let candidates = [
            URL(fileURLWithPath: ref.path),
            beside.appendingPathComponent(ref.filename),
            url.appendingPathComponent("comics").appendingPathComponent(ref.filename),
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found
        }
        // One level down from the project's own folder, which covers a shared
        // folder holding the project and a folder of comics beside it.
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: beside, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles])
        else { return nil }
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let candidate = entry.appendingPathComponent(ref.filename)
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Comics this project references that aren't on this Mac.
    var missingComics: [ComicRef] {
        manifest.comics.filter { locate($0) == nil }
    }

    /// The citations in the order they appear in the script — the order the
    /// video runs, which is not the order they were made in.
    var citationsInScriptOrder: [Citation] {
        let byID = Dictionary(manifest.citations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScriptMarkdown.citationIDs(in: script).compactMap { byID[$0] }
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
        return (trashed, bytes)
    }

    /// The sentence a citation sits in.
    func context(of id: String) -> String? {
        ScriptMarkdown.context(of: id, in: script)
    }

    func captureURL(for citation: Citation) -> URL? {
        citation.captureFile.map { capturesFolder.appendingPathComponent($0) }
    }

    /// The script with chips as plain text, for pasting somewhere else.
    var plainTextScript: String {
        ScriptMarkdown.plainText(ScriptMarkdown.parse(script))
    }
}

/// Formatting the writer can apply to the paragraph at the cursor.
enum ScriptCommand: Equatable {
    case heading(Int)
    case body
}

import UniformTypeIdentifiers

extension UTType {
    /// The project package, as declared in Info.plist.
    static let panelsProject = UTType(exportedAs: "com.mida.panels.project", conformingTo: .package)
}
