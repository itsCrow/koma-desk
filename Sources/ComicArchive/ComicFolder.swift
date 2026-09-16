import Foundation

/// One comic file inside a series folder.
public struct Chapter: Equatable, Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    /// The file's name without its extension.
    public let title: String
    /// The folder between the series and the file — an arc, a volume — or nil
    /// when the file sits directly in the series folder.
    public let arc: String?

    public init(url: URL, title: String, arc: String?) {
        self.url = url
        self.title = title
        self.arc = arc
    }
}

/// A folder of comics read as one series: chapters in reading order, grouped
/// by the folders they sit in.
public enum ComicFolder {
    public static let comicExtensions: Set<String> = ["cbr", "cbz", "cb7"]

    /// Every comic under `root`, up to three folders deep, in natural order of
    /// path — so "02 Turtle School" comes before "04 Red Ribbon", and
    /// "Chapter 024" before "Chapter 031" whatever the zero-padding. Sidecars
    /// such as `.cbr.jpg` and `.cbr.json` are not comics and are skipped.
    public static func scan(_ root: URL) -> [Chapter] {
        let manager = FileManager.default
        var found: [(relative: String, chapter: Chapter)] = []

        func walk(_ folder: URL, depth: Int) {
            guard depth <= 3,
                  let entries = try? manager.contentsOfDirectory(
                      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory {
                    walk(entry, depth: depth + 1)
                } else if comicExtensions.contains(entry.pathExtension.lowercased()) {
                    let parent = entry.deletingLastPathComponent()
                    let arc = parent.standardizedFileURL == root.standardizedFileURL ? nil : parent.lastPathComponent
                    let relative = entry.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)
                    found.append((String(relative), Chapter(url: entry, title: entry.deletingPathExtension().lastPathComponent, arc: arc)))
                }
            }
        }
        walk(root, depth: 0)
        return found.sorted { naturalPrecedes($0.relative, $1.relative) }.map(\.chapter)
    }

    /// Arcs in reading order, each with its chapters; a nil arc for chapters
    /// sitting directly in the series folder.
    public static func grouped(_ chapters: [Chapter]) -> [(arc: String?, chapters: [Chapter])] {
        var groups: [(arc: String?, chapters: [Chapter])] = []
        for chapter in chapters {
            if let last = groups.indices.last, groups[last].arc == chapter.arc {
                groups[last].chapters.append(chapter)
            } else {
                groups.append((chapter.arc, [chapter]))
            }
        }
        return groups
    }
}
