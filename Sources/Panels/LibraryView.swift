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
        let shown = model.librarySort.sorted(library.series.filter { HomeSearch.matches(model.homeSearch, $0.name) },
                                             recent: library.index.recentSeries)
        // No page title: the covers are the page.
        return HomeScroll(header: { HomeControlsRow { controls } }) {
            VStack(alignment: .leading, spacing: 28) {
                if let missing = model.missingSeries {
                    MissingSeriesNotice(series: missing) { library.presentAddPanel() }
                }
                if shown.isEmpty {
                    ContentUnavailableView.search(text: model.homeSearch)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 24, alignment: .top)],
                              alignment: .leading, spacing: 30) {
                        ForEach(shown) { series in
                            SeriesCard(model: model, series: series) {
                                model.browsingSeries = series.name
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 2)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private var controls: some View {
        Menu {
            Picker("Sort By", selection: $model.librarySort) {
                ForEach(LibrarySort.allCases, id: \.self) { sort in
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
        .help("Sort series: \(model.librarySort.label)")
        AddMenu(model: model)
    }

    private var empty: some View {
        EmptyStateView(icon: "books.vertical", title: "Your library is empty",
                       subtitle: "Paste a link to pull in a series, or add comics you already have.") {
            if let missing = model.missingSeries {
                Text("The open project is about \(missing).")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            ImportBar(model: model)
                .padding(.top, 4)
            Button("or add a folder of comics you own…") { library.presentAddPanel() }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: 420)
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
                .buttonStyle(PrimaryButtonStyle())
        }
        .foregroundStyle(.white)
        .padding(14)
        .glassPanel(cornerRadius: Radius.medium)
    }
}

/// A series as its cover, standing on its own the way a book does on a
/// shelf — no card around it — with its name and size underneath, and
/// where the reader is up to on the cover once it's been started.
private struct SeriesCard: View {
    @Bindable var model: ReaderModel
    let series: Series
    let open: () -> Void
    @State private var hovered = false

    /// "Ch. 931", for a series that's been started.
    private var upTo: String? {
        guard model.library.index.lastRead[series.name] != nil,
              let item = model.library.continueItem(in: series) else { return nil }
        return item.label
    }

    var body: some View {
        let isOpen = model.series?.name == series.name
        let fromALink = model.library.isRemoteSeries(series)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                CoverView(model: model, itemID: series.items.first?.id, fill: true)
                    .frame(height: 270)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                    .overlay(alignment: .bottomTrailing) {
                        if let upTo {
                            Text(upTo)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Palette.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassCapsule()
                                .padding(8)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Radius.medium)
                        .strokeBorder(isOpen ? Palette.accent : Color.white.opacity(0.08), lineWidth: isOpen ? 1.5 : 1))
                    .shadow(color: .black.opacity(hovered ? 0.55 : 0.35), radius: hovered ? 16 : 10, y: hovered ? 10 : 4)
                    .scaleEffect(hovered ? 1.04 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(series.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        if let progress = model.library.remoteDownloadProgress[series.name] {
                            DownloadProgressBadge(progress: progress)
                        }
                    }
                    Text(series.summary)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                    RemoteRefreshStatus(model: model, seriesName: series.name)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .contextMenu {
            Button("Read") { model.read(series) }
            Button("New Project…") { model.requestNewProject(series: series.name) }
            if fromALink {
                Divider()
                Button("Update") {
                    Task { await model.checkForNewChapters(named: series.name) }
                }
                .disabled(model.library.isCheckingForChapters(series.name))
                Divider()
                Button("Remove Series", role: .destructive) {
                    if model.series?.name == series.name { model.closeComicToHome() }
                    model.library.removeRemoteSeries(series)
                }
            }
        }
    }
}

/// Under a series' name: "Checking…", "2 new chapters", "Up to date", or why
/// a check failed. Absent when there's nothing to say.
struct RemoteRefreshStatus: View {
    @Bindable var model: ReaderModel
    let seriesName: String
    var topPadding: CGFloat = 0
    /// The series page says "Updating" on the button itself. The shelf has
    /// no button, so it still needs this line.
    var showsActivity: Bool = true

    var body: some View {
        if showsActivity, model.library.isCheckingForChapters(seriesName) {
            status("Updating…", color: Palette.textTertiary, lines: 1)
        } else if !model.library.isCheckingForChapters(seriesName),
                  let notice = model.library.remoteRefreshNotice[seriesName] {
            status(notice.message, color: color(for: notice.kind), lines: 2)
        }
    }

    private func status(_ message: String, color: Color, lines: Int) -> some View {
        Text(message)
            .font(Typography.caption)
            .foregroundStyle(color)
            .lineLimit(lines)
            .padding(.top, topPadding)
    }

    private func color(for kind: RemoteRefreshNotice.Kind) -> Color {
        switch kind {
        case .newChapters: return Palette.noteColor
        case .upToDate: return Palette.textTertiary
        case .failed: return Palette.pageRangeColor
        }
    }
}

/// Right-click on a chapter that came from a link. A folder of files you
/// already have has nothing to redownload, so it doesn't grow an empty menu.
struct RedownloadChapterMenu: ViewModifier {
    var enabled: Bool
    var isBusy: Bool = false
    let redownload: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button("Redownload Chapter", action: redownload)
                    .disabled(isBusy)
            }
        } else {
            content
        }
    }
}

/// Next to a series' name while its chapters are prefetching: a sliver of a
/// bar and a count while it runs, a checkmark for a moment once every
/// chapter has settled — proof the whole series downloaded, not just the
/// one chapter someone happened to open.
struct DownloadProgressBadge: View {
    let progress: Library.DownloadProgress

    var body: some View {
        if progress.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .help("Every chapter downloaded")
        } else {
            HStack(spacing: 4) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 40)
                Text("\(progress.done)/\(progress.total)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
            }
            .help("Downloading chapters — \(progress.done) of \(progress.total) so far")
        }
    }
}

/// A link to pull a series in from the web — inline when the library is
/// empty and it's the way in, and in `ImportLinkSheet` otherwise.
struct ImportBar: View {
    @Bindable var model: ReaderModel
    @State private var urlString = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.35))
            TextField("Paste a link to import a series", text: $urlString)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .disabled(model.isAddingRemoteSource)
                .onSubmit(submit)
            if model.isAddingRemoteSource {
                ProgressView()
                    .controlSize(.small)
            } else if !urlString.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add", action: submit)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassPanel(cornerRadius: Radius.large)
        .frame(maxWidth: 640)
        .onAppear { focused = true }
    }

    private func submit() {
        let value = urlString.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !model.isAddingRemoteSource else { return }
        Task {
            await model.addRemoteSource(urlString: value)
            if model.errorMessage == nil { urlString = "" }
        }
    }
}

/// "Import from Link…": the import bar on its own, with a word on what it
/// takes. Closes itself once a series has come in.
struct ImportLinkSheet: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Link")
                .font(.headline)
            Text("Paste a link to a series or one of its chapters. It’s added to your library, and its chapters download in the background.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ImportBar(model: model)
            HStack {
                Spacer()
                Button("Cancel") { model.isImportingLink = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Bringing comics in — from a link or a folder — plus, once there's
/// something watched, the management that goes with it (revealing or
/// removing a folder, rescanning).
private struct AddMenu: View {
    @Bindable var model: ReaderModel

    var body: some View {
        Menu {
            Button("Import from Link…") { model.isImportingLink = true }
            Button("Add Comics Folder…") { model.library.presentAddPanel() }
            if !model.library.roots.isEmpty {
                Divider()
                ForEach(model.library.roots, id: \.self) { root in
                    Menu(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                        Button("Remove from Library", role: .destructive) { model.library.removeRoot(root) }
                    }
                }
                Divider()
                Button("Rescan") { model.library.rescan() }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .glassButtonStyle()
        .fixedSize()
        .help("Add comics to your library")
    }
}
