import SwiftUI
import PanelsProject

/// The projects half of home: every project, grouped by series.
struct ProjectsBrowserView: View {
    @Bindable var model: ReaderModel
    /// Only projects about this series, when set.
    let seriesFilter: String?

    @State private var newName = ""
    @State private var newSeries = ""
    @State private var isNaming = false
    @FocusState private var nameFocused: Bool

    private var projects: ProjectLibrary { model.projects }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 22)
                .padding(.vertical, 12)

            if projects.summaries.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(projects.groupedBySeries, id: \.series) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.series)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .textCase(.uppercase)
                                ProjectsGrid(model: model, projects: group.projects)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }

            Divider().overlay(.white.opacity(0.08))
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
        }
        .onAppear { if model.wantsNewProject { beginNaming() } }
        .onChange(of: model.wantsNewProject) { _, wants in if wants { beginNaming() } }
    }

    // MARK: - New project

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("\(projects.summaries.count) project\(projects.summaries.count == 1 ? "" : "s")")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            if isNaming {
                HStack(spacing: 8) {
                    Picker("Series", selection: $newSeries) {
                        ForEach(model.library.series) { series in
                            Text(series.name).tag(series.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    TextField("Project name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .focused($nameFocused)
                        .frame(width: 200)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                        .onSubmit(create)
                        .onExitCommand { isNaming = false }
                    Button("Create", action: create)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newSeries.isEmpty)
                    Button("Cancel") { isNaming = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Button { beginNaming() } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.library.isEmpty)
                .help(model.library.isEmpty ? "Add a series to the library first — a project is about one series" : "New project (⌘N)")
            }
            Button("Open…") { model.presentOpenProjectPanel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open a project from anywhere (⌥⌘O)")
        }
    }

    private func beginNaming() {
        model.wantsNewProject = false
        guard !model.library.isEmpty else { return }
        newName = ""
        newSeries = seriesFilter ?? model.series?.name ?? model.project?.manifest.series ?? model.library.series[0].name
        if model.library.series(named: newSeries) == nil { newSeries = model.library.series[0].name }
        isNaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !newSeries.isEmpty else { return }
        isNaming = false
        model.newProject(named: name, series: newSeries)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.white.opacity(0.5))
            Text(projects.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.6))
            Button("Change…") { projects.chooseRoot() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([projects.root]) }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
        }
        .font(.system(size: 12))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.white.opacity(0.4))
            Text("No projects yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(model.library.isEmpty
                 ? "A project is a script about one series, with its citations and captures. Add a series to the library first."
                 : "A project is a script about one series, with its citations and captures. Make one here, or from a series’ page.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Grid and card

/// Project cards, with their menu.
struct ProjectsGrid: View {
    @Bindable var model: ReaderModel
    let projects: [ProjectSummary]

    @State private var renaming: ProjectSummary?
    @State private var renameTo = ""

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16, alignment: .top)],
                  alignment: .leading, spacing: 16) {
            ForEach(projects) { summary in
                ProjectCard(summary: summary, isOpen: summary.url == model.project?.url) {
                    model.switchTo(summary.url)
                }
                .contextMenu { contextMenu(for: summary) }
            }
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTo)
            Button("Rename") {
                if let renaming { model.renameProject(renaming.url, to: renameTo) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func contextMenu(for summary: ProjectSummary) -> some View {
        Button("Open") { model.switchTo(summary.url) }
        Button("Rename…") { renameTo = summary.name; renaming = summary }
        Button("Duplicate") { model.duplicateProject(summary.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trashProject(summary.url) }
    }
}

private struct ProjectCard: View {
    let summary: ProjectSummary
    let isOpen: Bool
    let open: () -> Void

    @State private var hovered = false
    @State private var picture: NSImage?

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06))
                    if let picture {
                        Image(nsImage: picture)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28, weight: .thin))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(summary.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(summary.items.isEmpty ? "Nothing cited yet" : summary.items.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(hovered ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isOpen ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .task(id: summary.picture) {
            guard let url = summary.picture else { picture = nil; return }
            picture = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }

    private var detail: String {
        var parts = ["\(summary.citationCount) citation\(summary.citationCount == 1 ? "" : "s")"]
        if let edited = summary.edited {
            parts.append("edited " + edited.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}
