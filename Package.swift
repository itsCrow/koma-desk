// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Panels",
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
        .target(name: "PanelsFormat"),
        // Reading the lettering off pages and searching it. No UI, so it can
        // be tested on its own.
        .target(name: "PageSearch", dependencies: ["PanelsFormat"]),
        // Finding panels on a page and saving them for an editor. No UI.
        .target(name: "PageCapture", dependencies: ["PanelsFormat"]),
        // A project: the script, its citations, and what they point at. No UI.
        .target(name: "PanelsProject", dependencies: ["PanelsFormat"]),
        // The library: folders of comics understood as series, volumes, arcs
        // and chapters. No UI.
        .target(name: "ComicLibrary", dependencies: ["ComicArchive"]),
        // The SwiftUI reader.
        .executableTarget(name: "Panels", dependencies: ["ComicArchive", "PageSearch", "PageCapture", "PanelsProject", "ComicLibrary", "PanelsFormat"]),
        .testTarget(name: "ComicArchiveTests", dependencies: ["ComicArchive"]),
        .testTarget(name: "PageSearchTests", dependencies: ["PageSearch", "ComicArchive", "PanelsFormat"]),
        .testTarget(name: "PageCaptureTests", dependencies: ["PageCapture", "ComicArchive", "PanelsFormat"]),
        .testTarget(name: "PanelsProjectTests", dependencies: ["PanelsProject", "PanelsFormat"]),
        .testTarget(name: "ComicLibraryTests", dependencies: ["ComicLibrary"]),
        // The reader's model driven the way the menus drive it.
        .testTarget(name: "PanelsTests", dependencies: ["Panels", "PanelsProject", "ComicLibrary", "ComicArchive", "PanelsFormat"]),
    ]
)
