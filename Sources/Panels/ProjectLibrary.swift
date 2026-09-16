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
    /// A capture to stand for the project, if it has one.
    let picture: URL?
    /// Opened from outside the projects folder.
    let isElsewhere: Bool
}

/// Every project the app knows about: the ones in the projects folder, and
/// any opened from elsewhere.
@Observable
@MainActor
final class ProjectLibrary {
    private static let rootKey = "PanelsProjectsRoot"
    private static let recentsKey = "PanelsProjectRecents"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var fixedRoot: URL?

    private(set) var summaries: [ProjectSummary] = []
    private(set) var recents: [URL] = []

    /// `root` fixes the folder without touching preferences — for tests.
    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fixedRoot = root
        recents = (defaults.stringArray(forKey: Self.recentsKey) ?? []).map { URL(fileURLWithPath: $0) }
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
        summaries = inRoot.compactMap { Self.summary(of: $0, elsewhere: false) }
            + elsewhere.compactMap { Self.summary(of: $0, elsewhere: true) }
    }

    nonisolated static func summary(of url: URL, elsewhere: Bool) -> ProjectSummary? {
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
            picture: picture,
            isElsewhere: elsewhere
        )
    }

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
    func create(named name: String, series: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = ProjectStore.uniqueURL(named: name, in: root)
        _ = try ProjectStore.create(at: url, name: url.deletingPathExtension().lastPathComponent, series: series)
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
