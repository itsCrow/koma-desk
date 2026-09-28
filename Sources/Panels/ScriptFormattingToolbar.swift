import SwiftUI
import PanelsProject

/// Bold, italic, a style level, alignment, a highlight, and a text color —
/// pinned under the script pane's header the way Word or Docs pins theirs,
/// shown only in the extended writing area. A menu and a couple of popovers
/// stand in for the toolbar's own dropdowns, rather than building bespoke
/// ones — the same restraint the rest of the app's chrome already keeps to.
struct ScriptFormattingToolbar: View {
    @Bindable var model: ReaderModel

    private var formatting: ScriptSelectionFormatting { model.selectionFormatting }

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            styleMenu
            divider
            HStack(spacing: 2) {
                toggleButton("Bold", systemImage: "bold", active: formatting.bold) {
                    model.formatInline(.toggleBold)
                }
                toggleButton("Italic", systemImage: "italic", active: formatting.italic) {
                    model.formatInline(.toggleItalic)
                }
            }
            divider
            HStack(spacing: 2) {
                alignmentButton(.leading, systemImage: "text.alignleft")
                alignmentButton(.center, systemImage: "text.aligncenter")
                alignmentButton(.trailing, systemImage: "text.alignright")
            }
            divider
            SwatchPickerButton(systemImage: "highlighter", help: "Highlight", current: formatting.highlight) { swatch in
                model.formatInline(.setHighlight(swatch))
            }
            SwatchPickerButton(systemImage: "character", help: "Text Color", current: formatting.textColor) { swatch in
                model.formatInline(.setTextColor(swatch))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(ScriptStyle.backgroundColor)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 16)
    }

    private var styleMenu: some View {
        Menu {
            Button("Body") { model.format(.body) }
            Button("Subheading") { model.format(.heading(3)) }
            Button("Heading") { model.format(.heading(2)) }
            Button("Title") { model.format(.heading(1)) }
            Divider()
            Button("Synopsis") { model.format(.synopsis) }
        } label: {
            HStack(spacing: 4) {
                Text(styleName)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var styleName: String {
        switch formatting.style {
        case .body: "Body"
        case .heading3: "Subheading"
        case .heading2: "Heading"
        case .heading1: "Title"
        case .note: "Note"
        case .synopsis: "Synopsis"
        }
    }

    private func toggleButton(_ help: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(active ? 1 : 0.6))
                .frame(width: 24, height: 24)
                .background(.white.opacity(active ? 0.18 : 0), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func alignmentButton(_ alignment: ScriptAlignment, systemImage: String) -> some View {
        let active = formatting.alignment == alignment
        return Button {
            model.format(.alignment(alignment))
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(active ? 1 : 0.6))
                .frame(width: 24, height: 24)
                .background(.white.opacity(active ? 0.18 : 0), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A small dot for the current color (or none), opening a popover of the
/// curated swatches — the app's one color-picker, kept as narrow as the
/// choice actually on offer.
private struct SwatchPickerButton: View {
    let systemImage: String
    let help: String
    let current: ScriptSwatch?
    let action: (ScriptSwatch?) -> Void

    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 24)
                if let current {
                    Circle()
                        .fill(Palette.swatchDot(current))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                ForEach(ScriptSwatch.allCases, id: \.self) { swatch in
                    Button {
                        action(swatch)
                        showing = false
                    } label: {
                        Circle()
                            .fill(Palette.swatchDot(swatch))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.white, lineWidth: current == swatch ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    action(nil)
                    showing = false
                } label: {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("None")
            }
            .padding(10)
        }
    }
}
