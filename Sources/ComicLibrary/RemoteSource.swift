import Foundation

public enum RemoteSourceKind: String, Codable, Sendable {
    case manifest, site
}

/// A web source the user added — enough to re-check it for new chapters
/// later without asking them to paste the link again.
public struct RemoteSourceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public var url: URL
    public var kind: RemoteSourceKind
    /// Set when `kind == .site`, e.g. "weebcentral".
    public var siteID: String?
    public var seriesName: String
    public var addedDate: Date
    public var lastRefreshed: Date?

    public init(url: URL, kind: RemoteSourceKind, siteID: String?, seriesName: String,
                addedDate: Date, lastRefreshed: Date?) {
        self.url = url
        self.kind = kind
        self.siteID = siteID
        self.seriesName = seriesName
        self.addedDate = addedDate
        self.lastRefreshed = lastRefreshed
    }
}
