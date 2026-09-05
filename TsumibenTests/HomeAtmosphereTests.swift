import Testing
import UIKit
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

    @Test @MainActor
    func overviewDisclosureTextMeetsWCAGAAOnOpaqueCard() {
        let ratio = contrastRatio(
            UIColor(TsumibenTheme.text),
            UIColor(TsumibenTheme.card)
        )

        #expect(ratio != nil)
        #expect((ratio ?? 0) >= 4.5)
    }

    @Test @MainActor
    func overviewStatTextMeetsWCAGAAOnOpaqueRaisedSurface() {
        let ratio = contrastRatio(
            UIColor(TsumibenTheme.text),
            UIColor(TsumibenTheme.raised)
        )

        #expect(ratio != nil)
        #expect((ratio ?? 0) >= 4.5)
    }

    private func contrastRatio(
        _ first: UIColor,
        _ second: UIColor
    ) -> CGFloat? {
        guard let firstLuminance = relativeLuminance(first),
              let secondLuminance = relativeLuminance(second)
        else { return nil }
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}
