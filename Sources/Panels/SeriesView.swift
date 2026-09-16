import SwiftUI
import ComicLibrary

/// One series: what there is of it, how far it's been read, and the
/// projects about it.
struct SeriesView: View {
    @Bindable var model: ReaderModel
    let series: Series

    @State private var newName = ""
    @State private var isNaming = false
    @FocusState private var nameFocused: Bool

    private var projects: [ProjectSummary] {
        model.projects.summaries
            .filter { $0.series == series.name }
            .sorted { ($0.edited ?? .distantPast) > ($1.edited ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                contents
                projectsSection
            }
            .padding(22)
        }
        .onAppear { if model.wantsNewProject { beginNaming() } }
        .onChange(of: model.wantsNewProject) { _, wants in if wants { beginNaming() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            CoverView(model: model, itemID: series.items.first?.id)
                .frame(width: 130, height: 180)
            VStack(alignment: .leading, spacing: 8) {
                Button { model.browsingSeries = nil } label: {
                    Label("Library", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                Text(series.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text(series.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    let pickUp = model.library.continueItem(in: series)
                    let started = pickUp.map { model.library.hasStarted($0) || model.library.index.lastRead[series.name] != nil } ?? false
                    Button { model.read(series) } label: {
                        Label(started ? "Continue" : "Read", systemImage: "book")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pickUp == nil)
                    if started, let pickUp {
                        Text(pickUp.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Contents

    private var contents: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(series.arcs.enumerated()), id: \.offset) { _, group in
                if let name = group.name {
                    sectionHeading(name).padding(.top, 8)
                } else if !series.hasArcs {
                    sectionHeading("Volumes")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 4) {
                    ForEach(group.items) { item in
                        ItemRow(model: model, item: item)
                    }
                }
            }
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .textCase(.uppercase)
    }

    // MARK: - Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                sectionHeading("Projects")
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if projects.isEmpty {
                Text("No scripts about \(series.name) yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProjectsGrid(model: model, projects: projects)
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
        model.newProject(named: name, series: series.name)
    }
}

/// One volume or chapter in the series' list, with how far it's been read.
private struct ItemRow: View {
    @Bindable var model: ReaderModel
    let item: LibraryItem
    @State private var hovered = false

    var body: some View {
        Button { model.showsHome = false; model.open(item: item) } label: {
            HStack(spacing: 10) {
                Text(item.label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(item.id == model.item?.id ? Color.accentColor : .white.opacity(0.9))
                    .frame(minWidth: 48, alignment: .leading)
                if item.chapter != nil, !item.title.isEmpty, item.title != item.label {
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                let spread = model.library.position(for: item)
                if spread > 0 {
                    Text("spread \(spread + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovered ? 0.1 : 0.04)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
