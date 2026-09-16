import Foundation

/// Turns a title into something every filesystem will accept as a name.
///
/// macOS is forgiving; Windows is not, and these files travel. A project
/// folder and a folder of exported shots both end up in Google Drive or a zip
/// and are opened on whatever machine the writer or the editor happens to use.
/// A name Windows refuses doesn't fail politely there — the copy or the unzip
/// stops with nothing useful said about which file caused it.
public enum PortableName {
    /// Characters Windows forbids outright, plus the control characters, which
    /// no filesystem should be asked to carry.
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        .union(.controlCharacters)
        .union(.newlines)

    /// Windows still refuses the names MS-DOS gave to devices — in any case,
    /// and whatever extension follows, so `AUX.png` is as doomed as `AUX`.
    private static let reservedDeviceNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 {
            names.insert("COM\(n)")
            names.insert("LPT\(n)")
        }
        return names
    }()

    /// A filesystem-safe version of `name`, or `fallback` if nothing is left.
    ///
    /// - Parameter replacement: what illegal characters become. Captures use
    ///   "-" so a stripped character stays visible in the name; project folders
    ///   use "" so "Ch: 1/2" reads as "Ch 12" rather than "Ch- 1-2".
    public static func sanitised(_ name: String,
                                 replacingIllegalWith replacement: String = "-",
                                 fallback: String = "Untitled") -> String {
        var cleaned = name.components(separatedBy: illegal).joined(separator: replacement)
            .trimmingCharacters(in: .whitespaces)

        // Windows drops trailing dots and spaces silently, which turns two
        // different names into one file.
        while let last = cleaned.last, last == "." || last == " " {
            cleaned.removeLast()
        }
        guard !cleaned.isEmpty else { return fallback }

        // Reserved-ness is decided by the part before the first dot.
        let stem = cleaned.prefix { $0 != "." }.uppercased()
        if reservedDeviceNames.contains(stem) {
            cleaned += "_"
        }
        return cleaned
    }
}
