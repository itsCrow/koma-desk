import SwiftUI
import PanelsProject

/// The script pane: the writing, or the list of shots it adds up to.
struct ScriptPaneView: View {
    @Bindable var model: ReaderModel
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                projectMenu
                Spacer(minLength: 6)
                if model.showsShotList {
                    Text("\(project.citationsInScriptOrder.count) shots")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: 2) {
                    tab("Script", shots: false)
                    tab("Shots", shots: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ScriptStyle.headerBackground)

            Divider().overlay(.white.opacity(0.1))

            ZStack {
                // Both stay alive so switching doesn't reload the editor and
                // lose the cursor.
                ScriptEditorView(project: project, model: model)
                    .opacity(model.showsShotList ? 0 : 1)
                    .allowsHitTesting(!model.showsShotList)
                if model.showsShotList {
                    ShotListView(model: model, project: project)
                }
            }
        }
    }

    /// The project's name, and a way to any other.
    private var projectMenu: some View {
        Menu {
            ForEach(model.projects.groupedBySeries, id: \.series) { group in
                Section(group.series) {
                    ForEach(group.projects) { summary in
                        Button {
                            model.switchTo(summary.url)
                        } label: {
                            if summary.url == project.url {
                                Label(summary.name, systemImage: "checkmark")
                            } else {
                                Text(summary.name)
                            }
                        }
                        .disabled(summary.url == project.url)
                    }
                }
            }
            Divider()
            Button("New Project…") { model.requestNewProject() }
            Button("All Projects…") { model.homeTab = .projects; model.showsHome = true }
        } label: {
            HStack(spacing: 5) {
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch project")
    }

    private func tab(_ title: String, shots: Bool) -> some View {
        let selected = model.showsShotList == shots
        return Button {
            model.showsShotList = shots
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? Color.white.opacity(0.9) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
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
                ForEach(Array(shots.enumerated()), id: \.element.id) { index, citation in
                    ShotRow(
                        number: index + 1,
                        citation: citation,
                        context: project.context(of: citation.id),
                        image: project.captureURL(for: citation)
                    ) {
                        model.revealShot(citation)
                    }
                    Divider().overlay(.white.opacity(0.07))
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
                            Text(citation.text)
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
}

private struct ShotRow: View {
    let number: Int
    let citation: Citation
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
                    Text(citation.text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
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
