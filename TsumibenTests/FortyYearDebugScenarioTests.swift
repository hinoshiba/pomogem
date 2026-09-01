#if DEBUG
import XCTest
@testable import Tsumiben

final class FortyYearDebugScenarioTests: XCTestCase {
    @MainActor
    func testFortyYearsRemainExactAndRenderWithinThePhysicsBudget() async throws {
        let report = try await FortyYearDebugScenario.run()

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.dayCount, 14_610)
        XCTAssertEqual(report.completionCount, 350_640)
        XCTAssertEqual(report.focusHours, 146_100)
        XCTAssertEqual(report.grams, 87_660_000)
        XCTAssertEqual(report.pebbleCount, report.completionCount)
        XCTAssertEqual(report.bodiesByLevel, [1: 4, 2: 6, 4: 5, 5: 3])
        XCTAssertEqual(report.aggregateCreationCount, 38_958)
        XCTAssertLessThanOrEqual(
            report.maximumStudyBodyCount,
            Constants.Jar.maxPhysicsBodies
        )

        XCTAssertEqual(report.normalCount, 313_820)
        XCTAssertEqual(report.goldCount, 34_067)
        XCTAssertEqual(report.prismCount, 2_753)
        XCTAssertEqual(report.pityGoldCount, 6_315)
        XCTAssertEqual(report.finalMissesSinceGold, 4)
        let finalRootGoldCount = report.bodies.reduce(0) {
            $0 + $1.goldPebbleCount
        }
        let finalRootPrismCount = report.bodies.reduce(0) {
            $0 + $1.prismPebbleCount
        }
        XCTAssertTrue(report.bodies.allSatisfy(\.isAggregate))
        XCTAssertEqual(finalRootGoldCount, report.goldCount)
        XCTAssertEqual(finalRootPrismCount, report.prismCount)
        XCTAssertEqual(finalRootGoldCount, 34_067)
        XCTAssertEqual(finalRootPrismCount, 2_753)
        XCTAssertEqual(
            finalRootGoldCount + finalRootPrismCount + report.normalCount,
            report.completionCount,
            "The final root frontier must account for every rare result exactly once"
        )
        XCTAssertEqual(report.subjectTotals.map(\.pebbleCount), Array(repeating: 70_128, count: 5))
        XCTAssertEqual(report.achievements.count, 120)
        XCTAssertEqual(report.visibleAchievements.count, 12)

        let scene = JarScene(size: CGSize(
            width: Constants.Jar.defaultSceneWidth,
            height: Constants.Jar.height
        ))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.restore(pebbles: report.descriptors)

        XCTAssertEqual(scene.physicalPebbleCount, 30)
        XCTAssertEqual(scene.representedPebbleCount, 350_640)
        XCTAssertLessThanOrEqual(scene.physicalPebbleCount, Constants.Jar.maxPhysicsBodies)
    }
}
#endif
