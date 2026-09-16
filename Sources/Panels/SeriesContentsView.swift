import SwiftUI
import ComicLibrary

/// The series being read, beside the pages: its volumes, or its arcs and
/// their chapters, with the one on screen marked. A click opens another.
struct SeriesContentsView: View {
    @Bindable var model: ReaderModel
    let series: Series

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { model.showSeriesPage() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Back to the series")
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
                        ForEach(Array(series.arcs.enumerated()), id: \.offset) { _, group in
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
                                            hasStarted: model.library.hasStarted(item)) {
                                    model.openItem(item)
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
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(item.label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.85))
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
                        .foregroundStyle(Color.accentColor)
                } else if hasStarted {
                    Circle().fill(.white.opacity(0.35)).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isCurrent ? Color.accentColor.opacity(0.14) : (hovered ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
