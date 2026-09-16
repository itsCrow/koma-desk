import AppKit
import CryptoKit
import Foundation
import Observation
import ComicArchive
import ComicLibrary

/// The comics on this Mac, as the app understands them: folders being
/// watched, the series found in them, and how far each item has been read.
/// Nothing is copied; the folders are read where they are.
@Observable
@MainActor
final class Library {
    private(set) var index: LibraryIndex
    /// Where the index and the covers live.
    let folder: URL

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var coverTasks: [String: Task<NSImage?, Never>] = [:]

    /// `folder` other than the default keeps a test's library to itself.
    init(folder: URL = LibraryStore.defaultFolder) {
        self.folder = folder
        index = LibraryStore.load(from: folder)
        // Files come and go between launches.
        rescan()
    }

    var roots: [URL] { index.roots }
    var series: [Series] { index.series }
    var isEmpty: Bool { index.series.isEmpty }

    func series(named name: String) -> Series? { index.series(named: name) }
    func item(id: String) -> LibraryItem? { index.item(id: id) }
    func series(containing item: LibraryItem) -> Series? { index.series(containing: item) }

    // MARK: - Folders

    /// Watches a folder, or a single file, and reads what's in it.
    func addRoot(_ url: URL) {
        let standard = url.standardizedFileURL
        guard !index.roots.contains(where: { $0.standardizedFileURL == standard }) else {
            rescan()
            return
        }
        index.roots.append(standard)
        rescan()
    }

    func removeRoot(_ url: URL) {
        index.roots.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        rescan()
    }

    /// Reads every root again. Quick — it's a directory walk, not an
    /// extraction — so it runs whenever the app comes back to the front.
    func rescan() {
        let found = LibraryScanner.scan(roots: index.roots)
        if found != index.series {
            index.series = found
        }
        scheduleSave()
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add to Library"
        panel.message = "Choose a folder of comics — a series, or a folder of series — or a single comic file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ReaderModel.supportedContentTypes
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addRoot(url) }
    }

    // MARK: - Reading

    func position(for item: LibraryItem) -> Int {
        index.positions[item.id] ?? 0
    }

    func setPosition(_ spread: Int, for item: LibraryItem) {
        guard index.positions[item.id] != spread else { return }
        index.positions[item.id] = spread
        scheduleSave()
    }

    func noteRead(_ item: LibraryItem) {
        index.noteRead(item)
        scheduleSave()
    }

    /// The item to pick up in a series: the one last read there, or the first.
    func continueItem(in series: Series) -> LibraryItem? {
        index.continueItem(in: series)
    }

    /// Whether anything of this item has been read past its first spread.
    func hasStarted(_ item: LibraryItem) -> Bool {
        position(for: item) > 0
    }

    /// Series with something to pick up, most recently read first.
    var recentlyRead: [(series: Series, item: LibraryItem)] {
        index.recentSeries.compactMap { name in
            guard let series = index.series(named: name),
                  let id = index.lastRead[name], let item = series.item(id: id) else { return nil }
            return (series, item)
        }
    }

    // MARK: - Covers

    /// The first page of the item, small, from a cache that's filled the
    /// first time it's asked for — without extracting the whole file.
    func cover(for item: LibraryItem) async -> NSImage? {
        if let task = coverTasks[item.id] { return await task.value }
        let file = coverURL(for: item)
        let source = item.url
        let task = Task<NSImage?, Never> {
            if let image = NSImage(contentsOf: file) { return image }
            return await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = try? ComicArchive.firstPageData(of: source),
                      let full = NSImage(data: data) else { return nil }
                let small = Self.downscale(full, toHeight: 600)
                if let jpeg = Self.jpegData(small) {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: file, options: .atomic)
                }
                return small
            }.value
        }
        coverTasks[item.id] = task
        let image = await task.value
        if image == nil { coverTasks[item.id] = nil }
        return image
    }

    /// A series' cover is its first item's.
    func cover(for series: Series) async -> NSImage? {
        guard let first = series.items.first else { return nil }
        return await cover(for: first)
    }

    private func coverURL(for item: LibraryItem) -> URL {
        let digest = SHA256.hash(data: Data(item.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return LibraryStore.coversFolder(in: folder).appendingPathComponent("\(digest).jpg")
    }

    nonisolated private static func downscale(_ image: NSImage, toHeight height: CGFloat) -> NSImage {
        guard image.size.height > height, image.size.height > 0 else { return image }
        let scale = height / image.size.height
        let size = NSSize(width: (image.size.width * scale).rounded(), height: height)
        let small = NSImage(size: size)
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        small.unlockFocus()
        return small
    }

    nonisolated private static func jpegData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? LibraryStore.save(index, to: folder)
    }
}

extension LibraryItem {
    /// "Berserk · Vol. 1", "Dragon Ball · Ch. 24" — the item named with its series.
    var fullName: String { "\(series) · \(label)" }
}

// The app module's `Library` is a class; SwiftUI also has a `LibraryItem`, so the
// library's item type is named through the module.
typealias LibraryItem = ComicLibrary.LibraryItem
typealias Series = ComicLibrary.Series
