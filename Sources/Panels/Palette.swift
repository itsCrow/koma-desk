import AppKit
import SwiftUI

/// The colours that carry meaning, decided together rather than one at a time.
///
/// Two of them point at the comic and are warm neighbours, so a citation
/// sitting inside a page range looks like it belongs there. The note is a
/// message to a person rather than a thing in the comic, so it's the cool
/// counterweight and sits back from both.
///
/// Deliberately *not* here: what's currently selected. That stays the system
/// accent, the way it does in every Mac app, and keeping it separate is what
/// stops "this is a citation" and "this is the current thing" sharing a colour
/// — which they did, and which broke outright if the accent was set to orange.
enum Palette {
    /// A shot: the inline chip, the shape ringed on a page after a jump, and
    /// the lasso you draw to make one.
    static let citation = NSColor(srgbRed: 0.890, green: 0.639, blue: 0.235, alpha: 1)   // #E3A33C
    /// A run of writing and the pages it's about.
    static let pageRange = NSColor(srgbRed: 0.824, green: 0.439, blue: 0.247, alpha: 1)  // #D2703F
    /// An aside for the editor — not narration.
    static let note = NSColor(srgbRed: 0.510, green: 0.588, blue: 0.678, alpha: 1)       // #8296AD
    /// A search hit on the page. Transient, and belongs to neither half of the
    /// palette, so it stays the highlighter yellow it always was — but one
    /// yellow, not the three slightly different ones it had grown.
    static let searchHit = NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)

    /// Legible on top of `citation` and `searchHit`, both of which are light.
    static let onLight = NSColor(calibratedWhite: 0.08, alpha: 1)

    static var citationColor: Color { Color(nsColor: citation) }
    static var pageRangeColor: Color { Color(nsColor: pageRange) }
    static var noteColor: Color { Color(nsColor: note) }
    static var searchHitColor: Color { Color(nsColor: searchHit) }
    static var onLightColor: Color { Color(nsColor: onLight) }
}
