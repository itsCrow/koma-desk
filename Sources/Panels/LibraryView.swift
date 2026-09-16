import SwiftUI
import ComicLibrary

/// The library half of home: what there is to read, and where to pick up.
struct LibraryView: View {
    @Bindable var model: ReaderModel

    private var library: Library { model.library }

    var body: some View {
        if let name = model.browsingSeries, let series = library.series(named: name) {
            SeriesView(model: model, series: series)
        } else if library.isEmpty {
            empty
        } else {
            shelves
        }
    }

    // MARK: - Shelves

    private var shelves: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let missing = model.missingSeries {
                        MissingSeriesNotice(series: missing) { library.presentAddPanel() }
                    }
                    if !library.recentlyRead.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            heading("Continue reading")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(library.recentlyRead, id: \.item.id) { entry in
                                        ContinueCard(model: model, series: entry.series, item: entry.item)
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Series")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16, alignment: .top)],
                                  alignment: .leading, spacing: 18) {
                            ForEach(library.series) { series in
                                SeriesCard(model: model, series: series) {
                                    model.browsingSeries = series.name
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }
            Divider().overlay(.white.opacity(0.08))
            FoldersFooter(model: model)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .textCase(.uppercase)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.white.opacity(0.45))
            Text("Your library is empty")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("Add a folder of comics and it's read where it is — nothing is copied. Volumes, arcs and chapters are worked out from the file names.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let missing = model.missingSeries {
                Text("The open project is about \(missing).")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button { library.presentAddPanel() } label: {
                Label("Add Folder to Library…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)
            Text("or drop a folder or a .cbz / .cbr file on the window")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

/// The open project's series isn't here — the editor's Mac, before they've
/// added the folder.
struct MissingSeriesNotice: View {
    let series: String
    let add: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("This project is about \(series), which isn’t in your library")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add the folder holding its comics. They have to be the same files — a different release has different pages.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button("Add Folder…", action: add)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ContinueCard: View {
    @Bindable var model: ReaderModel
    let series: Series
    let item: LibraryItem
    @State private var hovered = false

    var body: some View {
        Button { model.showsHome = false; model.open(item: item) } label: {
            HStack(spacing: 10) {
                CoverView(model: model, itemID: item.id)
                    .frame(width: 54, height: 76)
                VStack(alignment: .leading, spacing: 3) {
                    Text(series.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    let spread = model.library.position(for: item)
                    Text(spread > 0 ? "spread \(spread + 1)" : "from the start")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(width: 150, alignment: .leading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovered ? 0.1 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct SeriesCard: View {
    @Bindable var model: ReaderModel
    let series: Series
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                CoverView(model: model, itemID: series.items.first?.id)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                Text(series.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(series.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovered ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(model.series?.name == series.name ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Read") { model.read(series) }
            Button("New Project…") { model.browsingSeries = series.name; model.wantsNewProject = true }
        }
    }
}

/// The folders being watched, with a way to stop watching one.
struct FoldersFooter: View {
    @Bindable var model: ReaderModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.white.opacity(0.5))
            Menu {
                ForEach(model.library.roots, id: \.self) { root in
                    Menu(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                        Button("Remove from Library", role: .destructive) { model.library.removeRoot(root) }
                    }
                }
                Divider()
                Button("Add Folder…") { model.library.presentAddPanel() }
                Button("Rescan") { model.library.rescan() }
            } label: {
                let count = model.library.roots.count
                Text("\(count) folder\(count == 1 ? "" : "s") watched")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            let series = model.library.series.count
            Text("\(series) series · \(model.library.series.reduce(0) { $0 + $1.items.count }) items")
                .foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 12))
    }
}
