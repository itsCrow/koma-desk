import SwiftUI
import ComicArchive

/// The chapters of an open series, grouped by arc, with the one being read
/// marked. Click to jump; hide it when you just want to read.
struct ChapterSidebarView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.seriesTitle ?? "Series")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(model.chapters.count) chapters")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 4)
                Button { model.showsChapters = false } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Chapters (⌥⌘C)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(ScriptStyle.headerBackground)

            Divider().overlay(.white.opacity(0.1))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ComicFolder.grouped(model.chapters).enumerated()), id: \.offset) { _, group in
                            if let arc = group.arc {
                                Text(Self.tidy(arc))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .padding(.horizontal, 12)
                                    .padding(.top, 14)
                                    .padding(.bottom, 4)
                            }
                            ForEach(group.chapters) { chapter in
                                ChapterRow(chapter: chapter, isCurrent: chapter.url == model.currentChapter?.url) {
                                    model.openChapter(chapter)
                                }
                                .id(chapter.url)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear {
                    if let current = model.currentChapter { proxy.scrollTo(current.url, anchor: .center) }
                }
                .onChange(of: model.currentChapter?.url) { _, url in
                    if let url { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(url, anchor: .center) } }
                }
            }
        }
        .background(ScriptStyle.backgroundColor)
    }

    /// "02 Turtle School Training Arc" → "Turtle School Training Arc". The
    /// number orders the folders; it isn't part of the name.
    static func tidy(_ arc: String) -> String {
        arc.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let isCurrent: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isCurrent ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                Text(chapter.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isCurrent ? Color.accentColor.opacity(0.18) : (hovered ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
