import Foundation

/// Reads weebcentral.com directly from a series or chapter link — no
/// manifest needed. Verified against the live site's actual markup:
///
///   Series:      https://weebcentral.com/series/{ULID}/{slug}
///   Chapter list: GET https://weebcentral.com/series/{ULID}/full-chapter-list
///                 → an HTML fragment, one `<a href="/chapters/{ULID}">…
///                 <span class="">Chapter N</span>…` block per chapter,
///                 newest first.
///   Chapter:      https://weebcentral.com/chapters/{ULID}
///   Chapter pages: GET https://weebcentral.com/chapters/{ULID}/images
///                 → an HTML fragment of `<img src="…">` tags in reading
///                 order.
///
/// Weebcentral can change this shape without notice — a parse failure here
/// throws `.siteMarkupChanged` rather than a generic error, so it's
/// diagnosable rather than a mystery.
struct WeebCentralAdapter: SiteAdapter {
    let id = "weebcentral"

    func canHandle(_ url: URL) -> Bool {
        switch url.host?.lowercased() {
        case "weebcentral.com", "www.weebcentral.com": return true
        default: return false
        }
    }

    func resolveSeries(from url: URL) async throws -> ResolvedSeries {
        let seriesURL = try await resolvedSeriesURL(for: url)
        guard let seriesID = Self.seriesID(from: seriesURL) else {
            throw RemoteSourceError.siteMarkupChanged(
                site: "weebcentral", detail: "“\(seriesURL.absoluteString)” doesn’t look like a series link."
            )
        }

        let seriesHTML = try await fetchString(seriesURL)
        let title = Self.extractTitle(from: seriesHTML)
        let cover = Self.extractCover(from: seriesHTML)

        guard let listURL = URL(string: "https://weebcentral.com/series/\(seriesID)/full-chapter-list") else {
            throw RemoteSourceError.siteMarkupChanged(site: "weebcentral", detail: "Couldn’t build the chapter list link.")
        }
        let listHTML = try await fetchString(listURL)
        let chapters = Self.parseChapters(from: listHTML)
        guard !chapters.isEmpty else {
            throw RemoteSourceError.siteMarkupChanged(site: "weebcentral", detail: "No chapters were found on the series page.")
        }
        return ResolvedSeries(seriesName: title, cover: cover, chapters: chapters)
    }

    func pageImageURLs(chapterURL: URL) async throws -> [URL] {
        let html = try await fetchString(chapterURL.appendingPathComponent("images"))
        let urls = Self.parseImageURLs(from: html)
        guard !urls.isEmpty else {
            throw RemoteSourceError.siteMarkupChanged(site: "weebcentral", detail: "No page images were found for this chapter.")
        }
        return urls
    }

    // MARK: - Resolving whichever kind of link was pasted

    /// A chapter link names no series of its own — its page links back to
    /// one, so that's read first.
    private func resolvedSeriesURL(for url: URL) async throws -> URL {
        if Self.seriesID(from: url) != nil { return url }
        let html = try await fetchString(url)
        guard let match = Self.firstMatch(#"(/series/[0-9A-Za-z]{20,30}/[A-Za-z0-9-]+)"#, in: html) else {
            throw RemoteSourceError.siteMarkupChanged(site: "weebcentral", detail: "Couldn’t find this chapter’s series.")
        }
        guard let seriesURL = URL(string: "https://weebcentral.com\(match[0])") else {
            throw RemoteSourceError.siteMarkupChanged(site: "weebcentral", detail: "Couldn’t build the series link.")
        }
        return seriesURL
    }

    private static func seriesID(from url: URL) -> String? {
        let components = url.pathComponents
        guard components.count >= 3, components[1] == "series" else { return nil }
        return components[2]
    }

    // MARK: - Fetching

    private func fetchString(_ url: URL) async throws -> String {
        let data = try await RemoteComicSource.fetcher.fetchData(url)
        guard let html = String(data: data, encoding: .utf8) else {
            throw RemoteSourceError.siteMarkupChanged(site: "weebcentral", detail: "The page wasn’t readable text.")
        }
        return html
    }

    // MARK: - Parsing

    private static func extractTitle(from html: String) -> String {
        guard let match = firstMatch(#"<meta property="og:title" content="([^"]*)""#, in: html) else {
            return "Untitled"
        }
        let raw = match[0].replacingOccurrences(of: "&amp;", with: "&")
        if let range = raw.range(of: " | Weeb Central") { return String(raw[..<range.lowerBound]) }
        return raw
    }

    private static func extractCover(from html: String) -> URL? {
        firstMatch(#"<meta property="og:image" content="([^"]*)""#, in: html).flatMap { URL(string: $0[0]) }
    }

    /// Chapters come off the page newest first; reversed so reading order
    /// runs oldest to newest, matching a manifest's chapter order.
    private static func parseChapters(from html: String) -> [ResolvedChapter] {
        let pattern = #"<a href="(/chapters/[0-9A-Za-z]+)"[^>]*>[\s\S]*?<span class="">([^<]*)</span>"#
        let entries = allMatches(pattern, in: html).compactMap { groups -> ResolvedChapter? in
            guard let href = groups[0], let label = groups[1],
                  let chapterURL = URL(string: "https://weebcentral.com\(href)")
            else { return nil }
            let chapterKey = href.replacingOccurrences(of: "/chapters/", with: "")
            let (number, title) = parseChapterLabel(label.trimmingCharacters(in: .whitespacesAndNewlines))
            return ResolvedChapter(chapterURL: chapterURL, chapterKey: chapterKey, number: number, volume: nil, title: title)
        }
        return entries.reversed()
    }

    /// "Chapter 104" → (104, nil); "Chapter 12 - A Rival Appears!" → (12, "A Rival Appears!").
    private static func parseChapterLabel(_ label: String) -> (Double?, String?) {
        guard let match = firstMatch(#"(?i)^chapter\s+(\d+(?:\.\d+)?)\s*(?:[-–—:]\s*(.+))?$"#, in: label) else {
            return (nil, label.isEmpty ? nil : label)
        }
        let number = Double(match[0])
        let title = match.count > 1 ? match[1] : nil
        return (number, title)
    }

    private static func parseImageURLs(from html: String) -> [URL] {
        allMatches(#"<img[^>]*\ssrc="(https?://[^"]+)""#, in: html).compactMap { groups -> URL? in
            guard let src = groups[0], !src.contains("broken_image") else { return nil }
            return URL(string: src)
        }
    }

    // MARK: - Regex helpers

    /// The first match's capture groups, or nil if nothing matched.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        allMatches(pattern, in: text).first?.compactMap { $0 }
    }

    /// Every match's capture groups (group 1 onward; group 0, the whole
    /// match, is never included), in order. A group that didn't
    /// participate — an optional one that wasn't present — comes back nil.
    private static func allMatches(_ pattern: String, in text: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { result in
            (1..<result.numberOfRanges).map { i in
                let range = result.range(at: i)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
        }
    }
}
