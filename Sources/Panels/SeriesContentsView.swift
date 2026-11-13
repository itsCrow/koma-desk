import SwiftUI
import ComicLibrary

/// The series being read, beside the pages: its volumes, or its arcs and
/// their chapters, with the one on screen marked. A click opens another.
struct SeriesContentsView: View {
    @Bindable var model: ReaderModel
    let series: Series

    /// Reading order by default; reversed shows the newest arc and its
    /// newest item first, each arc's own items reversed right along with
    /// it, so the list reads top-to-bottom the same way either direction.
    @State private var isReversed = false

    private var displayedArcs: [(name: String?, items: [LibraryItem])] {
        guard isReversed else { return series.arcs }
        return series.arcs.reversed().map { (name: $0.name, items: $0.items.reversed()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { model.closeComicToHome() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close the comic")
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(series.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button { isReversed.toggle() } label: {
                    Image(systemName: isReversed ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(isReversed ? "Showing newest first — click for oldest first" : "Showing oldest first — click for newest first")
                Button { model.showsContents = false } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Hide the contents (⌥⌘C)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(.white.opacity(0.1))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(displayedArcs.enumerated()), id: \.offset) { _, group in
                            Text(group.name ?? (series.hasArcs ? "" : "Volumes"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .textCase(.uppercase)
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .opacity((group.name ?? (series.hasArcs ? "" : "Volumes")).isEmpty ? 0 : 1)
                                .frame(height: (group.name ?? (series.hasArcs ? "" : "Volumes")).isEmpty ? 6 : nil)
                            ForEach(group.items) { item in
                                ContentsRow(item: item,
                                            isCurrent: item.id == model.item?.id,
                                            hasStarted: model.library.hasStarted(item),
                                            canRedownload: model.library.isRemoteItem(item)) {
                                    model.openItem(item)
                                } redownload: {
                                    model.redownloadChapter(item)
                                }
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onAppear {
                    if let current = model.item { proxy.scrollTo(current.id, anchor: .center) }
                }
                .onChange(of: model.item?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .background(Color(white: 0.08))
    }
}

private struct ContentsRow: View {
    let item: LibraryItem
    let isCurrent: Bool
    let hasStarted: Bool
    var canRedownload = false
    let open: () -> Void
    var redownload: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(item.label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Palette.textPrimary : .white.opacity(0.85))
                    .frame(minWidth: 44, alignment: .leading)
                if item.chapter != nil, !item.title.isEmpty, item.title != item.label {
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(isCurrent ? 0.95 : 0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "book.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textPrimary)
                } else if hasStarted {
                    Circle().fill(.white.opacity(0.35)).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isCurrent ? Palette.surfaceSelected : (hovered ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .modifier(RedownloadChapterMenu(enabled: canRedownload, redownload: redownload))
    }
}

// MARK: - The tab that brings it back

/// Fills the very corner of the page area, its outer edge cut away on the
/// diagonal so it reads as something tucked behind the page rather than a
/// button sitting on top of it.
struct CornerTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// With the contents hidden there is nothing on screen saying they exist, and
/// ⌥⌘C is not discoverable. This is the way back.
struct ContentsTab: View {
    let show: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: show) {
            ZStack(alignment: .topLeading) {
                CornerTabShape()
                    .fill(Color(white: hovered ? 0.22 : 0.14))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(hovered ? 1 : 0.7))
                    .padding(.leading, 10)
                    .padding(.top, 10)
            }
            .frame(width: 54, height: 54)
            // Only the triangle takes the click; the page keeps the rest.
            .contentShape(CornerTabShape())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show the contents (⌥⌘C)")
    }
}
