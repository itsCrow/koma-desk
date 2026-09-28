import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import Panels
import ComicArchive
import ComicLibrary
import PanelsFormat
import PanelsProject
import PageCapture

/// The reader, the library and a project together, driven the way the menus
/// drive them. The tests on real comics need PANELS_TEST_CBR (a single file)
/// and PANELS_TEST_FOLDER (a folder of chapters).
@Suite("Reader, library and project", .serialized)
@MainActor
struct ReaderProjectTests {
    static var comicPath: String? { ProcessInfo.processInfo.environment["PANELS_TEST_CBR"] }
    static var folderPath: String? { ProcessInfo.processInfo.environment["PANELS_TEST_FOLDER"] }

    /// A library, a projects folder and a reader of their own, in a scratch
    /// folder that goes when the test does.
    @MainActor
    struct Scratch {
        let root: URL
        let library: Library
        let projects: ProjectLibrary
        let model: ReaderModel

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PanelsTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = Library(folder: root.appendingPathComponent("Library", isDirectory: true))
            let projectsRoot = root.appendingPathComponent("Projects", isDirectory: true)
            try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            projects = ProjectLibrary(root: projectsRoot, defaults: UserDefaults(suiteName: "PanelsTests-\(UUID().uuidString)")!)
            model = ReaderModel(library: library, projects: projects)
        }

        func tearDown() {
            model.closeProject()
            model.closeComic()
            try? FileManager.default.removeItem(at: root)
        }

        /// A project folder about `series`, made directly rather than
        /// through the reader.
        func project(named name: String, series: String) throws -> Project {
            let url = try projects.create(named: name, series: series)
            return try Project.open(url)
        }
    }

    static func wait(seconds: Double = 30, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    // MARK: - Projects folder

    @Test("Projects are grouped by the series they're about, newest first")
    func projectGrouping() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }

        func make(_ name: String, series: String, cites title: String?, editedSecondsAgo: Double) throws {
            let url = try scratch.projects.create(named: name, series: series)
            var loaded = try ProjectStore.load(url)
            if let title {
                loaded.manifest.register(ItemRef(itemID: "\(title).cbz|1", filename: "\(title).cbz", fileSize: 1, series: series, title: title))
            }
            try ProjectStore.save(loaded, to: url)
            let date = Date().addingTimeInterval(-editedSecondsAgo)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ProjectStore.scriptURL(of: url).path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ProjectStore.manifestURL(of: url).path)
        }
        try make("Eclipse", series: "Berserk", cites: "Vol. 13", editedSecondsAgo: 100)
        try make("Golden Age", series: "Berserk", cites: "Vol. 4", editedSecondsAgo: 3000)
        try make("Buu Saga", series: "Dragon Ball", cites: nil, editedSecondsAgo: 500)
        scratch.projects.refresh()

        let groups = scratch.projects.groupedBySeries
        #expect(groups.map(\.series) == ["Berserk", "Dragon Ball"])
        #expect(groups[0].projects.map(\.name) == ["Eclipse", "Golden Age"])
        #expect(groups[1].projects.map(\.name) == ["Buu Saga"])
        #expect(scratch.projects.summary(for: groups[0].projects[0].url)?.items == ["Vol. 13"])
        #expect(scratch.projects.summary(for: groups[1].projects[0].url)?.items == [])
    }

    @Test("Rename, duplicate and trash keep the folder and the list in step")
    func projectEdits() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let projects = scratch.projects

        let url = try projects.create(named: "Draft", series: "Berserk")
        #expect(projects.summaries.map(\.name) == ["Draft"])

        let renamed = try projects.rename(url, to: "Final")
        #expect(renamed.lastPathComponent == "Final.panelsproject")
        #expect(try ProjectStore.loadManifest(renamed).name == "Final")
        #expect(try ProjectStore.loadManifest(renamed).series == "Berserk")
        #expect(projects.summaries.map(\.name) == ["Final"])

        let copy = try projects.duplicate(renamed)
        #expect(copy.lastPathComponent == "Final copy.panelsproject")
        #expect(Set(projects.summaries.map(\.name)) == ["Final", "Final copy"])

        try projects.trash(copy)
        #expect(projects.summaries.map(\.name) == ["Final"])
    }

    @Test("A project can't be made without a series to be about")
    func projectNeedsSeries() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        scratch.model.newProject(named: "Nothing")
        #expect(scratch.model.project == nil)
        #expect(scratch.model.errorMessage != nil)
    }

    // MARK: - Reading through the library

    @Test("A comic file joins the library as a series of one and opens where it was left")
    func libraryOpensAFile() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        let file = URL(fileURLWithPath: path)

        model.addToLibrary(file)
        #expect(scratch.library.series.count == 1)
        let series = try #require(scratch.library.series.first)
        #expect(series.items.count == 1)
        #expect(series.items[0].id == LibraryItem.makeID(filename: file.lastPathComponent,
                                                         fileSize: (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1))
        #expect(await Self.wait { model.hasComic })
        #expect(model.item?.id == series.items[0].id)
        #expect(model.series?.name == series.name)
        // One item: nothing to list beside the pages.
        #expect(!model.hasContents)

        // The position lives in the library, per item.
        model.goTo(spread: 9)
        #expect(scratch.library.position(for: series.items[0]) == 9)
        #expect(scratch.library.recentlyRead.map(\.item.id) == [series.items[0].id])

        model.closeComic()
        #expect(model.item == nil)
        model.read(series)
        #expect(await Self.wait { model.hasComic })
        #expect(model.spreadIndex == 9)

        // Adding the same file again changes nothing.
        model.addToLibrary(file)
        #expect(scratch.library.series.count == 1)
        #expect(scratch.library.roots.count == 1)

        // Forgetting the folder forgets the series.
        scratch.library.removeRoot(file)
        #expect(scratch.library.isEmpty)
    }

    @Test("Page Layout decides how pages pair into spreads; Reading Orientation never does")
    func pageLayoutControlsPairing() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        model.pageLayout = .twoPage
        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })

        let pageCount = model.pages.count
        let pairedSpreadCount = model.spreads.count
        // A real, multi-page comic pairs at least some of the time, so this
        // is an actual check rather than counts that would match anyway.
        #expect(pairedSpreadCount < pageCount)

        model.pageLayout = .singlePage
        #expect(model.spreads.count == pageCount)
        #expect(model.spreads.allSatisfy { $0.pageIndices.count == 1 })

        // Orientation only changes how a spread is shown, never which pages
        // share one — flipping it must leave spreads and position untouched.
        let spreadsBeforeOrientationChange = model.spreads
        let spreadIndexBeforeOrientationChange = model.spreadIndex
        model.readingOrientation = .vertical
        #expect(model.spreads == spreadsBeforeOrientationChange)
        #expect(model.spreadIndex == spreadIndexBeforeOrientationChange)
        model.readingOrientation = .horizontal
        #expect(model.spreads == spreadsBeforeOrientationChange)

        model.pageLayout = .twoPage
        #expect(model.spreads.count == pairedSpreadCount)
    }

    @Test("Switching Page Layout mid-chapter keeps the same page, not the start")
    func pageLayoutSwitchPreservesPosition() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        model.pageLayout = .twoPage
        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })

        model.goTo(spread: 3)
        let currentPage = try #require(model.currentSpread?.pageIndices.first)

        // Single Page's spreads are indexed 1:1 with pages, so the page
        // itself — not just "a" page — has to be the one still on screen.
        model.pageLayout = .singlePage
        #expect(model.currentSpread?.pageIndices == [currentPage])

        // And back: two-page pairing may put that same page second in its
        // spread rather than first, which is still "the same page."
        model.pageLayout = .twoPage
        #expect(model.currentSpread?.pageIndices.contains(currentPage) == true)
    }

    @Test("A folder reads as one series: the last page turns into the next chapter, and back")
    func readThroughASeries() async throws {
        guard let path = Self.folderPath else {
            withKnownIssue("Set PANELS_TEST_FOLDER to a folder of chapters to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        let folder = URL(fileURLWithPath: path, isDirectory: true)

        model.addToLibrary(folder)
        // A folder lands on its series' page rather than opening anything.
        #expect(model.showsHome)
        #expect(model.homeTab == .library)
        let series = try #require(scratch.library.series.first)
        #expect(model.browsingSeries == series.name)
        #expect(series.items.count >= 2)
        #expect(series.chapterCount == series.items.count)

        model.read(series)
        #expect(await Self.wait { model.hasComic })
        #expect(!model.showsHome)
        #expect(model.hasContents)
        let first = try #require(model.item)
        #expect(first.id == series.items[0].id)
        #expect(model.currentItemIndex == 0)
        #expect(model.itemNoun == "Chapter")

        // Off the end of this chapter, into the start of the next.
        model.goToEnd()
        let lastSpread = model.spreadIndex
        #expect(model.canGoForward)
        model.goForward()
        // `item` moves on at once; the pages follow when the file has opened.
        #expect(await Self.wait { model.item?.id == series.items[1].id && !model.isLoading })
        #expect(model.spreadIndex == 0)
        #expect(scratch.library.position(for: first) == lastSpread)

        // Back off the front of it, onto the last spread of the one before.
        model.goBack()
        #expect(await Self.wait { model.item?.id == first.id && !model.isLoading })
        #expect(model.spreadIndex == model.spreads.count - 1)

        // A project made while reading is about this series.
        model.newProject(named: "Arc")
        let project = try #require(model.project)
        #expect(project.manifest.series == series.name)
        #expect(scratch.projects.summaries.map(\.series) == [series.name])

        // Picking the series up again lands on the chapter last read.
        model.closeComic()
        #expect(scratch.library.continueItem(in: series)?.id == first.id)
    }

    // MARK: - Projects and citations

    @Test("Opening a project brings up its series where it was left; the same series keeps its pages")
    func switching() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let series = try #require(model.series)

        model.newProject(named: "First")
        let first = try #require(model.project)
        #expect(first.manifest.series == series.name)
        first.script = "The first script."
        model.goTo(spread: 7)

        model.newProject(named: "Second")
        let second = try #require(model.project)
        #expect(second.name == "Second")
        #expect(model.spreadIndex == 7)
        // The first was saved on the way out.
        #expect(try ProjectStore.load(first.url).script == "The first script.")

        // Back to the first: same series, so the pages don't move.
        model.switchTo(first.url)
        #expect(model.project?.name == "First")
        #expect(model.project?.script == "The first script.")
        #expect(model.spreadIndex == 7)
        #expect(model.hasComic)
        model.closeProject()

        // With nothing open, a project brings its series up where it was left.
        model.closeComic()
        model.switchTo(second.url)
        #expect(await Self.wait { model.hasComic })
        #expect(model.series?.name == series.name)
        #expect(model.spreadIndex == 7)
        #expect(scratch.projects.summaries.map(\.name).sorted() == ["First", "Second"])
    }

    @Test("A project about a series that isn't here says so, until its folder is added")
    func missingSeries() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model
        let file = URL(fileURLWithPath: path)
        let seriesName = ComicIdentity(fileURL: file).series

        let project = try scratch.project(named: "Elsewhere", series: seriesName)
        model.openProject(at: project.url)
        #expect(model.project?.name == "Elsewhere")
        #expect(model.missingSeries == seriesName)
        #expect(!model.hasComic)

        scratch.library.addRoot(file)
        #expect(model.missingSeries == nil)
        // Nothing to capture into without pages; nothing opened by itself.
        #expect(!model.hasComic)
        model.read(try #require(scratch.library.series(named: seriesName)))
        #expect(await Self.wait { model.hasComic })
    }

    @Test("Citing puts a citation in the project by library item, queues its chip, and can be jumped to")
    func citeAndJump() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let item = try #require(model.item)
        model.newProject(named: "Cited")
        let project = try #require(model.project)
        #expect(project.manifest.items.isEmpty)

        model.goTo(spread: 5)
        let text = try #require(model.copyCitation())
        #expect(text.hasPrefix(item.series))
        #expect(project.manifest.citations.count == 1)
        let citation = project.manifest.citations[0]
        #expect(citation.itemID == item.id)
        #expect(citation.text == text)
        #expect(citation.pageNumbers == model.visiblePages.map(\.number))
        #expect(project.pendingInsertion?.id == citation.id)
        // The item is on record, once, however often it's cited.
        model.copyCitation()
        #expect(project.manifest.items.map(\.itemID) == [item.id])
        #expect(project.manifest.items[0].filename == item.url.lastPathComponent)
        #expect(project.manifest.items[0].series == item.series)

        // Go elsewhere, then follow the citation back.
        model.goTo(spread: 40)
        model.jump(toCitation: citation.id)
        #expect(model.spreadIndex == 5)
        #expect(!model.focusOutlines.isEmpty)

        // From nothing open, the jump opens the item first.
        model.closeComic()
        model.jump(toCitation: citation.id)
        #expect(await Self.wait { model.hasComic && model.spreadIndex == 5 })
        #expect(!model.focusOutlines.isEmpty)

        // The project saves itself.
        #expect(await Self.wait(seconds: 5) { (try? ProjectStore.load(project.url))?.manifest.citations.count == 2 })
    }

    @Test("Jumping to a citation or a page range leaves the extended writing area, so there's something to land on")
    func jumpLeavesFocusedWriting() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let url = try scratch.projects.create(named: "Jumping", series: "Berserk")
        scratch.model.openProject(at: url)
        let project = try #require(scratch.model.project)

        // Neither points at anything in the (empty) library, so both jumps
        // take their existing "not in your library" path — no real comic
        // needed just to prove the mode switch happens.
        let citation = Citation(itemID: "missing.cbz|1", pageIndex: 0, pageNumbers: [1], text: "a shot")
        project.manifest.citations.append(citation)
        let span = PageSpan(id: "k7m2pq", itemID: "missing.cbz|1", firstPageIndex: 0,
                            pageNumbers: [1], text: "a range")
        project.manifest.store(span)

        scratch.model.isFocusedWriting = true
        scratch.model.jump(toCitation: citation.id)
        #expect(scratch.model.isFocusedWriting == false)
        #expect(scratch.model.errorMessage != nil)

        scratch.model.isFocusedWriting = true
        scratch.model.errorMessage = nil
        scratch.model.jump(toSpan: span.id)
        #expect(scratch.model.isFocusedWriting == false)
        #expect(scratch.model.errorMessage != nil)

        // A citation or span id nothing recognizes doesn't exist to jump to
        // at all — no reason to interrupt the writing for it.
        scratch.model.isFocusedWriting = true
        scratch.model.jump(toCitation: "nope12")
        scratch.model.jump(toSpan: "nope12")
        #expect(scratch.model.isFocusedWriting == true)
    }

    @Test("A comic that won't open leaves the model on the one still showing")
    func failedOpenKeepsIdentity() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let good = try #require(model.item)
        let series = try #require(model.series)

        // A truncated download — half the collection is in this state, and it
        // is exactly what produced a citation pointing at the wrong comic.
        let broken = scratch.root.appendingPathComponent("Broken v01.cbz")
        try Data(repeating: 0, count: 4096).write(to: broken)
        let brokenItem = LibraryItem(url: broken, series: "Broken", volume: 1, chapter: nil,
                                     title: "Vol. 1", arc: nil, fileSize: 4096)

        model.open(item: brokenItem)
        #expect(await Self.wait(seconds: 10) { model.errorMessage != nil })

        // The good comic's pages never left the screen, so it is still what
        // the model is showing — and what a citation would name.
        #expect(model.hasComic)
        #expect(model.item?.id == good.id)
        #expect(model.series?.name == series.name)

        model.newProject(named: "After the failure")
        let project = try #require(model.project)
        _ = model.copyCitation()
        #expect(project.manifest.citations.first?.itemID == good.id)
        #expect(project.manifest.items.map(\.itemID) == [good.id])
    }

    @Test("A page range records the pages on screen, stretches, and reaches the writing")
    func pageRanges() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        model.newProject(named: "Ranges")
        let project = try #require(model.project)
        let item = try #require(model.item)

        model.goTo(spread: 6)
        let opened = model.visiblePages.map(\.number).sorted()
        model.startPageRange()

        let span = try #require(project.manifest.spans.first)
        #expect(span.itemID == item.id)
        // The comic is on record, so the range reads as its volume or chapter
        // and not just its pages.
        #expect(project.manifest.items.map(\.itemID) == [item.id])
        #expect(project.manifest.label(for: span).item != nil)
        #expect(span.firstPage == opened.first)
        #expect(span.lastPage == opened.last)
        #expect(span.text.hasPrefix(item.series))
        // The editor is told to put it on the writing and keep it going.
        #expect(project.pendingSpanCommand == .start(span))
        project.pendingSpanCommand = nil

        // The page a range opens is the page it starts on.
        #expect(span.firstPageIndex == span.firstPage - 1)

        // Extending only ever touches the block the cursor is in.
        model.spanAtCursor = span.id
        model.goTo(spread: 12)
        let reached = try #require(model.visiblePages.map(\.number).max())
        model.extendPageRange()
        let stretched = try #require(project.manifest.span(id: span.id))
        #expect(stretched.firstPage == span.firstPage)
        #expect(stretched.lastPage == reached)
        // Still one range, not two.
        #expect(project.manifest.spans.count == 1)

        // Reading back moves the start, and the page it opens moves with it.
        model.goTo(spread: 1)
        let backTo = try #require(model.visiblePages.map(\.number).min())
        model.extendPageRange()
        let widened = try #require(project.manifest.span(id: span.id))
        #expect(widened.firstPage == backTo)
        #expect(widened.lastPage == reached)
        #expect(widened.firstPageIndex == backTo - 1)
        #expect(widened.text.contains("pp. \(backTo)–\(reached)"))

        // With the cursor outside any block there is nothing to extend.
        model.spanAtCursor = nil
        #expect(!model.canExtendPageRange)
        model.goTo(spread: 20)
        model.extendPageRange()
        #expect(project.manifest.span(id: span.id) == widened)

        // Ending and removing are the editor's to carry out.
        model.endPageRange()
        #expect(project.pendingSpanCommand == .end)
        model.removePageRange()
        #expect(project.pendingSpanCommand == .remove)
    }

    @Test("One key starts a range and ends it, following where the cursor is")
    func oneKeyToggles() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "The eclipse begins.", in: scratch)
        let model = scratch.model
        model.spanAtCursor = nil

        // Outside a block, the key starts one — here from a range made by hand,
        // since this test has no comic open.
        let span = PageSpan(id: "k7m2pq", itemID: "b.cbz|1", firstPageIndex: 11,
                            pageNumbers: [12, 17], text: "Berserk, Vol. 1, pp. 12–17")
        project.manifest.store(span)
        #expect(!model.isWritingInRange)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applySpan(.start(span))

        // The editor reports the cursor is now inside a block, so the same key
        // means "end" from here on.
        #expect(model.spanAtCursor == "k7m2pq")
        #expect(model.isWritingInRange)
        model.togglePageRange()
        #expect(project.pendingSpanCommand == .end)
        coordinator.applySpan(.end)
        #expect(!model.isWritingInRange)

        // And back out, the key starts again rather than ending nothing.
        project.pendingSpanCommand = nil
        model.togglePageRange()
        // No comic is open in this test, so starting can't pick pages — the
        // point is that it tried to start rather than end.
        #expect(project.pendingSpanCommand != .end)
    }

    @Test("Selected writing is linked to pages whole paragraph by whole paragraph, and stops there")
    func linkSelection() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        Before any of it.
        The eclipse begins.
        Griffith makes his choice.
        Long after.
        """, in: scratch)
        let span = PageSpan(id: "k7m2pq", itemID: "b.cbz|1", firstPageIndex: 41,
                            pageNumbers: [42, 45], text: "Berserk, Vol. 13, pp. 42–45")
        project.manifest.store(span)

        // Part of the second line through part of the third.
        let string = textView.string as NSString
        let start = string.range(of: "eclipse").location
        let end = string.range(of: "makes").location
        let selection = NSRange(location: start, length: end - start)

        // The request remembers what was selected; by the time it's answered
        // the caret has gone somewhere else entirely.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applySpan(.link(span, selection: selection))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).map(\.spanID) == [nil, "k7m2pq", "k7m2pq", nil])

        // Typing on at the end doesn't join it — it wasn't a block being written.
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.insertText("\nAnd more.", replacementRange: textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).map(\.spanID) == [nil, "k7m2pq", "k7m2pq", nil, nil])
    }

    @Test("With writing selected, the range key links it rather than starting a block")
    func rangeKeyLinksSelection() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "The eclipse begins.", in: scratch)
        let model = scratch.model

        textView.setSelectedRange(NSRange(location: 4, length: 7))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        #expect(model.hasScriptSelection)
        // Writer mode offers both ways to link; no comic is open, so the pages
        // on screen can't be one of them yet.
        let items = coordinator.contextMenuItems(at: 5)
        #expect(items.map(\.title).contains("Link to Page…"))
        #expect(items.first { $0.title.hasPrefix("Link to Pages on Screen") }?.isEnabled == false)
        model.togglePageRange()
        #expect(project.pendingSpanCommand == nil)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        #expect(!model.hasScriptSelection)
        #expect(coordinator.contextMenuItems(at: 5).isEmpty)
    }

    @Test("Link to Page… makes a range for any comic, or changes an existing one's pages")
    func linkToTypedPages() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (_, _, project) = try editor(script: "The eclipse begins.", in: scratch)
        let model = scratch.model
        let item = LibraryItem(url: URL(fileURLWithPath: "/tmp/Berserk v13.cbz"), series: "Berserk",
                               volume: 13, chapter: nil, title: "Berserk v13", arc: nil, fileSize: 1)

        let selection = NSRange(location: 0, length: 3)
        model.beginLinkingPages(selection: selection)
        let request = try #require(model.linkingPages)
        model.finishLinkingPages(request, item: item, pages: 42...45)
        #expect(model.linkingPages == nil)
        let span = try #require(project.manifest.spans.first)
        #expect(span.itemID == item.id)
        #expect(span.firstPageIndex == 41)
        #expect(span.pageNumbers == [42, 45])
        #expect(span.text == "Berserk, Vol. 13, pp. 42–45")
        #expect(project.manifest.items.map(\.itemID) == [item.id])
        #expect(project.pendingSpanCommand == .link(span, selection: selection))
        project.pendingSpanCommand = nil

        // Changing the pages keeps the id, so the writing needn't change.
        model.beginLinkingPages(changing: span.id)
        let change = try #require(model.linkingPages)
        #expect(change.pages == "42–45")
        #expect(change.itemID == item.id)
        model.finishLinkingPages(change, item: item, pages: 50...50)
        #expect(project.manifest.spans.count == 1)
        #expect(project.manifest.span(id: span.id)?.pageNumbers == [50, 50])
        #expect(project.pendingSpanCommand == nil)
    }

    @Test("A range linked by hand stays put while reading on")
    func linkedRangeStaysPut() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        model.newProject(named: "Linked")
        let project = try #require(model.project)

        model.goTo(spread: 4)
        model.linkSelectionToPagesOnScreen()
        let linked = try #require(project.manifest.spans.first)
        model.spanAtCursor = linked.id

        model.goTo(spread: 9)
        #expect(project.manifest.span(id: linked.id) == linked)
    }

    @Test("The range follows the reading while the block is being written")
    func rangeFollowsReading() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        model.newProject(named: "Following")
        let project = try #require(model.project)

        model.goTo(spread: 4)
        model.startPageRange()
        let started = try #require(project.manifest.spans.first)
        model.spanAtCursor = started.id

        // Read on, saying nothing. The block grows with you.
        model.goTo(spread: 9)
        let reached = try #require(model.visiblePages.map(\.number).max())
        let grown = try #require(project.manifest.span(id: started.id))
        #expect(grown.firstPage == started.firstPage)
        #expect(grown.lastPage == reached)

        // Turning back to check something leaves the start where it was.
        model.goTo(spread: 1)
        let afterBack = try #require(project.manifest.span(id: started.id))
        #expect(afterBack == grown)

        // With no block being written, reading changes nothing.
        model.spanAtCursor = nil
        model.goTo(spread: 30)
        #expect(project.manifest.span(id: started.id) == grown)

        // Reopening at a remembered position is not reading, either.
        model.spanAtCursor = started.id
        model.closeComic()
        let item = try #require(scratch.library.series.first?.items.first)
        model.open(item: item)
        #expect(await Self.wait { model.hasComic })
        #expect(project.manifest.span(id: started.id) == grown)
    }

    @Test("A range never stretches across two comics")
    func rangesStayInOneComic() async throws {
        guard let folderPath = Self.folderPath else {
            withKnownIssue("Set PANELS_TEST_FOLDER to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: folderPath, isDirectory: true))
        let series = try #require(scratch.library.series.first)
        #expect(series.items.count >= 2)
        model.read(series)
        #expect(await Self.wait { model.hasComic })
        model.newProject(named: "Arc")
        let project = try #require(model.project)

        model.goTo(spread: 2)
        model.startPageRange()
        let span = try #require(project.manifest.spans.first)
        model.spanAtCursor = span.id

        // Read on into the next chapter, where the page numbering starts over.
        model.nextItem()
        #expect(await Self.wait { model.item?.id == series.items[1].id && !model.isLoading })
        #expect(await Self.wait { model.hasComic })
        #expect(!model.canExtendPageRange)
        model.extendPageRange()

        // Untouched: merging the two numberings would have been nonsense.
        #expect(project.manifest.span(id: span.id) == span)
        #expect(model.lastCaptureMessage?.contains("is in") == true)
    }

    @Test("A range reaches the script, the shot list and a paste")
    func rangesInTheScript() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Ranges", series: "Berserk")

        let span = PageSpan(id: "k7m2pq", itemID: "b.cbz|1", firstPageIndex: 11,
                            pageNumbers: [12, 17], text: "Berserk, Vol. 1, pp. 12–17")
        project.manifest.store(span)
        let cited = Citation(itemID: "b.cbz|1", pageIndex: 13, pageNumbers: [14], text: "Berserk, Vol. 1, p. 14")
        project.manifest.citations = [cited]
        project.script = """
        <span:k7m2pq> The eclipse begins.
        <span:k7m2pq> It keeps going [Berserk, Vol. 1, p. 14](panels://cite/\(cited.id)) here.
        Then something else entirely.
        """

        #expect(project.spansInScriptOrder.map(\.id) == ["k7m2pq"])
        #expect(project.unusedSpans.isEmpty)
        // A shot knows which block of writing it sits in.
        #expect(project.span(containing: cited.id)?.id == "k7m2pq")
        #expect(project.opening(of: "k7m2pq") == "The eclipse begins.")
        // Pasting elsewhere carries the range, once, at the end of the block.
        #expect(project.plainTextScript == """
        The eclipse begins.
        It keeps going Berserk, Vol. 1, p. 14 here. (Berserk, Vol. 1, pp. 12–17)
        Then something else entirely.
        """)

        // A range the writing no longer points at is dropped on a tidy-up.
        project.script = "Nothing points at it now."
        #expect(project.unusedSpans.map(\.id) == ["k7m2pq"])
        project.cleanUpUnusedCaptures()
        #expect(project.manifest.spans.isEmpty)
    }

    /// Drives the real editor: an NSTextView, the real coordinator, the real
    /// render/serialise round trip. This is where page ranges can be silently
    /// destroyed, so it is tested here rather than only through the model.
    @MainActor
    private func editor(script: String, in scratch: Scratch) throws -> (ScriptEditorView.Coordinator, ScriptTextView, Project) {
        // Opened through the model, so the reader and the editor are working on
        // the same project — the toggle asks the model for it.
        let url = try scratch.projects.create(named: "Editing", series: "Berserk")
        scratch.model.openProject(at: url)
        let project = try #require(scratch.model.project)
        project.script = script
        let coordinator = ScriptEditorView.Coordinator(project: project, model: scratch.model)
        let textView = ScriptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.load()
        return (coordinator, textView, project)
    }

    @Test("Formatting a paragraph inside a block does not knock it out of the block")
    func headingKeepsTheBlock() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        <span:k7m2pq> The eclipse begins.
        <span:k7m2pq> It keeps going.
        <span:k7m2pq> And then it stops.
        """, in: scratch)

        // Put the cursor in the middle paragraph and make it a heading.
        let middle = (textView.string as NSString).range(of: "It keeps going.")
        textView.setSelectedRange(NSRange(location: middle.location, length: 0))
        coordinator.apply(.heading(2))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        // All three lines still belong to the block, and the middle one is now
        // a heading. Without carrying the span across setAttributes, the block
        // would have been cut in three.
        let blocks = ScriptMarkdown.parse(project.script)
        #expect(blocks.map(\.spanID) == ["k7m2pq", "k7m2pq", "k7m2pq"])
        #expect(blocks[1].headingLevel == 2)
        #expect(textView.spanRuns().count == 1)
    }

    @Test("Restyling the whole document at once keeps each paragraph's own span, or lack of one")
    func stylingEverythingKeepsEachParagraphsOwnSpan() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        <span:k7m2pq> The eclipse begins.
        Just an ordinary line, in no range at all.
        """, in: scratch)

        // Select-all, the way the toolbar's style menu can, rather than a
        // cursor sitting in one paragraph the way the keyboard shortcuts do.
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.apply(.heading(1))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        let blocks = ScriptMarkdown.parse(project.script)
        #expect(blocks.map(\.spanID) == ["k7m2pq", nil])
        #expect(blocks.allSatisfy { $0.headingLevel == 1 })
        #expect(textView.spanRuns().count == 1)
    }

    @Test("A plain edit inside a block forces the view to repaint, so its box and margin rule can't fall out of sync")
    func typingForcesARepaint() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, _) = try editor(script: "<span:k7m2pq> The eclipse begins.", in: scratch)

        // needsDisplay only really sticks once a view is in a window — off
        // in space it just reports false regardless, which would make this
        // check meaningless.
        let window = NSWindow(contentRect: textView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = textView
        textView.needsDisplay = false
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText("\nA new line, widening the block.", replacementRange: textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        // The box (drawn from the live layout) and its margin rule (drawn
        // beside it, in the left margin — outside any glyph AppKit's own
        // invalidation would notice) are only guaranteed to agree if the
        // whole view actually repaints after every edit.
        #expect(textView.needsDisplay)
    }

    @Test("Turning a line into a note survives the round trip, span and all")
    func notesInTheEditor() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        <span:k7m2pq> Goku's training begins in earnest.
        <span:k7m2pq> Hold this panel a beat.
        <span:k7m2pq> The milk gag lands three times over.
        """, in: scratch)
        let span = PageSpan(id: "k7m2pq", itemID: "b.cbz|1", firstPageIndex: 11,
                            pageNumbers: [12, 17], text: "Berserk, Vol. 1, pp. 12–17")
        project.manifest.store(span)

        // Make the middle line an aside.
        let middle = (textView.string as NSString).range(of: "Hold this panel a beat.")
        textView.setSelectedRange(NSRange(location: middle.location, length: 0))
        coordinator.apply(.note)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        let blocks = ScriptMarkdown.parse(project.script)
        #expect(blocks.map(\.isNote) == [false, true, false])
        // The page range survives being restyled, as headings already had to.
        #expect(blocks.map(\.spanID) == ["k7m2pq", "k7m2pq", "k7m2pq"])
        #expect(textView.spanRuns().count == 1)
        #expect(project.notesInScriptOrder == ["Hold this panel a beat."])

        // It is not narration...
        #expect(project.plainTextScript == """
        Goku's training begins in earnest.
        The milk gag lands three times over. (Berserk, Vol. 1, pp. 12–17)
        """)
        // ...until the paste asks for it.
        #expect(project.plainTextScript(notes: .marked).contains("[NOTE: Hold this panel a beat.]"))

        // And back to prose again.
        textView.setSelectedRange(NSRange(location: middle.location, length: 0))
        coordinator.apply(.body)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).allSatisfy { !$0.isNote })
        #expect(project.notesInScriptOrder.isEmpty)
    }

    @Test("Voice mode strips notes, chips and page ranges from what's on screen, but not from the script")
    func voiceModeStripsWorkingMarks() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        <span:k7m2pq> Goku's training begins in earnest.
        <span:k7m2pq> Hold this panel a beat.
        """, in: scratch)
        let span = PageSpan(id: "k7m2pq", itemID: "b.cbz|1", firstPageIndex: 11,
                            pageNumbers: [12, 17], text: "Berserk, Vol. 1, pp. 12–17")
        project.manifest.store(span)
        let middle = (textView.string as NSString).range(of: "Hold this panel a beat.")
        textView.setSelectedRange(NSRange(location: middle.location, length: 0))
        coordinator.apply(.note)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        let citation = Citation(itemID: "b.cbz|1", pageIndex: 3, pageNumbers: [4], text: "shot")
        project.manifest.citations.append(citation)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        coordinator.insert(citation)

        #expect(textView.spanRuns().count == 1)

        coordinator.setMode(.voice)
        #expect(textView.spanRuns().isEmpty)
        #expect(!textView.string.contains("Hold this panel a beat."))
        var sawChip = false
        textView.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage!.length), options: []) { value, _, _ in
            if value is CitationAttachment { sawChip = true }
        }
        #expect(!sawChip)
        #expect(textView.isEditable == false)

        // The script on disk — the source of truth — is untouched.
        let blocks = ScriptMarkdown.parse(project.script)
        #expect(blocks.contains { $0.isNote })
        #expect(blocks.map(\.spanID).contains("k7m2pq"))

        coordinator.setMode(.writer)
        #expect(textView.spanRuns().count == 1)
        #expect(textView.string.contains("Hold this panel a beat."))
        #expect(textView.isEditable == true)
    }

    @Test("Mode switching sets editability for all three modes")
    func modeSwitchingSetsEditability() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, _) = try editor(script: "Some writing.", in: scratch)
        #expect(textView.isEditable)

        coordinator.setMode(.voice)
        #expect(!textView.isEditable)

        coordinator.setMode(.editor)
        #expect(!textView.isEditable)

        coordinator.setMode(.writer)
        #expect(textView.isEditable)
    }

    @Test("Creating a beat in Editor mode marks the manifest and the script, and draws a block")
    func createsABeat() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "Cold open begins here.", in: scratch)
        coordinator.setMode(.editor)

        coordinator.createBeat(title: "Cold Open", blockRange: 0...0)

        #expect(project.manifest.beats.count == 1)
        let beat = try #require(project.manifest.beats.first)
        #expect(beat.title == "Cold Open")
        #expect(!beat.isDone)
        #expect(ScriptMarkdown.parse(project.script)[0].beatID == beat.id)
        #expect(textView.beatRuns().map(\.id) == [beat.id])
    }

    @Test("Removing a beat clears the marker and forgets the manifest record")
    func removesABeat() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "Cold open begins here.", in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "Cold Open", blockRange: 0...0)
        let beat = try #require(project.manifest.beats.first)

        coordinator.removeBeat(id: beat.id)

        #expect(project.manifest.beats.isEmpty)
        #expect(ScriptMarkdown.beatIDs(in: project.script).isEmpty)
        #expect(textView.beatRuns().isEmpty)
    }

    @Test("A beat covers only the paragraphs it was made on — never the rest of the script")
    func beatDoesNotOverextend() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        Cold open.
        The middle beat.
        The ending, untouched.
        """, in: scratch)
        coordinator.setMode(.editor)

        // Made on just the middle paragraph — with no other beat in the
        // script, the old "runs to the next beat or the end" design would
        // have swallowed the ending too.
        coordinator.createBeat(title: "Middle", blockRange: 1...1)

        let blocks = ScriptMarkdown.parse(project.script)
        #expect(blocks[0].beatID == nil)
        #expect(blocks[1].beatID != nil)
        #expect(blocks[2].beatID == nil)

        let run = try #require(textView.beatRuns().first)
        #expect(textView.beatRuns().count == 1)
        let coveredText = (textView.string as NSString).substring(with: run.range)
        #expect(coveredText.trimmingCharacters(in: .newlines) == "The middle beat.")
    }

    @Test("Creating a beat over a multi-paragraph selection covers exactly that range")
    func beatCoversASelection() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        First paragraph.
        Second paragraph.
        Third paragraph.
        """, in: scratch)
        coordinator.setMode(.editor)

        coordinator.createBeat(title: "First Two", blockRange: 0...1)

        let blocks = ScriptMarkdown.parse(project.script)
        #expect(blocks[0].beatID == blocks[1].beatID)
        #expect(blocks[0].beatID != nil)
        #expect(blocks[2].beatID == nil)
        #expect(textView.beatRuns().count == 1)
    }

    @Test("Right-clicking a blank line between paragraphs still offers New Beat Here")
    func beatMenuWorksOnABlankLine() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, _) = try editor(script: """
        First paragraph.

        Third paragraph.
        """, in: scratch)
        coordinator.setMode(.editor)

        // The blank line itself: `render(_:mode:)` never attaches anything
        // there, since an empty block never satisfies `result.length >
        // start` — this is exactly the gap that made the beat menu vanish
        // on a script with blank-line paragraph spacing.
        let blankLineLocation = (textView.string as NSString).range(of: "First paragraph.\n").length
        #expect(coordinator.beatMenuItems(at: blankLineLocation).map(\.title) == ["New Beat Here"])

        // The very last character, and one past it — both realistic
        // right-click targets near the end of a script.
        let lastCharacter = textView.string.utf16.count - 1
        #expect(!coordinator.beatMenuItems(at: lastCharacter).isEmpty)
        #expect(!coordinator.beatMenuItems(at: textView.string.utf16.count).isEmpty)
    }

    @Test("Removing a beat that spans several paragraphs clears every one of them")
    func removingAMultiParagraphBeatClearsAll() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: """
        First paragraph.
        Second paragraph.
        Third paragraph.
        """, in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "First Two", blockRange: 0...1)
        let beat = try #require(project.manifest.beats.first)

        coordinator.removeBeat(id: beat.id)

        let blocks = ScriptMarkdown.parse(project.script)
        #expect(blocks.allSatisfy { $0.beatID == nil })
        #expect(textView.beatRuns().isEmpty)
    }

    @Test("Toggling a beat's checkbox only touches the manifest, not the script")
    func toggleBeatDoneOnlyTouchesManifest() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, _, project) = try editor(script: "Cold open begins here.", in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "Cold Open", blockRange: 0...0)
        let beat = try #require(project.manifest.beats.first)
        let scriptBefore = project.script

        coordinator.toggleBeatDone(id: beat.id)
        #expect(project.manifest.beat(id: beat.id)?.isDone == true)
        #expect(project.script == scriptBefore)

        coordinator.toggleBeatDone(id: beat.id)
        #expect(project.manifest.beat(id: beat.id)?.isDone == false)
    }

    @Test("A done beat's text stays full strength — finishing one is never a reason to dim it")
    func doneBeatTextDoesNotFade() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, _, project) = try editor(script: "Cold open begins here.", in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "Cold Open", blockRange: 0...0)
        let beat = try #require(project.manifest.beats.first)

        let notDone = coordinator.render(project.script, mode: .editor)
        let notDoneAlpha = try #require((notDone.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.alphaComponent)

        coordinator.toggleBeatDone(id: beat.id)
        let done = coordinator.render(project.script, mode: .editor)
        let doneAlpha = try #require((done.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.alphaComponent)

        #expect(doneAlpha == notDoneAlpha)
    }

    @Test("The first not-done beat is next up; finishing it advances which one is")
    func nextUpBeatAdvancesAsEachIsFinished() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, _, project) = try editor(script: """
        First.
        Second.
        Third.
        """, in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "One", blockRange: 0...0)
        coordinator.createBeat(title: "Two", blockRange: 1...1)
        coordinator.createBeat(title: "Three", blockRange: 2...2)
        let beats = project.beatsInScriptOrder
        #expect(beats.map(\.title) == ["One", "Two", "Three"])

        #expect(coordinator.beatInfo(for: beats[0].id)?.isNextUp == true)
        #expect(coordinator.beatInfo(for: beats[1].id)?.isNextUp == false)
        #expect(coordinator.beatInfo(for: beats[2].id)?.isNextUp == false)

        coordinator.toggleBeatDone(id: beats[0].id)
        #expect(coordinator.beatInfo(for: beats[0].id)?.isNextUp == false)
        #expect(coordinator.beatInfo(for: beats[1].id)?.isNextUp == true)
        #expect(coordinator.beatInfo(for: beats[2].id)?.isNextUp == false)

        coordinator.toggleBeatDone(id: beats[1].id)
        #expect(coordinator.beatInfo(for: beats[1].id)?.isNextUp == false)
        #expect(coordinator.beatInfo(for: beats[2].id)?.isNextUp == true)

        coordinator.toggleBeatDone(id: beats[2].id)
        #expect(coordinator.beatInfo(for: beats[2].id)?.isNextUp == false)
    }

    @Test("A beat marker is invisible to Writer mode, and survives an edit there")
    func beatSurvivesWriterModeEdit() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "Cold open begins here.", in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "Cold Open", blockRange: 0...0)
        let beat = try #require(project.manifest.beats.first)

        coordinator.setMode(.writer)
        // Nothing about the beat shows up in Writer mode — `beatRuns()` is
        // empty even though the `beatKey` attribute is still there, because
        // `showsBeatBlocks` gates it off outside Editor mode.
        #expect(textView.string == "Cold open begins here.")
        #expect(textView.beatRuns().isEmpty)
        var sawBeatKeyInWriterMode = false
        textView.textStorage?.enumerateAttribute(ScriptStyle.beatKey, in: NSRange(location: 0, length: textView.textStorage!.length), options: []) { value, _, _ in
            if value != nil { sawBeatKeyInWriterMode = true }
        }
        #expect(sawBeatKeyInWriterMode)

        // ...but typing anywhere still round-trips the marker rather than
        // silently dropping it on the next save.
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.insertText(" Still going.", replacementRange: textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(ScriptMarkdown.beatIDs(in: project.script) == [beat.id])
        #expect(project.script.contains("Still going."))
    }

    @Test("Voice mode strips a beat's block and attribute, the same way it strips notes and chips")
    func voiceModeStripsBeats() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, _) = try editor(script: "Cold open begins here.", in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "Cold Open", blockRange: 0...0)

        coordinator.setMode(.voice)

        #expect(textView.string == "Cold open begins here.")
        #expect(textView.beatRuns().isEmpty)
        var sawBeatKey = false
        textView.textStorage?.enumerateAttribute(ScriptStyle.beatKey, in: NSRange(location: 0, length: textView.textStorage!.length), options: []) { value, _, _ in
            if value != nil { sawBeatKey = true }
        }
        #expect(!sawBeatKey)
    }

    @Test("Beats come back in script order, and orphans are cleaned up like unused spans")
    func beatsInScriptOrderAndGC() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, _, project) = try editor(script: "First.\nSecond.", in: scratch)
        coordinator.setMode(.editor)
        coordinator.createBeat(title: "First Beat", blockRange: 0...0)
        coordinator.createBeat(title: "Second Beat", blockRange: 1...1)

        #expect(project.beatsInScriptOrder.map(\.title) == ["First Beat", "Second Beat"])

        // The marker lines are removed directly, without going through
        // "Remove Beat".
        project.script = "First, no longer marked.\nSecond, no longer marked."
        #expect(Set(project.unusedBeats.map(\.title)) == Set(["First Beat", "Second Beat"]))
        project.cleanUpUnusedCaptures()
        #expect(project.manifest.beats.isEmpty)
    }

    @Test("Bold, italic, highlight and text color apply to a selection, compose, and round-trip; alignment is per-paragraph")
    func inlineFormattingAndAlignment() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "Guts raises his sword.", in: scratch)

        let word = (textView.string as NSString).range(of: "raises")
        textView.setSelectedRange(word)
        coordinator.applyInline(.toggleBold)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script) == [.paragraph([
            .text("Guts "),
            .styledText(TextRun(text: "raises", bold: true)),
            .text(" his sword."),
        ])])

        // Toggling the same selection again turns it back off, cleanly.
        textView.setSelectedRange(word)
        coordinator.applyInline(.toggleBold)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script) == [.paragraph([.text("Guts raises his sword.")])])

        // A highlight and a text color on a different word, together.
        let sword = (textView.string as NSString).range(of: "sword")
        textView.setSelectedRange(sword)
        coordinator.applyInline(.setHighlight(.yellow))
        coordinator.applyInline(.setTextColor(.blue))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script) == [.paragraph([
            .text("Guts raises his "),
            .styledText(TextRun(text: "sword", highlight: .yellow, textColor: .blue)),
            .text("."),
        ])])

        // Clearing the highlight leaves the text color alone.
        textView.setSelectedRange(sword)
        coordinator.applyInline(.setHighlight(nil))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script) == [.paragraph([
            .text("Guts raises his "),
            .styledText(TextRun(text: "sword", textColor: .blue)),
            .text("."),
        ])])

        // Alignment is whole-paragraph and independent of the inline styling.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.apply(.alignment(.center))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        let aligned = ScriptMarkdown.parse(project.script)
        #expect(aligned.map(\.alignment) == [.center])
        #expect(aligned == [.paragraph([
            .text("Guts raises his "),
            .styledText(TextRun(text: "sword", textColor: .blue)),
            .text("."),
        ], alignment: .center)])
    }

    @Test("A note ends on an empty line, or on the same key that started it")
    func leavingANote() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "Goku's training begins.", in: scratch)
        let model = scratch.model

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.insertText("\nHold this panel a beat.", replacementRange: textView.selectedRange())
        let noteLine = (textView.string as NSString).range(of: "Hold this panel a beat.")
        textView.setSelectedRange(NSRange(location: noteLine.location, length: 0))
        coordinator.apply(.note)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(model.isWritingNote)

        // Return at the end of a note with words in it carries the note on:
        // what gets typed next is still part of the aside.
        textView.setSelectedRange(NSRange(location: noteLine.location + noteLine.length, length: 0))
        let carriesOn = coordinator.textView(textView, shouldChangeTextIn: textView.selectedRange(),
                                             replacementString: "\n")
        #expect(carriesOn)
        textView.insertText("\n", replacementRange: textView.selectedRange())
        textView.insertText("And a second line of it.", replacementRange: textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).map(\.isNote) == [false, true, true])

        // Return at the end of that, leaving an empty note line...
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.insertText("\n", replacementRange: textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.publishSpanAtCursor()
        #expect(model.isWritingNote)

        // ...and Return again lets go of the note instead of making another.
        let letsGo = coordinator.textView(textView, shouldChangeTextIn: textView.selectedRange(),
                                          replacementString: "\n")
        #expect(!letsGo)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).map(\.isNote) == [false, true, true, false])
        #expect(!model.isWritingNote)

        // And the same key that starts a note ends one.
        textView.setSelectedRange(NSRange(location: noteLine.location, length: 0))
        coordinator.publishSpanAtCursor()
        coordinator.publishSpanAtCursor()
        #expect(model.isWritingNote)
        model.toggleNote()
        #expect(project.pendingCommand == .body)
        project.pendingCommand = nil
        coordinator.apply(.body)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(!model.isWritingNote)
        model.toggleNote()
        #expect(project.pendingCommand == .note)
    }

    @Test("A block's label says the pages, and the chapter only when it differs")
    func spanLabelText() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, _, project) = try editor(script: "Nothing yet.", in: scratch)

        project.register(ItemRef(itemID: "ch24|1", filename: "Chapter 024.cbr", fileSize: 1,
                                 series: "Dragon Ball + Super", chapter: 24, title: "Ch. 24"))
        let elsewhere = PageSpan(id: "k7m2pq", itemID: "ch24|1", firstPageIndex: 3,
                                 pageNumbers: [4, 7], text: "Dragon Ball + Super, Ch. 24, pp. 4–7")
        project.manifest.store(elsewhere)

        // No comic open, so the block is not about what's on screen: the
        // chapter earns its place.
        #expect(coordinator.spanLabelText(for: "k7m2pq") == "Ch. 24 · pp. 4–7")
        // An id nothing knows about draws nothing at all.
        #expect(coordinator.spanLabelText(for: "nope12") == nil)
    }

    @Test("A block keeps growing as the writing continues, until it's ended")
    func blockKeepsGrowing() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let (coordinator, textView, project) = try editor(script: "Nothing yet.", in: scratch)

        let span = PageSpan(id: "k7m2pq", itemID: "b.cbz|1", firstPageIndex: 11,
                            pageNumbers: [12, 17], text: "Berserk, Vol. 1, pp. 12–17")
        project.manifest.store(span)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applySpan(.start(span))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).map(\.spanID) == ["k7m2pq"])

        // Carry on writing: the new paragraphs join the block by themselves.
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.insertText("\nStill the same beat.", replacementRange: textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).map(\.spanID) == ["k7m2pq", "k7m2pq"])

        // End it, and what follows belongs to no block.
        coordinator.applySpan(.end)
        textView.insertText("\nA different subject.", replacementRange: textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        let after = ScriptMarkdown.parse(project.script)
        #expect(after.map(\.spanID) == ["k7m2pq", "k7m2pq", nil])
        #expect(textView.spanRuns().count == 1)

        // Removing takes the whole run off at once.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applySpan(.remove)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(ScriptMarkdown.parse(project.script).allSatisfy { $0.spanID == nil })
        #expect(textView.spanRuns().isEmpty)
    }

    @Test("Shots come back in script order, and a deleted chip leaves an unused citation")
    func shotOrder() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Order", series: "Berserk")

        // Three citations, made in one order...
        let first = Citation(itemID: "b|1", pageIndex: 10, pageNumbers: [11], text: "first")
        let second = Citation(itemID: "b|1", pageIndex: 20, pageNumbers: [21], text: "second")
        let third = Citation(itemID: "b|1", pageIndex: 30, pageNumbers: [31], text: "third")
        project.manifest.citations = [first, second, third]

        // ...and written into the script in another, with one left out.
        project.script = """
        # Beat one
        The bear falls [third](panels://cite/\(third.id)) and then [first](panels://cite/\(first.id)).
        """

        #expect(project.citationsInScriptOrder.map(\.text) == ["third", "first"])
        #expect(project.unusedCitations.map(\.text) == ["second"])
        #expect(project.context(of: third.id) == "The bear falls and then .")

        project.removeCitation(id: second.id)
        #expect(project.unusedCitations.isEmpty)
        #expect(project.manifest.citations.count == 2)
    }

    @Test("Cleaning up trashes only what the script doesn't use")
    func cleanUp() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Clean", series: "B")

        func writeCapture(_ name: String) throws {
            try Data(repeating: 7, count: 2048).write(to: project.capturesFolder.appendingPathComponent(name))
        }
        // One cited, one whose chip was deleted, one belonging to no citation
        // at all — a page saved automatically beside a panel, as used to happen.
        try writeCapture("kept.png")
        try writeCapture("orphan.png")
        try writeCapture("stray.png")
        let kept = Citation(itemID: "b|1", pageIndex: 1, pageNumbers: [2], captureFile: "kept.png", text: "kept")
        let orphan = Citation(itemID: "b|1", pageIndex: 5, pageNumbers: [6], captureFile: "orphan.png", text: "orphan")
        project.manifest.citations = [kept, orphan]
        project.script = "Only [kept](panels://cite/\(kept.id)) is in the script."

        #expect(Set(project.unusedCaptureFiles.map(\.lastPathComponent)) == ["orphan.png", "stray.png"])
        #expect(project.unusedCaptureBytes == 4096)

        let gone = project.cleanUpUnusedCaptures()
        #expect(gone.files == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(left == ["kept.png"])
        #expect(project.manifest.citations.map(\.id) == [kept.id])
        #expect(project.unusedCaptureFiles.isEmpty)
    }

    @Test("Cleaning up leaves the writer's manifest describing what's really there")
    func cleanUpPrunesWriterManifest() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Prune", series: "B")

        // Two captures written properly, so captures.json knows them both.
        let writer = CaptureWriter(folder: project.capturesFolder)
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        let image = context.makeImage()!
        func record(_ page: Int) -> CaptureRecord {
            CaptureRecord(kind: .page, series: "B", volume: 1, chapter: nil, pages: [page], panel: nil,
                          region: nil, citation: "p\(page)", source: "b.cbz", file: "")
        }
        let keptFile = try writer.write(image, record: record(1)).record.file
        let droppedFile = try writer.write(image, record: record(2)).record.file
        #expect(writer.loadManifest().count == 2)

        let cited = Citation(itemID: "b|1", pageIndex: 0, pageNumbers: [1], captureFile: keptFile, text: "kept")
        project.manifest.citations = [cited]
        project.script = "Only [kept](panels://cite/\(cited.id))."

        project.cleanUpUnusedCaptures()

        let onDisk = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(onDisk == [keptFile])
        #expect(writer.loadManifest().map(\.file) == [keptFile])
        #expect(!writer.loadManifest().contains { $0.file == droppedFile })
    }

    @Test("Removing one citation trashes its capture, but not one still cited")
    func removeOne() throws {
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let project = try scratch.project(named: "Remove", series: "B")
        for name in ["a.png", "b.png"] {
            try Data(repeating: 1, count: 16).write(to: project.capturesFolder.appendingPathComponent(name))
        }
        let a = Citation(itemID: "b|1", pageIndex: 0, pageNumbers: [1], captureFile: "a.png", text: "a")
        let b = Citation(itemID: "b|1", pageIndex: 1, pageNumbers: [2], captureFile: "b.png", text: "b")
        project.manifest.citations = [a, b]
        project.script = "Kept [b](panels://cite/\(b.id))."

        project.removeCitation(id: a.id)
        let left = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(left == ["b.png"])
    }

    @Test("A capture lands in the project's captures folder as a citation with its shape — and needs a project")
    func captureIntoProject() async throws {
        guard let path = Self.comicPath else {
            withKnownIssue("Set PANELS_TEST_CBR to run.") { Issue.record("skipped") }
            return
        }
        let scratch = try Scratch()
        defer { scratch.tearDown() }
        let model = scratch.model

        model.addToLibrary(URL(fileURLWithPath: path))
        #expect(await Self.wait { model.hasComic })
        let page = model.pages[10]
        let triangle = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.3, y: 0.5)]

        // Without a project there's nowhere for a capture to go.
        #expect(!model.canCapture)
        model.toggleCapture()
        #expect(!model.isCapturing)
        model.capture(page: page, shape: .polygon(triangle))
        #expect(model.lastCaptureMessage?.contains("project") == true)

        model.newProject(named: "Shots")
        let project = try #require(model.project)
        #expect(model.canCapture)
        model.capture(page: page, shape: .polygon(triangle))
        #expect(await Self.wait(seconds: 20) { project.manifest.citations.count == 1 })

        let citation = project.manifest.citations[0]
        #expect(citation.polygon == triangle.pagePoints)
        #expect(citation.pageIndex == 10)
        #expect(citation.itemID == model.item?.id)
        let file = try #require(citation.captureFile)
        #expect(FileManager.default.fileExists(atPath: project.capturesFolder.appendingPathComponent(file).path))
        // Only the shape: the whole page is its own command, not a companion.
        let written = try FileManager.default.contentsOfDirectory(atPath: project.capturesFolder.path)
            .filter { $0.hasSuffix(".png") }
        #expect(written == [file])
        #expect(project.pendingInsertion?.id == citation.id)
    }
}
