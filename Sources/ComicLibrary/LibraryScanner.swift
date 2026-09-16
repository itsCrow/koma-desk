import Foundation
import ComicArchive

/// Turns folders of comic files into series.
public enum LibraryScanner {
    /// Every comic under every root, grouped into series by what each file's
    /// name says it belongs to — not by how deep it sits. A Berserk volume in
    /// Downloads and a Dragon Ball chapter three folders down both know their
    /// series. A single file as a root is one item.
    public static func scan(roots: [URL]) -> [Series] {
        var seen = Set<String>()
        var itemsBySeries: [String: [LibraryItem]] = [:]
        var order: [String] = []

        for root in roots {
            let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let files: [Chapter] = isDirectory
                ? ComicFolder.scan(root)
                : (ComicFolder.comicExtensions.contains(root.pathExtension.lowercased())
                   ? [Chapter(url: root, title: root.deletingPathExtension().lastPathComponent, arc: nil)] : [])
            for file in files {
                let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let id = LibraryItem.makeID(filename: file.url.lastPathComponent, fileSize: size)
                guard seen.insert(id).inserted else { continue }   // the same file twice over
                let identity = ComicIdentity(fileURL: file.url)
                let item = LibraryItem(
                    url: file.url,
                    series: identity.series,
                    volume: identity.volume,
                    chapter: identity.chapter,
                    title: identity.chapterTitle ?? file.title,
                    arc: arc(of: file.url, series: identity.series, root: isDirectory ? root : nil),
                    fileSize: size
                )
                if itemsBySeries[item.series] == nil { order.append(item.series) }
                itemsBySeries[item.series, default: []].append(item)
            }
        }

        return order.map { name in
            Series(name: name, items: itemsBySeries[name]!.sorted(by: precedes))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The folder a file sits in counts as its arc unless that folder is the
    /// root, or reads as the series itself — "Berserk (Digital) (danke-Empire)"
    /// holding the volumes is Berserk's folder, not an arc of it.
    static func arc(of url: URL, series: String, root: URL?) -> String? {
        let parent = url.deletingLastPathComponent()
        if let root, parent.standardizedFileURL == root.standardizedFileURL { return nil }
        if root == nil { return nil }
        let folderReadsAs = ComicIdentity(fileURL: parent).series
        return folderReadsAs == series ? nil : parent.lastPathComponent
    }

    /// Volumes by number, then chapters by number, then whatever's left by name.
    static func precedes(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        switch (a.volume, b.volume) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        switch (a.chapter, b.chapter) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        return naturalPrecedes(a.url.path, b.url.path)
    }
}
