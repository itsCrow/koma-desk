import Foundation

/// Reads the generic JSON manifest format — see `ChapterManifest`.
enum ManifestSource {
    static func resolveSeries(from manifestURL: URL) async throws -> ResolvedSeries {
        let manifest = try await fetch(manifestURL)
        let chapters = manifest.chapters.enumerated().map { index, chapter in
            ResolvedChapter(
                chapterURL: manifestURL,
                chapterKey: chapter.key(atIndex: index),
                number: chapter.number,
                volume: chapter.volume,
                title: chapter.title
            )
        }
        return ResolvedSeries(seriesName: manifest.title, cover: manifest.cover, chapters: chapters)
    }

    static func pageImageURLs(manifestURL: URL, chapterKey: String) async throws -> [URL] {
        let manifest = try await fetch(manifestURL)
        guard let match = manifest.chapters.enumerated().first(where: {
            $0.element.key(atIndex: $0.offset) == chapterKey
        }) else {
            throw RemoteSourceError.malformedManifest(detail: "Chapter “\(chapterKey)” is no longer in the manifest.")
        }
        guard !match.element.pages.isEmpty else { throw RemoteSourceError.noPages }
        return match.element.pages
    }

    /// Manifests are typically a few KB, so re-fetching on every call is
    /// cheap and avoids needing any staleness/invalidation logic.
    private static func fetch(_ url: URL) async throws -> ChapterManifest {
        let data = try await RemoteComicSource.fetcher.fetchData(url)
        let manifest: ChapterManifest
        do {
            manifest = try JSONDecoder().decode(ChapterManifest.self, from: data)
        } catch {
            throw RemoteSourceError.malformedManifest(detail: error.localizedDescription)
        }
        guard manifest.formatVersion == ChapterManifest.supportedFormatVersion else {
            throw RemoteSourceError.unsupportedManifestVersion(
                found: manifest.formatVersion, supported: ChapterManifest.supportedFormatVersion
            )
        }
        return manifest
    }
}
