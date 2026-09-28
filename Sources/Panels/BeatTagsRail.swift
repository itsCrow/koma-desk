import AppKit
import SwiftUI
import PanelsProject

/// Every beat, always listed — an editor reviewing a long script needs to
/// keep their place even in the beats they've already dealt with, so
/// nothing here ever hides a beat the way an earlier version of this view
/// did by following the script's own scroll position. Numbered in script
/// order, each with an optional color of its own. The one that's "next up"
/// — the first not yet marked done — draws brighter than the rest, so the
/// standout signal answers "what should I do next," not "where has the
/// reader scrolled to." Shown only in Editor mode, and only once there's a
/// beat at all — see `ScriptPaneView.showsBeatTagsRail`.
///
/// Rows sit at the same height as their beat's highlighted block back in
/// the script — like a margin of comments beside a document — rather than
/// just being stacked one after another. That means the rail has no
/// scrollbar of its own: scrolling the script is what moves it, via
/// `model.scriptScrollOffset`/`beatBoxTops`/`scriptContentHeight`, all
/// published by `ScriptTextView`.
struct BeatTagsRail: View {
    @Bindable var model: ReaderModel
    let project: Project

    /// Below this, a row drops its title but keeps its tags — the name is
    /// what a narrow rail can't afford, not the production notes an editor
    /// actually scans for.
    static let compactThreshold: CGFloat = 90

    /// The rail's fixed width outside the extended writing area: a number
    /// badge plus room for a short tag, not a slice the reader has any
    /// reason to drag wider — a long tag still fits by truncating, the same
    /// as it always has.
    static let unextendedWidth: CGFloat = 92

    /// The gap kept between two rows whose beats sit closer together in the
    /// script than the rows themselves are tall.
    private static let minRowGap: CGFloat = 10

    /// Outside the extended writing area the comic is still on screen, so
    /// the rail is a side panel rather than a margin — it stays in its
    /// compact shape no matter how wide it's dragged, the same way it does
    /// when the drag itself narrows it past `compactThreshold`.
    private var isCompact: Bool {
        !model.isFocusedWriting || model.beatRailWidth < Self.compactThreshold
    }

    /// The first not-done beat, in script order — what to work on next.
    /// `nil` once every beat is done.
    private var nextUpBeatID: String? {
        project.beatsInScriptOrder.first { !$0.isDone }?.id
    }

    @State private var rowHeights: [String: CGFloat] = [:]

    /// A row's height before its real size has been measured — close enough
    /// to the true shape (badge, title, one line per tag, add-tag control)
    /// that the very first layout doesn't under-reserve space for a
    /// several-tag row and collide with the one after it. Real measurements
    /// from `BeatRowHeightKey` override this the moment they arrive.
    private func estimatedRowHeight(for beat: Beat) -> CGFloat {
        let tagsHeight = beat.tags.isEmpty ? 0 : CGFloat(beat.tags.count) * 16 + CGFloat(beat.tags.count - 1) * 4 + 5
        guard !isCompact else {
            let addButtonHeight: CGFloat = beat.tags.isEmpty ? 16 : 16 + 5
            return 20 + 8 + tagsHeight + addButtonHeight
        }
        return 14 + 5 + tagsHeight + 5 + 14 + 12
    }

    /// Each beat's true top, nudged down only far enough to keep it from
    /// overlapping the row before it — a row snaps to its beat's real
    /// position whenever there's room, and only gives ground when two beats
    /// are packed tightly together in the script.
    private var adjustedTops: [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        var cursor: CGFloat = 0
        for beat in project.beatsInScriptOrder {
            let raw = model.beatBoxTops[beat.id] ?? cursor
            let top = max(raw, cursor)
            result[beat.id] = top
            cursor = top + (rowHeights[beat.id] ?? estimatedRowHeight(for: beat)) + Self.minRowGap
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let tops = adjustedTops
            ZStack(alignment: .topLeading) {
                ForEach(project.beatsInScriptOrder.indices, id: \.self) { index in
                    let beat = project.beatsInScriptOrder[index]
                    BeatRailRow(project: project, beat: beat, number: index + 1,
                                isCompact: isCompact, isNextUp: beat.id == nextUpBeatID)
                        .padding(.horizontal, isCompact ? 6 : 10)
                        .background {
                            GeometryReader { rowGeo in
                                Color.clear.preference(key: BeatRowHeightKey.self,
                                                        value: [beat.id: rowGeo.size.height])
                            }
                        }
                        .offset(y: tops[beat.id] ?? 0)
                }
            }
            .frame(width: geo.size.width, height: max(model.scriptContentHeight, geo.size.height), alignment: .topLeading)
            .offset(y: -model.scriptScrollOffset)
        }
        .clipped()
        .background(ScriptStyle.backgroundColor)
        .onPreferenceChange(BeatRowHeightKey.self) { rowHeights = $0 }
    }
}

/// Collects each row's real rendered height, read from a `.background` so it
/// never feeds back into the row's own size — the standard measure-without-a-
/// layout-loop pattern.
private struct BeatRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct BeatRailRow: View {
    let project: Project
    let beat: Beat
    let number: Int
    let isCompact: Bool
    /// The first not-done beat in script order — drawn brighter than the
    /// rest. A beat is never dimmed for being *done*; only this one stands
    /// out, for being *next*.
    let isNextUp: Bool

    @State private var isAdding = false
    @State private var isPickingColor = false
    @State private var isHovered = false

    private var accent: Color { beat.color.map(Palette.textTintColor) ?? Palette.beatColor }

    /// Number and, when there's room, the title — but tags, and the control
    /// to add one, stay in place even when compact, since scanning tags
    /// ("green screen", "zoom") and adding them are what the rail is for,
    /// name or no name.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            numberBadge
            VStack(alignment: .leading, spacing: 5) {
                if !isCompact {
                    Text(beat.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }

                if !beat.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(beat.tags) { tag in
                            TagChip(tag: tag) { remove(tag) }
                        }
                    }
                }

                addTagButton
            }
        }
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .padding(isCompact ? 4 : 6)
        .background {
            if isNextUp {
                RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.16))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04))
            }
        }
        .overlay {
            if isNextUp {
                RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 1.5)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var numberBadge: some View {
        Button {
            isPickingColor = true
        } label: {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.onLightColor)
                .frame(width: 20, height: 20)
                .background(accent, in: Circle())
        }
        .buttonStyle(.plain)
        .help(beat.title)
        .popover(isPresented: $isPickingColor, arrowEdge: .trailing) {
            BeatColorPopover(current: beat.color) { color in
                project.pendingBeatColorChange = BeatColorChange(beatID: beat.id, color: color)
                isPickingColor = false
            }
        }
    }

    /// Full "+ Tag" label with room to spell it out; just the glyph, in a
    /// circle matching the number badge's footprint, where a compact row
    /// can't spare the width for a word.
    private var addTagButton: some View {
        Button {
            isAdding = true
        } label: {
            if isCompact {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .background(.white.opacity(0.08), in: Circle())
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Tag")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.35))
            }
        }
        .buttonStyle(.plain)
        .help("Add a tag")
        .popover(isPresented: $isAdding, arrowEdge: .trailing) {
            AddTagPopover { text, color in
                add(Tag(text: text, color: color))
                isAdding = false
            }
        }
    }

    private func add(_ tag: Tag) {
        var updated = beat
        updated.tags.append(tag)
        project.manifest.store(updated)
    }

    private func remove(_ tag: Tag) {
        var updated = beat
        updated.tags.removeAll { $0.id == tag.id }
        project.manifest.store(updated)
    }
}

private struct TagChip: View {
    let tag: Tag
    let onRemove: () -> Void

    var body: some View {
        Text(tag.text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.textTintColor(tag.color))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.highlightFillColor(tag.color), in: RoundedRectangle(cornerRadius: 4))
            .contextMenu {
                Button("Remove Tag", role: .destructive, action: onRemove)
            }
    }
}

/// A tag's text and its color, in one small surface — mirrors
/// `SwatchPickerButton` in `ScriptFormattingToolbar.swift`, which is private
/// to that file and shaped around `ScriptSelectionFormatting` rather than a
/// standalone value, so not worth pulling apart to share.
private struct AddTagPopover: View {
    let onAdd: (String, ScriptSwatch) -> Void

    @State private var text = ""
    @State private var color: ScriptSwatch = .yellow
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($focused)
                .onSubmit(submit)
            HStack(spacing: 8) {
                ForEach(ScriptSwatch.allCases, id: \.self) { swatch in
                    Button {
                        color = swatch
                    } label: {
                        Circle()
                            .fill(Palette.swatchDot(swatch))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.white, lineWidth: color == swatch ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add", action: submit)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed, color)
    }
}

/// A beat's own color, or back to the default violet — same swatch picker
/// shape as `AddTagPopover`'s, plus the "None" escape a tag's picker
/// doesn't need (a tag always has a color; a beat's is optional).
private struct BeatColorPopover: View {
    let current: ScriptSwatch?
    let onPick: (ScriptSwatch?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ScriptSwatch.allCases, id: \.self) { swatch in
                Button {
                    onPick(swatch)
                } label: {
                    Circle()
                        .fill(Palette.swatchDot(swatch))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: current == swatch ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
            Button {
                onPick(nil)
            } label: {
                Image(systemName: "circle.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Default")
        }
        .padding(10)
    }
}

/// The rail's own resize handle — a thin draggable strip in place of the
/// plain divider the script pane uses everywhere else, since this is the
/// one edge in the pane a reader actually resizes.
struct BeatRailResizeHandle: View {
    @Bindable var model: ReaderModel

    private static let widthRange: ClosedRange<CGFloat> = 44...280

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = widthAtDragStart ?? model.beatRailWidth
                        if widthAtDragStart == nil { widthAtDragStart = start }
                        model.beatRailWidth = min(max(start + value.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}
