import SwiftUI
import XCTest
@testable import PomoGem

/// Pins the two share layouts added after review: tags wrap instead of
/// being cut or scrolled away, and 記念石 in the drawn bottle rest on what
/// is under them instead of floating on a fixed shelf.
@MainActor
final class ShareLayoutTests: XCTestCase {
    // MARK: - Tags

    func testFlowLinesWrapInsteadOfOverflowing() {
        XCTAssertEqual(
            ShareFlowLayout.lines(widths: [60, 60, 60], maxWidth: 200, spacing: 8),
            [[0, 1, 2]]
        )
        XCTAssertEqual(
            ShareFlowLayout.lines(widths: [60, 60, 60, 60], maxWidth: 200, spacing: 8),
            [[0, 1, 2], [3]]
        )
        // An item wider than the line gets a line of its own at line width.
        XCTAssertEqual(
            ShareFlowLayout.lines(widths: [60, 400, 60], maxWidth: 200, spacing: 8),
            [[0], [1], [2]]
        )
        XCTAssertEqual(ShareFlowLayout.lines(widths: [], maxWidth: 200, spacing: 8), [])
        XCTAssertEqual(
            ShareFlowLayout.lines(widths: [100, 92], maxWidth: 200, spacing: 8),
            [[0, 1]],
            "Exactly filling the line is not an overflow"
        )
    }

    func testEveryTagChoiceAndALongCustomTagStayOnTheCard() throws {
        // Four chips plus a 30-character custom tag used to be scaled on one
        // line and cut with 「…」 in the exported image.
        let custom = "#" + String(repeating: "集", count: ShareHashtagPolicy.maximumBodyLength)
        XCTAssertNotNil(ShareHashtagPolicy.normalized(custom))
        let hashtags = ShareCopy.hashtagChoices + [custom]
        let contentWidth = ShareCardLayoutPolicy.canvasSize(for: .feed).width
            - ShareCardLayoutPolicy.contentInsets(for: .feed).leading
            - ShareCardLayoutPolicy.contentInsets(for: .feed).trailing

        for story in [false, true] {
            let single = try rowSize(hashtags: [ShareCopy.hashtags[0]], story: story, width: contentWidth)
            let all = try rowSize(hashtags: hashtags, story: story, width: contentWidth)
            XCTAssertLessThanOrEqual(all.width, contentWidth + 0.5, "story=\(story)")
            XCTAssertGreaterThan(
                all.height,
                single.height * 1.5,
                "The tags must wrap onto a second line (story=\(story))"
            )
            XCTAssertLessThan(all.height, single.height * 3.5, "story=\(story)")
        }
    }

    func testCardsWithEveryTagRenderForVisualReview() throws {
        let custom = "#" + String(repeating: "集", count: ShareHashtagPolicy.maximumBodyLength)
        for format in ShareComposerView.Format.allCases {
            let size = ShareCardLayoutPolicy.canvasSize(for: format)
            let card = ShareCardView(
                sessions: sampleSessions(count: 3),
                aggregates: [],
                achievements: [sampleStone()],
                includesSelfReportedFocus: false,
                format: format,
                jarSnapshot: nil,
                periodLabel: "これまで",
                hashtags: ShareCopy.hashtagChoices + [custom],
                animationPhase: 0.25
            )
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: card)
            renderer.proposedSize = ProposedViewSize(size)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, size.width)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Share card \(format == .feed ? "4x5" : "9x16") all tags and a stone"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Stones in the drawn bottle

    func testStonesBesideAFewGemsRestOnTheFloor() {
        // One gem at the far left; the stones are centred, over empty glass.
        let gem = ShareJarPileLayout.Footprint(minX: -100, maxX: -74, top: 7 + 21)
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [-54, -18],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: [gem]
        )
        XCTAssertEqual(bottoms, [7, 7], "Nothing is under them, so they sit on the floor")
    }

    func testStonesRestOnTheGemsUnderThem() {
        let gems = (0..<8).map { column -> ShareJarPileLayout.Footprint in
            let x = CGFloat(column - 4) * 20
            return ShareJarPileLayout.Footprint(minX: x - 9, maxX: x + 9, top: 7 + 16)
        }
        let taller = ShareJarPileLayout.Footprint(minX: 50, maxX: 70, top: 7 + 32)
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [-20, 60],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: gems + [taller]
        )
        XCTAssertEqual(bottoms, [23, 39])
    }

    func testLaterStonesStackOnEarlierOnes() {
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [0, 13.6, 200],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: []
        )
        XCTAssertEqual(bottoms, [7, 32, 7])
    }

    func testAStoneTouchingOnlyAnEdgeIsNotLifted() {
        // The neighbour's edge reaches under the stone's rounded corner but
        // not its middle.
        let neighbour = ShareJarPileLayout.Footprint(minX: -40, maxX: -12, top: 60)
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [0],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: [neighbour]
        )
        XCTAssertEqual(bottoms, [7])
    }

    // MARK: - Fixtures

    private func rowSize(hashtags: [String], story: Bool, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(
            content: ShareCardHashtagRow(hashtags: hashtags, story: story)
                .frame(width: width)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage).size
    }

    private func sampleSessions(count: Int) -> [ShareSessionVisual] {
        (0..<count).map { index in
            ShareSessionVisual(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                grams: 250,
                source: .timer,
                kind: .normal,
                rewardCounts: RareRewardCounts(drawCount: 1, goldCount: 0, prismCount: 0),
                colorHex: Constants.Color.mathematics,
                endAt: Date(timeIntervalSinceReferenceDate: Double(index * 1_500))
            )
        }
    }

    private func sampleStone() -> ShareAchievementVisual {
        ShareAchievementVisual(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            kind: .examPass,
            colorHex: Constants.Color.english
        )
    }
}
