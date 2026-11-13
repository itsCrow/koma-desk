import Foundation

/// A failure reading a comic from the web.
public enum RemoteSourceError: Error, LocalizedError, Equatable {
    /// No site adapter recognised the URL, and it isn't a manifest either.
    case unrecognizedURL(String)
    /// The manifest is a newer format than this build of Koma Desk reads.
    case unsupportedManifestVersion(found: Int, supported: Int)
    /// The manifest fetched, but isn't shaped the way Koma Desk expects.
    case malformedManifest(detail: String)
    /// A fetch came back with a non-2xx status.
    case http(status: Int, url: String)
    /// The chapter resolved, but named no pages at all.
    case noPages
    /// A named site adapter isn't registered — the source predates a
    /// site being supported, or supported it and no longer does.
    case unknownSite(String)
    /// A site adapter's parsing broke — most likely the site changed its
    /// markup. Kept distinct from a generic failure so this is diagnosable.
    case siteMarkupChanged(site: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedURL(let url):
            return "Koma Desk doesn’t know how to open “\(url)”."
        case .unsupportedManifestVersion(let found, let supported):
            return "This link needs a newer version of Koma Desk to open (format \(found), this build reads up to \(supported))."
        case .malformedManifest(let detail):
            return "That link’s manifest isn’t in a shape Koma Desk understands. \(detail)"
        case .http(let status, let url):
            return "“\(url)” returned an error (HTTP \(status))."
        case .noPages:
            return "That chapter doesn’t have any pages."
        case .unknownSite(let site):
            return "Koma Desk doesn’t have a reader for “\(site)” yet."
        case .siteMarkupChanged(let site, let detail):
            return "\(site)’s pages have changed shape — the \(site) reader in Koma Desk may need updating. \(detail)"
        }
    }
}
