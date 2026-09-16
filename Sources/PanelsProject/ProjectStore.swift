import Foundation

/// A project on disk: a folder holding the script, the manifest and the
/// captures. Finder shows it as one file.
public enum ProjectStore {
    public static let packageExtension = "panelsproject"

    public struct Loaded: Equatable, Sendable {
        public var manifest: ProjectManifest
        public var script: String

        public init(manifest: ProjectManifest, script: String) {
            self.manifest = manifest
            self.script = script
        }
    }

    public static func manifestURL(of project: URL) -> URL { project.appendingPathComponent("project.json") }
    public static func scriptURL(of project: URL) -> URL { project.appendingPathComponent("script.md") }
    public static func capturesFolder(of project: URL) -> URL { project.appendingPathComponent("captures", isDirectory: true) }

    /// Every project directly inside `root`, in no particular order.
    public static func list(in root: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            $0.pathExtension == packageExtension
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && FileManager.default.fileExists(atPath: manifestURL(of: $0).path)
        }
    }

    /// Just the manifest — enough to describe a project without its script.
    public static func loadManifest(_ url: URL) throws -> ProjectManifest {
        try decoder.decode(ProjectManifest.self, from: Data(contentsOf: manifestURL(of: url)))
    }

    /// A place for a new project called `name` inside `root` that isn't taken:
    /// "Name.panelsproject", then "Name 2.panelsproject", and so on. Characters
    /// a folder can't be called are dropped.
    public static func uniqueURL(named name: String, in root: URL) -> URL {
        let illegal = CharacterSet(charactersIn: "/:").union(.newlines).union(.controlCharacters)
        var stem = name.components(separatedBy: illegal).joined().trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "Untitled" }
        var candidate = root.appendingPathComponent(stem).appendingPathExtension(packageExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(stem) \(n)").appendingPathExtension(packageExtension)
            n += 1
        }
        return candidate
    }

    /// When the script was last written — the project's "edited" date.
    public static func lastEdited(_ url: URL) -> Date? {
        let script = (try? scriptURL(of: url).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let manifest = (try? manifestURL(of: url).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return [script, manifest].compactMap { $0 }.max()
    }

    /// Makes a new, empty project at `url` (which should end in `.panelsproject`).
    public static func create(at url: URL, name: String) throws -> Loaded {
        try FileManager.default.createDirectory(at: capturesFolder(of: url), withIntermediateDirectories: true)
        let loaded = Loaded(manifest: ProjectManifest(name: name), script: "")
        try save(loaded, to: url)
        return loaded
    }

    public static func load(_ url: URL) throws -> Loaded {
        let data = try Data(contentsOf: manifestURL(of: url))
        let manifest = try decoder.decode(ProjectManifest.self, from: data)
        let script = (try? String(contentsOf: scriptURL(of: url), encoding: .utf8)) ?? ""
        return Loaded(manifest: manifest, script: script)
    }

    public static func save(_ loaded: Loaded, to url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try encoder.encode(loaded.manifest).write(to: manifestURL(of: url), options: .atomic)
        try loaded.script.write(to: scriptURL(of: url), atomically: true, encoding: .utf8)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
