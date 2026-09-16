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
        let candidates = [
            URL(fileURLWithPath: ref.path),
            url.deletingLastPathComponent().appendingPathComponent(ref.filename),
            url.appendingPathComponent("comics").appendingPathComponent(ref.filename),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
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
