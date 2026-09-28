import AppKit
import Foundation
import Observation
import PanelsProject

/// What the browser knows about a project without opening it.
struct ProjectSummary: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    /// "Berserk", "Dragon Ball + Super" — what the script is about.
    let series: String
    /// The volumes or chapters cited so far.
    let items: [String]
    let citationCount: Int
    let edited: Date?
    /// When the writer last opened it here — distinct from `edited`, which
    /// follows the file's own modification date and so also moves on an
    /// autosave the writer never asked for.
    let lastOpened: Date?
    /// A capture to stand for the project, if it has one.
    let picture: URL?
    /// Opened from outside the projects folder.
    let isElsewhere: Bool
    /// How long the script is meant to run, in words, if a goal was set.
    var targetWordCount: Int? = nil
    /// The beats marked off in Editor mode, and how many are done.
    var beatsDone = 0
    var beatsTotal = 0

    /// When it was last worked on: opened here, or failing that, saved.
    var recency: Date { lastOpened ?? edited ?? .distantPast }
}

/// What a project's script shows before it's opened: its first lines, for
/// a preview, and how many words of narration it holds — notes left out,
/// since a word target is about what gets read aloud.
struct ProjectPreview: Equatable, Sendable {
    let blocks: [ScriptBlock]
    let words: Int

    /// Read off the main thread: the script file is the one thing a summary
    /// doesn't already have in hand.
    static func load(_ url: URL) async -> ProjectPreview {
        await Task.detached(priority: .utility) {
            guard let raw = try? String(contentsOf: ProjectStore.scriptURL(of: url), encoding: .utf8)
            else { return ProjectPreview(blocks: [], words: 0) }
            let blocks = ScriptMarkdown.parse(raw)
            let text = ScriptMarkdown.plainText(blocks, notes: .omit)
            // More than any preview could ever show isn't worth keeping.
            return ProjectPreview(blocks: Array(blocks.prefix(80)),
                                  words: text.split { $0.isWhitespace || $0.isNewline }.count)
        }.value
    }
}

/// How projects are ordered within their series.
enum ProjectsSort: String, CaseIterable, Sendable {
    case recent, name, words

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .name: return "Name"
        case .words: return "Words"
        }
    }

    /// Ties fall back to the name, so the order never shuffles between
    /// refreshes. A project whose words haven't been counted yet goes last
    /// under Words rather than pretending to be empty.
    func sorted(_ projects: [ProjectSummary], words: [URL: Int]) -> [ProjectSummary] {
        func byName(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        switch self {
        case .recent:
            return projects.sorted { $0.recency != $1.recency ? $0.recency > $1.recency : byName($0, $1) }
        case .name:
            return projects.sorted(by: byName)
        case .words:
            return projects.sorted { a, b in
                switch (words[a.url], words[b.url]) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        }
    }
}

/// Every project the app knows about: the ones in the projects folder, and
/// any opened from elsewhere.
@Observable
@MainActor
final class ProjectLibrary {
    private static let rootKey = "PanelsProjectsRoot"
    private static let recentsKey = "PanelsProjectRecents"
    private static let lastOpenedKey = "PanelsProjectLastOpened"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var fixedRoot: URL?
    /// Keyed by standardized path, since a project can be renamed or moved
    /// without losing when it was last opened.
    @ObservationIgnored private var lastOpenedByPath: [String: Date]

    private(set) var summaries: [ProjectSummary] = []
    private(set) var recents: [URL] = []
    /// Each project's preview and word count, once read — shared by the
    /// hero, the cards, the rows and the Words sort, and kept until the
    /// project is saved again.
    private(set) var previews: [URL: ProjectPreview] = [:]
    @ObservationIgnored private var previewStamps: [URL: Date] = [:]

    /// `root` fixes the folder without touching preferences — for tests.
    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fixedRoot = root
        recents = (defaults.stringArray(forKey: Self.recentsKey) ?? []).map { URL(fileURLWithPath: $0) }
        lastOpenedByPath = (defaults.dictionary(forKey: Self.lastOpenedKey) as? [String: Date]) ?? [:]
        refresh()
    }

    /// The writer just opened this project — worth remembering separately
    /// from the file's own modification date.
    func noteLastOpened(_ url: URL) {
        lastOpenedByPath[url.standardizedFileURL.path] = Date()
        defaults.set(lastOpenedByPath, forKey: Self.lastOpenedKey)
        refresh()
    }

    /// Where projects live. ~/Documents/Panels Projects unless moved — point it
    /// at a shared folder and the editor sees every project.
    var root: URL {
        get {
            if let fixedRoot { return fixedRoot }
            if let path = defaults.string(forKey: Self.rootKey) { return URL(fileURLWithPath: path, isDirectory: true) }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            return documents.appendingPathComponent("Panels Projects", isDirectory: true)
        }
        set {
            if fixedRoot != nil { fixedRoot = newValue } else { defaults.set(newValue.path, forKey: Self.rootKey) }
            refresh()
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = "Projects Folder"
        panel.message = "Choose where your projects live. Share this folder and the editor sees them all."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
    }

    // MARK: - Reading the folder

    func refresh() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inRoot = ProjectStore.list(in: root)
        let rootPath = root.standardizedFileURL.path
        // Projects opened from elsewhere, as long as they still exist.
        let elsewhere = recents.filter {
            !$0.standardizedFileURL.path.hasPrefix(rootPath + "/")
                && FileManager.default.fileExists(atPath: ProjectStore.manifestURL(of: $0).path)
        }
        summaries = inRoot.compactMap { summary(of: $0, elsewhere: false) }
            + elsewhere.compactMap { summary(of: $0, elsewhere: true) }
    }

    private func summary(of url: URL, elsewhere: Bool) -> ProjectSummary? {
        guard let manifest = try? ProjectStore.loadManifest(url) else { return nil }
        let captures = ProjectStore.capturesFolder(of: url)
        let picture = manifest.citations.lazy
            .compactMap(\.captureFile)
            .map { captures.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return ProjectSummary(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            series: manifest.series,
            items: manifest.items.map(\.title),
            citationCount: manifest.citations.count,
            edited: ProjectStore.lastEdited(url),
            lastOpened: lastOpenedByPath[url.standardizedFileURL.path],
            picture: picture,
            isElsewhere: elsewhere,
            targetWordCount: manifest.targetWordCount,
            beatsDone: manifest.beats.filter(\.isDone).count,
            beatsTotal: manifest.beats.count
        )
    }

    /// Reads a project's preview unless the one on hand is still current —
    /// called from a view's `.task`, never from its body.
    func loadPreview(for summary: ProjectSummary) async {
        let stamp = summary.edited ?? .distantPast
        if previews[summary.url] != nil, previewStamps[summary.url] == stamp { return }
        let preview = await ProjectPreview.load(summary.url)
        previews[summary.url] = preview
        previewStamps[summary.url] = stamp
    }

    /// Word counts read so far, for sorting.
    var wordCounts: [URL: Int] { previews.mapValues(\.words) }

    /// Series in order of their most recently edited project; within a
    /// series, most recent first. Projects from outside the folder come last,
    /// under their own heading.
    var groupedBySeries: [(series: String, projects: [ProjectSummary])] {
        func newest(_ projects: [ProjectSummary]) -> Date { projects.compactMap(\.edited).max() ?? .distantPast }
        let local = summaries.filter { !$0.isElsewhere }
        var groups = Dictionary(grouping: local, by: \.series).map { series, projects in
            (series: series, projects: projects.sorted { ($0.edited ?? .distantPast) > ($1.edited ?? .distantPast) })
        }
        groups.sort { newest($0.projects) > newest($1.projects) }
        let elsewhere = summaries.filter(\.isElsewhere)
        if !elsewhere.isEmpty {
            groups.append((series: "Elsewhere", projects: elsewhere.sorted { ($0.edited ?? .distantPast) > ($1.edited ?? .distantPast) }))
        }
        return groups
    }

    func summary(for url: URL) -> ProjectSummary? {
        summaries.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: - Changing the folder

    /// A new, empty project about `series`.
    func create(named name: String, series: String, targetWordCount: Int? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = ProjectStore.uniqueURL(named: name, in: root)
        _ = try ProjectStore.create(at: url, name: url.deletingPathExtension().lastPathComponent, series: series,
                                     targetWordCount: targetWordCount)
        refresh()
        return url
    }

    /// The project's name is its folder's name, so renaming is a move.
    func rename(_ url: URL, to name: String) throws -> URL {
        let destination = ProjectStore.uniqueURL(named: name, in: url.deletingLastPathComponent())
        try FileManager.default.moveItem(at: url, to: destination)
        var loaded = try ProjectStore.load(destination)
        loaded.manifest.name = destination.deletingPathExtension().lastPathComponent
        try ProjectStore.save(loaded, to: destination)
        replaceRecent(url, with: destination)
        refresh()
        return destination
    }

    func duplicate(_ url: URL) throws -> URL {
        let name = url.deletingPathExtension().lastPathComponent + " copy"
        let destination = ProjectStore.uniqueURL(named: name, in: url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: url, to: destination)
        var loaded = try ProjectStore.load(destination)
        loaded.manifest.name = destination.deletingPathExtension().lastPathComponent
        try ProjectStore.save(loaded, to: destination)
        refresh()
        return destination
    }

    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        replaceRecent(url, with: nil)
        refresh()
    }

    /// A project opened from wherever it is: remembered if it's not in the folder.
    func noteOpened(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        replaceRecent(url, with: url)
    }

    private func replaceRecent(_ old: URL, with new: URL?) {
        recents.removeAll { $0.standardizedFileURL == old.standardizedFileURL }
        if let new { recents.insert(new, at: 0) }
        recents = Array(recents.prefix(20))
        defaults.set(recents.map(\.path), forKey: Self.recentsKey)
        refresh()
    }
}
