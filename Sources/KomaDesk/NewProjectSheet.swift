import SwiftUI

/// "New Project…": a small dialog over whatever's on screen — the reader,
/// the library, anywhere — rather than a trip to the projects list. Title,
/// the series it's about (defaulting to whatever's open), and a target word
/// count to write toward.
struct NewProjectSheet: View {
    @Bindable var model: ReaderModel

    @State private var name = ""
    @State private var chosenSeries: [String] = []
    @State private var targetWordCountText = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.system(size: 15, weight: .semibold))

            field("Title") {
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
            }

            field("Series") {
                SeriesChecklist(names: model.library.series.map(\.name), chosen: $chosenSeries)
            }

            field("Target Word Count") {
                TextField("Optional — a goal to write toward", text: $targetWordCountText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.wantsNewProject = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosenSeries.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: setUp)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func setUp() {
        name = ""
        targetWordCountText = ""
        // A caller that already knows which series it means (a series' own
        // page) wins outright; otherwise fall back to whatever's already
        // open. A library with nothing in it yet leaves this blank — there's
        // no series to pick.
        if let single = model.newProjectSeriesOverride ?? model.series?.name ?? model.browsingSeries {
            chosenSeries = [single]
        } else if let open = model.project?.manifest.series, !open.isEmpty {
            chosenSeries = open
        } else {
            chosenSeries = model.library.series.first.map { [$0.name] } ?? []
        }
        model.newProjectSeriesOverride = nil
        DispatchQueue.main.async { nameFocused = true }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !chosenSeries.isEmpty else { return }
        let target = Int(targetWordCountText.trimmingCharacters(in: .whitespaces))
        model.wantsNewProject = false
        model.newProject(named: trimmedName, series: chosenSeries, targetWordCount: target)
    }
}

/// "Add Series to Project…": the library's series the open project isn't
/// about yet, to tick and add.
struct AddSeriesSheet: View {
    @Bindable var model: ReaderModel
    @State private var chosenSeries: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Series to Project")
                .font(.system(size: 15, weight: .semibold))

            let available = model.seriesNotInProject.map(\.name)
            if available.isEmpty {
                Text("Every series in your library is already in this project.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                SeriesChecklist(names: available, chosen: $chosenSeries)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.wantsAddSeries = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    for name in chosenSeries { model.addSeriesToProject(name) }
                    model.wantsAddSeries = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(chosenSeries.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { chosenSeries = [] }
    }
}

/// A scrolling list of series with a checkbox each. `chosen` keeps the
/// order they were ticked in, which is the order they join the project.
private struct SeriesChecklist: View {
    let names: [String]
    @Binding var chosen: [String]

    var body: some View {
        if names.isEmpty {
            Text("Your library has no series yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        Toggle(name, isOn: binding(for: name))
                            .toggleStyle(.checkbox)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 160)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(name) },
            set: { isOn in
                if isOn, !chosen.contains(name) { chosen.append(name) }
                if !isOn { chosen.removeAll { $0 == name } }
            }
        )
    }
}
