import XCTest
@testable import Tsumiben

final class PostDropProgressAccessibilityPresentationTests: XCTestCase {
    func testJarAnnouncesMassBeforeCountBasedOrganizationAndAchievements() throws {
        let message = JarAccessibilityPresentation.value(
            totalGrams: 3_100,
            pebbleCount: 2,
            achievementCount: 1,
            aggregateCount: 1,
            representedPebbleCount: 12,
            goldPebbleCount: 1,
            prismPebbleCount: 0,
            fusionProgressDescription: "×100へ 1/10",
            projectionIsLowerBound: false
        )

        let massRange = try XCTUnwrap(message.range(of: "集中時間の質量：3.10キログラム"))
        let organizationRange = try XCTUnwrap(message.range(of: "瓶の整理"))
        let achievementRange = try XCTUnwrap(message.range(of: "記念石1個"))
        XCTAssertLessThan(massRange.lowerBound, organizationRange.lowerBound)
        XCTAssertLessThan(organizationRange.lowerBound, achievementRange.lowerBound)
        XCTAssertTrue(message.contains("合計12粒分"))
        XCTAssertTrue(message.contains("金1粒"))
        XCTAssertTrue(message.contains("×100へ 1/10"))
    }

    func testJarNeverClaimsAnExactMassDuringPartialProjection() {
        let message = JarAccessibilityPresentation.value(
            totalGrams: 600,
            pebbleCount: 1,
            achievementCount: 0,
            aggregateCount: 0,
            representedPebbleCount: 1,
            goldPebbleCount: 0,
            prismPebbleCount: 0,
            fusionProgressDescription: nil,
            projectionIsLowerBound: true
        )

        XCTAssertTrue(message.hasPrefix("現在確認できた集中時間の質量：600グラム以上、同期中"))
        XCTAssertFalse(message.hasPrefix("記録した集中時間の質量"))
    }

    func testMassReceiptAnnouncesEffortBeforeSecondaryJarOrganization() throws {
        let message = PostDropProgressAccessibilityPresentation.description(
            effortProgress: EffortProgressPolicy.snapshot(
                totalGrams: 3_100,
                latestContributionGrams: 600
            ),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 10),
            projectionIsLowerBound: false
        )

        let effortRange = try XCTUnwrap(message.range(of: "時間の核"))
        let organizationRange = try XCTUnwrap(message.range(of: "瓶の整理"))
        XCTAssertLessThan(effortRange.lowerBound, organizationRange.lowerBound)
        XCTAssertTrue(message.contains("5時間10分"))
        XCTAssertTrue(message.contains("10/10"))
    }

    func testPartialMassReceiptStillLeadsWithKnownContribution() {
        let message = PostDropProgressAccessibilityPresentation.description(
            effortProgress: EffortProgressPolicy.snapshot(
                totalGrams: 600,
                latestContributionGrams: 600
            ),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 3),
            projectionIsLowerBound: true
        )

        XCTAssertTrue(message.hasPrefix("今回の完走で1時間を追加"))
        XCTAssertTrue(message.contains("時間の核を同期中"))
        XCTAssertTrue(message.contains("瓶の整理"))
        XCTAssertTrue(message.contains("結晶進捗を同期中"))
    }

    func testLegacyReceiptKeepsCountCompatibilityPresentation() {
        let message = PostDropProgressAccessibilityPresentation.description(
            effortProgress: nil,
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 9),
            projectionIsLowerBound: false
        )

        XCTAssertTrue(message.hasPrefix("×10へ 9/10"))
        XCTAssertTrue(message.contains("あと1粒"))
        XCTAssertFalse(message.contains("時間の核"))
    }
}
