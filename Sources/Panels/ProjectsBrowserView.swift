import SwiftUI
import PanelsProject

/// Every project, grouped by series. The home screen when nothing is open,
/// and an overlay over the reader when something is.
struct ProjectsBrowserView: View {
    @Bindable var model: ReaderModel
    let isOverlay: Bool

    @State private var newName = ""
    @State private var isNaming = false
    @FocusState private var nameFocused: Bool
    @State private var renaming: ProjectSummary?
    @State private var renameTo = ""

    private var library: ProjectLibrary { model.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Divider().overlay(.white.opacity(0.08))

            if library.summaries.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(library.groupedBySeries, id: \.series) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.series)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .textCase(.uppercase)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16, alignment: .top)],
                                          alignment: .leading, spacing: 16) {
                                    ForEach(group.projects) { summary in
                                        ProjectCard(summary: summary, isOpen: summary.url == model.project?.url) {
                                            model.switchTo(summary.url)
                                        }
                                        .contextMenu { contextMenu(for: summary) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(22)
                }
            }

            Divider().overlay(.white.opacity(0.08))
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 24)
        .onAppear {
            library.refresh()
            if model.wantsNewProject { beginNaming() }
        }
        .onChange(of: model.wantsNewProject) { _, wants in if wants { beginNaming() } }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTo)
            Button("Rename") {
                if let renaming { model.renameProject(renaming.url, to: renameTo) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Projects")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if isNaming {
                HStack(spacing: 8) {
                    TextField("Project name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .focused($nameFocused)
                        .frame(width: 220)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                        .onSubmit(create)
                        .onExitCommand { isNaming = false }
                    Button("Create", action: create)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
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
                .keyboardShortcut("n")
            }
            Button("Open Comic…") { model.presentOpenPanel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Open Folder…") { model.presentOpenFolderPanel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if isOverlay {
                Button { model.showsProjects = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
        }
    }

    private func beginNaming() {
        newName = ""
        isNaming = true
        model.wantsNewProject = false
        DispatchQueue.main.async { nameFocused = true }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isNaming = false
        model.newProject(named: name)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.white.opacity(0.5))
            Text(library.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.6))
            Button("Change…") { library.chooseRoot() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Text("\(library.summaries.count) project\(library.summaries.count == 1 ? "" : "s")")
                .foregroundStyle(.white.opacity(0.5))
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
            Text("A project is a script with its citations and captures. Make one, then open the comic it's about.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Card

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
                Text(summary.comics.isEmpty ? "No comic yet" : summary.comics.joined(separator: ", "))
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
