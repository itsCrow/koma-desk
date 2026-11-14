import SwiftUI
import ComicLibrary

/// One series: where the reader is up to in it, the projects about it, and
/// everything there is of it, with what's been read marked.
struct SeriesView: View {
    @Bindable var model: ReaderModel
    let series: Series

    private var projects: [ProjectSummary] {
        ProjectsSort.recent.sorted(model.projects.summaries.filter { $0.series.contains(series.name) }, words: [:])
    }

    var body: some View {
        HomeScroll(header: {
            HomeControlsRow {
                Button { model.browsingSeries = nil } label: {
                    Label("Library", systemImage: "chevron.left")
                }
                .glassButtonStyle()
            } trailing: {
                EmptyView()
            }
        }) {
            VStack(alignment: .leading, spacing: 36) {
                SeriesHero(model: model, series: series)
                if !projects.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading("Projects", count: projects.count)
                        ProjectsRow(model: model, projects: projects, seriesName: series.name)
                    }
                }
                contents
            }
            .padding(.horizontal, 28)
            .padding(.top, 2)
            .padding(.bottom, 28)
        }
        .onAppear {
            let opened = series
            Task { await model.refreshSeriesIfStale(opened) }
        }
    }

    // MARK: - Contents

    /// One section per arc, each listing its chapters the same way a plain
    /// series (no arcs at all) lists its own — a folder is just another
    /// section, not a separate screen to drill into. A series with no arcs
    /// gets a single "Chapters" or "Volumes" heading over the lot.
    private var contents: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(Array(series.arcs.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(sectionName(for: group), count: group.items.count)
                    itemList(group.items)
                }
            }
        }
    }

    private func sectionName(for group: (name: String?, items: [LibraryItem])) -> String {
        if series.hasArcs, let name = group.name { return name }
        return series.chapterCount > 0 ? "Chapters" : (series.volumeCount > 0 ? "Volumes" : "Contents")
    }

    private func itemList(_ items: [LibraryItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 8, alignment: .top)],
                  alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                ItemRow(model: model, item: item)
            }
        }
    }
}

// MARK: - Hero

/// The series, big: its cover, how far through the whole of it the reader
/// is, and the button to carry on — or start.
private struct SeriesHero: View {
    @Bindable var model: ReaderModel
    let series: Series
    @State private var hovered = false

    var body: some View {
        let library = model.library
        let pickUp = library.continueItem(in: series)
        let progress = library.seriesProgress(series)
        HStack(alignment: .bottom, spacing: 30) {
            Button { model.read(series) } label: {
                CoverView(model: model, itemID: series.items.first?.id, fill: true)
                    .frame(width: 200, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                    .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(hovered ? 0.6 : 0.45), radius: hovered ? 28 : 20, y: hovered ? 16 : 10)
                    .scaleEffect(hovered ? 1.02 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .disabled(pickUp == nil)

            VStack(alignment: .leading, spacing: 0) {
                Text(series.name)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Text(series.summary)
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, 4)
                if let download = model.library.remoteDownloadProgress[series.name] {
                    DownloadProgressBadge(progress: download)
                        .padding(.top, 8)
                }

                SeriesActions(model: model, series: series, canRead: pickUp != nil, hasProgress: progress != nil)
                    .padding(.top, 22)
            }
            .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
    }
}

/// Continue is the one thing this page is for. New Project and Update sit
/// under it, smaller, so they read as other things you can do — not as
/// three equal buttons.
private struct SeriesActions: View {
    @Bindable var model: ReaderModel
    let series: Series
    let canRead: Bool
    let hasProgress: Bool

    private var checking: Bool { model.library.isCheckingForChapters(series.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.read(series) } label: {
                Label(hasProgress ? "Continue" : "Start Reading", systemImage: "play.fill")
                    .frame(minWidth: 132, alignment: .center)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.large)
            .disabled(!canRead)

            HStack(alignment: .center, spacing: 2) {
                Button { model.requestNewProject(series: series.name) } label: {
                    Label("New Project", systemImage: "square.and.pencil")
                }
                .buttonStyle(QuietButtonStyle())

                if model.library.isRemoteSeries(series) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)

                    Button {
                        Task { await model.checkForNewChapters(named: series.name) }
                    } label: {
                        if checking {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating")
                            }
                        } else {
                            Label("Update", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(checking)
                    .help("Check this series for new chapters")

                    RemoteRefreshStatus(model: model, seriesName: series.name, showsActivity: false)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Items

/// Where the reader stands with one volume or chapter.
enum ItemReadState: Equatable {
    case unread
    case reading(Double)
    case read

    /// Near enough the end counts as read: the last spread is rarely the
    /// exact final position, and a credits page shouldn't leave it "unread".
    static func of(progress: Double?, started: Bool) -> ItemReadState {
        if let progress, progress >= 0.95 { return .read }
        if started { return .reading(progress ?? 0) }
        return .unread
    }
}

/// One volume or chapter in the series' list: whether it's been read, its
/// number, its title.
private struct ItemRow: View {
    @Bindable var model: ReaderModel
    let item: LibraryItem
    @State private var hovered = false

    var body: some View {
        let isOpen = item.id == model.item?.id
        let state = ItemReadState.of(progress: model.library.progress(for: item), started: model.library.hasStarted(item))
        Button { model.showsHome = false; model.open(item: item) } label: {
            HStack(spacing: 10) {
                mark(for: state)
                    .frame(width: 14, height: 14)
                Text(item.label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isOpen ? Palette.textPrimary : (state == .read ? Palette.textTertiary : Palette.textSecondary))
                    .frame(minWidth: 48, alignment: .leading)
                if item.chapter != nil, !item.title.isEmpty, item.title != item.label {
                    Text(item.title)
                        .font(Typography.caption)
                        .foregroundStyle(state == .read ? Palette.textTertiary : Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isOpen ? Palette.surfaceSelected : (hovered ? Palette.surfaceHover : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.small))
            .contentShape(RoundedRectangle(cornerRadius: Radius.small))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .modifier(RedownloadChapterMenu(
            enabled: model.library.isRemoteItem(item),
            isBusy: model.isLoading && model.item?.id == item.id
        ) {
            model.redownloadChapter(item)
        })
    }

    @ViewBuilder
    private func mark(for state: ItemReadState) -> some View {
        switch state {
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary)
        case .reading(let fraction):
            ProgressRing(fraction: fraction, lineWidth: 2)
        case .unread:
            Image(systemName: "circle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary.opacity(0.5))
        }
    }
}
