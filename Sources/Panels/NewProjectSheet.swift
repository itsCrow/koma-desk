import SwiftUI

/// "New Project…": a small dialog over whatever's on screen — the reader,
/// the library, anywhere — rather than a trip to the projects list. Title,
/// the series it's about (defaulting to whatever's open), and a target word
/// count to write toward.
struct NewProjectSheet: View {
    @Bindable var model: ReaderModel

    @State private var name = ""
    @State private var seriesName = ""
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
                Picker("", selection: $seriesName) {
                    if seriesName.isEmpty {
                        Text("None").tag("")
                    }
                    ForEach(model.library.series) { series in
                        Text(series.name).tag(series.name)
                    }
                }
                .labelsHidden()
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || seriesName.isEmpty)
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
        seriesName = model.newProjectSeriesOverride
            ?? model.series?.name
            ?? model.browsingSeries
            ?? model.project?.manifest.series
            ?? model.library.series.first?.name
            ?? ""
        model.newProjectSeriesOverride = nil
        DispatchQueue.main.async { nameFocused = true }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !seriesName.isEmpty else { return }
        let target = Int(targetWordCountText.trimmingCharacters(in: .whitespaces))
        model.wantsNewProject = false
        model.newProject(named: trimmedName, series: seriesName, targetWordCount: target)
    }
}
