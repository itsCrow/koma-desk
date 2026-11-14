import Testing
@testable import KomaDesk

@Suite("Home search")
struct HomeSearchTests {
    @Test("Every word has to match somewhere, ignoring case and accents")
    func matching() {
        #expect(HomeSearch.matches("", "Berserk"))
        #expect(HomeSearch.matches("   ", "Berserk"))
        #expect(HomeSearch.matches("BERS", "Berserk"))
        #expect(HomeSearch.matches("pokemon adv", "Pokémon Adventures"))
        // Across names: a project's own name and its series.
        #expect(HomeSearch.matches("eclipse berserk", "The Eclipse", "Berserk"))
        #expect(!HomeSearch.matches("eclipse vagabond", "The Eclipse", "Berserk"))
        #expect(!HomeSearch.matches("dragon", "Berserk"))
    }
}
