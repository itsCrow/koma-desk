import Foundation
import CoreGraphics

/// A comic the project cites. Referenced, not copied: the path is where it
/// was last seen, and the name and size are how it's found again if it moves.
public struct ComicRef: Codable, Equatable, Sendable, Identifiable {
    /// Stable for the life of the project, whatever happens to the file.
    public var id: String
    public var title: String
    public var path: String
    public var filename: String
    public var fileSize: Int
    /// The series the comic belongs to — "Berserk", "Dragon Ball + Super" —
    /// recorded when it joins a project so projects can be grouped without
    /// re-reading filenames. Older manifests don't have it.
    public var series: String?

    public init(id: String = ProjectManifest.makeID(), title: String, path: String, filename: String,
                fileSize: Int, series: String? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.filename = filename
        self.fileSize = fileSize
        self.series = series
    }
}

/// A moment in a comic that the script points at. In the script it's a link,
/// `panels://cite/<id>`; here is everything the link means.
public struct Citation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var comicID: String
    /// Zero-based index of the (first) page.
    public var pageIndex: Int
    /// One-based page numbers as cited, ascending.
    public var pageNumbers: [Int]
    public var panel: Int?
    /// A drawn shape, unit coords, top-left origin.
    public var polygon: [CGPoint]?
    /// A dragged rectangle, unit coords, top-left origin.
    public var region: CGRect?
    /// The saved image, relative to the project's captures folder.
    public var captureFile: String?
    /// How the citation reads: "Berserk, Vol. 1, p. 117, panel 3".
    public var text: String
    public var date: Date

    public init(id: String = ProjectManifest.makeID(), comicID: String, pageIndex: Int, pageNumbers: [Int],
                panel: Int? = nil, polygon: [CGPoint]? = nil, region: CGRect? = nil,
                captureFile: String? = nil, text: String, date: Date = Date()) {
        self.id = id
        self.comicID = comicID
        self.pageIndex = pageIndex
        self.pageNumbers = pageNumbers
        self.panel = panel
        self.polygon = polygon
        self.region = region
        self.captureFile = captureFile
        self.text = text
        self.date = date
    }
}

/// Everything about a project except the script itself.
public struct ProjectManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var comics: [ComicRef]
    public var citations: [Citation]
    /// Reading position (spread index) per comic id.
    public var positions: [String: Int]
    /// The comic that was open last, to reopen with the project.
    public var lastComicID: String?

    public init(name: String, comics: [ComicRef] = [], citations: [Citation] = [],
                positions: [String: Int] = [:], lastComicID: String? = nil) {
        self.version = 1
        self.name = name
        self.comics = comics
        self.citations = citations
        self.positions = positions
        self.lastComicID = lastComicID
    }

    public func citation(id: String) -> Citation? {
        citations.first { $0.id == id }
    }

    public func comic(id: String) -> ComicRef? {
        comics.first { $0.id == id }
    }

    /// The comic for a file, matching the path first and then the name and
    /// size — the same file moved.
    public func comic(for url: URL) -> ComicRef? {
        let path = url.standardizedFileURL.path
        if let byPath = comics.first(where: { $0.path == path }) { return byPath }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        return comics.first { $0.filename == url.lastPathComponent && $0.fileSize == size }
    }

    /// Short, unambiguous, safe in a URL: six characters of base-36.
    public static func makeID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
