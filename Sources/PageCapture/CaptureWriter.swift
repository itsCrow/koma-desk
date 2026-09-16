import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes captures to the editor's folder: a PNG carrying its citation, and a
/// line in the manifest.
public struct CaptureWriter: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var manifestURL: URL { folder.appendingPathComponent("captures.json") }

    /// Writes `image` as PNG under a name built from the record, embedding the
    /// citation in the file, and appends the record (with the final filename)
    /// to the manifest. Returns the record as written.
    @discardableResult
    public func write(_ image: CGImage, record: CaptureRecord) throws -> CaptureRecord {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = availableURL(for: Self.filename(for: record))
        var written = record
        written.file = url.lastPathComponent

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let comment = (try? JSONEncoder.manifest.encode(written)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: written.citation,
                kCGImagePropertyPNGTitle: url.deletingPathExtension().lastPathComponent,
                kCGImagePropertyPNGComment: comment,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

        try append(written)
        return written
    }

    /// Whether the whole page for this citation has already been saved, so it
    /// is written once however many panels are taken from it.
    public func hasPage(for record: CaptureRecord) -> Bool {
        var page = record
        page.kind = .page
        page.panel = nil
        page.region = nil
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.filename(for: page)).path)
    }

    public func loadManifest() -> [CaptureRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder.manifest.decode([CaptureRecord].self, from: data)
        else { return [] }
        return records
    }

    private func append(_ record: CaptureRecord) throws {
        var records = loadManifest()
        records.append(record)
        try JSONEncoder.manifest.encode(records).write(to: manifestURL, options: .atomic)
    }

    // MARK: - Names

    /// "Berserk v01 p117 panel3.png", "Dragon Ball + Super ch052 p4 crop.png",
    /// "Berserk v01 p117 page.png".
    public static func filename(for record: CaptureRecord) -> String {
        var parts = [record.series]
        if let volume = record.volume { parts.append(String(format: "v%02d", volume)) }
        if let chapter = record.chapter { parts.append(String(format: "ch%03d", chapter)) }
        if let first = record.pages.first, let last = record.pages.last {
            parts.append(first == last ? "p\(first)" : "p\(first)-\(last)")
        }
        switch record.kind {
        case .panel: parts.append("panel\(record.panel ?? 0)")
        case .region: parts.append("crop")
        case .page: parts.append("page")
        }
        return sanitised(parts.joined(separator: " ")) + ".png"
    }

    private static func sanitised(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        return name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private func availableURL(for filename: String) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

private extension JSONEncoder {
    static var manifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var manifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
