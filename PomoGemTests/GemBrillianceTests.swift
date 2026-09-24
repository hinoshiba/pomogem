import SpriteKit
import XCTest
@testable import PomoGem

/// Gem brilliance v1 is a rendering skin only. These tests pin the
/// invariants it must never break (physics, mass, obstacle matteness,
/// Reduce Motion) and the deterministic tier → cut mapping.
final class GemBrillianceTests: XCTestCase {
    private func looseDescriptor(
        id: UUID = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!,
        source: SessionSource = .timer,
        grams: Int = Constants.Mass.measuredPebbleGrams,
        isTutorial: Bool = false
    ) -> PebbleDescriptor {
        PebbleDescriptor(
            id: id,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: source,
            kind: .normal,
            grams: grams,
            isTutorial: isTutorial
        )
    }

    private func aggregateDescriptor(level: Int, grams: Int? = nil) -> PebbleDescriptor {
        let pebbleCount = Int(pow(10, Double(level)))
        let metadata = AggregateMetadata(
            level: level,
            pebbleCount: pebbleCount,
            childAggregateCount: level == 1 ? 0 : 10,
            colorMix: [
                StratumColorFraction(hex: Constants.Color.english, fraction: 0.6),
                StratumColorFraction(hex: Constants.Color.mathematics, fraction: 0.4)
            ],
            subjectMix: [AggregateSubjectFraction(
                name: "英語",
                colorHex: Constants.Color.english,
                pebbleCount: pebbleCount
            )],
            periodStart: Date(timeIntervalSince1970: 100),
            periodEnd: Date(timeIntervalSince1970: 200),
            sessionIDs: [],
            measuredPebbleCount: pebbleCount,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0
        )
        return PebbleDescriptor(
            id: UUID(uuidString: String(format: "C1000000-0000-4000-8000-%012X", level))!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: metadata,
            grams: grams ?? pebbleCount * Constants.Mass.measuredPebbleGrams
        )
    }

    func testCutLadderMapsExistingTiersDeterministically() {
        let ladder = GemCutLadder.standard
        XCTAssertEqual(ladder.rung(for: looseDescriptor()).cut, .tumbled)
        XCTAssertEqual(ladder.rung(for: looseDescriptor(source: .manual)).cut, .rough)
        XCTAssertEqual(ladder.rung(for: looseDescriptor(grams: 0, isTutorial: true)).cut, .glass)
        XCTAssertEqual(ladder.rung(aggregateLevel: 1).cut, .step)
        XCTAssertEqual(ladder.rung(aggregateLevel: 2).cut, .brilliant)
        XCTAssertEqual(ladder.rung(aggregateLevel: 3).cut, .radiant)
        XCTAssertEqual(ladder.rung(aggregateLevel: 9).cut, .radiant)
        // Light budget never decreases up the ladder.
        let rungs = (1 ... 6).map { ladder.rung(aggregateLevel: $0) }
        for (lower, higher) in zip(rungs, rungs.dropFirst()) {
            XCTAssertLessThanOrEqual(lower.haloAlpha, higher.haloAlpha)
            XCTAssertLessThanOrEqual(lower.glintCount, higher.glintCount)
        }
        XCTAssertLessThan(ladder.loose.haloAlpha, ladder.rung(aggregateLevel: 1).haloAlpha)
    }

    func testOutlinesStayInsideTheCircularPhysicsBody() {
        for cut in GemCut.allCases {
            for symmetry in [8, 10, 12] {
                for variant in 0 ..< GemArtworkSpec.variantCount {
                    let points = GemArtwork.outline(cut: cut, symmetry: symmetry, variant: variant)
                    XCTAssertGreaterThanOrEqual(points.count, 5)
                    for point in points {
                        XCTAssertLessThanOrEqual(hypot(point.x, point.y), 1.0001, "\(cut)")
                        // Silhouettes stay round enough to read as the body.
                        XCTAssertGreaterThan(hypot(point.x, point.y), 0.7, "\(cut)")
                    }
                }
            }
        }
    }

    @MainActor
    func testFacetedLooseGemKeepsPhysicsMassAndUsesSharedLightSprites() throws {
        let descriptor = looseDescriptor()
        let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
        let body = try XCTUnwrap(pebble.physicsBody)

        XCTAssertEqual(pebble.radius, descriptor.radius)
        XCTAssertEqual(pebble.radius, PebbleRadiusPolicy.measuredRadius(grams: descriptor.grams))
        XCTAssertEqual(
            body.area,
            SKPhysicsBody(circleOfRadius: descriptor.radius).area,
            accuracy: 0.0001,
            "The collision body stays the same circle"
        )
        XCTAssertEqual(pebble.glowWidth, 0, "Loose gems glow through the shared halo sprite")
        XCTAssertEqual(pebble.gemRung?.cut, .tumbled)

        let gemBody = try XCTUnwrap(pebble.childNode(withName: "gem.body") as? SKSpriteNode)
        let halo = try XCTUnwrap(pebble.childNode(withName: "gem.halo") as? SKSpriteNode)
        XCTAssertEqual(halo.texture, GemArtwork.haloTexture)
        XCTAssertEqual(halo.blendMode, .add)
        XCTAssertNotNil(pebble.childNode(withName: "//gem.glint"))
        XCTAssertNotNil(pebble.childNode(withName: "//pebble.dimensionalLight"))
        XCTAssertLessThanOrEqual(
            gemBody.size.width,
            GemArtwork.bodySpriteSize(radius: descriptor.radius).width + 0.001
        )

        // Equal gems share one baked texture.
        let twin = PebbleNode(descriptor: descriptor, reduceMotion: true)
        let twinBody = try XCTUnwrap(twin.childNode(withName: "gem.body") as? SKSpriteNode)
        XCTAssertTrue(gemBody.texture === twinBody.texture)
    }

    @MainActor
    func testGlowFollowsRecordedGramsNotCompletionCount() throws {
        let short = PebbleNode(descriptor: looseDescriptor(grams: 10), reduceMotion: true)
        let standard = PebbleNode(descriptor: looseDescriptor(), reduceMotion: true)
        let shortHalo = try XCTUnwrap(short.childNode(withName: "gem.halo"))
        let standardHalo = try XCTUnwrap(standard.childNode(withName: "gem.halo"))
        XCTAssertLessThan(shortHalo.alpha, standardHalo.alpha)

        // Same ×10 membership, a third of the time: a dimmer crystal.
        let full = PebbleNode(descriptor: aggregateDescriptor(level: 1), reduceMotion: true)
        let split = PebbleNode(
            descriptor: aggregateDescriptor(level: 1, grams: 10 * 80),
            reduceMotion: true
        )
        let fullHalo = try XCTUnwrap(full.childNode(withName: "gem.halo"))
        let splitHalo = try XCTUnwrap(split.childNode(withName: "gem.halo"))
        XCTAssertLessThan(splitHalo.alpha, fullHalo.alpha)
    }

    @MainActor
    func testAggregateKeepsLabelsUprightOnAnInkPlate() throws {
        let descriptor = aggregateDescriptor(level: 2)
        let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
        XCTAssertEqual(pebble.gemRung?.cut, .brilliant)
        let label = try XCTUnwrap(pebble.childNode(withName: "aggregate.count") as? SKLabelNode)
        let plate = try XCTUnwrap(pebble.childNode(withName: "aggregate.countPlate") as? SKShapeNode)
        XCTAssertEqual(label.text, "×100")
        XCTAssertGreaterThan(plate.fillColor.cgColor.alpha, 0.7)
        XCTAssertGreaterThan(plate.zPosition, try XCTUnwrap(pebble.childNode(withName: "gem.body")).zPosition)
        XCTAssertLessThan(plate.zPosition, label.zPosition)

        pebble.zRotation = .pi / 3
        pebble.updatePresentationLighting(horizontal: 0.4)
        XCTAssertEqual(label.zRotation, -pebble.zRotation, accuracy: 0.001)
        XCTAssertEqual(plate.zRotation, -pebble.zRotation, accuracy: 0.001)
        let rig = try XCTUnwrap(pebble.childNode(withName: "gem.lightRig"))
        XCTAssertEqual(rig.zRotation, -pebble.zRotation, accuracy: 0.001)
    }

    @MainActor
    func testReduceMotionKeepsGlintsStaticAndCancelsTwinkles() throws {
        let descriptor = aggregateDescriptor(level: 3)
        let animated = PebbleNode(descriptor: descriptor, reduceMotion: false)
        XCTAssertTrue(animated.canGemTwinkle)
        animated.playGemTwinkle(sequence: 1)
        XCTAssertTrue(animated.isGemTwinkling)

        animated.setReduceMotion(true)
        XCTAssertFalse(animated.isGemTwinkling)
        XCTAssertFalse(animated.canGemTwinkle)
        animated.playGemTwinkle(sequence: 2)
        XCTAssertFalse(animated.isGemTwinkling, "Reduce Motion never starts a twinkle")
        animated.enumerateChildNodes(withName: "//gem.glint") { node, _ in
            XCTAssertFalse(node.hasActions())
            XCTAssertGreaterThan(node.alpha, 0, "Static highlights remain visible")
        }
    }

    @MainActor
    func testScreenTimeObstaclesStayMatteAndNeverSparkle() throws {
        let obstacle = PebbleDescriptor(
            screenTimeObstacle: ScreenTimeObstacleProjection.visibleDescriptors(totalUnits: 12)[0]
        )
        let pebble = PebbleNode(descriptor: obstacle, reduceMotion: false)
        XCTAssertEqual(pebble.glowWidth, 0)
        XCTAssertNil(pebble.gemRung)
        XCTAssertNil(pebble.childNode(withName: "//gem.*"))
        XCTAssertFalse(pebble.canGemTwinkle)
    }

    @MainActor
    func testAchievementStonesKeepTheirOwnMaterial() throws {
        let descriptor = PebbleDescriptor(
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )
        let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
        XCTAssertNil(pebble.gemRung)
        XCTAssertNotNil(pebble.childNode(withName: "achievement.mark"))
        XCTAssertEqual(pebble.glowWidth, descriptor.radius * 0.36, accuracy: 0.001)
    }

    @MainActor
    func testSceneTwinklesAreBoundedAndOffUnderReduceMotion() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        let descriptors = (0 ..< 9).map { index in
            looseDescriptor(id: UUID(uuidString: String(format: "C2000000-0000-4000-8000-%012X", index))!)
        } + [aggregateDescriptor(level: 3), aggregateDescriptor(level: 2)]
        scene.restore(pebbles: descriptors)

        var time: TimeInterval = 0
        for _ in 0 ..< 60 {
            time += Constants.Jar.gemTwinkleInterval + 0.01
            scene.update(time)
        }
        var twinkling = 0
        scene.enumerateChildNodes(withName: "//pebble.*") { node, _ in
            if (node as? PebbleNode)?.isGemTwinkling == true { twinkling += 1 }
        }
        XCTAssertLessThanOrEqual(twinkling, Constants.Jar.maximumConcurrentGemTwinkles)

        scene.reduceMotion = true
        for _ in 0 ..< 10 {
            time += Constants.Jar.gemTwinkleInterval + 0.01
            scene.update(time)
        }
        scene.enumerateChildNodes(withName: "//pebble.*") { node, _ in
            XCTAssertFalse((node as? PebbleNode)?.isGemTwinkling == true)
        }
    }

    func testCoreImageIsCachedAndSized() {
        let first = GemArtwork.coreImage(colorHex: Constants.Color.english, level: 1, diameter: 60)
        let second = GemArtwork.coreImage(colorHex: Constants.Color.english, level: 1, diameter: 60)
        XCTAssertTrue(first === second)
        XCTAssertGreaterThanOrEqual(first.size.width, 60)
    }
}
