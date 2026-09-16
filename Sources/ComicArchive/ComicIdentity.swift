import Foundation

/// What a comic is, as far as its filename can say: the series and either the
/// volume or the chapter. Scan-group filenames are regular enough for this to
/// work almost always; where it doesn't, the name itself stands as the title.
public struct ComicIdentity: Equatable, Sendable {
    public var series: String
    public var volume: Int?
    public var chapter: Int?
    public var chapterTitle: String?
    public var year: Int?

    public init(series: String, volume: Int? = nil, chapter: Int? = nil,
                chapterTitle: String? = nil, year: Int? = nil) {
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.chapterTitle = chapterTitle
        self.year = year
    }

    /// Reads the identity off a comic's file name and, for a chapter file, the
    /// folder it sits in.
    ///
    ///     Berserk v01 (2003) (Digital) (danke-Empire).cbz   → Berserk, vol 1, 2003
    ///     Chapter 052 - Goku and Vegeta's Training.cbr       → chapter 52, series from the folder
    public init(fileURL: URL) {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        var name = stem

        // Bracketed tags are release notes, not identity — except a bare year.
        for match in Self.matches(#"[\(\[]([^\)\]]*)[\)\]]"#, in: stem) {
            let inner = match.1
            if year == nil, let y = Int(inner), (1900...2100).contains(y) { year = y }
            name = name.replacingOccurrences(of: match.0, with: " ")
        }
        name = Self.tidy(name)

        // "Chapter 052 - Title", "Ch. 12", "c012", "#12"
        if let m = Self.first(#"(?i)^(?:chapter|chap\.?|ch\.?|c|#)\s*0*(\d+)\s*(?:[-–—:]\s*(.+))?$"#, in: name) {
            chapter = Int(m.1)
            chapterTitle = m.2.map(Self.tidy).flatMap { $0.isEmpty ? nil : $0 }
            // A chapter file names no series of its own; the folder does.
            series = Self.seriesFromFolder(of: fileURL) ?? name
            return
        }

        // "Berserk v01", "Berserk Vol. 1", "Berserk Volume 01", "Berserk 01"
        if let m = Self.first(#"(?i)^(.+?)\s+(?:v|vol\.?|volume)\s*0*(\d+)\b.*$"#, in: name) {
            series = Self.tidy(m.1)
            volume = m.2.flatMap(Int.init)
            return
        }
        // "One Piece 105 - Title" or "One Piece c105": a number after the series.
        if let m = Self.first(#"(?i)^(.+?)\s+(?:c|ch\.?|chapter)\s*0*(\d+)\b\s*(?:[-–—:]\s*(.+))?$"#, in: name) {
            series = Self.tidy(m.1)
            chapter = m.2.flatMap(Int.init)
            chapterTitle = m.3.map(Self.tidy).flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        if let m = Self.first(#"^(.+?)\s+0*(\d{1,4})$"#, in: name) {
            series = Self.tidy(m.1)
            volume = m.2.flatMap(Int.init)
            return
        }

        series = name.isEmpty ? stem : name
    }

    // MARK: - Helpers

    /// The nearest folder that reads as a series name rather than an arc,
    /// volume range or other grouping.
    ///
    ///     …/Dragon Ball + Super [Complete Manga]/18 Galactic Patrol Prisoner Arc/Chapter 052.cbr
    ///     → "Dragon Ball + Super"
    private static func seriesFromFolder(of url: URL) -> String? {
        var directory = url.deletingLastPathComponent()
        for _ in 0..<3 {
            let raw = directory.lastPathComponent
            if raw.isEmpty || raw == "/" { return nil }
            var name = raw
            for match in matches(#"[\(\[][^\)\]]*[\)\]]"#, in: raw) {
                name = name.replacingOccurrences(of: match.0, with: " ")
            }
            name = tidy(name)
            let isGrouping = first(#"(?i)^\d+\s"#, in: name) != nil          // "18 Galactic Patrol…"
                || first(#"(?i)\barc$"#, in: name) != nil                  // "…Arc"
                || first(#"(?i)^(?:v|vol\.?|volumes?|ch\.?|chapters?)\b"#, in: name) != nil
                || ["downloads", "comics", "manga", "desktop", "documents"].contains(name.lowercased())
            if !name.isEmpty, !isGrouping { return name }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—_."))
    }

    private static func first(_ pattern: String, in s: String) -> (String, String, String?, String?)? {
        matches(pattern, in: s).first
    }

    private static func matches(_ pattern: String, in s: String) -> [(String, String, String?, String?)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            func group(_ i: Int) -> String? {
                guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return nil }
                return ns.substring(with: m.range(at: i))
            }
            return (group(0) ?? "", group(1) ?? "", group(2), group(3))
        }
    }
}

// MARK: - Citation

extension ComicIdentity {
    /// A compact citation of the given page(s): "Berserk, Vol. 1, p. 117",
    /// "Dragon Ball + Super, Ch. 52, pp. 4–5", or with a panel,
    /// "Berserk, Vol. 1, p. 117, panel 3".
    public func citation(pages: [Int], panel: Int? = nil) -> String {
        var parts = [series]
        if let volume { parts.append("Vol. \(volume)") }
        if let chapter { parts.append("Ch. \(chapter)") }
        let sorted = Array(Set(pages)).sorted()
        if let first = sorted.first, let last = sorted.last {
            parts.append(first == last ? "p. \(first)" : "pp. \(first)–\(last)")
        }
        if let panel { parts.append("panel \(panel)") }
        return parts.joined(separator: ", ")
    }
}
