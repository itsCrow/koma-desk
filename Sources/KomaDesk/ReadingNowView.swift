import SwiftUI
import ComicLibrary

/// What's currently being read: the last thing read as a hero to pick
/// straight back up, and everything else in a shelf underneath — most
/// recently read first.
struct ReadingNowView: View {
    @Bindable var model: ReaderModel

    private var library: Library { model.library }

    private var entries: [(series: Series, item: LibraryItem)] {
        library.recentlyRead.filter { HomeSearch.matches(model.homeSearch, $0.series.name, $0.item.displayName) }
    }

    var body: some View {
        if library.recentlyRead.isEmpty {
            EmptyStateView(icon: "book", title: "Nothing read yet",
                           subtitle: "Whatever you open next shows up here.")
        } else {
            let entries = entries
            // No page title: the hero's "Continue Reading" says it.
            HomeScroll(header: { EmptyView() }) {
                if let first = entries.first {
                    VStack(alignment: .leading, spacing: 34) {
                        ReadingHero(model: model, series: first.series, item: first.item)
                        if entries.count > 1 {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionHeading("Also Reading", count: entries.count - 1)
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 20) {
                                        ForEach(entries.dropFirst(), id: \.item.id) { entry in
                                            ReadingCard(model: model, series: entry.series, item: entry.item)
                                                .frame(width: 160)
                                        }
                                    }
                                    // Room for a lifted card's shadow, which
                                    // a horizontal scroll view would clip.
                                    .padding(.vertical, 16)
                                    .padding(.horizontal, 28)
                                }
                                .scrollIndicators(.hidden)
                                .padding(.horizontal, -28)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 28)
                } else {
                    ContentUnavailableView.search(text: model.homeSearch)
                        .padding(.top, 80)
                }
            }
        }
    }
}

/// The thing read last, big: its cover, where it's up to, and one button
/// to carry on.
private struct ReadingHero: View {
    @Bindable var model: ReaderModel
    let series: Series
    let item: LibraryItem
    @State private var hovered = false

    private var progress: Double? { model.library.progress(for: item) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 30) {
            Button(action: resume) {
                CoverView(model: model, itemID: item.id, fill: true)
                    .frame(width: 250, height: 370)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                    .overlay(RoundedRectangle(cornerRadius: Radius.large)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(hovered ? 0.6 : 0.45), radius: hovered ? 28 : 20, y: hovered ? 16 : 10)
                    .scaleEffect(hovered ? 1.02 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }

            VStack(alignment: .leading, spacing: 10) {
                Text("Continue Reading")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Text(series.name)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Text(item.displayName)
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    ProgressRing(fraction: progress ?? 0)
                        .frame(width: 18, height: 18)
                    Text(progress.map { "\(Int(($0 * 100).rounded()))% read" } ?? "Not started")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.top, 4)
                Button(action: resume) {
                    Label(progress.map { $0 > 0 } == true ? "Resume" : "Start Reading", systemImage: "play.fill")
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.large)
                .padding(.top, 10)
            }
            .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func resume() {
        model.showsHome = false
        model.open(item: item)
    }
}

/// A smaller cover for the shelf: the cover itself, with how far along as a
/// glass pill on it, and the name underneath the way Books shelves a title.
private struct ReadingCard: View {
    @Bindable var model: ReaderModel
    let series: Series
    let item: LibraryItem
    @State private var hovered = false

    var body: some View {
        Button { model.showsHome = false; model.open(item: item) } label: {
            VStack(alignment: .leading, spacing: 8) {
                CoverView(model: model, itemID: item.id, fill: true)
                    .frame(height: 236)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                    .overlay(alignment: .bottomTrailing) {
                        if let progress = model.library.progress(for: item) {
                            ProgressPill(fraction: progress)
                                .padding(8)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Radius.medium)
                        .strokeBorder(item.id == model.item?.id ? Palette.accent : Color.white.opacity(0.08),
                                      lineWidth: item.id == model.item?.id ? 1.5 : 1))
                    .shadow(color: .black.opacity(hovered ? 0.55 : 0.35), radius: hovered ? 16 : 10, y: hovered ? 10 : 4)
                    .scaleEffect(hovered ? 1.04 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(item.displayName)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// How far along, as a small glass capsule on a cover: "62%".
struct ProgressPill: View {
    let fraction: Double

    var body: some View {
        Text("\(Int((fraction * 100).rounded()))%")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassCapsule()
    }
}

/// How far along, as a ring filling clockwise — reading through a chapter,
/// or writing toward a word goal. Full, not overflowing, once it's there.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Palette.textPrimary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}
