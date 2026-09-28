import Testing
@testable import Panels

@Suite("Lettering copied off a page")
struct LetteringTests {
    @Test("A balloon's lines come back as the one line they were written as")
    func joinsLines() {
        #expect(Lettering.oneLine("I CAN'T\nBELIEVE\nIT'S YOU!") == "I CAN'T BELIEVE IT'S YOU!")
        #expect(Lettering.oneLine("One line already.") == "One line already.")
    }

    @Test("A hyphen at a break keeps the word whole; an interruption keeps its space")
    func hyphens() {
        #expect(Lettering.oneLine("A WELL-\nKNOWN FACT") == "A WELL-KNOWN FACT")
        #expect(Lettering.oneLine("I THOUGHT--\nNO.") == "I THOUGHT-- NO.")
        #expect(Lettering.oneLine("WAIT—\nWHAT?") == "WAIT— WHAT?")
        #expect(Lettering.oneLine("AND THEN…\nNOTHING.") == "AND THEN… NOTHING.")
    }

    @Test("Stray whitespace, blank lines and Windows line endings don't leave gaps")
    func whitespace() {
        #expect(Lettering.oneLine("  HEY  \r\n\r\n  YOU  \n") == "HEY YOU")
        #expect(Lettering.oneLine("A\u{2028}B") == "A B")
        #expect(Lettering.oneLine("\n\n") == "")
    }

    @Test("A copy is the page's selection when it's the same words with the breaks still in")
    func recognisesTheCopy() {
        let selected = "I CAN'T\nBELIEVE\nIT'S YOU!"
        #expect(Lettering.isCopy(of: selected, pasteboard: selected))
        #expect(Lettering.isCopy(of: selected, pasteboard: "I CAN'T\r\nBELIEVE\r\nIT'S YOU!\n"))
        // Already one line, but still in capitals: still the page's copy.
        #expect(Lettering.isCopy(of: selected, pasteboard: "I CAN'T BELIEVE IT'S YOU!"))
        // Something else entirely, copied while a selection lingers.
        #expect(!Lettering.isCopy(of: selected, pasteboard: "Notes from\nsomewhere else"))
        #expect(!Lettering.isCopy(of: "", pasteboard: "\n"))
    }

    @Test("Lettering in capitals reads as sentences")
    func sentenceCase() {
        #expect(Lettering.sentenceCase("I CAN'T BELIEVE IT'S YOU!") == "I can't believe it's you!")
        #expect(Lettering.sentenceCase("WAIT! WHAT ARE YOU DOING?") == "Wait! What are you doing?")
        #expect(Lettering.sentenceCase("AND THEN... NOTHING.") == "And then... nothing.")
        #expect(Lettering.sentenceCase("AND THEN… NOTHING.") == "And then… nothing.")
        #expect(Lettering.sentenceCase("I THOUGHT-- NO.") == "I thought-- no.")
        #expect(Lettering.sentenceCase("\"GET DOWN!\" HE SAID") == "\"Get down!\" he said")
        #expect(Lettering.sentenceCase("I'M SURE I’LL BE FINE. IT'S IN ME, I'D SAY.") == "I'm sure I’ll be fine. It's in me, I'd say.")
        // "I" only as a word, never inside one.
        #expect(Lettering.sentenceCase("IT IS I, KING OF THE ISLE") == "It is I, king of the isle")
        // Already written in mixed case: left alone.
        #expect(Lettering.sentenceCase("Already fine, iPhone and all.") == "Already fine, iPhone and all.")
        #expect(Lettering.sentenceCase("...!?") == "...!?")
    }

    @Test("A copy is the page's selection when it still has capitals to take out, even on one line")
    func recognisesCapitals() {
        #expect(Lettering.isCopy(of: "WAIT!", pasteboard: "WAIT!"))
        #expect(Lettering.forScript("I CAN'T\nBELIEVE\nIT'S YOU!") == "I can't believe it's you!")
        // Already as the script wants it: nothing to do.
        #expect(!Lettering.isCopy(of: "WAIT!", pasteboard: "Wait!"))
    }
}
