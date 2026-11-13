import AppKit
import SwiftUI
import PanelsProject

/// The colours that carry meaning, decided together rather than one at a time.
///
/// Four named colours, not a theory: vermillion for a page-range, gold for a
/// cited shot, azure for an editor note, violet for a beat. Saturated enough
/// to sit on manga art and on the dark script without muting into each other.
///
/// Deliberately *not* here: what's currently selected. That stays the system
/// accent, the way it does in every Mac app, and keeping it separate is what
/// stops "this is a citation" and "this is the current thing" sharing a colour
/// — which they did, and which broke outright if the accent was set to orange.
enum Palette {
    /// A shot: the inline chip, the shape ringed on a page after a jump, and
    /// the lasso you draw to make one.
    static let citation = NSColor(srgbRed: 1.000, green: 0.706, blue: 0.000, alpha: 1)   // #FFB400 gold
    /// A run of writing and the pages it's about.
    static let pageRange = NSColor(srgbRed: 0.965, green: 0.318, blue: 0.114, alpha: 1)  // #F6511D vermillion
    /// An aside for the editor — not narration.
    static let note = NSColor(srgbRed: 0.000, green: 0.651, blue: 0.929, alpha: 1)       // #00A6ED azure
    /// A section the writer has marked off in Editor mode — a block, the
    /// same shape as a page range's, but its own colour: a beat and a range
    /// often cover the same writing at once, and need to read as two things.
    static let beat = NSColor(srgbRed: 0.545, green: 0.361, blue: 0.965, alpha: 1)       // #8B5CF6 violet
    /// A search hit on the page. Transient, and belongs to neither half of the
    /// palette, so it stays the highlighter yellow it always was — but one
    /// yellow, not the three slightly different ones it had grown.
    static let searchHit = NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)

    /// Legible on any of the above — all of them are bright enough now that a
    /// dark mark reads best on every one.
    static let onLight = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let onCitation = onLight

    static var citationColor: Color { Color(nsColor: citation) }
    static var pageRangeColor: Color { Color(nsColor: pageRange) }
    static var noteColor: Color { Color(nsColor: note) }
    static var beatColor: Color { Color(nsColor: beat) }
    static var searchHitColor: Color { Color(nsColor: searchHit) }
    static var onLightColor: Color { Color(nsColor: onLight) }

    // MARK: - The writer's curated swatches

    /// A low-alpha wash behind text. Muted on purpose — a highlight marks a
    /// passage, it shouldn't fight the prose for attention.
    static func highlightFill(_ swatch: ScriptSwatch) -> NSColor {
        switch swatch {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.85, blue: 0.20, alpha: 0.28)
        case .green: NSColor(srgbRed: 0.30, green: 0.85, blue: 0.40, alpha: 0.22)
        case .blue: NSColor(srgbRed: 0.30, green: 0.60, blue: 1.00, alpha: 0.24)
        case .pink: NSColor(srgbRed: 1.00, green: 0.40, blue: 0.70, alpha: 0.22)
        }
    }

    /// The same four hues, saturated enough to stand as the text's own
    /// color on the dark script background.
    static func textTint(_ swatch: ScriptSwatch) -> NSColor {
        switch swatch {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.82, blue: 0.25, alpha: 1)
        case .green: NSColor(srgbRed: 0.45, green: 0.90, blue: 0.50, alpha: 1)
        case .blue: NSColor(srgbRed: 0.45, green: 0.68, blue: 1.00, alpha: 1)
        case .pink: NSColor(srgbRed: 1.00, green: 0.50, blue: 0.75, alpha: 1)
        }
    }

    static func highlightFillColor(_ swatch: ScriptSwatch) -> Color { Color(nsColor: highlightFill(swatch)) }
    static func textTintColor(_ swatch: ScriptSwatch) -> Color { Color(nsColor: textTint(swatch)) }
    /// The dot a swatch picker shows — the vivid tint, whichever picker it's
    /// in, so a color reads as one idea across highlight and text-color.
    static func swatchDot(_ swatch: ScriptSwatch) -> Color { textTintColor(swatch) }

    // MARK: - UI chrome (home screens)

    /// Three text tiers instead of a different hand-picked opacity in every
    /// view — primary content, secondary/supporting text, and the quietest
    /// tier (timestamps, placeholders, disabled-ish hints).
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary = Color.white.opacity(0.4)

    /// A card's resting fill, its hover fill, and the fill it gets when it's
    /// the thing currently open/selected — one scale, reused everywhere a
    /// card or row needs to react to the mouse.
    static let surface = Color.white.opacity(0.04)
    static let surfaceHover = Color.white.opacity(0.07)
    static let surfaceSelected = Color.white.opacity(0.12)
    /// The hairline edge a selected pill or card carries.
    static let selectionStroke = Color.white.opacity(0.18)

    /// The one colour for "selected" and "do this": white, the way the
    /// system's own media apps do dark mode. Not `Color.accentColor` — that's
    /// the *user's* system accent, which the app has no say in (the same
    /// defect the citation colour had). And not a hue: colour here means
    /// something — a citation, a range, a note, a beat — and the chrome
    /// shouldn't compete with it.
    static let accent = Color.white.opacity(0.92)
    /// A hairline divider or border, quiet enough to separate without
    /// drawing its own attention.
    static let hairline = Color.white.opacity(0.08)
    /// The one surface home is drawn on — window, title bar and content
    /// alike — so the only other tone on screen is the glass floating on it.
    static let homeBackground = Color(white: 0.075)
}

// MARK: - Shape

/// The three corner radii every surface in the app should round to — no
/// more picking a number per view.
enum Radius {
    /// The home panel itself — the outermost shape, so everything inside
    /// it rounds a little less and the corners stay concentric.
    static let window: CGFloat = 28
    /// Hero-sized cards and the floating sidebar: cover art, Reading Now.
    static let large: CGFloat = 22
    /// Standard cards: project cards, series cards.
    static let medium: CGFloat = 16
    /// Rows, chips, small buttons.
    static let small: CGFloat = 10
}

// MARK: - Type scale

/// The sizes/weights every home-screen label should be picked from, instead
/// of a bespoke `.system(size:weight:)` per label.
enum Typography {
    /// A tab's own title (e.g. "Reading").
    static let pageTitle = Font.system(size: 30, weight: .bold)
    /// A heading over a group — "Also Reading", a series' projects — in
    /// sentence case, the way the system's own apps head a section now.
    static let sectionTitle = Font.system(size: 19, weight: .bold)
    /// A series name, a card's headline.
    static let heading = Font.system(size: 17, weight: .semibold)
    /// Ordinary reading text: card titles, row labels.
    static let body = Font.system(size: 13)
    /// Supporting text: dates, counts, secondary lines.
    static let caption = Font.system(size: 11)
}

// MARK: - Elevation

private struct Elevated: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

extension View {
    /// The one shadow every card in the home screens should cast — real
    /// depth instead of an opacity bump standing in for it.
    func elevated() -> some View { modifier(Elevated()) }
}

// MARK: - Glass

extension View {
    /// Liquid Glass where the system has it, the nearest material where it
    /// doesn't. Deployment target is macOS 14; the effect arrived in 26.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// A glass capsule for a small round control — a close button, a pill
    /// — that reacts to the pointer where the system can.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        } else {
            self.background(tint.map { AnyShapeStyle($0.opacity(0.35)) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
    }

    /// A header button: glass on 26, a bordered capsule before it. The
    /// prominent one is the app's own white capsule on every version — see
    /// `PrimaryButtonStyle`.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if prominent {
            self.buttonStyle(PrimaryButtonStyle())
        } else if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// A scroll view whose top meets the title bar makes macOS 26 draw a
    /// band of its own across the whole window there — a second grey on a
    /// screen meant to be one surface. Home has nothing pinned over its
    /// content for that band to separate, so it goes.
    @ViewBuilder
    func noTitlebarPocket() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

/// Neighbouring glass that should read as one piece — header buttons, a
/// segmented toggle — merges where the system can; a plain row otherwise.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) { content }
            }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// The one thing to do on a screen — Resume, Create, New Project: a solid
/// white capsule with black text, instead of the system's blue.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, isEnabled: isEnabled, large: controlSize == .large)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isEnabled: Bool
        let large: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 12, weight: .semibold))
                .foregroundStyle(Color.black.opacity(isEnabled ? 0.9 : 0.5))
                .padding(.horizontal, large ? 18 : 12)
                .padding(.vertical, large ? 9 : 5)
                .background(Capsule().fill(Color.white.opacity(fill)))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 }
        }

        private var fill: Double {
            guard isEnabled else { return 0.3 }
            if configuration.isPressed { return 0.78 }
            return hovered ? 1 : 0.92
        }
    }
}

/// A secondary action beside a primary one — New Project, Update. Text and
/// an icon, with a capsule only while the pointer is over it, so it doesn't
/// compete with the white button.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, isEnabled: isEnabled)
    }

    private struct QuietButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isEnabled: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(foreground))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(fill)))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 }
        }

        private var foreground: Double {
            guard isEnabled else { return 0.38 }
            return hovered ? 0.92 : 0.62
        }

        private var fill: Double {
            hovered && isEnabled ? 0.08 : 0
        }
    }
}
