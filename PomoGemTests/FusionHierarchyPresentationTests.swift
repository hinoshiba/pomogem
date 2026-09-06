import XCTest
@testable import PomoGem

final class FusionHierarchyPresentationTests: XCTestCase {
    func testRequiredBoundaryValuesDecomposeIntoExactDecimalLevels() {
        let fixtures: [(total: Int, digits: [Int])] = [
            (0, [0]),
            (1, [1]),
            (9, [9]),
            (10, [0, 1]),
            (99, [9, 9]),
            (100, [0, 0, 1]),
            (999, [9, 9, 9]),
            (1_000, [0, 0, 0, 1]),
            (350_640, [0, 4, 6, 0, 5, 3])
        ]

        for fixture in fixtures {
            let snapshot = FusionHierarchyPresentation.snapshot(
                totalPebbleCount: fixture.total
            )
            XCTAssertEqual(
                snapshot.levels.map(\.unitCount),
                fixture.digits,
                "Unexpected digits for \(fixture.total)"
            )
            XCTAssertEqual(snapshot.representedPebbleCount, fixture.total)
        }
    }

    func testFortyYearHierarchyPreservesGapsUnitsAndRepresentedCounts() {
        let snapshot = FusionHierarchyPresentation.snapshot(totalPebbleCount: 350_640)

        XCTAssertEqual(snapshot.levels.map(\.level), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(
            snapshot.levels.map(\.unitPebbleCount),
            [1, 10, 100, 1_000, 10_000, 100_000]
        )
        XCTAssertEqual(
            snapshot.levels.map(\.representedPebbleCount),
            [0, 40, 600, 0, 50_000, 300_000]
        )
        XCTAssertEqual(
            snapshot.activeLevels.map(\.level),
            [1, 2, 4, 5]
        )
        XCTAssertEqual(snapshot.highestActiveLevel, 5)
        XCTAssertEqual(snapshot.representedPebbleCount, 350_640)
    }

    func testNextFusionHorizonReportsExactDistanceAndCarryChain() {
        let zero = FusionHierarchyPresentation.snapshot(totalPebbleCount: 0)
            .nextFusionHorizon
        XCTAssertEqual(zero.sourceUnitCount, 0)
        XCTAssertEqual(zero.remainingPebbleCount, 10)
        XCTAssertEqual(zero.cascadingDestinationLevels, [1])

        let nine = FusionHierarchyPresentation.snapshot(totalPebbleCount: 9)
            .nextFusionHorizon
        XCTAssertEqual(nine.sourceUnitCount, 9)
        XCTAssertEqual(nine.remainingPebbleCount, 1)
        XCTAssertEqual(nine.cascadingDestinationLevels, [1])

        let ninetyNine = FusionHierarchyPresentation.snapshot(totalPebbleCount: 99)
            .nextFusionHorizon
        XCTAssertEqual(ninetyNine.representedPebbleCountInDestination, 9)
        XCTAssertEqual(ninetyNine.remainingPebbleCount, 1)
        XCTAssertEqual(ninetyNine.cascadingDestinationLevels, [1, 2])

        let nineHundredNinetyNine = FusionHierarchyPresentation.snapshot(
            totalPebbleCount: 999
        ).nextFusionHorizon
        XCTAssertEqual(nineHundredNinetyNine.remainingPebbleCount, 1)
        XCTAssertEqual(
            nineHundredNinetyNine.cascadingDestinationLevels,
            [1, 2, 3]
        )
    }

    func testHomeHorizonContinuesExistingCrystalTierInsteadOfResettingLooseDigit() {
        let firstCrystal = FusionHierarchyPresentation.snapshot(totalPebbleCount: 10)
            .homeFusionHorizon
        XCTAssertEqual(firstCrystal.sourceLevel, 1)
        XCTAssertEqual(firstCrystal.destinationLevel, 2)
        XCTAssertEqual(firstCrystal.sourceUnitCount, 1)
        XCTAssertEqual(firstCrystal.requiredSourceUnitCount, 10)
        XCTAssertEqual(firstCrystal.representedPebbleCountInDestination, 10)
        XCTAssertEqual(firstCrystal.destinationPebbleCount, 100)
        XCTAssertEqual(firstCrystal.remainingPebbleCount, 90)
        XCTAssertEqual(firstCrystal.progressFraction, 0.1, accuracy: 0.000_001)

        let ninetyNine = FusionHierarchyPresentation.snapshot(totalPebbleCount: 99)
            .homeFusionHorizon
        XCTAssertEqual(ninetyNine.sourceLevel, 1)
        XCTAssertEqual(ninetyNine.sourceUnitCount, 9)
        XCTAssertEqual(ninetyNine.remainingPebbleCount, 1)
        XCTAssertEqual(ninetyNine.cascadingDestinationLevels, [2])

        let oneHundred = FusionHierarchyPresentation.snapshot(totalPebbleCount: 100)
            .homeFusionHorizon
        XCTAssertEqual(oneHundred.sourceLevel, 2)
        XCTAssertEqual(oneHundred.destinationLevel, 3)
        XCTAssertEqual(oneHundred.sourceUnitCount, 1)
        XCTAssertEqual(oneHundred.remainingPebbleCount, 900)

        let oneThousand = FusionHierarchyPresentation.snapshot(totalPebbleCount: 1_000)
            .homeFusionHorizon
        XCTAssertEqual(oneThousand.sourceLevel, 3)
        XCTAssertEqual(oneThousand.destinationLevel, 4)
        XCTAssertEqual(oneThousand.sourceUnitCount, 1)
        XCTAssertEqual(oneThousand.remainingPebbleCount, 9_000)

        let fortyYears = FusionHierarchyPresentation.snapshot(totalPebbleCount: 350_640)
            .homeFusionHorizon
        XCTAssertEqual(fortyYears.sourceLevel, 1)
        XCTAssertEqual(fortyYears.destinationLevel, 2)
        XCTAssertEqual(fortyYears.sourceUnitCount, 4)
        XCTAssertEqual(fortyYears.representedPebbleCountInDestination, 40)
        XCTAssertEqual(fortyYears.remainingPebbleCount, 60)
    }

    func testPreCrystalHomeHorizonMatchesChronologicallyNextFusion() {
        for total in [0, 1, 9] {
            let snapshot = FusionHierarchyPresentation.snapshot(totalPebbleCount: total)
            XCTAssertEqual(snapshot.homeFusionHorizon, snapshot.nextFusionHorizon)
        }
    }

    func testNegativeTotalsAreSafelyPresentedAsZero() {
        let snapshot = FusionHierarchyPresentation.snapshot(totalPebbleCount: -1)

        XCTAssertEqual(snapshot.totalPebbleCount, 0)
        XCTAssertEqual(snapshot.levels, [
            FusionHierarchyLevel(
                level: 0,
                unitCount: 0,
                unitPebbleCount: 1,
                representedPebbleCount: 0
            )
        ])
        XCTAssertEqual(snapshot.nextFusionHorizon.remainingPebbleCount, 10)
    }

    func testMaximumIntegerStillDecomposesWithoutOverflow() {
        let snapshot = FusionHierarchyPresentation.snapshot(totalPebbleCount: .max)

        XCTAssertEqual(snapshot.representedPebbleCount, .max)
        XCTAssertEqual(snapshot.levels.last?.unitPebbleCount, 1_000_000_000_000_000_000)
        XCTAssertLessThanOrEqual(
            snapshot.homeFusionHorizon.destinationPebbleCount,
            Int.max
        )
    }
}
