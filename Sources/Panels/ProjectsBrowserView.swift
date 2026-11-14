import SwiftUI
import PanelsProject

/// The projects half of home: the project last worked on, big, to carry on
/// with — then every project, grouped by series.
struct ProjectsBrowserView: View {
    @Bindable var model: ReaderModel
    /// Only projects about this series, when set.
    let seriesFilter: String?

    private var projects: ProjectLibrary { model.projects }

    /// The groups, narrowed to what the home search matches — by a
    /// project's own name or by the series it's about — and ordered within
    /// each by the chosen sort.
    private var groups: [(series: String, projects: [ProjectSummary])] {
        let words = projects.wordCounts
        return projects.groupedBySeries.compactMap { group in
            let shown = group.projects.filter { HomeSearch.matches(model.homeSearch, $0.name, $0.seriesName) }
            return shown.isEmpty ? nil : (group.series, model.projectsSort.sorted(shown, words: words))
        }
    }

    var body: some View {
        if projects.summaries.isEmpty {
            VStack(spacing: 0) {
                controlsRow
                empty
            }
        } else {
            let groups = groups
            let latest = groups.flatMap(\.projects).max { $0.recency < $1.recency }
            // No page title: the hero's "Continue Writing" says it.
            HomeScroll(header: { controlsRow }) {
                if let latest {
                    VStack(alignment: .leading, spacing: 36) {
                        ProjectHero(model: model, summary: latest)
                        ForEach(groups, id: \.series) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                SectionHeading(group.series, count: group.projects.count)
                                switch model.projectsViewMode {
                                case .grid:
                                    ProjectsGrid(model: model, projects: group.projects)
                                case .list:
                                    ProjectsList(model: model, projects: group.projects)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                } else {
                    ContentUnavailableView.search(text: model.homeSearch)
                        .padding(.top, 80)
                }
            }
        }
    }

    // MARK: - Header controls

    /// The tab's controls with no title beside them, at the top right.
    private var controlsRow: some View {
        HomeControlsRow { controls }
    }

    @ViewBuilder
    private var controls: some View {
        sortMenu
        viewModePicker
        moreMenu
        Button { model.requestNewProject(series: seriesFilter) } label: {
            Label("New Project", systemImage: "plus")
        }
        .glassButtonStyle(prominent: true)
        .disabled(model.library.isEmpty)
        .help(model.library.isEmpty ? "Add a series to the library first — a project is about the series it cites" : "New project (⇧⌘N)")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.projectsSort) {
                ForEach(ProjectsSort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .glassButtonStyle()
        .fixedSize()
        .help("Sort projects: \(model.projectsSort.label)")
    }

    /// Where projects live, and opening one from anywhere else — kept out of
    /// the way in a menu rather than across the bottom of the cards.
    private var moreMenu: some View {
        Menu {
            Section("Projects Folder") {
                Text(projects.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Change Folder…") { projects.chooseRoot() }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([projects.root]) }
            }
            Divider()
            Button("Open Project…") { model.presentOpenProjectPanel() }
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .glassButtonStyle()
        .fixedSize()
        .help("Projects folder, and opening a project from elsewhere")
    }

    /// Grid of cards, or a list of rows.
    private var viewModePicker: some View {
        HStack(spacing: 2) {
            viewModeButton(.grid, systemImage: "square.grid.2x2")
            viewModeButton(.list, systemImage: "list.bullet")
        }
        .padding(3)
        .glassCapsule()
    }

    private func viewModeButton(_ mode: ProjectsViewMode, systemImage: String) -> some View {
        let active = model.projectsViewMode == mode
        return Button {
            model.projectsViewMode = mode
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .frame(width: 30, height: 22)
                .background(active ? Palette.surfaceSelected : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode == .grid ? "Grid view" : "List view")
    }

    private var empty: some View {
        EmptyStateView(icon: "doc.text.below.ecg", title: "No projects yet",
                       subtitle: model.library.isEmpty
                       ? "A project is a script about one series, with its citations and captures. Add a series to the library first."
                       : "A project is a script about one series, with its citations and captures. Make one here, or from a series’ page.")
    }
}

// MARK: - Hero

/// The project worked on last, big: a readable page of its script, how far
/// along it is, and one button to carry on — the writing counterpart of
/// Reading Now's hero.
private struct ProjectHero: View {
    @Bindable var model: ReaderModel
    let summary: ProjectSummary
    @State private var hovered = false

    private var preview: ProjectPreview? { model.projects.previews[summary.url] }

    var body: some View {
        HStack(alignment: .bottom, spacing: 30) {
            Button(action: open) {
                ScriptPage(blocks: preview?.blocks ?? [], lines: 26, fontSize: 9.5)
                    .padding(18)
                    .frame(width: 250, height: 340, alignment: .topLeading)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                    .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(hovered ? 0.6 : 0.45), radius: hovered ? 28 : 20, y: hovered ? 16 : 10)
                    .scaleEffect(hovered ? 1.02 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }

            VStack(alignment: .leading, spacing: 0) {
                Text("Continue Writing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Text(summary.name)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .padding(.top, 8)
                Text(summary.seriesName)
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 4)
                if let lastWorkedOn {
                    Text(lastWorkedOn)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, 3)
                }

                VStack(alignment: .leading, spacing: 9) {
                    if let words = preview?.words {
                        if let target = summary.targetWordCount, target > 0 {
                            statLine {
                                ProgressRing(fraction: Double(words) / Double(target), lineWidth: 2.5)
                                    .frame(width: 18, height: 18)
                            } text: {
                                Text(ProjectStats.wordsPhrase(words, target: target))
                                    .contentTransition(.numericText())
                                if words >= target {
                                    Text("· Goal reached").foregroundStyle(Palette.textPrimary)
                                }
                            }
                        } else {
                            statLine { glyph("text.alignleft") } text: {
                                Text(ProjectStats.wordsPhrase(words, target: nil))
                                    .contentTransition(.numericText())
                            }
                        }
                    }
                    if summary.beatsTotal > 0 {
                        statLine { BeatDots(done: summary.beatsDone, total: summary.beatsTotal) } text: {
                            Text("\(summary.beatsDone) of \(summary.beatsTotal) beats")
                        }
                    }
                    statLine { glyph("photo") } text: {
                        Text(ProjectStats.citationsPhrase(summary.citationCount))
                    }
                }
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 16)

                Button(action: open) {
                    Label("Continue", systemImage: "square.and.pencil")
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.large)
                .padding(.top, 20)
            }
            .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
        .task(id: summary.url.path + (summary.edited?.description ?? "")) {
            await model.projects.loadPreview(for: summary)
        }
    }

    /// "Opened 2 hours ago", or when it was saved if it's never been opened here.
    private var lastWorkedOn: String? {
        if let opened = summary.lastOpened { return "Opened " + opened.formatted(.relative(presentation: .named)) }
        if let edited = summary.edited { return "Edited " + edited.formatted(.relative(presentation: .named)) }
        return nil
    }

    /// One line of the stats: a fixed-width column for its mark, so the
    /// text of every line starts at the same place. Beat dots overflow it
    /// to the right, which is fine — they're the mark.
    private func statLine<Mark: View, Words: View>(@ViewBuilder mark: () -> Mark,
                                                   @ViewBuilder text: () -> Words) -> some View {
        HStack(spacing: 10) {
            mark().frame(minWidth: 18, alignment: .center)
            HStack(spacing: 5) { text() }
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.textTertiary)
    }

    private func open() {
        model.showsHome = false
        model.switchTo(summary.url)
    }
}

/// The small phrases every project view says the same way.
enum ProjectStats {
    /// "1,240 of 2,000 words", or "1,240 words" with no goal.
    static func wordsPhrase(_ words: Int, target: Int?) -> String {
        let count = words.formatted()
        if let target, target > 0 { return "\(count) of \(target.formatted()) words" }
        return words == 1 ? "1 word" : "\(count) words"
    }

    /// "1.2k words" — for a card's stats row, where room is short.
    static func compactWords(_ words: Int) -> String {
        let count = words >= 1000
            ? words.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
            : "\(words)"
        return words == 1 ? "1 word" : "\(count) words"
    }

    static func citationsPhrase(_ count: Int) -> String {
        count == 1 ? "1 citation" : "\(count) citations"
    }

    /// "2h ago" — when it was last opened, or saved if it never was here.
    static func shortDate(_ summary: ProjectSummary) -> String {
        guard let date = summary.lastOpened ?? summary.edited else { return "" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// Beats as dots: filled for done, outlined for still to do — capped, with
/// the rest counted, so a long script doesn't draw a row of fifty.
private struct BeatDots: View {
    let done: Int
    let total: Int
    private let cap = 12

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(total, cap), id: \.self) { index in
                Circle()
                    .fill(index < done ? Palette.accent : .clear)
                    .overlay(Circle().strokeBorder(Palette.accent.opacity(index < done ? 0 : 0.5), lineWidth: 1))
                    .frame(width: 7, height: 7)
            }
            if total > cap {
                Text("+\(total - cap)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

// MARK: - Grid and card

/// The menu every project offers, wherever it's shown.
private struct ProjectMenu: View {
    @Bindable var model: ReaderModel
    let summary: ProjectSummary
    let rename: () -> Void

    var body: some View {
        Button("Open") { model.switchTo(summary.url) }
        Button("Rename…", action: rename)
        Button("Duplicate") { model.duplicateProject(summary.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trashProject(summary.url) }
    }
}

/// Renaming, shared by the grid, the row and the list.
private struct RenameAlert: ViewModifier {
    @Bindable var model: ReaderModel
    @Binding var renaming: ProjectSummary?
    @Binding var renameTo: String

    func body(content: Content) -> some View {
        content.alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTo)
            Button("Rename") {
                if let renaming { model.renameProject(renaming.url, to: renameTo) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

/// Project cards, with their menu.
struct ProjectsGrid: View {
    @Bindable var model: ReaderModel
    let projects: [ProjectSummary]

    @State private var renaming: ProjectSummary?
    @State private var renameTo = ""

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18, alignment: .top)],
                  alignment: .leading, spacing: 22) {
            ForEach(projects) { summary in
                card(summary)
            }
        }
        .modifier(RenameAlert(model: model, renaming: $renaming, renameTo: $renameTo))
    }

    private func card(_ summary: ProjectSummary) -> some View {
        let menu = ProjectMenu(model: model, summary: summary) { renameTo = summary.name; renaming = summary }
        return ProjectCard(model: model, summary: summary, isOpen: summary.url == model.project?.url) {
            model.switchTo(summary.url)
        } menu: { menu }
        .contextMenu { menu }
    }
}

// MARK: - Row

/// Projects about a series, as a single scrolling row rather than a
/// multi-row grid — for a series page, where projects are the actual point
/// and shouldn't sit buried below a long chapter list. "New Project" is
/// pinned at the start, always reachable whatever the row scrolls to.
struct ProjectsRow: View {
    @Bindable var model: ReaderModel
    let projects: [ProjectSummary]
    let seriesName: String

    @State private var renaming: ProjectSummary?
    @State private var renameTo = ""

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                NewProjectCard { model.requestNewProject(series: seriesName) }
                ForEach(projects) { summary in
                    let menu = ProjectMenu(model: model, summary: summary) { renameTo = summary.name; renaming = summary }
                    ProjectCard(model: model, summary: summary, isOpen: summary.url == model.project?.url) {
                        model.switchTo(summary.url)
                    } menu: { menu }
                    .frame(width: 210)
                    .contextMenu { menu }
                }
            }
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .modifier(RenameAlert(model: model, renaming: $renaming, renameTo: $renameTo))
    }
}

/// The pinned card at the start of a `ProjectsRow`, the same size as the
/// cards beside it.
private struct NewProjectCard: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                Text("New Project")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(hovered ? Palette.textPrimary.opacity(0.8) : Palette.textTertiary)
            .frame(width: 210, height: ProjectCard<EmptyView>.height)
            .background(RoundedRectangle(cornerRadius: Radius.medium)
                .strokeBorder(hovered ? Color.white.opacity(0.5) : Palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - List

/// Projects as a table — name, series, words, beats, citations, when last
/// opened — for scanning a lot of them at once.
struct ProjectsList: View {
    @Bindable var model: ReaderModel
    let projects: [ProjectSummary]

    @State private var renaming: ProjectSummary?
    @State private var renameTo = ""

    var body: some View {
        VStack(spacing: 0) {
            ProjectColumns(name: Text("Name"), series: Text("Series"), words: Text("Words"),
                           beats: Text("Beats"), citations: Text("Citations"), opened: Text("Opened"),
                           trailing: Color.clear.frame(width: 20, height: 1))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            ForEach(Array(projects.enumerated()), id: \.element.id) { index, summary in
                Divider().overlay(Palette.hairline)
                let menu = ProjectMenu(model: model, summary: summary) { renameTo = summary.name; renaming = summary }
                ProjectRow(model: model, summary: summary, isOpen: summary.url == model.project?.url) {
                    model.switchTo(summary.url)
                } menu: { menu }
                .contextMenu { menu }
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.medium))
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
        .modifier(RenameAlert(model: model, renaming: $renaming, renameTo: $renameTo))
    }
}

/// The list's columns, laid out the same for the header and every row so
/// they line up.
private struct ProjectColumns<Trailing: View>: View {
    let name: Text
    let series: Text
    let words: Text
    let beats: Text
    let citations: Text
    let opened: Text
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            name.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            series.lineLimit(1).frame(width: 150, alignment: .leading)
            words.lineLimit(1).frame(width: 110, alignment: .trailing)
            beats.lineLimit(1).frame(width: 56, alignment: .trailing)
            citations.lineLimit(1).frame(width: 64, alignment: .trailing)
            opened.lineLimit(1).frame(width: 110, alignment: .trailing)
            trailing
        }
    }
}

private struct ProjectRow<Menu: View>: View {
    @Bindable var model: ReaderModel
    let summary: ProjectSummary
    let isOpen: Bool
    let open: () -> Void
    @ViewBuilder let menu: Menu

    @State private var hovered = false

    private var words: Int? { model.projects.previews[summary.url]?.words }

    var body: some View {
        Button(action: open) {
            ProjectColumns(
                name: Text(summary.name).font(.system(size: 13, weight: isOpen ? .semibold : .medium))
                    .foregroundColor(Palette.textPrimary),
                series: Text(summary.seriesName),
                words: ringGlyph + Text(wordsText),
                beats: Text(summary.beatsTotal > 0 ? "\(summary.beatsDone)/\(summary.beatsTotal)" : "—"),
                citations: Text("\(summary.citationCount)"),
                opened: Text(dateText),
                trailing: SwiftUI.Menu { menu } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(hovered ? Palette.textSecondary : Palette.textTertiary)
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            )
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(isOpen ? Palette.surfaceSelected : (hovered ? Palette.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .task(id: summary.url.path + (summary.edited?.description ?? "")) {
            await model.projects.loadPreview(for: summary)
        }
    }

    /// A small ring ahead of the count when there's a goal — the same mark
    /// the hero and the cards use — drawn as a symbol so it sits in the
    /// column's text.
    private var ringGlyph: Text {
        guard let words, let target = summary.targetWordCount, target > 0 else { return Text("") }
        let fraction = Double(words) / Double(target)
        let name = fraction >= 1 ? "circle.fill" : (fraction >= 0.5 ? "circle.righthalf.filled" : "circle")
        return Text(Image(systemName: name)).font(.system(size: 10)) + Text("  ")
    }

    /// "1,240 / 2,000" against a goal, "1,240" without one.
    private var wordsText: String {
        guard let words else { return "" }
        if let target = summary.targetWordCount, target > 0 { return "\(words.formatted()) / \(target.formatted())" }
        return words.formatted()
    }

    private var dateText: String { ProjectStats.shortDate(summary) }
}

/// A project card: a page of the actual script text — what the document
/// really contains, not a citation image, so it reads like a document
/// browser rather than a comic-panel gallery — and how far along it is.
struct ProjectCard<Menu: View>: View {
    @Bindable var model: ReaderModel
    let summary: ProjectSummary
    let isOpen: Bool
    let open: () -> Void
    @ViewBuilder let menu: Menu

    /// Fixed rather than derived from the column's width: width-derived
    /// sizing doesn't relayout reliably across a LazyVGrid's drastic resize
    /// (e.g. going fullscreen), leaving some cards taller than others.
    static var previewHeight: CGFloat { 170 }
    /// The whole card, for anything that has to sit beside one at its size.
    static var height: CGFloat { previewHeight + 66 }

    @State private var hovered = false

    private var preview: ProjectPreview? { model.projects.previews[summary.url] }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ScriptPage(blocks: preview?.blocks ?? [], lines: 12, fontSize: 8.5)
                    .padding(12)
                    .frame(height: Self.previewHeight, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .clipped()

                Divider().overlay(Palette.hairline)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(summary.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        // The date gives way to the menu on hover, in the
                        // same spot, so the name never shifts.
                        ZStack(alignment: .trailing) {
                            Text(ProjectStats.shortDate(summary))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textTertiary)
                                .opacity(hovered ? 0 : 1)
                            SwiftUI.Menu { menu } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(width: 20, height: 16)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .opacity(hovered ? 1 : 0)
                        }
                        .animation(.easeOut(duration: 0.15), value: hovered)
                    }
                    HStack(spacing: 6) {
                        if let target = summary.targetWordCount, target > 0, let words = preview?.words {
                            ProgressRing(fraction: Double(words) / Double(target), lineWidth: 2)
                                .frame(width: 12, height: 12)
                        }
                        Text(stats)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: Self.height)
            // Without this, a card with little content (a near-empty
            // script, a short name) shrinks to its own natural width instead
            // of filling its grid column, and cards in a row come out uneven.
            .frame(maxWidth: .infinity)
            .cardChrome(isSelected: isOpen, isHovered: hovered)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .task(id: summary.url.path + (summary.edited?.description ?? "")) {
            await model.projects.loadPreview(for: summary)
        }
    }

    /// "1.2k words · 12 citations · 4/9 beats" — words once they're counted,
    /// beats only when there are some.
    private var stats: String {
        var parts: [String] = []
        if let words = preview?.words { parts.append(ProjectStats.compactWords(words)) }
        parts.append(ProjectStats.citationsPhrase(summary.citationCount))
        if summary.beatsTotal > 0 { parts.append("\(summary.beatsDone)/\(summary.beatsTotal) beats") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Script preview

/// The first lines of a script, drawn the way the editor means them — a
/// page range as one tinted block with its margin bar, a note in its
/// colour, a citation as a small image glyph — at a size meant to be read,
/// not just glanced at as texture.
struct ScriptPage: View {
    let blocks: [ScriptBlock]
    /// At most this many lines: a line is one block, cut to one line.
    let lines: Int
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.45) {
            ForEach(runs) { run in
                PreviewRunView(run: run, fontSize: fontSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Consecutive lines sharing a span id are one block of writing in the
    /// real editor — grouped here the same way, so the preview shows one
    /// continuous tinted region per span instead of a separate box per line.
    /// Blank lines are dropped: at this size they're only gaps.
    private var runs: [PreviewRun] {
        var runs: [PreviewRun] = []
        let shown = blocks.filter { !$0.inlines.isEmpty }.prefix(lines)
        for block in shown {
            if let spanID = block.spanID, spanID == runs.last?.spanID {
                runs[runs.count - 1].blocks.append(block)
            } else {
                runs.append(PreviewRun(id: runs.count, spanID: block.spanID, blocks: [block]))
            }
        }
        return runs
    }
}

/// A run of consecutive script lines sharing a span id (or none at all).
private struct PreviewRun: Identifiable {
    let id: Int
    let spanID: String?
    var blocks: [ScriptBlock]
}

/// One span's worth of lines, boxed as one continuous region — a left
/// accent bar and a tint, the same idea as the real editor's margin box —
/// rather than a separate background per line.
private struct PreviewRunView: View {
    let run: PreviewRun
    let fontSize: CGFloat

    var body: some View {
        let lines = VStack(alignment: .leading, spacing: fontSize * 0.3) {
            ForEach(Array(run.blocks.enumerated()), id: \.offset) { _, block in
                PreviewLineText(block: block, fontSize: fontSize)
            }
        }
        if run.spanID != nil {
            lines
                .padding(.leading, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(Palette.pageRangeColor.opacity(0.85)).frame(width: 1.5)
                        Rectangle().fill(Palette.pageRangeColor.opacity(0.12))
                    }
                }
        } else {
            lines
        }
    }
}

/// One line's text, styled the same way the real editor means it: a note in
/// its aside color, a citation marked with a small image glyph like the
/// editor's chip.
private struct PreviewLineText: View {
    let block: ScriptBlock
    let fontSize: CGFloat

    var body: some View {
        text
            .font(.system(size: fontSize))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: Text {
        var line = block.inlines.reduce(Text("")) { built, inline in
            switch inline {
            case .text(let string):
                return built + Text(string)
            case .styledText(let run):
                // A highlight wash doesn't translate to a `Text` run, but
                // bold, italic and the color do.
                var piece = Text(run.text)
                if run.bold { piece = piece.bold() }
                if run.italic { piece = piece.italic() }
                if let color = run.textColor { piece = piece.foregroundColor(Palette.textTintColor(color)) }
                return built + piece
            case .citation:
                // The real editor never spells a citation out as text either
                // — it's one atomic chip glyph where the citation was made.
                return built + Text(Image(systemName: "photo.fill"))
                    .font(.system(size: fontSize * 0.9))
                    .foregroundColor(Palette.citationColor)
            }
        }
        switch block.kind {
        case .heading:
            line = line.bold().foregroundColor(Palette.textPrimary)
        case .note:
            line = line.italic().foregroundColor(Palette.noteColor)
        case .synopsis:
            line = line.foregroundColor(Palette.textTertiary)
        case .paragraph:
            line = line.foregroundColor(Palette.textSecondary)
        }
        return line
    }
}
