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
        // Reading the lettering off pages and searching it. No UI, so it can
        // be tested on its own.
        .target(name: "PageSearch"),
        // Finding panels on a page and saving them for an editor. No UI.
        .target(name: "PageCapture"),
        // A project: the script, its citations, and what they point at. No UI.
        .target(name: "PanelsProject"),
        // The SwiftUI reader.
        .executableTarget(name: "Panels", dependencies: ["ComicArchive", "PageSearch", "PageCapture", "PanelsProject"]),
        .testTarget(name: "ComicArchiveTests", dependencies: ["ComicArchive"]),
        .testTarget(name: "PageSearchTests", dependencies: ["PageSearch", "ComicArchive"]),
        .testTarget(name: "PageCaptureTests", dependencies: ["PageCapture", "ComicArchive"]),
        .testTarget(name: "PanelsProjectTests", dependencies: ["PanelsProject"]),
        // The reader's model driven the way the menus drive it.
        .testTarget(name: "PanelsTests", dependencies: ["Panels", "PanelsProject"]),
    ]
)
