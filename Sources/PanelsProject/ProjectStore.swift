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
