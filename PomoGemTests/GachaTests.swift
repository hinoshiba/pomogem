import XCTest
import SpriteKit
import UIKit
@testable import PomoGem

final class GachaTests: XCTestCase {
    private struct CountingRandomNumberGenerator: RandomNumberGenerator {
        private(set) var callCount = 0
        let value: UInt64

        init(value: UInt64 = .max) {
            self.value = value
        }

        mutating func next() -> UInt64 {
            callCount += 1
            return value
        }
    }

    func testGoldGuaranteeDisclosureMatchesTheActualDeterministicBoundary() {
        XCTAssertEqual(Constants.Gacha.pityMissCount, 20)
        XCTAssertEqual(
            GachaEngine.goldGuaranteeDisclosure,
            "250gごとの抽選で金が20回続けて出なかった場合、次の抽選は金の粒になります。虹はこの回数をリセットしません。"
        )
        XCTAssertEqual(GachaEngine.creditsUntilGuaranteedGold(sinceLastGold: 0), 21)
        XCTAssertEqual(GachaEngine.creditsUntilGuaranteedGold(sinceLastGold: 20), 1)
    }

    func testStandardAndQuietModesPreserveDrawOutcomeAndStateMutation() {
        for mode in [RareRewardMode.standard, .quiet] {
            let expectedState = GachaState(sinceLastGold: 7)
            var expectedGenerator = CountingRandomNumberGenerator()
            _ = GachaEngine.draw(
                source: .timer,
                completedSeconds: Constants.Gacha.minimumEligibleSeconds,
                state: expectedState,
                using: &expectedGenerator
            )

            let actualState = GachaState(sinceLastGold: 7)
            var actualGenerator = CountingRandomNumberGenerator()
            let actual = RareRewardPolicy.draw(
                source: .timer,
                completedSeconds: Constants.Gacha.minimumEligibleSeconds,
                mode: mode,
                state: actualState,
                using: &actualGenerator
            )

            XCTAssertEqual(actualState.sinceLastGold, expectedState.sinceLastGold)
            XCTAssertEqual(actual.kind, .normal)
            XCTAssertEqual(actual.creditOutcomes, [.normal])
            XCTAssertTrue(actual.participated)
            XCTAssertEqual(actual.consumedCreditCount, 1)
            XCTAssertEqual(actual.acceptedContributionGrams, 250)
            XCTAssertEqual(actual.creditRemainderGrams, 0)
            XCTAssertEqual(actualState.sinceLastGold, 8)
            XCTAssertEqual(actualState.rewardCreditGrams, 250)
            XCTAssertEqual(actualGenerator.callCount, expectedGenerator.callCount)
            XCTAssertGreaterThan(actualGenerator.callCount, 0)
        }
    }

    func testUnselectedPreferenceResolvesOffBeforeRandomGeneratorIsAsked() {
        let preferences = [Prefs(
            rareRewardModeRawValue: RareRewardMode.standard.rawValue,
            rareRewardModeUpdatedAt: nil
        )]
        let state = GachaState(sinceLastGold: 12)
        var generator = CountingRandomNumberGenerator(value: 0)

        let result = RareRewardPolicy.draw(
            source: .timer,
            completedSeconds: Constants.Gacha.minimumEligibleSeconds,
            mode: RareRewardMode.resolved(preferences: preferences),
            state: state,
            using: &generator
        )

        XCTAssertEqual(result.kind, .normal)
        XCTAssertFalse(result.participated)
        XCTAssertFalse(result.wasEligible)
        XCTAssertEqual(result.sinceLastGold, 12)
        XCTAssertEqual(state.sinceLastGold, 12)
        XCTAssertEqual(generator.callCount, 0)
    }

    func testOffModeNeverDrawsOrChangesPityAcrossFortyYearsOfEligibleCompletions() {
        let eligibleCompletionCount = 350_640
        let initialPity = Constants.Gacha.pityMissCount - 1
        let state = GachaState(sinceLastGold: initialPity)
        var generator = CountingRandomNumberGenerator(value: 0)
        var allResultsAreNormal = true
        var anyResultWasEligible = false
        var anyResultTriggeredPity = false
        var everyResultPreservedPity = true

        for _ in 0 ..< eligibleCompletionCount {
            let result = RareRewardPolicy.draw(
                source: .timer,
                completedSeconds: Constants.Gacha.minimumEligibleSeconds,
                mode: .off,
                state: state,
                using: &generator
            )
            allResultsAreNormal = allResultsAreNormal && result.kind == .normal
            anyResultWasEligible = anyResultWasEligible || result.wasEligible
            anyResultTriggeredPity = anyResultTriggeredPity || result.triggeredPity
            everyResultPreservedPity = everyResultPreservedPity
                && result.sinceLastGold == initialPity
        }

        XCTAssertTrue(allResultsAreNormal)
        XCTAssertFalse(anyResultWasEligible)
        XCTAssertFalse(anyResultTriggeredPity)
        XCTAssertTrue(everyResultPreservedPity)
        XCTAssertEqual(state.sinceLastGold, initialPity)
        XCTAssertEqual(state.rewardCreditGrams, 0)
        XCTAssertEqual(generator.callCount, 0, "off must not consume a hidden random value")
    }

    func testEqualSixHundredGramRoutesEarnTwoCreditsAndCarryOneHundredGrams() {
        func run(_ contributions: [(seconds: Int, grams: Int)])
            -> (draws: Int, remainder: Int, total: Int, pity: Int, rngCalls: Int) {
            let state = GachaState()
            var generator = CountingRandomNumberGenerator()
            var draws = 0
            for contribution in contributions {
                let roll = RareRewardPolicy.draw(
                    source: .timer,
                    completedSeconds: contribution.seconds,
                    completedGrams: contribution.grams,
                    mode: .standard,
                    state: state,
                    using: &generator
                )
                draws += roll.consumedCreditCount
            }
            return (
                draws,
                state.rewardCreditRemainderGrams,
                state.rewardCreditGrams,
                state.sinceLastGold,
                generator.callCount
            )
        }

        let tenBySix = run(Array(
            repeating: (seconds: 10 * 60, grams: 100),
            count: 6
        ))
        let twentyFiveTwicePlusTen = run([
            (seconds: 25 * 60, grams: 250),
            (seconds: 25 * 60, grams: 250),
            (seconds: 10 * 60, grams: 100)
        ])
        let sixtyOnce = run([(seconds: 60 * 60, grams: 600)])

        XCTAssertEqual(tenBySix.draws, 2)
        XCTAssertEqual(tenBySix.remainder, 100)
        XCTAssertEqual(tenBySix.total, 600)
        XCTAssertEqual(tenBySix.pity, 2)
        XCTAssertEqual(tenBySix.rngCalls, 2)
        XCTAssertEqual(twentyFiveTwicePlusTen.draws, tenBySix.draws)
        XCTAssertEqual(twentyFiveTwicePlusTen.remainder, tenBySix.remainder)
        XCTAssertEqual(twentyFiveTwicePlusTen.total, tenBySix.total)
        XCTAssertEqual(twentyFiveTwicePlusTen.pity, tenBySix.pity)
        XCTAssertEqual(twentyFiveTwicePlusTen.rngCalls, tenBySix.rngCalls)
        XCTAssertEqual(sixtyOnce.draws, tenBySix.draws)
        XCTAssertEqual(sixtyOnce.remainder, tenBySix.remainder)
        XCTAssertEqual(sixtyOnce.total, tenBySix.total)
        XCTAssertEqual(sixtyOnce.pity, tenBySix.pity)
        XCTAssertEqual(sixtyOnce.rngCalls, tenBySix.rngCalls)
    }

    func testOffFreezesExistingCarryAndDoesNotBankDisabledMass() {
        let state = GachaState(
            sinceLastGold: Constants.Gacha.pityMissCount - 1,
            rewardCreditGrams: 200
        )
        var generator = CountingRandomNumberGenerator()

        let disabled = RareRewardPolicy.draw(
            source: .timer,
            completedSeconds: 60 * 60,
            completedGrams: 600,
            mode: .off,
            state: state,
            using: &generator
        )
        XCTAssertFalse(disabled.participated)
        XCTAssertEqual(disabled.consumedCreditCount, 0)
        XCTAssertEqual(disabled.creditRemainderGrams, 200)
        XCTAssertEqual(state.rewardCreditGrams, 200)
        XCTAssertEqual(state.sinceLastGold, Constants.Gacha.pityMissCount - 1)
        XCTAssertEqual(generator.callCount, 0)

        let resumed = RareRewardPolicy.draw(
            source: .timer,
            completedSeconds: 10 * 60,
            completedGrams: 100,
            mode: .standard,
            state: state,
            using: &generator
        )
        XCTAssertTrue(resumed.participated)
        XCTAssertEqual(resumed.consumedCreditCount, 1)
        XCTAssertEqual(resumed.creditRemainderGrams, 50)
        XCTAssertEqual(state.rewardCreditGrams, 300)
        XCTAssertEqual(state.sinceLastGold, Constants.Gacha.pityMissCount)
        XCTAssertEqual(generator.callCount, 1)
    }

    func testMultiCreditCompletionPreservesEveryOutcomeWhileGoldRepresentsThePebble() {
        let state = GachaState(sinceLastGold: Constants.Gacha.pityMissCount)
        var generator = CountingRandomNumberGenerator(value: 0)

        let result = RareRewardPolicy.draw(
            source: .timer,
            completedSeconds: 60 * 60,
            completedGrams: 600,
            mode: .standard,
            state: state,
            using: &generator
        )

        XCTAssertEqual(result.consumedCreditCount, 2)
        XCTAssertEqual(result.creditOutcomes, [.gold, .prism])
        XCTAssertEqual(result.kind, .gold, "pity gold must not be hidden by batch presentation")
        XCTAssertTrue(result.triggeredPity)
        XCTAssertEqual(state.sinceLastGold, 1, "the post-gold prism remains a gold miss")
        XCTAssertEqual(generator.callCount, 2)
        let encoded = RareRewardOutcomeCodec.encode(result.creditOutcomes)
        XCTAssertEqual(RareRewardOutcomeCodec.decode(encoded), [.gold, .prism])

        let session = StudySession(
            startAt: .now.addingTimeInterval(-3_600),
            endAt: .now,
            seconds: 3_600,
            source: .timer,
            pebbleKind: result.kind,
            grams: 600,
            deviceDayKey: "fixture",
            rareRewardRuleVersion: Constants.Gacha.creditRuleVersion,
            rareRewardParticipated: true,
            rareRewardCreditedGrams: 600,
            rareRewardOutcomesRawValue: encoded
        )
        XCTAssertEqual(
            session.rareRewardCounts,
            RareRewardCounts(drawCount: 2, goldCount: 1, prismCount: 1)
        )
        XCTAssertEqual(
            PebbleDescriptor(session: session).rewardBatchSummary,
            "250gごとの抽選2回（金1・虹1）"
        )
    }

    func testManualDemotedAndDebugLengthCompletionsCannotAdvanceCreditMass() {
        for (source, seconds) in [
            (SessionSource.manual, 60 * 60),
            (.timerDemoted, 60 * 60),
            // The DEBUG planning/demo timer is intentionally 12 seconds.
            (.timer, 12)
        ] {
            let state = GachaState(sinceLastGold: 4, rewardCreditGrams: 125)
            var generator = CountingRandomNumberGenerator(value: 0)
            let result = RareRewardPolicy.draw(
                source: source,
                completedSeconds: seconds,
                completedGrams: 600,
                mode: .standard,
                state: state,
                using: &generator
            )
            XCTAssertFalse(result.participated)
            XCTAssertEqual(result.consumedCreditCount, 0)
            XCTAssertEqual(state.rewardCreditGrams, 125)
            XCTAssertEqual(state.sinceLastGold, 4)
            XCTAssertEqual(generator.callCount, 0)
        }
    }

    func testCreditAllocationIsOverflowSafeAndBoundsMalformedCompletionMass() {
        let saturated = RareRewardCreditPolicy.allocation(
            previousTotalGrams: Int.max,
            completedGrams: Int.max,
            source: .timer
        )
        XCTAssertEqual(saturated.totalGrams, Int.max)
        XCTAssertEqual(saturated.acceptedContributionGrams, 0)
        XCTAssertEqual(saturated.earnedCreditCount, 0)

        let bounded = RareRewardCreditPolicy.allocation(
            previousTotalGrams: 249,
            completedGrams: Int.max,
            source: .timer
        )
        XCTAssertEqual(bounded.acceptedContributionGrams, 3_600)
        XCTAssertEqual(bounded.earnedCreditCount, 15)
        XCTAssertEqual(bounded.remainderGrams, 99)
    }

    func testSixHourRewardPreservesAllCreditsAndRejectsOversizedOutcomePayload() {
        let state = GachaState(rewardCreditGrams: 249)
        var generator = CountingRandomNumberGenerator()
        let result = RareRewardPolicy.draw(
            source: .timer, completedSeconds: 21_600, completedGrams: 3_600,
            mode: .standard, state: state, using: &generator
        )
        XCTAssertEqual(result.acceptedContributionGrams, 3_600)
        XCTAssertEqual(result.consumedCreditCount, 15)
        XCTAssertEqual(result.creditRemainderGrams, 99)
        XCTAssertEqual(state.rewardCreditGrams, 3_849)
        XCTAssertEqual(generator.callCount, 15)
        XCTAssertEqual(result.creditOutcomes, Array(repeating: .normal, count: 15))
        XCTAssertEqual(
            RareRewardOutcomeCodec.decode(RareRewardOutcomeCodec.encode(result.creditOutcomes)),
            result.creditOutcomes
        )
        XCTAssertNil(RareRewardOutcomeCodec.decode(RareRewardOutcomeCodec.encode(
            Array(repeating: .normal, count: 16)
        )))
    }

    func testLegacyGachaStateKeepsPityAndStartsMassLedgerAtZero() {
        let legacy = GachaState(sinceLastGold: 13)
        XCTAssertEqual(legacy.sinceLastGold, 13)
        XCTAssertEqual(legacy.rewardCreditGrams, 0)
        XCTAssertEqual(legacy.earnedRewardCreditCount, 0)
        XCTAssertEqual(legacy.rewardCreditRemainderGrams, 0)
    }

    func testLegacyStudySessionHasNoInventedRewardParticipation() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = StudySession(
            startAt: end.addingTimeInterval(-3_600),
            endAt: end,
            seconds: 3_600,
            source: .timer,
            pebbleKind: .gold,
            grams: 600,
            deviceDayKey: "2027-01-01"
        )

        XCTAssertNil(legacy.rareRewardRuleVersion)
        XCTAssertNil(legacy.rareRewardParticipated)
        XCTAssertNil(legacy.rareRewardCreditedGrams)
        XCTAssertNil(legacy.rareRewardOutcomesRawValue)
        XCTAssertNil(RareRewardOutcomeCodec.decode(legacy.rareRewardOutcomesRawValue))
        XCTAssertEqual(
            legacy.rareRewardCounts,
            RareRewardCounts(drawCount: 1, goldCount: 1, prismCount: 0)
        )
    }

    func testNaturalRatesAcrossOneHundredThousandUniformRolls() {
        let trialCount = 100_000
        var goldCount = 0
        var prismCount = 0

        for index in 0 ..< trialCount {
            let roll = (Double(index) + 0.5) / Double(trialCount)
            switch GachaEngine.naturalKind(forUnitRoll: roll) {
            case .normal:
                break
            case .gold:
                goldCount += 1
            case .prism:
                prismCount += 1
            }
        }

        let goldRate = Double(goldCount) / Double(trialCount)
        let prismRate = Double(prismCount) / Double(trialCount)
        XCTAssertEqual(goldRate, Constants.Gacha.goldProbability, accuracy: 0.005)
        XCTAssertEqual(prismRate, Constants.Gacha.prismProbability, accuracy: 0.002)
    }

    func testNaturalRateBoundariesAreDisjoint() {
        XCTAssertEqual(GachaEngine.naturalKind(forUnitRoll: 0), .prism)
        XCTAssertEqual(
            GachaEngine.naturalKind(forUnitRoll: Constants.Gacha.prismProbability),
            .gold
        )
        XCTAssertEqual(
            GachaEngine.naturalKind(
                forUnitRoll: Constants.Gacha.prismProbability + Constants.Gacha.goldProbability
            ),
            .normal
        )
    }

    func testTwentyMissCreditsMakeFollowingCreditGuaranteedGold() {
        var misses = 0
        for expectedMisses in 1 ... Constants.Gacha.pityMissCount {
            let roll = GachaEngine.draw(
                source: .timer,
                completedSeconds: Constants.Gacha.minimumEligibleSeconds,
                sinceLastGold: misses,
                unitRoll: 0.99
            )
            XCTAssertEqual(roll.kind, .normal)
            XCTAssertFalse(roll.triggeredPity)
            XCTAssertEqual(roll.sinceLastGold, expectedMisses)
            misses = roll.sinceLastGold
        }

        let pity = GachaEngine.draw(
            source: .timer,
            completedSeconds: Constants.Gacha.minimumEligibleSeconds,
            sinceLastGold: misses,
            unitRoll: 0.99
        )
        XCTAssertEqual(pity.kind, .gold)
        XCTAssertTrue(pity.triggeredPity)
        XCTAssertEqual(pity.sinceLastGold, 0)
    }

    func testNaturalGoldResetsCounterButPrismDoesNot() {
        let gold = GachaEngine.draw(
            source: .timer,
            completedSeconds: Constants.Gacha.minimumEligibleSeconds,
            sinceLastGold: 12,
            unitRoll: Constants.Gacha.prismProbability
        )
        XCTAssertEqual(gold.kind, .gold)
        XCTAssertEqual(gold.sinceLastGold, 0)

        let prism = GachaEngine.draw(
            source: .timer,
            completedSeconds: Constants.Gacha.minimumEligibleSeconds,
            sinceLastGold: 12,
            unitRoll: 0
        )
        XCTAssertEqual(prism.kind, .prism)
        XCTAssertEqual(prism.sinceLastGold, 13)
    }

    func testManualAndDemotedSessionsNeverDrawOrConsumePity() {
        for source in [SessionSource.manual, .timerDemoted] {
            let result = GachaEngine.draw(
                source: source,
                completedSeconds: Constants.Gacha.minimumEligibleSeconds,
                sinceLastGold: Constants.Gacha.pityMissCount,
                unitRoll: 0
            )
            XCTAssertEqual(result.kind, .normal)
            XCTAssertFalse(result.wasEligible)
            XCTAssertFalse(result.triggeredPity)
            XCTAssertEqual(result.sinceLastGold, Constants.Gacha.pityMissCount)
        }
    }

    func testPersistedStateOverloadUpdatesCounter() {
        let state = GachaState(sinceLastGold: Constants.Gacha.pityMissCount)
        let result = GachaEngine.draw(
            source: .timer,
            completedSeconds: Constants.Gacha.minimumEligibleSeconds,
            state: state,
            unitRoll: 0.99
        )
        XCTAssertEqual(result.kind, .gold)
        XCTAssertEqual(state.sinceLastGold, 0)
    }

    func testNaturalProbabilityDisclosureMatchesOutcomeBoundaries() {
        let total = PebbleKind.allCases.reduce(0.0) {
            $0 + GachaEngine.naturalProbability(for: $1)
        }
        XCTAssertEqual(total, 1, accuracy: 0.000_001)
        XCTAssertEqual(GachaEngine.probabilityLabel(for: .gold), "8%")
        XCTAssertEqual(GachaEngine.probabilityLabel(for: .prism), "0.8%")
        XCTAssertEqual(GachaEngine.probabilityLabel(for: .normal), "91.2%")
    }

    func testGoldGuaranteeRemainingCreditCountIsClampedAndPrismDoesNotResetIt() {
        XCTAssertEqual(
            GachaEngine.creditsUntilGuaranteedGold(sinceLastGold: 0),
            Constants.Gacha.pityMissCount + 1
        )
        XCTAssertEqual(
            GachaEngine.creditsUntilGuaranteedGold(
                sinceLastGold: Constants.Gacha.pityMissCount
            ),
            1
        )
        XCTAssertEqual(GachaEngine.creditsUntilGuaranteedGold(sinceLastGold: 999), 1)

        let prism = GachaEngine.draw(
            source: .timer,
            completedSeconds: Constants.Gacha.minimumEligibleSeconds,
            sinceLastGold: Constants.Gacha.pityMissCount - 1,
            unitRoll: 0
        )
        XCTAssertEqual(prism.kind, .prism)
        XCTAssertEqual(prism.sinceLastGold, Constants.Gacha.pityMissCount)
        XCTAssertEqual(
            GachaEngine.creditsUntilGuaranteedGold(sinceLastGold: prism.sinceLastGold),
            1
        )
    }

    func testLegacyCompletionPrimitiveRetainsPreMigrationDurationGate() {
        let short = GachaEngine.draw(
            source: .timer,
            completedSeconds: Constants.Gacha.minimumEligibleSeconds - 1,
            sinceLastGold: Constants.Gacha.pityMissCount,
            unitRoll: 0
        )
        XCTAssertEqual(short.kind, .normal)
        XCTAssertFalse(short.wasEligible)
        XCTAssertFalse(short.triggeredPity)
        XCTAssertEqual(short.sinceLastGold, Constants.Gacha.pityMissCount)
    }

    func testLegacyCompletionPrimitiveRepresentsExactlyOneOldDraw() {
        for seconds in [
            Constants.Gacha.minimumEligibleSeconds,
            Constants.Timer.sixtyMinutes * Constants.Timer.secondsPerMinute,
            Constants.Timer.customMaximumMinutes * Constants.Timer.secondsPerMinute
        ] {
            let result = GachaEngine.draw(
                source: .timer,
                completedSeconds: seconds,
                sinceLastGold: 0,
                unitRoll: Constants.Gacha.prismProbability
            )
            XCTAssertTrue(result.wasEligible)
            XCTAssertEqual(result.kind, .gold)
            XCTAssertEqual(result.sinceLastGold, 0)
        }
    }

    @MainActor
    func testRarePebblesRemainDistinguishableWithoutColor() {
        let gold = PebbleNode(
            descriptor: PebbleDescriptor(
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .gold,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            reduceMotion: true
        )
        let prism = PebbleNode(
            descriptor: PebbleDescriptor(
                subjectName: "数学",
                colorHex: Constants.Color.mathematics,
                source: .timer,
                kind: .prism,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            reduceMotion: true
        )

        XCTAssertEqual((gold.childNode(withName: "rare.mark") as? SKLabelNode)?.text, "✦")
        XCTAssertEqual((prism.childNode(withName: "rare.mark") as? SKLabelNode)?.text, "◇")
        XCTAssertNotNil(gold.childNode(withName: "rare.innerRing"))
        XCTAssertNotNil(prism.childNode(withName: "rare.innerRing"))
    }

    @MainActor
    func testPrismShaderStopsTimeAnimationWhenReduceMotionIsEnabled() {
        let prism = PebbleNode(
            descriptor: PebbleDescriptor(
                subjectName: "科学",
                colorHex: Constants.Color.science,
                source: .timer,
                kind: .prism,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            reduceMotion: false
        )

        XCTAssertTrue(prism.fillShader?.source?.contains("u_time") == true)
        prism.setReduceMotion(true)
        XCTAssertFalse(prism.fillShader?.source?.contains("u_time") == true)
        prism.setReduceMotion(false)
        XCTAssertTrue(prism.fillShader?.source?.contains("u_time") == true)
    }

    @MainActor
    func testRareLooseGemPresentationModesKeepMarksWhileReducingOptionalEffects() throws {
        for kind in [PebbleKind.gold, .prism] {
            let descriptor = PebbleDescriptor(
                id: kind == .gold
                    ? UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
                    : UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!,
                subjectName: kind == .gold ? "英語" : "数学",
                colorHex: kind == .gold
                    ? Constants.Color.english
                    : Constants.Color.mathematics,
                source: .timer,
                kind: kind,
                grams: Constants.Mass.measuredPebbleGrams
            )
            let standard = PebbleNode(
                descriptor: descriptor,
                reduceMotion: false,
                rareRewardMode: .standard
            )
            let quiet = PebbleNode(
                descriptor: descriptor,
                reduceMotion: false,
                rareRewardMode: .quiet
            )
            let off = PebbleNode(
                descriptor: descriptor,
                reduceMotion: false,
                rareRewardMode: .off
            )
            let strongGlowScale = kind == .gold
                ? Constants.Jar.goldGlowScale
                : Constants.Jar.prismGlowScale

            XCTAssertEqual(
                standard.glowWidth,
                descriptor.radius * strongGlowScale,
                accuracy: 0.001
            )
            XCTAssertEqual(quiet.glowWidth, descriptor.radius * 0.10, accuracy: 0.001)
            XCTAssertEqual(off.glowWidth, descriptor.radius * 0.10, accuracy: 0.001)
            XCTAssertGreaterThan(standard.glowWidth, quiet.glowWidth)
            XCTAssertEqual(quiet.glowWidth, off.glowWidth, accuracy: 0.001)

            if kind == .prism {
                XCTAssertTrue(
                    standard.fillShader?.source?.contains("u_time") == true,
                    "Standard prism presentation needs its animated material shader"
                )
            } else {
                XCTAssertNil(standard.fillShader, "Gold uses material and glow rather than a shader")
            }
            XCTAssertNil(quiet.fillShader)
            XCTAssertNil(off.fillShader)

            let expectedMark = kind == .gold ? "✦" : "◇"
            for (mode, pebble) in [
                (RareRewardMode.standard, standard),
                (.quiet, quiet),
                (.off, off)
            ] {
                let mark = try XCTUnwrap(
                    pebble.childNode(withName: "rare.mark") as? SKLabelNode
                )
                XCTAssertEqual(mark.text, expectedMark, "\(mode) must retain factual rarity")
                XCTAssertGreaterThan(mark.alpha, 0, "\(mode) must not hide the non-color mark")
                XCTAssertNotNil(pebble.childNode(withName: "rare.innerRing"))
            }
        }
    }

    @MainActor
    func testLiveRareRewardModeChangesUpdateExistingPrismWithoutRebuildingIt() throws {
        let descriptor = PebbleDescriptor(
            id: UUID(uuidString: "A2000000-0000-4000-8000-000000000001")!,
            subjectName: "科学",
            colorHex: Constants.Color.science,
            source: .timer,
            kind: .prism,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        scene.rareRewardMode = .standard
        scene.restore(pebbles: [descriptor])

        let pebble = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        let identity = ObjectIdentifier(pebble)
        let enhancedGlow = pebble.glowWidth
        XCTAssertTrue(pebble.fillShader?.source?.contains("u_time") == true)

        scene.rareRewardMode = .quiet
        XCTAssertEqual(pebble.rareRewardMode, .quiet)
        XCTAssertNil(pebble.fillShader)
        XCTAssertLessThan(pebble.glowWidth, enhancedGlow)
        XCTAssertNotNil(pebble.childNode(withName: "rare.mark"))

        scene.rareRewardMode = .off
        XCTAssertEqual(pebble.rareRewardMode, .off)
        XCTAssertNil(pebble.fillShader)
        XCTAssertEqual(pebble.glowWidth, descriptor.radius * 0.10, accuracy: 0.001)
        XCTAssertNotNil(pebble.childNode(withName: "rare.mark"))

        scene.rareRewardMode = .standard
        XCTAssertEqual(pebble.rareRewardMode, .standard)
        XCTAssertTrue(pebble.fillShader?.source?.contains("u_time") == true)
        XCTAssertEqual(pebble.glowWidth, enhancedGlow, accuracy: 0.001)
        XCTAssertEqual(ObjectIdentifier(pebble), identity, "Mode changes must update the live node")
    }

    @MainActor
    func testAchievementJewelPresentationIsUnchangedInQuietMode() throws {
        let descriptor = PebbleDescriptor(
            id: UUID(uuidString: "A3000000-0000-4000-8000-000000000001")!,
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )
        let pebble = PebbleNode(
            descriptor: descriptor,
            reduceMotion: false,
            rareRewardMode: .standard
        )
        let originalGlow = pebble.glowWidth
        let originalHalo = pebble.gemHaloAlpha
        let originalFill = pebble.fillColor
        let originalStroke = pebble.strokeColor
        let originalMark = try XCTUnwrap(pebble.childNode(withName: "achievement.mark"))
        let loose = PebbleNode(
            descriptor: PebbleDescriptor(
                subjectName: "資格",
                colorHex: Constants.Color.science,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            reduceMotion: false
        )

        pebble.setRareRewardMode(.quiet)

        XCTAssertEqual(pebble.rareRewardMode, .quiet)
        // v1.2: the jewel glows through its copper-tinted halo sprite, which
        // is stronger than a loose gem's and never changes with the mode.
        XCTAssertEqual(originalGlow, 0, accuracy: 0.001)
        XCTAssertGreaterThan(originalHalo, loose.gemHaloAlpha)
        XCTAssertEqual(pebble.gemHaloAlpha, originalHalo, accuracy: 0.001)
        XCTAssertEqual(pebble.glowWidth, originalGlow, accuracy: 0.001)
        XCTAssertTrue(pebble.fillColor.isEqual(originalFill))
        XCTAssertTrue(pebble.strokeColor.isEqual(originalStroke))
        XCTAssertTrue(
            originalMark === pebble.childNode(withName: "achievement.mark"),
            "A rare-reward preference must not rebuild or dim an achievement mark"
        )
    }

    @MainActor
    func testAggregateKeepsDeterministicBaseGlowWhenRareEnhancementIsQuiet() throws {
        let sessionIDs = (1 ... 100).map { index in
            UUID(uuidString: String(
                format: "A4000000-0000-4000-8000-%012X",
                index
            ))!
        }
        let metadata = AggregateMetadata(
            level: 2,
            pebbleCount: 100,
            childAggregateCount: 10,
            colorMix: [StratumColorFraction(
                hex: Constants.Color.english,
                fraction: 1
            )],
            subjectMix: [AggregateSubjectFraction(
                name: "英語",
                colorHex: Constants.Color.english,
                pebbleCount: 100
            )],
            periodStart: Date(timeIntervalSince1970: 100),
            periodEnd: Date(timeIntervalSince1970: 200),
            sessionIDs: sessionIDs,
            measuredPebbleCount: 100,
            manualPebbleCount: 0,
            goldPebbleCount: 4,
            prismPebbleCount: 1
        )
        let descriptor = PebbleDescriptor(
            id: UUID(uuidString: "A4000000-0000-4000-8000-000000000101")!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: metadata,
            grams: 100 * Constants.Mass.measuredPebbleGrams,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let pebble = PebbleNode(
            descriptor: descriptor,
            reduceMotion: true,
            rareRewardMode: .standard
        )
        // v1.2: the earned bloom is the halo sprite inside `aggregate.aura`
        // (no glowWidth neon rim). Rare enhancement may brighten it; quiet
        // and off return to the deterministic, gram-derived base glow.
        XCTAssertNotNil(pebble.childNode(withName: "aggregate.aura/gem.halo"))
        XCTAssertEqual(pebble.glowWidth, 0, accuracy: 0.001)
        let enhancedHalo = pebble.gemHaloAlpha

        pebble.setRareRewardMode(.quiet)
        let baseHalo = pebble.gemHaloAlpha
        XCTAssertGreaterThan(baseHalo, 0, "The earned aggregate keeps its base glow")
        XCTAssertGreaterThan(enhancedHalo, baseHalo)

        pebble.setRareRewardMode(.off)
        XCTAssertEqual(pebble.gemHaloAlpha, baseHalo, accuracy: 0.001)
    }

    @MainActor
    func testEarlyEffortSpotlightNeverChangesStonePhysicsOrMass() {
        let descriptor = PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
        let radius = pebble.radius
        let mass = pebble.physicsBody?.mass

        pebble.setEarlyEffortSpotlight(true)
        XCTAssertNotNil(pebble.childNode(withName: "pebble.earlyEffortAura"))
        XCTAssertEqual(pebble.radius, radius)
        XCTAssertEqual(pebble.descriptor.grams, descriptor.grams)
        XCTAssertEqual(pebble.physicsBody?.mass, mass)

        pebble.setEarlyEffortSpotlight(false)
        XCTAssertNil(pebble.childNode(withName: "pebble.earlyEffortAura"))
    }

    /// Round 13: the mark is engraved in the moonstone, upright however the
    /// stone rolls, and VoiceOver keeps the kind. Round 14: the groove is at
    /// least 4.5:1 against the crown (WCAG AA for the small 「100」 and
    /// 「W」), 7:1 with Increase Contrast (main's former floor), for every
    /// kind and for any hue a stone could take.
    @MainActor
    func testEveryAchievementMarkHasHighContrastUprightTreatment() {
        for kind in AchievementKind.allCases {
            let descriptor = PebbleDescriptor(
                subjectName: "記念",
                colorHex: Constants.Color.english,
                source: .manual,
                kind: .normal,
                achievementKind: kind,
                grams: 0
            )
            let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
            let originalRadius = pebble.radius
            let originalMass = pebble.physicsBody?.mass

            guard let mark = pebble.childNode(withName: "achievement.mark") as? SKSpriteNode else {
                XCTFail("\(kind) needs its engraved mark")
                continue
            }
            XCTAssertNil(pebble.childNode(withName: "achievement.markBackdrop"), "No badge plate behind the mark")
            XCTAssertNotNil(mark.texture)
            for increased in [false, true] {
                let colors = GemArtwork.achievementEngravingColors(hex: kind.gemBaseHex, increasedContrast: increased)
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(colors.groove.withAlpha(1), colors.surface.withAlpha(1)),
                    increased ? 7 : 4.5,
                    "\(kind) stays readable in the moonstone"
                )
            }
            XCTAssertEqual(mark.accessibilityLabel, kind.title)
            XCTAssertEqual(mark.blendMode, .alpha)
            XCTAssertFalse(mark.hasActions())

            pebble.zRotation = .pi / 3
            pebble.updatePresentationLighting(horizontal: 0)
            XCTAssertEqual(mark.zRotation, -pebble.zRotation, accuracy: 0.001)

            XCTAssertEqual(pebble.radius, originalRadius)
            XCTAssertEqual(pebble.physicsBody?.mass, originalMass)
            XCTAssertEqual(pebble.descriptor.grams, 0)
            XCTAssertFalse(pebble.descriptor.participatesInAggregation)
        }
    }

    /// The Overview's achievement card engraves in the milestone's own
    /// colour, so the floors hold for every hue, not only the three kinds.
    func testAchievementEngravingKeepsItsContrastFloorForEveryHue() {
        for step in 0 ..< 72 {
            let hex = GemColor(hue: CGFloat(step) / 72, saturation: 0.7, brightness: 0.8).hexString
            for increased in [false, true] {
                let colors = GemArtwork.achievementEngravingColors(hex: hex, increasedContrast: increased)
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(colors.groove.withAlpha(1), colors.surface.withAlpha(1)),
                    increased ? 7 : 4.5,
                    hex
                )
            }
        }
    }

    /// Round 14: turning Increase Contrast on while the jar is shown re-bakes
    /// the engraving (and the facet edges) at once; turning it off returns
    /// to the default bake.
    @MainActor
    func testIncreaseContrastReachesLiveStonesWithoutARestore() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        scene.bakesGemBedInBackground = false
        let stone = PebbleDescriptor(
            id: UUID(uuidString: "D0C20000-0000-4000-8000-000000000001")!,
            subjectName: "記念",
            colorHex: Constants.Color.english,
            source: .manual,
            kind: .normal,
            achievementKind: .perfectScore,
            grams: 0
        )
        let gem = PebbleDescriptor(
            id: UUID(uuidString: "D0C20000-0000-4000-8000-000000000002")!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        scene.restore(pebbles: [stone, gem])
        let pebbles = scene.children.flatMap(\.children).compactMap { $0 as? PebbleNode }
        let achievement = try XCTUnwrap(pebbles.first { $0.descriptor.isAchievement })
        let loose = try XCTUnwrap(pebbles.first { !$0.descriptor.isAchievement })
        let mark = try XCTUnwrap(achievement.childNode(withName: "achievement.mark") as? SKSpriteNode)

        scene.setIncreasedContrast(true)
        XCTAssertEqual(GemTextureAtlas.shared.textureName(of: mark)?.hasSuffix("|c"), true, "The deeper groove")
        XCTAssertEqual(loose.displayedBodySpec?.edgeBoost, 0.2, "Brighter facet edges")
        XCTAssertEqual(achievement.displayedBodySpec?.edgeBoost, 0.2)

        scene.setIncreasedContrast(false)
        XCTAssertEqual(GemTextureAtlas.shared.textureName(of: mark)?.hasSuffix("|c"), false)
        XCTAssertEqual(loose.displayedBodySpec?.edgeBoost, 0)
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))

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
