import SwiftUI

/// The home screen: the library on one side, the projects on the other. It
/// is what's shown when nothing is open, and lies over the pages (⇧⌘O)
/// when something is.
struct HomeView: View {
    @Bindable var model: ReaderModel
    let isOverlay: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $model.homeTab) {
                    Text("Library").tag(HomeTab.library)
                    Text("Projects").tag(HomeTab.projects)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                if model.homeTab == .library {
                    Button { model.library.presentAddPanel() } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Watch a folder of comics, or a single comic (⇧⌘L)")
                }
                if isOverlay {
                    Button { model.showsHome = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 26, height: 26)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to the pages (Esc)")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().overlay(.white.opacity(0.08))

            switch model.homeTab {
            case .library:
                LibraryView(model: model)
            case .projects:
                ProjectsBrowserView(model: model, seriesFilter: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 24)
        .onAppear {
            model.projects.refresh()
            model.library.rescan()
        }
    }
}

/// A comic's first page, small, from the library's cover cache.
struct CoverView: View {
    @Bindable var model: ReaderModel
    let itemID: String?
    var placeholder: String = "book.closed"

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            } else {
                Image(systemName: placeholder)
                    .font(.system(size: 28, weight: .thin))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .task(id: itemID) {
            guard let itemID, let item = model.library.item(id: itemID) else { image = nil; return }
            image = await model.library.cover(for: item)
        }
    }
}
