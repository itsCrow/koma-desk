import SwiftUI
import ComicArchive

/// The glass panel that rises from the bottom when the reader clicks a page:
/// an overview of every page with the current spread raised, a progress bar,
/// and the reading time and position.
struct ReaderControlsPanel: View {
    @Bindable var model: ReaderModel

    private static let thumbnailHeight: CGFloat = 132
    private static let currentScale: CGFloat = 1.22

    var body: some View {
        VStack(spacing: 14) {
            overview
                .frame(height: Self.thumbnailHeight * Self.currentScale + 40)
                .overlay(alignment: .leading) { edgeArrow("chevron.left", enabled: leftEnabled) { model.pressedLeftArrow() } }
                .overlay(alignment: .trailing) { edgeArrow("chevron.right", enabled: rightEnabled) { model.pressedRightArrow() } }

            progressBar
                .padding(.horizontal, 16)

            HStack {
                Text("Time reading: \(model.readingTimeLabel)")
                Spacer()
                Text("Page: \(model.currentPageNumber) of \(model.pages.count)")
            }
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
        }
        .padding(.top, 18)
        .padding(.bottom, 20)
        .overlay(alignment: .topTrailing) {
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Full Screen")
        }
        .glassPanel(cornerRadius: 28)
    }

    // MARK: - Page overview

    private var overview: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 18) {
                    ForEach(model.spreads.indices, id: \.self) { index in
                        spreadThumbnail(at: index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 90)
                .padding(.top, 20)
            }
            .onAppear { proxy.scrollTo(model.spreadIndex, anchor: .center) }
            .onChange(of: model.spreadIndex) { _, index in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func spreadThumbnail(at index: Int) -> some View {
        let isCurrent = index == model.spreadIndex
        return Button {
            model.goTo(spread: index)
        } label: {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(model.orderedPages(forSpreadAt: index), id: \.number) { page in
                    VStack(spacing: 8) {
                        PageThumbnail(url: page.url, height: Self.thumbnailHeight)
                        Text("\(page.number)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(isCurrent ? 0.95 : 0.55))
                    }
                }
            }
            .scaleEffect(isCurrent ? Self.currentScale : 1, anchor: .bottom)
            .animation(.spring(duration: 0.3), value: isCurrent)
        }
        .buttonStyle(.plain)
    }

    private func edgeArrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.3))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: 28)
        .padding(.horizontal, 14)
        .disabled(!enabled)
    }

    /// The left arrow advances in manga order and retreats in Western order,
    /// so which arrow is live flips with the reading direction.
    private var leftEnabled: Bool {
        model.direction == .rightToLeft ? model.canGoForward : model.canGoBack
    }

    private var rightEnabled: Bool {
        model.direction == .rightToLeft ? model.canGoBack : model.canGoForward
    }

    // MARK: - Progress

    private var progressBar: some View {
        GeometryReader { geometry in
            let fraction = model.spreads.isEmpty
                ? 0 : CGFloat(model.spreadIndex + 1) / CGFloat(model.spreads.count)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Thumbnail

private struct PageThumbnail: View {
    let url: URL
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // A page-shaped placeholder holds the layout still while decoding.
                Color.white.opacity(0.12)
                    .aspectRatio(0.7, contentMode: .fit)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

// MARK: - Glass

private extension View {
    /// Liquid Glass where the system has it, the nearest material where it
    /// doesn't. Deployment target is macOS 14; the effect arrived in 26.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
