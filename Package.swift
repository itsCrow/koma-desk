// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KomaDesk",
    platforms: [.macOS(.v14)],
    targets: [
        // Declarations for the libarchive that ships with macOS. The SDK has the
        // stub library but not the headers, so we bring our own.
        .target(
            name: "CLibarchive",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        // Archive handling, free of any UI so it can be tested on its own.
        .target(name: "ComicArchive", dependencies: ["CLibarchive"]),
        // The shapes everything written to disk is made of: page geometry with
        // named keys, and names any filesystem will take. Depends on nothing,
        // so the on-disk formats are defined in one place.
        .target(name: "KomaFormat"),
        // Reading the lettering off pages and searching it. No UI, so it can
        // be tested on its own.
        .target(name: "PageSearch", dependencies: ["KomaFormat"]),
        // Finding panels on a page and saving them for an editor. No UI.
        .target(name: "PageCapture", dependencies: ["KomaFormat"]),
        // A project: the script, its citations, and what they point at. No UI.
        .target(name: "KomaProject", dependencies: ["KomaFormat"]),
        // The library: folders of comics understood as series, volumes, arcs
        // and chapters. No UI.
        .target(name: "ComicLibrary", dependencies: ["ComicArchive"]),
        // Reading a comic from the web: a known site, or a generic JSON
        // manifest. No UI, and no dependency on ComicArchive/ComicLibrary —
        // KomaDesk is the only place that glues them together.
        .target(name: "RemoteComicSource"),
        // The SwiftUI reader.
        .executableTarget(name: "KomaDesk", dependencies: ["ComicArchive", "PageSearch", "PageCapture", "KomaProject", "ComicLibrary", "KomaFormat", "RemoteComicSource"]),
        .testTarget(name: "ComicArchiveTests", dependencies: ["ComicArchive"]),
        .testTarget(name: "PageSearchTests", dependencies: ["PageSearch", "ComicArchive", "KomaFormat"]),
        .testTarget(name: "PageCaptureTests", dependencies: ["PageCapture", "ComicArchive", "KomaFormat"]),
        .testTarget(name: "KomaProjectTests", dependencies: ["KomaProject", "KomaFormat"]),
        .testTarget(name: "ComicLibraryTests", dependencies: ["ComicLibrary"]),
        .testTarget(name: "RemoteComicSourceTests", dependencies: ["RemoteComicSource"],
                    resources: [.copy("Fixtures")]),
        // The reader's model driven the way the menus drive it.
        .testTarget(name: "KomaDeskTests", dependencies: ["KomaDesk", "KomaProject", "ComicLibrary", "ComicArchive", "KomaFormat"]),
    ]
)
