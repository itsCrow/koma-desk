import Foundation

/// A failure that prevented any pages from being read.
public enum ArchiveError: Error, LocalizedError, Equatable {
    /// libarchive could not identify the container at all. In practice this
    /// usually means the file is truncated to the point of having no header,
    /// or was never a comic archive.
    case unrecognizedFormat(filename: String, detail: String)
    /// The archive opened and parsed, but held no usable image files.
    case noPages(filename: String)
    /// The file could not be read from disk.
    case unreadableFile(filename: String, detail: String)
    /// The extraction cache could not be created.
    case cacheFailure(detail: String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat(let filename, _):
            return "“\(filename)” isn’t a readable comic archive."
        case .noPages(let filename):
            return "“\(filename)” doesn’t contain any images."
        case .unreadableFile(let filename, _):
            return "“\(filename)” couldn’t be read."
        case .cacheFailure:
            return "Panels couldn’t create its temporary working folder."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unrecognizedFormat(_, let detail):
            return "\(detail) The file is most likely an incomplete download."
        case .noPages:
            return "The archive opened, but every entry in it was skipped."
        case .unreadableFile(_, let detail):
            return detail
        case .cacheFailure(let detail):
            return detail
        }
    }
}

/// A non-fatal problem: some pages were recovered, but not all of them.
public struct ArchiveWarning: Sendable, Equatable {
    public let recoveredPages: Int
    public let detail: String

    public init(recoveredPages: Int, detail: String) {
        self.recoveredPages = recoveredPages
        self.detail = detail
    }

    public var message: String {
        "This file is damaged — only \(recoveredPages) page\(recoveredPages == 1 ? "" : "s") could be recovered."
    }
}
