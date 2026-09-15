import SwiftUI
import AppKit

struct ReaderView: View {
    @Bindable var model: ReaderModel
    @State private var chromeVisible = true
    @State private var chromeTimer: Task<Void, Never>?
    @State private var isDropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.hasComic {
                spread
            } else {
                EmptyStateView { model.presentOpenPanel() }
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            overlays
        }
        .frame(minWidth: 640, minHeight: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; scheduleChromeHide() }
        .onContinuousHover { phase in
            if case .active = phase { revealChrome() }
        }
        .onKeyPress(.leftArrow) { model.pressedLeftArrow(); revealChrome(); return .handled }
        .onKeyPress(.rightArrow) { model.pressedRightArrow(); revealChrome(); return .handled }
        .onKeyPress(.home) { model.goToStart(); revealChrome(); return .handled }
        .onKeyPress(.end) { model.goToEnd(); revealChrome(); return .handled }
        .onKeyPress(keys: [.space], phases: .down) { press in
            // Space pages forward through the book; shift-space steps back.
            press.modifiers.contains(.shift) ? model.goBack() : model.goForward()
            revealChrome()
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: {
                ReaderModel.supportedExtensions.contains($0.pathExtension.lowercased())
            }) else { return false }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .padding(8)
            }
        }
        .alert(
            "Can’t open this comic",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Pages

    private var spread: some View {
        HStack(spacing: 0) {
            ForEach(model.visiblePages, id: \.number) { page in
                PageImageView(url: page.url, loader: model)
            }
        }
        .padding(8)
        // Without this the two pages cross-fade into each other on every turn.
        .id(model.spreadIndex)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.12), value: model.spreadIndex)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var overlays: some View {
        VStack {
            if let warning = model.warning {
                WarningBanner(text: warning)
                    .padding(.top, 12)
            }
            Spacer()
            if model.hasComic {
                HStack(spacing: 16) {
                    NavigationArrow(systemName: "chevron.left", enabled: leftArrowEnabled) {
                        model.pressedLeftArrow()
                    }
                    Text(model.positionLabel)
                        .font(.system(.callout, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 110)
                    NavigationArrow(systemName: "chevron.right", enabled: rightArrowEnabled) {
                        model.pressedRightArrow()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.black.opacity(0.65), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .padding(.bottom, 20)
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: chromeVisible)
            }
        }
        .allowsHitTesting(chromeVisible)
    }

    /// The left arrow advances in manga order and retreats in Western order, so
    /// which arrow is available flips with the reading direction.
    private var leftArrowEnabled: Bool {
        model.direction == .rightToLeft ? model.canGoForward : model.canGoBack
    }

    private var rightArrowEnabled: Bool {
        model.direction == .rightToLeft ? model.canGoBack : model.canGoForward
    }

    private func revealChrome() {
        chromeVisible = true
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeTimer?.cancel()
        chromeTimer = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }
}

// MARK: - Components

/// Loads a single page asynchronously so a slow decode never blocks a page turn.
private struct PageImageView: View {
    let url: URL
    let loader: ReaderModel
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.black
                    .overlay(ProgressView().controlSize(.small).tint(.white))
            }
        }
        .task(id: url) {
            let loaded = await loader.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private struct NavigationArrow: View {
    let systemName: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.25))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct WarningBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.9), in: Capsule())
    }
}

private struct EmptyStateView: View {
    let openAction: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.white.opacity(0.5))
            Text("Open a comic to start reading")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
            Text("Drag a .cbr, .cbz or .cb7 file here")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.4))
            Button("Open Comic…", action: openAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
    }
}
