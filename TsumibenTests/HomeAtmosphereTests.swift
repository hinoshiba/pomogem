import Testing
@testable import Tsumiben

struct HomeAtmosphereTests {
    @Test func invalidStoredValueFallsBackToMidnight() {
        #expect(HomeAtmosphere.resolved("removed-theme") == .midnight)
    }

    @Test func everyAtmosphereHasACompletePresentation() {
        for atmosphere in HomeAtmosphere.allCases {
            #expect(!atmosphere.title.isEmpty)
            #expect(!atmosphere.subtitle.isEmpty)
            #expect(!atmosphere.systemImage.isEmpty)
            #expect(atmosphere.paletteHexes.count == 3)
            #expect(atmosphere.paletteHexes.allSatisfy { $0.count == 6 })
        }
    }
}
