import SwiftUI
import ComicLibrary
import PanelsProject

/// "Link to Page…" waiting on an answer: the writing it's for, or the range
/// whose pages are being changed, and what the sheet starts out showing.
struct LinkPagesRequest: Identifiable {
    let id = UUID()
    /// The selection when the writer asked — a sheet stands between asking
    /// and answering, and the selection can't be trusted to survive it.
    let selection: NSRange?
    /// Set when changing an existing range's pages rather than making one.
    let changingSpanID: String?
    let itemID: String?
    /// "42–45", as the field starts out.
    let pages: String
}

/// Which comic and which pages a block of writing is about, for when they
/// aren't the ones on screen.
struct LinkPagesSheet: View {
    let model: ReaderModel
    let request: LinkPagesRequest

    @State private var itemID: String?
    @State private var pagesText = ""
    @FocusState private var pagesFocused: Bool

    private var candidates: [LibraryItem] { model.linkCandidates }

    private var chosenItem: LibraryItem? {
        itemID.flatMap { id in candidates.first { $0.id == id } }
    }

    /// The pages typed, kept within the comic when it's the open one — the
    /// only one whose length is known without opening it.
    private var pages: ClosedRange<Int>? {
        guard let range = PageSpan.parsePages(pagesText) else { return nil }
        guard let chosenItem, chosenItem.id == model.item?.id, !model.pages.isEmpty else { return range }
        guard range.lowerBound <= model.pages.count else { return nil }
        return range.lowerBound...min(range.upperBound, model.pages.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.changingSpanID == nil ? "Link to Page" : "Change Pages")
                .font(.headline)

            if candidates.isEmpty {
                Text("None of this project’s series is in your library. Add the folder it’s in to link to its pages.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Form {
                    Picker("Comic", selection: $itemID) {
                        ForEach(candidates) { item in
                            Text(item.displayName).tag(Optional(item.id))
                        }
                    }
                    TextField("Pages", text: $pagesText, prompt: Text("42 or 42–45"))
                        .focused($pagesFocused)
                        .onSubmit(link)
                }
                if !pagesText.isEmpty, pages == nil {
                    Text(model.item?.id == itemID && !model.pages.isEmpty
                         ? "Pages 1 to \(model.pages.count), as “42” or “42–45”."
                         : "A page, or a range like “42–45”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.linkingPages = nil }
                    .keyboardShortcut(.cancelAction)
                Button(request.changingSpanID == nil ? "Link" : "Change", action: link)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenItem == nil || pages == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            itemID = request.itemID.flatMap { id in candidates.first { $0.id == id }?.id } ?? candidates.first?.id
            pagesText = request.pages
            pagesFocused = true
        }
    }

    private func link() {
        guard let chosenItem, let pages else { return }
        model.finishLinkingPages(request, item: chosenItem, pages: pages)
    }
}
