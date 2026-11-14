import AppKit
import OSLog
import VisionKit

/// Lettering copied off a page. A balloon breaks its words across short
/// lines to fit the shape, and Live Text keeps those breaks — so a line of
/// dialogue lands in the script as four. Copying puts it back together.
enum Lettering {
    /// A balloon's lines as the one line they were written as: "WELL-" and
    /// "KNOWN" become "WELL-KNOWN" — lettering hyphenates real compounds too
    /// often to drop the hyphen — and every other break becomes a space.
    static func oneLine(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var result = ""
        for line in lines {
            if !result.isEmpty && !endsInWordBreak(result) { result += " " }
            result += line
        }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// What a copy off a page becomes: one line, and in sentence case if
    /// it was lettered in capitals.
    static func forScript(_ text: String) -> String {
        sentenceCase(oneLine(text))
    }

    /// Lettering in capitals — which is nearly all of it — as a sentence
    /// would be written: "WAIT! I'M COMING" becomes "Wait! I'm coming".
    /// Lettering already in mixed case is left as it is; a name in capitals
    /// comes out lowercase, since there's no telling it from any other word.
    static func sentenceCase(_ text: String) -> String {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty,
              Double(letters.filter(\.isUppercase).count) >= Double(letters.count) * 0.8
        else { return text }

        let chars = Array(text.lowercased())
        var result = ""
        var capitalizeNext = true
        // A full stop, "!" or "?" just passed — one more space and the next
        // letter opens a sentence. An ellipsis or a dash carries the same
        // sentence on, the way lettering uses them; so does a closing quote,
        // since what follows "GET DOWN!" is "he said".
        var sentenceEnded = false
        for (index, c) in chars.enumerated() {
            if c.isLetter {
                result += capitalizeNext ? c.uppercased() : String(c)
                capitalizeNext = false
                sentenceEnded = false
                continue
            }
            result.append(c)
            if c == "!" || c == "?" {
                sentenceEnded = true
            } else if c == "." {
                let inEllipsis = (index > 0 && chars[index - 1] == ".")
                    || (index + 1 < chars.count && chars[index + 1] == ".")
                sentenceEnded = !inEllipsis
            } else if c.isWhitespace {
                if sentenceEnded { capitalizeNext = true }
                sentenceEnded = false
            } else if !capitalizeNext {
                sentenceEnded = false
            }
        }
        // "I", on its own or in "I'm", "I'll", "I've", "I'd".
        return result.replacingOccurrences(
            of: "(?<![\\p{L}\\p{N}'’])i(?=(?:['’](?:m|ll|ve|d))?(?![\\p{L}\\p{N}]))",
            with: "I", options: .regularExpression)
    }

    /// A single hyphen straight after a letter — not "--", which is an
    /// interruption and wants its space.
    private static func endsInWordBreak(_ s: String) -> Bool {
        guard s.hasSuffix("-"), !s.hasSuffix("--") else { return false }
        return s.dropLast().last?.isLetter ?? false
    }

    /// Whether `pasteboard` is `selected` as the system copied it — the
    /// same words, still with breaks or capitals to take out. Anything else
    /// on the pasteboard came from somewhere else and is left exactly as it is.
    static func isCopy(of selected: String, pasteboard: String) -> Bool {
        guard forScript(pasteboard) != pasteboard else { return false }
        let joined = oneLine(pasteboard)
        return !joined.isEmpty && joined == oneLine(selected)
    }

    // MARK: - Copying off a page

    private static let log = Logger(subsystem: "com.mida.KomaDesk", category: "Lettering")

    /// Every page's Live Text overlay, so a copy can be matched to the
    /// selection it came from. Weak: a page going off screen takes its
    /// overlay with it.
    @MainActor static let overlays = NSHashTable<ImageAnalysisOverlayView>.weakObjects()

    /// Lettering copied off a page lands on the pasteboard as one line,
    /// however the copy was asked for — ⌘C, Edit ▸ Copy, Live Text's own
    /// right-click menu. The system does that copying and never says so,
    /// so rather than chase every way in, this watches what arrives:
    ///
    /// - ⌘C is caught before it reaches anything, so it's instant.
    /// - Everything else is noticed on the pasteboard a moment later, and
    ///   rewritten when it's the page's selection with its breaks in.
    /// - ⌥⌘C is left alone, for when the lines matter.
    @MainActor static func installCopyMonitor(model: ReaderModel) {
        watcher.model = model
        watcher.start()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.charactersIgnoringModifiers == "c" else { return event }
            if modifiers == [.command, .option] {
                // The system copies on; the copy it makes is the one to keep.
                watcher.keepNextCopy = true
                log.debug("⌥⌘C: keeping the line breaks")
                return event
            }
            guard modifiers == .command else { return event }
            let responder = event.window?.firstResponder
            log.debug("⌘C, first responder \(String(describing: responder.map { type(of: $0) }), privacy: .public)")
            guard let text = selectedText(in: event.window) else { return event }
            watcher.write(forScript(text))
            return nil
        }
    }

    @MainActor private static let watcher = PasteboardWatcher()

    /// Looks at the pasteboard a few times a second — its change count
    /// costs nothing to read — and notes what's selected on the pages, so a
    /// copy is still recognised if the selection is gone by the time the
    /// copy is noticed (a click into the script clears it straight away).
    @MainActor private final class PasteboardWatcher: NSObject {
        weak var model: ReaderModel?
        var keepNextCopy = false
        private var changeCount = NSPasteboard.general.changeCount
        private var lastSelection: (text: String, seen: Date)?
        private var timer: Timer?

        func start() {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        @objc private func tick() {
            if let text = anySelectedText() { lastSelection = (text, Date()) }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != changeCount else { return }
            changeCount = pasteboard.changeCount
            if keepNextCopy {
                keepNextCopy = false
                return
            }
            guard let copied = pasteboard.string(forType: .string) else { return }
            let selection = anySelectedText()
                ?? lastSelection.flatMap { Date().timeIntervalSince($0.seen) < 3 ? $0.text : nil }
            let matched = selection.map { isCopy(of: $0, pasteboard: copied) } ?? false
            log.debug("Pasteboard changed: \(copied.count) characters, breaks \(copied.rangeOfCharacter(from: .newlines) != nil), selection \(selection?.count ?? -1), matched \(matched)")
            guard matched else { return }
            write(forScript(copied))
        }

        func write(_ text: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // Its own write isn't a copy to look at again.
            changeCount = pasteboard.changeCount
            model?.lastCaptureMessage = "Copied for the script"
            log.debug("Copied for the script: \(text.count) characters")
        }

        /// What's selected on any page, whether or not it has the keyboard —
        /// the copy's content, not where the focus is, decides what happens.
        private func anySelectedText() -> String? {
            for overlay in overlays.allObjects where overlay.hasActiveTextSelection {
                let text = overlay.selectedText
                if !text.isEmpty { return text }
            }
            return nil
        }
    }

    /// The lettering selected on a page in `window`, if any is and it's
    /// what ⌘C would copy. A text field or the script with the keyboard
    /// copies its own selection — a page's can linger behind one — but
    /// Live Text's own selection view is text too, and is the page's.
    @MainActor private static func selectedText(in window: NSWindow?) -> String? {
        guard let window else { return nil }
        for overlay in overlays.allObjects where overlay.window === window {
            let active = overlay.hasActiveTextSelection
            let text = active ? overlay.selectedText : ""
            log.debug("Overlay: selection \(active), \(text.count) characters")
            guard active, !text.isEmpty else { continue }
            if let responder = window.firstResponder as? NSText, !responder.isDescendant(of: overlay) {
                log.debug("Left to \(String(describing: type(of: responder)), privacy: .public), which has the keyboard")
                return nil
            }
            return text
        }
        return nil
    }
}
