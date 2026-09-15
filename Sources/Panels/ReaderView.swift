import SwiftUI
import AppKit

struct ReaderView: View {
    @Bindable var model: ReaderModel
    /// The controls panel is up. Pages dim behind it.
    @State private var showsControls = false
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
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.pressedLeftArrow(); return .handled }
        .onKeyPress(.rightArrow) { model.pressedRightArrow(); return .handled }
        .onKeyPress(.home) { model.goToStart(); return .handled }
        .onKeyPress(.end) { model.goToEnd(); return .handled }
        .onKeyPress(.escape) {
            guard showsControls else { return .ignored }
            setControls(visible: false)
            return .handled
        }
        .onKeyPress(keys: [.space], phases: .down) { press in
            // Space pages forward through the book; shift-space steps back.
            press.modifiers.contains(.shift) ? model.goBack() : model.goForward()
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
        SpreadStrip(
            model: model,
            spreadIndex: model.spreadIndex,
            direction: model.direction,
            // Swiping or zooming the pages means the reader is reading again.
            onInteraction: { setControls(visible: false) },
            onTap: { setControls(visible: !showsControls) }
        )
    }

    // MARK: - Controls

    @ViewBuilder
    private var overlays: some View {
        ZStack(alignment: .bottom) {
            if showsControls, model.hasComic {
                // Dims the pages, and a click on them puts the panel away.
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { setControls(visible: false) }
                    .transition(.opacity)

                ReaderControlsPanel(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let warning = model.warning {
                WarningBanner(text: warning)
                    .padding(.top, 12)
            }
        }
    }

    private func setControls(visible: Bool) {
        guard visible != showsControls else { return }
        withAnimation(.easeOut(duration: 0.22)) { showsControls = visible }
    }
}

// MARK: - Components

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
