import Foundation
import CryptoKit
import CLibarchive

/// An opened comic archive: an ordered list of page images sitting on disk.
///
/// `.cbr` / `.cbz` / `.cb7` are just RAR / ZIP / 7-Zip archives full of images.
/// libarchive reads RAR forward-only, so seeking backwards to re-read an earlier
/// page is slow and awkward. Rather than fight that, we extract everything once
/// into a temp cache on open and then treat pages as ordinary files — page turns
/// become instant and the streaming complexity disappears.
public struct ComicArchive: Sendable {
    /// The archive the pages came from.
    public let source: URL
    /// Stable for this file at this size and modification date. Keys the
    /// extraction cache, and anything else worth keeping per comic.
    public let identity: String
    /// Page images in reading order, already extracted to disk.
    public let pages: [URL]
    /// Set when the archive was damaged but some pages were still recoverable.
    public let warning: ArchiveWarning?

    public var pageCount: Int { pages.count }

    public var title: String {
        source.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Opening

extension ComicArchive {
    /// File extensions we treat as comic pages.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "avif", "heic",
    ]

    /// Directory and file names that appear inside comic archives but aren't pages.
    static let junkNames: Set<String> = ["__macosx", "thumbs.db", "desktop.ini"]

    public static var cacheRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KomaDesk", isDirectory: true)
    }

    /// Opens `url`, extracting its pages (or reusing a previous extraction).
    public static func open(_ url: URL) throws -> ComicArchive {
        let identity = try cacheKey(for: url)
        let directory = cacheRoot.appendingPathComponent(identity, isDirectory: true)

        if let cached = loadManifest(in: directory, source: url, identity: identity) {
            return cached
        }

        // A stale or half-written extraction is worse than none.
        try? FileManager.default.removeItem(at: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.cacheFailure(detail: error.localizedDescription)
        }

        let extraction = try extract(url, into: directory)

        guard !extraction.pages.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            throw ArchiveError.noPages(filename: url.lastPathComponent)
        }

        let ordered = sortedNaturally(extraction.pages)
        let warning = extraction.failureDetail.map {
            ArchiveWarning(recoveredPages: ordered.count, detail: $0)
        }
        saveManifest(Manifest(pages: ordered, warning: warning.map {
            Manifest.Warning(recoveredPages: $0.recoveredPages, detail: $0.detail)
        }), in: directory)

        return ComicArchive(
            source: url,
            identity: identity,
            pages: ordered.map { directory.appendingPathComponent($0) },
            warning: warning
        )
    }

    /// Identifies a cached extraction. Includes size and modification date so a
    /// re-downloaded file with the same path doesn't serve stale pages.
    private static func cacheKey(for url: URL) throws -> String {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            throw ArchiveError.unreadableFile(
                filename: url.lastPathComponent,
                detail: error.localizedDescription
            )
        }
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let seed = "\(url.standardizedFileURL.path)|\(size)|\(modified)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Extraction

extension ComicArchive {
    private struct Extraction {
        var pages: [String] = []
        /// Non-nil when extraction stopped early. Pages collected before the
        /// failure are still usable.
        var failureDetail: String?
    }

    // libarchive return codes.
    private static let ok: Int32 = 0
    private static let eof: Int32 = 1
    private static let warn: Int32 = -20
    private static let regularFileBit: mode_t = 0o100000

    private static func extract(_ url: URL, into directory: URL) throws -> Extraction {
        guard let handle = archive_read_new() else {
            throw ArchiveError.cacheFailure(detail: "libarchive could not allocate a reader.")
        }
        defer { archive_read_free(handle) }

        archive_read_support_filter_all(handle)
        // Registered explicitly rather than via support_format_all, so anything
        // unexpected fails loudly instead of being half-handled.
        archive_read_support_format_rar(handle)
        archive_read_support_format_rar5(handle)
        archive_read_support_format_zip(handle)
        archive_read_support_format_7zip(handle)

        let opened = url.path.withCString { archive_read_open_filename(handle, $0, 65536) }
        guard opened == ok else {
            throw ArchiveError.unrecognizedFormat(
                filename: url.lastPathComponent,
                detail: errorMessage(handle)
            )
        }

        var result = Extraction()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)

        while true {
            var entry: OpaquePointer?
            let status = archive_read_next_header(handle, &entry)

            if status == eof { break }
            if status < ok {
                if status >= warn, entry != nil {
                    // Recoverable; the entry is still usable.
                } else {
                    result.failureDetail = errorMessage(handle)
                    break
                }
            }
            guard let entry else { break }
            guard archive_entry_filetype(entry) & regularFileBit != 0 else { continue }
            guard let raw = entryPath(entry), let relative = sanitize(raw) else { continue }

            let destination = directory.appendingPathComponent(relative)
            do {
                // An entry that holds no bytes is a stray placeholder, not
                // damage — skip it and keep reading the rest of the comic.
                guard try writeEntry(handle, to: destination, buffer: &buffer) else { continue }
            } catch let failure as EntryFailure {
                // Partial page — drop it and stop; everything before it stands.
                try? FileManager.default.removeItem(at: destination)
                result.failureDetail = failure.detail
                break
            }
            result.pages.append(relative)
        }

        return result
    }

    private struct EntryFailure: Error { let detail: String }

    /// Extracts one entry to disk. Returns false when the entry held no data,
    /// which the caller skips; throws only when the archive itself went wrong.
    private static func writeEntry(
        _ handle: OpaquePointer,
        to destination: URL,
        buffer: inout [UInt8]
    ) throws -> Bool {
        var contents = Data()
        while true {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                archive_read_data(handle, raw.baseAddress, raw.count)
            }
            if read == 0 { break }
            if read < 0 { throw EntryFailure(detail: errorMessage(handle)) }
            contents.append(contentsOf: buffer[0..<read])
        }
        guard !contents.isEmpty else { return false }

        let parent = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try contents.write(to: destination, options: .atomic)
        } catch {
            throw EntryFailure(detail: error.localizedDescription)
        }
        return true
    }

    private static func entryPath(_ entry: OpaquePointer) -> String? {
        // Archives from Windows tools often carry non-ASCII names; prefer the
        // UTF-8 accessor and fall back only if libarchive has nothing for it.
        if let utf8 = archive_entry_pathname_utf8(entry) {
            return String(cString: utf8)
        }
        if let raw = archive_entry_pathname(entry) {
            return String(cString: raw)
        }
        return nil
    }

    private static func errorMessage(_ handle: OpaquePointer) -> String {
        if let message = archive_error_string(handle) {
            let text = String(cString: message)
            if !text.isEmpty { return text.hasSuffix(".") ? text : text + "." }
        }
        return "libarchive reported an unspecified error."
    }

    /// Validates an archive entry path and returns it as a safe relative path,
    /// or nil if the entry should be skipped.
    static func sanitize(_ raw: String) -> String? {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { return nil }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let filename = components.last else { return nil }

        for component in components {
            // `..` would let a crafted archive write outside the cache directory.
            guard component != ".." && component != "." else { return nil }
            // Catches .DS_Store and AppleDouble `._page01.jpg` sidecars.
            guard !component.hasPrefix(".") else { return nil }
            guard !junkNames.contains(component.lowercased()) else { return nil }
        }

        let ext = (filename as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return nil }

        return components.joined(separator: "/")
    }
}

// MARK: - Covers

extension ComicArchive {
    /// The bytes of the first page image, read straight out of the archive
    /// without extracting the rest — for a cover. Uses the extraction cache
    /// when the comic has already been opened.
    public static func firstPageData(of url: URL) throws -> Data {
        if let cached = try? open(url), let first = cached.pages.first,
           let data = try? Data(contentsOf: first), !data.isEmpty {
            return data
        }
        guard let handle = archive_read_new() else {
            throw ArchiveError.cacheFailure(detail: "libarchive could not allocate a reader.")
        }
        defer { archive_read_free(handle) }
        archive_read_support_filter_all(handle)
        archive_read_support_format_rar(handle)
        archive_read_support_format_rar5(handle)
        archive_read_support_format_zip(handle)
        archive_read_support_format_7zip(handle)
        guard url.path.withCString({ archive_read_open_filename(handle, $0, 65536) }) == ok else {
            throw ArchiveError.unrecognizedFormat(filename: url.lastPathComponent, detail: errorMessage(handle))
        }
        // Entries are in the order the archive holds them, which for a comic
        // is page order — but the first *image* is what we want, and its name
        // has to pass the same filter pages do.
        var candidates: [(String, Data)] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            var entry: OpaquePointer?
            let status = archive_read_next_header(handle, &entry)
            if status == eof || status < warn { break }
            guard let entry, archive_entry_filetype(entry) & regularFileBit != 0,
                  let raw = entryPath(entry), let relative = sanitize(raw) else { continue }
            var contents = Data()
            while true {
                let read = buffer.withUnsafeMutableBytes { archive_read_data(handle, $0.baseAddress, $0.count) }
                if read <= 0 { break }
                contents.append(contentsOf: buffer[0..<read])
            }
            if !contents.isEmpty { candidates.append((relative, contents)) }
            // A handful is enough to pick the first page from a stored-order archive.
            if candidates.count >= 4 { break }
        }
        guard let first = sortedNaturally(candidates.map(\.0)).first,
              let data = candidates.first(where: { $0.0 == first })?.1
        else { throw ArchiveError.noPages(filename: url.lastPathComponent) }
        return data
    }
}

// MARK: - Extraction manifest

extension ComicArchive {
    private struct Manifest: Codable {
        struct Warning: Codable {
            let recoveredPages: Int
            let detail: String
        }
        let pages: [String]
        let warning: Warning?
    }

    private static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private static func loadManifest(in directory: URL, source: URL, identity: String) -> ComicArchive? {
        guard let data = try? Data(contentsOf: manifestURL(in: directory)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.pages.isEmpty
        else { return nil }

        let pages = manifest.pages.map { directory.appendingPathComponent($0) }
        // A cache the user (or the OS) partially cleaned out is not a cache.
        guard pages.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        // Counts as a read, so pruning measures least-recently-*used* rather
        // than least-recently-extracted.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: directory.path
        )
        return ComicArchive(
            source: source,
            identity: identity,
            pages: pages,
            warning: manifest.warning.map {
                ArchiveWarning(recoveredPages: $0.recoveredPages, detail: $0.detail)
            }
        )
    }

    private static func saveManifest(_ manifest: Manifest, in directory: URL) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(in: directory), options: .atomic)
    }
}
