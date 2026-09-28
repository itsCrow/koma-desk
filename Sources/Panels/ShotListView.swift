import SwiftUI
import PanelsProject

/// The script pane: the writing, or (shown a different way — see the
/// Reader menu's "Show Shot List") the list of shots it adds up to.
struct ScriptPaneView: View {
    @Bindable var model: ReaderModel
    let project: Project

    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    /// A document's worth of width — beyond this, more room just goes to
    /// margin either side, the way a page keeps its shape as a window grows.
    private static let focusedWidth: CGFloat = 820

    /// Editor mode's tag rail earns its place the same way the formatting
    /// toolbar earns its — only once there's something for it to hold. A
    /// beat with no tags yet still gets a slot, so there's somewhere to add
    /// the first one.
    private var showsBeatTagsRail: Bool {
        model.scriptMode == .editor && !project.beatsInScriptOrder.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                title
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ScriptStyle.backgroundColor)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    modeMenu
                    focusButton
                }
            }

            Divider().overlay(.white.opacity(0.1))

            // The toolbar only earns its place when there's room to write in
            // and something worth formatting — the ordinary split view keeps
            // menu-and-shortcut-driven formatting exactly as it was.
            if model.isFocusedWriting, model.scriptMode == .writer {
                ScriptFormattingToolbar(model: model)
                Divider().overlay(.white.opacity(0.1))
            }

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isFocusedWriting {
            // The comic is hidden entirely — see ReaderView — so this pane
            // has the whole window. Centering the editor at a fixed width
            // instead of letting it stretch edge to edge is what makes it
            // read as a page, the way Docs or Word keep a document a
            // constant width no matter how wide the window gets.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                // The rail eats into space the spacer was already leaving
                // empty, so it "just appears" without the editor's own
                // width changing — flush against the editor, same divider
                // the split view uses, no gap between them.
                if showsBeatTagsRail {
                    BeatTagsRail(model: model, project: project)
                        .frame(width: model.beatRailWidth)
                    BeatRailResizeHandle(model: model)
                }
                ScriptEditorView(project: project, model: model)
                    .frame(maxWidth: Self.focusedWidth)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .background(ScriptStyle.backgroundColor)
        } else {
            HStack(spacing: 0) {
                // Outside the extended writing area the rail is a side
                // panel, not a margin to be dragged wide — it stays pinned
                // to just enough room for the number badge and a tag, so
                // the editor beside it keeps as much width as it can.
                if showsBeatTagsRail {
                    BeatTagsRail(model: model, project: project)
                        .frame(width: BeatTagsRail.unextendedWidth)
                }
                ZStack(alignment: .bottomTrailing) {
                    // Both stay alive so switching doesn't reload the editor
                    // and lose the cursor.
                    ScriptEditorView(project: project, model: model)
                        .opacity(model.showsShotList ? 0 : 1)
                        .allowsHitTesting(!model.showsShotList)
                    if model.showsShotList {
                        ShotListView(model: model, project: project)
                    } else {
                        ScriptStatsPill(project: project)
                            .allowsHitTesting(false)
                    }
                }
            }
            .background(ScriptStyle.backgroundColor)
        }
    }

    /// Writer, Voice, or Editor — a menu rather than a segmented control,
    /// since the header has room for one more ~22×22 button but not for
    /// three labeled segments.
    private var modeMenu: some View {
        Menu {
            ForEach(ScriptMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { model.scriptMode = mode }
                } label: {
                    if model.scriptMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            Image(systemName: model.scriptMode.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch between writing, voice, and editor modes")
    }

    private var focusButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { model.isFocusedWriting.toggle() }
        } label: {
            Image(systemName: model.isFocusedWriting
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help(model.isFocusedWriting ? "Show the comic again" : "Hide the comic and write full width")
    }

    /// The project's name — click to rename it in place, rather than to
    /// switch to another project (the Projects tab does that now).
    private var title: some View {
        Group {
            if isRenaming {
                TextField("Project name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .focused($renameFocused)
                    .frame(maxWidth: 280)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                Button(action: beginRenaming) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Click to rename")
            }
        }
    }

    private func beginRenaming() {
        renameText = project.name
        isRenaming = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        isRenaming = false
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        model.renameProject(project.url, to: trimmed)
    }
}

/// How much has been written — counted off the readable script, not the
/// raw Markdown, so a citation's link syntax doesn't inflate the count.
/// Pinned to the bottom edge and only rounded on top, like a tab sitting in
/// the corner, rather than a badge floating over the text.
private struct ScriptStatsPill: View {
    let project: Project

    private var plainText: String { project.plainTextScript(notes: .marked) }
    private var wordCount: Int {
        plainText.split { $0.isWhitespace || $0.isNewline }.count
    }
    private var characterCount: Int { plainText.count }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(wordCount) word\(wordCount == 1 ? "" : "s")")
            Text("·").foregroundStyle(.white.opacity(0.3))
            Text("\(characterCount) character\(characterCount == 1 ? "" : "s")")
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 4)
        .background(
            .white.opacity(0.08),
            in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0,
                                        bottomTrailingRadius: 0, topTrailingRadius: 0)
        )
    }
}

/// Every citation in the order the video runs, as a checklist.
struct ShotListView: View {
    @Bindable var model: ReaderModel
    let project: Project

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: project.unusedCaptureBytes, countStyle: .file)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let shots = project.citationsInScriptOrder
                if shots.isEmpty {
                    Text("Citations you make appear here, in the order they appear in the script.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(20)
                }
                let sections = project.shotSections
                if sections.isEmpty {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { index, citation in
                        row(number: index + 1, citation: citation)
                    }
                } else {
                    // The script's own outline: each section's heading and
                    // synopsis over the shots in it, numbered straight through.
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, group in
                        SectionHeader(section: group.section, isEmpty: group.shots.isEmpty)
                        ForEach(group.shots, id: \.citation.id) { shot in
                            row(number: shot.number, citation: shot.citation)
                        }
                    }
                }

                let unused = project.unusedCitations
                let strayFiles = project.unusedCaptureFiles
                if !unused.isEmpty || !strayFiles.isEmpty {
                    HStack {
                        Text("Not in the script")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Button("Clean Up (\(strayFiles.count) files, \(sizeText))") {
                            model.cleanUpUnusedCaptures()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.14), in: Capsule())
                        .help("Moves captures the script doesn't use to the Trash")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                    ForEach(unused, id: \.id) { citation in
                        HStack(spacing: 10) {
                            Text(project.manifest.label(for: citation).short)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                            Spacer()
                            Button("Remove") { project.removeCitation(id: citation.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .background(ScriptStyle.backgroundColor)
    }

    @ViewBuilder
    private func row(number: Int, citation: Citation) -> some View {
        ShotRow(
            number: number,
            label: project.manifest.label(for: citation),
            context: project.context(of: citation.id),
            image: project.captureURL(for: citation)
        ) {
            model.revealShot(citation)
        }
        Divider().overlay(.white.opacity(0.07))
    }
}

/// A section of the script over its shots: the heading, and the synopsis
/// written under it — Fountain-lite's outline, where the shots are listed.
private struct SectionHeader: View {
    let section: ScriptSection
    /// No shots in it yet — worth saying, since that's a gap in the video.
    let isEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title ?? "Opening")
                .font(.system(size: section.level <= 1 ? 14 : 13, weight: .semibold))
                .foregroundStyle(.white.opacity(section.title == nil ? 0.55 : 0.9))
                .lineLimit(2)
            if let synopsis = section.synopsis {
                Text(synopsis)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3)
            }
            if isEmpty {
                Text("No shots yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
            }
        }
        .padding(.leading, section.level >= 2 ? 26 : 14)
        .padding(.trailing, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShotRow: View {
    let number: Int
    let label: ReferenceLabel
    let context: String?
    let image: URL?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, alignment: .trailing)
                    .padding(.top, 2)

                Group {
                    if let image, let thumbnail = NSImage(contentsOf: image) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 34, height: 44)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .frame(maxWidth: 62, maxHeight: 56)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    // The series is the project's, so saying it on every row
                    // only pushes the pages off the end.
                    Text(label.short)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    if let context, !context.isEmpty {
                        Text(context)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovered ? Color.white.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
