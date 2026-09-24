import SpriteKit
import XCTest
@testable import PomoGem

/// Gem brilliance v1.2 is a rendering skin only. These tests pin the
/// invariants it must never break (physics, mass, obstacle matteness,
/// Reduce Motion), the grams → rung mapping, rotation-safe lighting and the
/// bounded sparkle budget (Docs/GemExperienceDesign.md §7).
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

    private func aggregateDescriptor(
        level: Int,
        grams: Int? = nil,
        pebbleCount rawCount: Int? = nil,
        idSuffix: Int? = nil
    ) -> PebbleDescriptor {
        let pebbleCount = rawCount ?? Int(pow(10, Double(level)))
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
            id: UUID(uuidString: String(format: "C1000000-0000-4000-8000-%012X", idSuffix ?? level))!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: metadata,
            grams: grams ?? pebbleCount * Constants.Mass.measuredPebbleGrams
        )
    }

    // MARK: Ladder

    func testAggregateRungFollowsContainedGramsNotLevel() {
        let ladder = GemCutLadder.standard
        XCTAssertEqual(GemCutLadder.aggregateTier(grams: 0), 0)
        XCTAssertEqual(GemCutLadder.aggregateTier(grams: 2_499), 0)
        XCTAssertEqual(GemCutLadder.aggregateTier(grams: 2_500), 1)
        XCTAssertEqual(GemCutLadder.aggregateTier(grams: 25_000), 2)
        XCTAssertEqual(GemCutLadder.aggregateTier(grams: 250_000), 3)
        XCTAssertEqual(GemCutLadder.aggregateTier(grams: 2_500_000), 4)
        XCTAssertEqual(GemCutLadder.aggregateTier(grams: Int.max), 4)

        XCTAssertEqual(ladder.rung(for: looseDescriptor()).cut, .tumbled)
        XCTAssertEqual(ladder.rung(for: looseDescriptor(source: .manual)).cut, .rough)
        XCTAssertEqual(ladder.rung(for: looseDescriptor(grams: 0, isTutorial: true)).cut, .glass)
        XCTAssertEqual(ladder.rung(aggregateGrams: 1_000).cut, .tumbled)
        XCTAssertEqual(ladder.rung(aggregateGrams: 2_500).cut, .step)
        XCTAssertEqual(ladder.rung(aggregateGrams: 25_000).cut, .brilliant)
        XCTAssertEqual(ladder.rung(aggregateGrams: 250_000).cut, .radiant)
        XCTAssertTrue(ladder.rung(aggregateGrams: 250_000).hasWhiteCore)
        XCTAssertTrue(ladder.rung(aggregateGrams: 2_500_000).hasCrown)

        // A 25-minute user's ×10 is A1; a Pro 1-minute ×100 (1 kg) stays A0.
        XCTAssertEqual(ladder.rung(for: aggregateDescriptor(level: 1)).cut, .step)
        XCTAssertEqual(
            ladder.rung(for: aggregateDescriptor(level: 2, grams: 1_000)).cut,
            .tumbled
        )

        // Light budget never decreases up the ladder.
        let rungs = [0, 2_500, 25_000, 250_000, 2_500_000].map { ladder.rung(aggregateGrams: $0) }
        for (lower, higher) in zip(rungs, rungs.dropFirst()) {
            XCTAssertLessThanOrEqual(lower.haloAlpha, higher.haloAlpha)
            XCTAssertLessThanOrEqual(lower.haloScale, higher.haloScale)
            XCTAssertLessThanOrEqual(lower.glintCount, higher.glintCount)
            XCTAssertLessThanOrEqual(lower.sparkleCount, higher.sparkleCount)
        }
        XCTAssertLessThan(ladder.loose.haloAlpha, ladder.rung(aggregateGrams: 2_500).haloAlpha)
    }

    /// 1 min × 10, 10 min × 1 and 100 min × 1 reach the same (loose) rung:
    /// splitting or lengthening time cannot buy a better cut.
    func testSplittingTimeCannotBuyABetterRung() {
        let ladder = GemCutLadder.standard
        let tenOneMinute = ladder.rung(for: aggregateDescriptor(level: 1, grams: 100))
        let tenMinutes = ladder.rung(for: looseDescriptor(grams: 100))
        let hundredMinutes = ladder.rung(for: looseDescriptor(grams: 1_000))
        for rung in [tenOneMinute, tenMinutes, hundredMinutes] {
            XCTAssertEqual(rung.cut, .tumbled)
            XCTAssertEqual(rung.glintCount, ladder.loose.glintCount)
            XCTAssertEqual(rung.sparkleCount, ladder.loose.sparkleCount)
            XCTAssertEqual(rung.facetContrast, ladder.loose.facetContrast)
        }
    }

    /// 25 / 60 / 90-minute gems share facet count and contrast (no ranking
    /// among loose gems by length).
    func testLooseGemsOfAnyLengthShareFacetsAndContrast() {
        let ladder = GemCutLadder.standard
        let rungs = [250, 600, 900].map { ladder.rung(for: looseDescriptor(grams: $0)) }
        XCTAssertEqual(Set(rungs.map(\.cut)).count, 1)
        XCTAssertEqual(Set(rungs.map(\.facetContrast)).count, 1)
        let facetCounts = (0 ..< GemArtworkSpec.variantCount).map {
            GemArtwork.facetCount(cut: .tumbled, symmetry: rungs[0].symmetry, variant: $0)
        }
        XCTAssertGreaterThan(facetCounts.min() ?? 0, 30)
        XCTAssertLessThanOrEqual((facetCounts.max() ?? 0) - (facetCounts.min() ?? 0), 12)
    }

    // MARK: Geometry

    func testOutlinesStayInsidePhysicsAndShareOneAreaRatio() {
        let target = GemArtwork.silhouetteAreaRatio
        for cut in GemCut.allCases {
            for symmetry in [8, 10, 12] {
                for variant in 0 ..< GemArtworkSpec.variantCount {
                    let points = GemArtwork.outline(cut: cut, symmetry: symmetry, variant: variant)
                    XCTAssertGreaterThanOrEqual(points.count, 5)
                    for point in points {
                        XCTAssertLessThanOrEqual(
                            hypot(point.x, point.y),
                            GemArtwork.silhouetteMaximumRadius + 0.0001,
                            "\(cut)"
                        )
                    }
                    var doubleArea: CGFloat = 0
                    for index in points.indices {
                        let a = points[index]
                        let b = points[(index + 1) % points.count]
                        doubleArea += a.x * b.y - b.x * a.y
                    }
                    let ratio = abs(doubleArea) / 2 / .pi
                    XCTAssertEqual(ratio, target, accuracy: 0.02, "\(cut) s\(symmetry) v\(variant)")
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
        XCTAssertFalse(GemSizePolicy.isApprovedForRelease, "D4 sizes wait for the owner")
        XCTAssertEqual(pebble.glowWidth, 0, "Loose gems glow through the shared halo sprite")
        XCTAssertEqual(pebble.gemRung?.cut, .tumbled)

        let gemBody = try XCTUnwrap(pebble.childNode(withName: "gem.body") as? SKSpriteNode)
        let halo = try XCTUnwrap(pebble.childNode(withName: "gem.halo") as? SKSpriteNode)
        XCTAssertEqual(halo.texture, GemArtwork.haloTexture)
        XCTAssertEqual(halo.blendMode, .add)
        XCTAssertNotNil(pebble.childNode(withName: "//gem.glint"))
        let light = try XCTUnwrap(pebble.childNode(withName: "//pebble.dimensionalLight") as? SKSpriteNode)
        XCTAssertEqual(light.texture, GemArtwork.lightRigAddTexture)
        XCTAssertEqual(light.blendMode, .add)
        let shade = try XCTUnwrap(pebble.childNode(withName: "//gem.rig.shade") as? SKSpriteNode)
        XCTAssertEqual(shade.texture, GemArtwork.lightRigShadeTexture)
        XCTAssertLessThanOrEqual(
            gemBody.size.width,
            GemArtwork.bodySpriteSize(radius: descriptor.radius).width + 0.001
        )

        // Equal gems share one baked texture.
        let twin = PebbleNode(descriptor: descriptor, reduceMotion: true)
        let twinBody = try XCTUnwrap(twin.childNode(withName: "gem.body") as? SKSpriteNode)
        XCTAssertTrue(gemBody.texture === twinBody.texture)
    }

    // MARK: Rotation-safe lighting

    /// The baked body carries no directional light: its luminance centroid
    /// sits within 4 % of the radius from the centre, so a rolling gem never
    /// shows a highlight on its underside.
    @MainActor
    func testBakedBodiesHaveNoDirectionalLightBias() throws {
        let ladder = GemCutLadder.standard
        let specs: [GemArtworkSpec] = [
            GemArtworkSpec(
                rung: ladder.loose,
                colors: [GemColorShare(hex: Constants.Color.english, fraction: 1)],
                variant: 0,
                isMuted: false,
                showsDashedRing: false
            ),
            GemArtworkSpec(
                rung: ladder.loose,
                colors: [GemColorShare(hex: Constants.Color.mathematics, fraction: 1)],
                variant: 3,
                isMuted: false,
                showsDashedRing: false
            ),
            GemArtworkSpec(
                rung: ladder.rung(aggregateGrams: 25_000),
                colors: [GemColorShare(hex: Constants.Color.science, fraction: 1)],
                variant: 1,
                isMuted: false,
                showsDashedRing: false
            ),
            GemArtworkSpec(
                rung: ladder.rung(aggregateGrams: 2_500),
                colors: [GemColorShare(hex: Constants.Color.socialStudies, fraction: 1)],
                variant: 2,
                isMuted: false,
                showsDashedRing: false
            )
        ]
        for spec in specs {
            let image = GemArtwork.bodyImage(for: spec, radius: 30)
            let cgImage = try XCTUnwrap(image.cgImage)
            let width = cgImage.width
            let height = cgImage.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var sumX = 0.0
            var sumY = 0.0
            var total = 0.0
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = (y * width + x) * 4
                    let luminance = 0.2126 * Double(pixels[offset])
                        + 0.7152 * Double(pixels[offset + 1])
                        + 0.0722 * Double(pixels[offset + 2])
                    sumX += Double(x) * luminance
                    sumY += Double(y) * luminance
                    total += luminance
                }
            }
            let centerX = Double(width - 1) / 2
            let centerY = Double(height - 1) / 2
            let offset = hypot(sumX / total - centerX, sumY / total - centerY)
            let radiusPixels = 30 * Double(image.scale)
            XCTAssertLessThanOrEqual(offset / radiusPixels, 0.04, "\(spec.cut) is lit from one side")
        }
    }

    @MainActor
    func testLightRigStaysScreenFixedAfterAHalfTurn() throws {
        for descriptor in [looseDescriptor(), aggregateDescriptor(level: 2)] {
            let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
            let rig = try XCTUnwrap(pebble.childNode(withName: "gem.lightRig"))
            pebble.zRotation = .pi
            pebble.updatePresentationLighting(horizontal: 0)
            XCTAssertEqual(rig.zRotation, -pebble.zRotation, accuracy: 0.0001)
            // The key sheen therefore stays at the upper left of the screen.
            let light = try XCTUnwrap(rig.childNode(withName: "pebble.dimensionalLight"))
            XCTAssertEqual(light.zRotation, 0, accuracy: 0.0001)
        }
    }

    // MARK: Glow

    @MainActor
    func testGlowFollowsRecordedGramsNotCompletionCount() throws {
        let short = PebbleNode(descriptor: looseDescriptor(grams: 10), reduceMotion: true)
        let standard = PebbleNode(descriptor: looseDescriptor(), reduceMotion: true)
        let long = PebbleNode(descriptor: looseDescriptor(grams: 900), reduceMotion: true)
        XCTAssertLessThan(short.gemHaloAlpha, standard.gemHaloAlpha)
        XCTAssertEqual(long.gemHaloAlpha, standard.gemHaloAlpha, accuracy: 0.0001, "s(g) tops out at 25 min")

        // Same ×10 membership, a third of the time: a dimmer crystal.
        let full = PebbleNode(descriptor: aggregateDescriptor(level: 1), reduceMotion: true)
        let split = PebbleNode(
            descriptor: aggregateDescriptor(level: 1, grams: 10 * 80),
            reduceMotion: true
        )
        XCTAssertLessThan(split.gemHaloAlpha, full.gemHaloAlpha)
        XCTAssertNotNil(full.childNode(withName: "aggregate.aura/gem.halo"))
        XCTAssertEqual(full.glowWidth, 0, "No neon rim on crystals")
    }

    @MainActor
    func testAggregateKeepsLabelsUprightOnAPlateBelowTheTable() throws {
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
        // In screen space the plate stays below the centre after rotation.
        let cosine = cos(pebble.zRotation)
        let sine = sin(pebble.zRotation)
        let screenY = sine * label.position.x + cosine * label.position.y
        let screenX = cosine * label.position.x - sine * label.position.y
        XCTAssertEqual(screenY, -descriptor.radius * PebbleNode.aggregatePlateDrop, accuracy: 0.01)
        XCTAssertEqual(screenX, 0, accuracy: 0.01)
    }

    // MARK: Motion and accessibility

    @MainActor
    func testReduceMotionKeepsOneStaticStarAndCancelsTwinkles() throws {
        let descriptor = aggregateDescriptor(level: 3)
        let animated = PebbleNode(descriptor: descriptor, reduceMotion: false)
        XCTAssertTrue(animated.canGemTwinkle)
        animated.playGemTwinkle(sequence: 1, at: 10)
        XCTAssertTrue(animated.isGemTwinkling)

        animated.setReduceMotion(true)
        XCTAssertFalse(animated.isGemTwinkling)
        XCTAssertFalse(animated.canGemTwinkle)
        animated.playGemTwinkle(sequence: 2, at: 20)
        XCTAssertFalse(animated.isGemTwinkling, "Reduce Motion never starts a twinkle")
        var alphas: [CGFloat] = []
        animated.enumerateChildNodes(withName: "//gem.glint") { node, _ in
            XCTAssertFalse(node.hasActions())
            alphas.append(node.alpha)
        }
        XCTAssertEqual(alphas.first ?? 0, PebbleNode.reducedMotionStarAlpha, accuracy: 0.001)
        XCTAssertEqual(alphas.filter { $0 > 0 }.count, 1, "One static star per gem")
        XCTAssertFalse(animated.childNode(withName: "aggregate.aura")?.hasActions() ?? true)
    }

    @MainActor
    func testTwinkleFlareIsShortAndBounded() throws {
        let pebble = PebbleNode(descriptor: looseDescriptor(), reduceMotion: false)
        XCTAssertTrue(pebble.canGemTwinkle(at: 100))
        pebble.playGemTwinkle(sequence: 0, at: 100)
        XCTAssertFalse(pebble.canGemTwinkle(at: 101), "Same gem waits 2.5 s")
        XCTAssertTrue(pebble.canGemTwinkle(at: 100 + PebbleNode.gemTwinkleCooldown))
        XCTAssertLessThanOrEqual(PebbleNode.gemTwinkleScale, 1.25)
        XCTAssertEqual(
            PebbleNode.gemTwinkleRise + PebbleNode.gemTwinkleHold + PebbleNode.gemTwinkleFall,
            0.42,
            accuracy: 0.001
        )
    }

    @MainActor
    func testScreenTimeObstaclesStayMatteAndAbsorbLight() throws {
        let obstacle = PebbleDescriptor(
            screenTimeObstacle: ScreenTimeObstacleProjection.visibleDescriptors(totalUnits: 12)[0]
        )
        let pebble = PebbleNode(descriptor: obstacle, reduceMotion: false)
        XCTAssertEqual(pebble.glowWidth, 0)
        XCTAssertNil(pebble.gemRung)
        XCTAssertNil(pebble.childNode(withName: "//gem.*"))
        XCTAssertFalse(pebble.canGemTwinkle)
        let shadow = try XCTUnwrap(pebble.childNode(withName: "obstacle.shadowHalo") as? SKSpriteNode)
        XCTAssertEqual(shadow.blendMode, .alpha, "Never additive")
        XCTAssertEqual(shadow.alpha, 0.35, accuracy: 0.001)
        // Above every reward halo (reward halos sit at −0.6).
        XCTAssertGreaterThan(shadow.zPosition, -0.6)
    }

    @MainActor
    func testAchievementStonesAreSetInCopperAndOutshineLooseGems() throws {
        let descriptor = PebbleDescriptor(
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )
        let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
        XCTAssertEqual(pebble.gemRung?.cut, .step)
        XCTAssertEqual(pebble.gemRung?.hasProngs, true)
        XCTAssertNotNil(pebble.childNode(withName: "achievement.mark"))
        XCTAssertNotNil(pebble.childNode(withName: "achievement.markBackdrop"))
        XCTAssertEqual(pebble.glowWidth, 0)
        let loose = PebbleNode(descriptor: looseDescriptor(), reduceMotion: true)
        XCTAssertGreaterThan(pebble.gemHaloAlpha, loose.gemHaloAlpha)
        XCTAssertEqual(pebble.radius, descriptor.radius, "Physics radius unchanged")
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
            time += 0.2
            scene.update(time)
            var twinkling = 0
            scene.enumerateChildNodes(withName: "//pebble.*") { node, _ in
                if (node as? PebbleNode)?.isGemTwinkling == true { twinkling += 1 }
            }
            XCTAssertLessThanOrEqual(twinkling, Constants.Jar.maximumConcurrentGemTwinkles)
        }
        XCTAssertLessThanOrEqual(Constants.Jar.maximumConcurrentGemTwinkles, 3)
        XCTAssertGreaterThanOrEqual(Constants.Jar.gemTwinkleInterval, 0.6)

        scene.reduceMotion = true
        for _ in 0 ..< 10 {
            time += 0.7
            scene.update(time)
        }
        scene.enumerateChildNodes(withName: "//pebble.*") { node, _ in
            XCTAssertFalse((node as? PebbleNode)?.isGemTwinkling == true)
        }
    }

    /// A single gem never blinks: after one flare it rests for 2.5 s even
    /// though the scene checks many times a second.
    @MainActor
    func testSingleGemDoesNotStrobe() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        scene.restore(pebbles: [looseDescriptor()])
        let pebble = try XCTUnwrap(scene.childNode(withName: "//pebble.*") as? PebbleNode)
        var flareTimes: [TimeInterval] = []
        var lastSeen = pebble.lastGemTwinkleTime
        var time: TimeInterval = 1
        for _ in 0 ..< 80 {
            time += 0.1
            scene.update(time)
            if pebble.lastGemTwinkleTime != lastSeen {
                lastSeen = pebble.lastGemTwinkleTime
                flareTimes.append(lastSeen)
            }
        }
        XCTAssertFalse(flareTimes.isEmpty)
        for (earlier, later) in zip(flareTimes, flareTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, PebbleNode.gemTwinkleCooldown - 0.001)
        }
    }

    /// Snapshots never catch a half-lit flare, and additive light is drawn
    /// with ordinary alpha while capturing (restored afterwards).
    @MainActor
    func testSnapshotPreparationSettlesFlaresAndAvoidsAdditiveBlending() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        scene.restore(pebbles: [looseDescriptor(), aggregateDescriptor(level: 1)])
        let pebble = try XCTUnwrap(scene.childNode(withName: "//pebble.*") as? PebbleNode)
        pebble.playGemTwinkle(sequence: 0, at: 5)
        XCTAssertTrue(pebble.isGemTwinkling)

        let restore = scene.prepareForSnapshot()
        XCTAssertFalse(pebble.isGemTwinkling)
        scene.enumerateChildNodes(withName: "//gem.halo") { node, _ in
            XCTAssertEqual((node as? SKSpriteNode)?.blendMode, .alpha)
        }
        scene.enumerateChildNodes(withName: "//gem.glint") { node, _ in
            XCTAssertEqual((node as? SKSpriteNode)?.blendMode, .alpha)
        }
        restore()
        scene.enumerateChildNodes(withName: "//gem.halo") { node, _ in
            XCTAssertEqual((node as? SKSpriteNode)?.blendMode, .add)
        }
    }

    /// A0 fusions (under 2.5 kg) only fade in; A1 adds a flash and a ring
    /// but no shards (those start at A2).
    @MainActor
    func testFusionFinaleScalesWithContainedGrams() throws {
        func fuse(gramsEach: Int, prefix: String) throws -> JarScene {
            let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.reduceMotion = false
            let descriptors = (0 ..< Constants.Jar.aggregateFanIn).map { index in
                PebbleDescriptor(
                    id: UUID(uuidString: String(format: "\(prefix)000000-0000-4000-8000-%012X", index + 1))!,
                    subjectName: "英語",
                    colorHex: Constants.Color.english,
                    source: .timer,
                    kind: .normal,
                    grams: gramsEach,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }
            var request: JarAggregateRequest?
            scene.onAggregateRequested = { request = $0 }
            scene.restore(pebbles: descriptors)
            scene.update(0)
            let finished = expectation(description: "fusion \(prefix)")
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Jar.aggregateFormationDuration + 0.25) {
                finished.fulfill()
            }
            wait(for: [finished], timeout: 3)
            // The persistence request is issued when the formation completes.
            XCTAssertNotNil(request)
            return scene
        }

        let small = try fuse(gramsEach: 10, prefix: "D1")
        XCTAssertNil(small.childNode(withName: "//drop.fusionFlash"))
        XCTAssertNil(small.childNode(withName: "//drop.fusionRing"))
        XCTAssertNil(small.childNode(withName: "//drop.fusionShard"))

        let standard = try fuse(gramsEach: Constants.Mass.measuredPebbleGrams, prefix: "D2")
        XCTAssertNotNil(standard.childNode(withName: "//drop.fusionFlash"))
        XCTAssertNotNil(standard.childNode(withName: "//drop.fusionRing"))
        XCTAssertNil(standard.childNode(withName: "//drop.fusionShard"))
    }

    @MainActor
    func testHeaviestCrystalLeadsThePileLight() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        let light = aggregateDescriptor(level: 1, idSuffix: 0x11)
        let heavy = aggregateDescriptor(level: 2, idSuffix: 0x12)
        scene.restore(pebbles: [light, heavy])
        scene.update(1)
        let heavyNode = try XCTUnwrap(scene.childNode(withName: "//pebble.\(heavy.id.uuidString)") as? PebbleNode)
        let lightNode = try XCTUnwrap(scene.childNode(withName: "//pebble.\(light.id.uuidString)") as? PebbleNode)
        let heavyAlone = PebbleNode(descriptor: heavy, reduceMotion: true)
        let lightAlone = PebbleNode(descriptor: light, reduceMotion: true)
        XCTAssertEqual(heavyNode.gemHaloAlpha, min(1, heavyAlone.gemHaloAlpha * 1.1), accuracy: 0.001)
        XCTAssertEqual(lightNode.gemHaloAlpha, lightAlone.gemHaloAlpha, accuracy: 0.001)
        let pileGlow = try XCTUnwrap(scene.childNode(withName: "//jar.pileGlow") as? SKSpriteNode)
        XCTAssertGreaterThan(pileGlow.alpha, 0)
        XCTAssertEqual(pileGlow.blendMode, .add)
    }

    // MARK: Time core

    func testCoreSharesAreQuantisedToTwentySlots() {
        let raw = [
            GemColorShare(hex: "#E85D4A", fraction: 0.47),
            GemColorShare(hex: "#4D7CDE", fraction: 0.27),
            GemColorShare(hex: "#8A6FD1", fraction: 0.13),
            GemColorShare(hex: "#C25FA3", fraction: 0.06),
            GemColorShare(hex: "#3FA57C", fraction: 0.04),
            GemColorShare(hex: "#D6863A", fraction: 0.02),
            GemColorShare(hex: "#36A7AE", fraction: 0.01)
        ]
        let quantized = GemArtwork.quantizedCoreShares(raw)
        XCTAssertLessThanOrEqual(quantized.count, 6, "Top five plus other")
        XCTAssertEqual(quantized.reduce(0) { $0 + $1.fraction }, 1, accuracy: 0.0001)
        for share in quantized {
            XCTAssertEqual((share.fraction * 20).rounded(), share.fraction * 20, accuracy: 0.0001)
        }
        XCTAssertEqual(quantized.first?.hex, "#E85D4A")
        XCTAssertEqual(GemArtwork.quantizedCoreShares([]).count, 1)
    }

    func testCoreImageIsCachedPerSharesAndLevel() {
        let single = [GemColorShare(hex: Constants.Color.english, fraction: 1)]
        let mixed = [
            GemColorShare(hex: Constants.Color.english, fraction: 0.5),
            GemColorShare(hex: Constants.Color.mathematics, fraction: 0.5)
        ]
        let first = GemArtwork.coreImage(shares: single, level: 1)
        let second = GemArtwork.coreImage(shares: single, level: 1)
        XCTAssertTrue(first === second)
        XCTAssertFalse(first === GemArtwork.coreImage(shares: mixed, level: 1))
        XCTAssertFalse(first === GemArtwork.coreImage(shares: single, level: 2))
        XCTAssertEqual(first.size.width, GemArtwork.coreBakeDiameter, accuracy: 0.5)
        XCTAssertTrue(GemArtwork.vesselImage(litFacets: 3) === GemArtwork.vesselImage(litFacets: 3))
    }
}
