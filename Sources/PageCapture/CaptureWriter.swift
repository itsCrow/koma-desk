import Foundation
import ImageIO
import UniformTypeIdentifiers
import PanelsFormat

/// Writes captures to the editor's folder: a PNG carrying its citation, and a
/// line in the manifest.
/// What came of a write: the record as stored, and whether it was already
/// there.
public struct WriteResult: Sendable {
    public let record: CaptureRecord
    /// True when an identical capture existed and was reused, nothing written.
    public let reused: Bool
}

public struct CaptureWriter: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var manifestURL: URL { folder.appendingPathComponent("captures.json") }

    /// Writes `image` as PNG under a name built from the record, embedding the
    /// citation in the file, and appends the record to the manifest.
    ///
    /// The same picture is never written twice: if an identical capture is
    /// already in the manifest and its file is still on disk, that one is
    /// handed back untouched.
    @discardableResult
    public func write(_ image: CGImage, record: CaptureRecord) throws -> WriteResult {
        if let existing = existingCapture(matching: record) {
            return WriteResult(record: existing, reused: true)
        }
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
        return WriteResult(record: written, reused: false)
    }

    /// An identical capture already on disk, if there is one. The file has to
    /// still exist: a cleanup can leave the manifest naming things that are
    /// gone, and handing one of those back would point at nothing.
    public func existingCapture(matching record: CaptureRecord) -> CaptureRecord? {
        loadManifest().first {
            $0.isSameShot(as: record)
                && !$0.file.isEmpty
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path)
        }
    }

    /// Drops records whose file is no longer there, so the manifest describes
    /// what the folder actually holds.
    @discardableResult
    public func pruneMissingRecords() -> Int {
        let records = loadManifest()
        let kept = records.filter {
            !$0.file.isEmpty && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path)
        }
        guard kept.count != records.count else { return 0 }
        try? JSONEncoder.manifest.encode(kept).write(to: manifestURL, options: .atomic)
        return records.count - kept.count
    }

    /// Whether the whole page for this citation has already been saved, so it
    /// is written once however many panels are taken from it.
    public func hasPage(for record: CaptureRecord) -> Bool {
        var page = record
        page.kind = .page
        page.panel = nil
        page.region = nil
        page.polygon = nil
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
    /// "Berserk v01 p117 shape.png", "Berserk v01 p117 page.png".
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
        case .shape: parts.append("shape")
        case .page: parts.append("page")
        }
        // These land in the editor's Downloads folder, which is as likely to be
        // Windows as not.
        return PortableName.sanitised(parts.joined(separator: " "), fallback: "Capture") + ".png"
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
