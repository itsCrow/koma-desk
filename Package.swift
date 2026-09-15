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
        // The SwiftUI reader.
        .executableTarget(name: "Panels", dependencies: ["ComicArchive"]),
        .testTarget(name: "ComicArchiveTests", dependencies: ["ComicArchive"]),
    ]
)
