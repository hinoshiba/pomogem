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
        // Shared light comes from the gem atlas (stand-alone until packed):
        // the registered name and the very texture the atlas serves for it.
        let atlas = GemTextureAtlas.shared
        func served(_ name: String) -> SKTexture { atlas.texture(named: name) { GemArtwork.haloImage } }
        XCTAssertEqual(atlas.textureName(of: halo), GemTextureAtlas.SharedName.halo)
        XCTAssertTrue(halo.texture === served(GemTextureAtlas.SharedName.halo))
        XCTAssertEqual(halo.blendMode, .add)
        XCTAssertNotNil(pebble.childNode(withName: "//gem.glint"))
        let light = try XCTUnwrap(pebble.childNode(withName: "//pebble.dimensionalLight") as? SKSpriteNode)
        XCTAssertEqual(atlas.textureName(of: light), GemTextureAtlas.SharedName.lightAdd)
        XCTAssertTrue(light.texture === served(GemTextureAtlas.SharedName.lightAdd))
        XCTAssertEqual(light.blendMode, .add)
        let shade = try XCTUnwrap(pebble.childNode(withName: "//gem.rig.shade") as? SKSpriteNode)
        XCTAssertEqual(atlas.textureName(of: shade), GemTextureAtlas.SharedName.lightShade)
        XCTAssertTrue(shade.texture === served(GemTextureAtlas.SharedName.lightShade))
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
            let image = GemArtwork.bodyImage(for: spec, radius: 30, scale: 3)
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

    /// The scene lights return to the blend mode each one had, instead of
    /// being forced to `.add` after a capture.
    @MainActor
    func testSnapshotRestoresEachSceneLightsOwnBlendMode() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.restore(pebbles: [looseDescriptor()])
        let floorGlow = try XCTUnwrap(scene.childNode(withName: "//jar.floorGlow") as? SKSpriteNode)
        let pileGlow = try XCTUnwrap(scene.childNode(withName: "//jar.pileGlow") as? SKSpriteNode)
        let highlights = try XCTUnwrap(scene.childNode(withName: "//jar.glass.highlights") as? SKSpriteNode)
        floorGlow.blendMode = .screen
        highlights.blendMode = .alpha
        let restore = scene.prepareForSnapshot()
        for light in [floorGlow, pileGlow, highlights] {
            XCTAssertEqual(light.blendMode, .alpha)
        }
        restore()
        XCTAssertEqual(floorGlow.blendMode, .screen)
        XCTAssertEqual(pileGlow.blendMode, .add)
        XCTAssertEqual(highlights.blendMode, .alpha)
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
        let first = GemArtwork.coreImage(shares: single, level: 1, scale: 3)
        let second = GemArtwork.coreImage(shares: single, level: 1, scale: 3)
        XCTAssertTrue(first === second)
        XCTAssertFalse(first === GemArtwork.coreImage(shares: mixed, level: 1, scale: 3))
        XCTAssertFalse(first === GemArtwork.coreImage(shares: single, level: 2, scale: 3))
        XCTAssertEqual(first.size.width, GemArtwork.coreBakeDiameter, accuracy: 0.5)
        XCTAssertTrue(
            GemArtwork.vesselImage(litFacets: 3, scale: 3) === GemArtwork.vesselImage(litFacets: 3, scale: 3)
        )
    }

    /// The core never stops growing visibly: size to 0.26 of the jar, then
    /// a second orbit (250 kg), a crown (2.5 t) and a third orbit (25 t).
    func testTimeCoreGrowthNeverStalls() {
        let jarWidth: CGFloat = 358
        var previous: (CGFloat, Int, Bool)?
        for level in 1 ... 5 {
            let current = (
                JarLifetimeCoreBackdrop.coreDiameter(jarWidth: jarWidth, level: level),
                JarLifetimeCoreBackdrop.orbitCount(level: level),
                GemArtwork.coreHasCrown(level: level)
            )
            XCTAssertLessThanOrEqual(current.0, 96)
            if let previous {
                XCTAssertGreaterThanOrEqual(current.0, previous.0)
                XCTAssertGreaterThanOrEqual(current.1, previous.1)
                let grew = current.0 > previous.0 + 0.5
                    || current.1 > previous.1
                    || (current.2 && !previous.2)
                XCTAssertTrue(grew, "level \(level) must add something visible")
            }
            previous = current
        }
    }

    // MARK: Time core v3

    /// The twenty radial facets take the share fan (top five + その他, 5 %
    /// steps, largest first from 12 o'clock), not a fixed hue sweep.
    func testCoreColorsFollowTheThemeShareFan() throws {
        let slots = GemArtwork.coreSlotHexes(shares: [
            GemColorShare(hex: "#E85D4A", fraction: 0.5),
            GemColorShare(hex: "#4D7CDE", fraction: 0.3),
            GemColorShare(hex: "#8A6FD1", fraction: 0.2)
        ])
        XCTAssertEqual(slots.count, 20)
        XCTAssertEqual(Array(slots[0 ..< 10]), Array(repeating: "#E85D4A", count: 10))
        XCTAssertEqual(Array(slots[10 ..< 16]), Array(repeating: "#4D7CDE", count: 6))
        XCTAssertEqual(Array(slots[16 ..< 20]), Array(repeating: "#8A6FD1", count: 4))

        let many = (0 ..< 8).map { GemColorShare(hex: String(format: "#%02X4060", 40 + $0 * 20), fraction: Double(8 - $0)) }
        XCTAssertLessThanOrEqual(Set(GemArtwork.coreSlotHexes(shares: many)).count, 6, "Top five plus その他")
        XCTAssertEqual(GemArtwork.coreSlotHexes(shares: [GemColorShare(hex: "#3FA57C", fraction: 1)]), Array(repeating: "#3FA57C", count: 20))

        // The baked stone really is painted by the fan: the right half
        // (slots 0–9) carries the first share, the left half the second.
        let halves = [
            GemColorShare(hex: "#E85D4A", fraction: 0.5),
            GemColorShare(hex: "#4D7CDE", fraction: 0.5)
        ]
        let fan = GemArtwork.coreSlotHexes(shares: halves)
        let image = try XCTUnwrap(GemArtwork.coreImage(shares: halves, level: 1, scale: 1).cgImage)
        let right = try pixel(in: image, clockwiseDegrees: 81, radiusFraction: 0.50)
        let left = try pixel(in: image, clockwiseDegrees: 261, radiusFraction: 0.50)
        let rightIsRed = fan[4] == "#E85D4A"
        XCTAssertEqual(right.red > right.blue, rightIsRed, "3 o'clock follows slot 4 (\(fan[4]))")
        XCTAssertEqual(left.red > left.blue, !rightIsRed, "9 o'clock follows slot 14 (\(fan[14]))")

        // A single theme still sparkles: the two halves of a sector differ
        // in light, both keep the theme's hue family.
        let coral = try XCTUnwrap(
            GemArtwork.coreImage(shares: [GemColorShare(hex: "#E85D4A", fraction: 1)], level: 1, scale: 1).cgImage
        )
        let lead = try pixel(in: coral, clockwiseDegrees: 45, radiusFraction: 0.58)
        let trail = try pixel(in: coral, clockwiseDegrees: 63, radiusFraction: 0.58)
        XCTAssertGreaterThan(abs(lead.luminance - trail.luminance), 0.04, "Facets must not be flat")
        for sample in [lead, trail] {
            XCTAssertGreaterThan(sample.red, sample.blue)
        }
        // A white-hot heart.
        let heart = try pixel(in: coral, clockwiseDegrees: 0, radiusFraction: 0.02)
        XCTAssertGreaterThan(heart.luminance, 0.92)
    }

    // MARK: Gem bed (積み上がりの光)

    /// Lifetime grams are the only size input: 0–250 g keeps the ordinary
    /// glow, then the bed grows logarithmically, never shrinks and never
    /// passes its cap.
    func testGemBedFollowsLifetimeGramsMonotoneAndCapped() {
        let shares = [GemColorShare(hex: Constants.Color.english, fraction: 1)]
        XCTAssertFalse(JarGemBedPresentation.state(totalGrams: 0, colorShares: shares).isVisible)
        XCTAssertFalse(JarGemBedPresentation.state(totalGrams: 250, colorShares: shares).isVisible)
        XCTAssertFalse(JarGemBedPresentation.state(totalGrams: -5, colorShares: shares).isVisible)
        XCTAssertTrue(JarGemBedPresentation.state(totalGrams: 251, colorShares: shares).isVisible)

        var samples: [Int] = [251, 300, 500, 1_000, 2_500, 3_750]
        var grams = 5_000
        while grams < Int.max / 3 {
            samples.append(grams)
            samples.append(grams + grams / 2)
            grams *= 3
        }
        samples.append(Int.max)
        let interiorHeight: CGFloat = 398
        var previous: JarGemBedState?
        for sample in samples {
            let state = JarGemBedPresentation.state(totalGrams: sample, colorShares: shares)
            XCTAssertLessThanOrEqual(state.heightBucket, JarGemBedPresentation.heightBucketCount)
            XCTAssertLessThanOrEqual(state.growthFraction, 1)
            XCTAssertLessThanOrEqual(
                state.height(interiorHeight: interiorHeight),
                (interiorHeight * JarGemBedPresentation.capFraction).rounded()
            )
            if let previous {
                XCTAssertGreaterThanOrEqual(state.heightBucket, previous.heightBucket, "\(sample) g")
                XCTAssertGreaterThanOrEqual(state.growthFraction, previous.growthFraction, "\(sample) g")
            }
            previous = state
        }
        XCTAssertEqual(
            JarGemBedPresentation.state(
                totalGrams: JarGemBedPresentation.saturationGrams,
                colorShares: shares
            ).heightBucket,
            JarGemBedPresentation.heightBucketCount
        )
        // The first kilograms already read as a bed; heavy users grow on.
        let early = JarGemBedPresentation.state(totalGrams: 3_750, colorShares: shares)
        let heavy = JarGemBedPresentation.state(totalGrams: 250_000, colorShares: shares)
        let veteran = JarGemBedPresentation.state(totalGrams: 2_500_000, colorShares: shares)
        XCTAssertGreaterThanOrEqual(early.height(interiorHeight: interiorHeight), 24)
        XCTAssertLessThan(early.heightBucket, heavy.heightBucket)
        XCTAssertLessThan(heavy.heightBucket, veteran.heightBucket)
        // Chip colours are the lifetime fan, like the core.
        XCTAssertEqual(early.slotHexes, GemArtwork.coreSlotHexes(shares: shares))
    }

    /// While the projection is provisional (CloudKit verification pending,
    /// or a local lower bound) the bed never sinks below the one on screen;
    /// a verified projection is followed exactly.
    func testGemBedHoldsWhileTheProjectionIsProvisional() {
        let shares = [GemColorShare(hex: Constants.Color.english, fraction: 1)]
        let full = JarGemBedPresentation.state(totalGrams: 250_000, colorShares: shares)
        let looseOnly = JarGemBedPresentation.state(totalGrams: 3_750, colorShares: shares)
        let grown = JarGemBedPresentation.state(totalGrams: 2_500_000, colorShares: shares)
        XCTAssertLessThan(looseOnly.heightBucket, full.heightBucket)

        XCTAssertEqual(JarGemBedPresentation.displayed(current: looseOnly, shown: full, isProvisional: true), full)
        XCTAssertEqual(JarGemBedPresentation.displayed(current: grown, shown: full, isProvisional: true), grown)
        XCTAssertEqual(JarGemBedPresentation.displayed(current: looseOnly, shown: nil, isProvisional: true), looseOnly)
        // Verified: the real value, even lower (the person deleted records).
        XCTAssertEqual(JarGemBedPresentation.displayed(current: looseOnly, shown: full, isProvisional: false), looseOnly)
    }

    /// Ten bodies fusing into one, or Screen Time obstacles arriving, leave
    /// the bed exactly as it was: same texture, size, position and light.
    @MainActor
    func testFusionAndObstaclesDoNotChangeTheGemBed() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        let descriptors = (0 ..< Constants.Jar.aggregateFanIn).map { index in
            PebbleDescriptor(
                id: UUID(uuidString: String(format: "E1000000-0000-4000-8000-%012X", index + 1))!,
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        scene.gemBed = JarGemBedPresentation.state(
            totalGrams: 3_750,
            colorShares: [
                GemColorShare(hex: Constants.Color.english, fraction: 0.6),
                GemColorShare(hex: Constants.Color.mathematics, fraction: 0.4)
            ]
        )
        let bed = try XCTUnwrap(scene.childNode(withName: "//jar.gemBed") as? SKSpriteNode)
        XCTAssertFalse(bed.isHidden)
        XCTAssertNil(bed.physicsBody, "Decoration only: never a physics body")
        XCTAssertLessThan(bed.zPosition, JarZPosition.pebble, "Behind every body")
        XCTAssertEqual(bed.blendMode, .alpha)
        func snapshot() -> (SKTexture?, CGSize, CGPoint, CGFloat, Bool) {
            (bed.texture, bed.size, bed.position, bed.alpha, bed.isHidden)
        }
        let before = snapshot()

        var request: JarAggregateRequest?
        scene.onAggregateRequested = { request = $0 }
        scene.restore(pebbles: descriptors)
        scene.update(0)
        let finished = expectation(description: "fusion")
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Jar.aggregateFormationDuration + 0.25) {
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        XCTAssertNotNil(request, "The ten bodies fused")
        scene.setScreenTimeObstacles(totalUnits: 36)
        scene.update(1)

        let after = snapshot()
        XCTAssertTrue(before.0 === after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(before.2, after.2)
        XCTAssertEqual(before.3, after.3)
        XCTAssertEqual(before.4, after.4)
    }

    // MARK: Orbit and HUD

    /// The orbit column never crosses the measured HUD or the core's own
    /// labels, at every stage height and HUD size (default, xxxL, AX sizes
    /// with the rail). The column stays above the gem bed (it is drawn behind
    /// the scene); the labels, drawn in front, stay above the floor row.
    /// Short bands tighten the orbit, then hide markers, then the orbit.
    func testOrbitPlacementClearsTheMeasuredHUDFrame() {
        let labelHeight = JarLifetimeCoreBackdrop.estimatedLabelHeight
        for stageHeight: CGFloat in [360, 420, 470, 520] {
            let floorRow = stageHeight - 10 - 30
            for hudBottom: CGFloat in [138, 180, 214, 250] {
                for bedTop: CGFloat? in [nil, stageHeight - 50, stageHeight - 90] {
                    for labelBottomLimit: CGFloat? in [nil, floorRow] {
                        for level in 1 ... 5 {
                            let core = JarLifetimeCoreBackdrop.coreDiameter(jarWidth: 358, level: level)
                            let layout = JarLifetimeCoreLayout.resolve(
                                stageHeight: stageHeight,
                                core: core,
                                orbitCount: JarLifetimeCoreBackdrop.orbitCount(level: level),
                                topClearance: hudBottom,
                                bottomLimit: bedTop,
                                labelBottomLimit: labelBottomLimit,
                                labelHeight: labelHeight
                            )
                            let context = "stage \(stageHeight), HUD \(hudBottom), bed \(String(describing: bedTop)), labels \(String(describing: labelBottomLimit)), L\(level)"
                            let stone = core * JarLifetimeCoreLayout.stoneRadiusFactor
                            let columnBottom = bedTop ?? stageHeight - 16
                            let labelBottom = labelBottomLimit ?? columnBottom
                            let top = hudBottom + JarLifetimeCoreLayout.hudGap
                            let minimumStone = stone * JarLifetimeCoreLayout.minimumStoneScale
                            let fits = columnBottom - top >= minimumStone * 2
                                && labelBottom - top >= minimumStone * 2 + JarLifetimeCoreLayout.labelGap + labelHeight
                            guard fits else {
                                // Too short for even the smallest stone: the
                                // core is marked buried (its labels step
                                // behind the scene), never silently spilled.
                                XCTAssertTrue(layout.overflows, context)
                                continue
                            }
                            XCTAssertFalse(layout.overflows, context)
                            XCTAssertGreaterThanOrEqual(layout.stoneScale, JarLifetimeCoreLayout.minimumStoneScale - 0.001, context)
                            XCTAssertLessThanOrEqual(layout.stoneScale, 1, context)
                            XCTAssertGreaterThanOrEqual(layout.columnTop, top - 0.5, context)
                            XCTAssertLessThanOrEqual(layout.columnBottom, columnBottom + 0.5, context)
                            XCTAssertGreaterThanOrEqual(layout.labelTop, layout.columnBottom, context)
                            XCTAssertLessThanOrEqual(layout.labelTop + labelHeight, labelBottom + 0.5, context)
                            let shownStone = stone * layout.stoneScale
                            if layout.showsMarkers {
                                XCTAssertGreaterThanOrEqual(
                                    layout.orbitRadius - JarLifetimeCoreLayout.markerSize / 2,
                                    shownStone,
                                    "Markers stay off the stone: \(context)"
                                )
                            }
                            if layout.showsOrbit {
                                XCTAssertGreaterThan(layout.orbitRadius, shownStone, context)
                                XCTAssertGreaterThanOrEqual(layout.stoneScale, JarLifetimeCoreLayout.orbitStoneScale - 0.001, context)
                            }
                        }
                    }
                }
            }
        }

        // Room to spare: the nominal orbit with its markers.
        let roomy = JarLifetimeCoreLayout.resolve(
            stageHeight: 700, core: 80, orbitCount: 1, topClearance: 100, bottomLimit: 690, labelHeight: labelHeight
        )
        XCTAssertEqual(roomy.orbitRadius, 80 * 1.075, accuracy: 0.01)
        XCTAssertTrue(roomy.showsMarkers)

        // Labels drawn in front may reach below the bed's top edge, which
        // leaves the heavy user's orbit its markers.
        let behindOnly = JarLifetimeCoreLayout.resolve(
            stageHeight: 420, core: 94, orbitCount: 2, topClearance: 170, bottomLimit: 344, labelHeight: labelHeight
        )
        let withFrontLabels = JarLifetimeCoreLayout.resolve(
            stageHeight: 420, core: 94, orbitCount: 2, topClearance: 170, bottomLimit: 344,
            labelBottomLimit: 380, labelHeight: labelHeight
        )
        XCTAssertGreaterThanOrEqual(withFrontLabels.orbitRadius, behindOnly.orbitRadius)
        XCTAssertTrue(withFrontLabels.showsMarkers)

        // Shrinking the band: the radius never grows, markers go before the
        // orbit, and the orbit goes last.
        var previousRadius = CGFloat.greatestFiniteMagnitude
        var sawMarkersHidden = false
        var sawOrbitHidden = false
        for bottom in stride(from: CGFloat(420), through: 200, by: -5) {
            let layout = JarLifetimeCoreLayout.resolve(
                stageHeight: 440, core: 90, orbitCount: 1, topClearance: 100, bottomLimit: bottom, labelHeight: labelHeight
            )
            if layout.showsOrbit {
                XCTAssertLessThanOrEqual(layout.orbitRadius, previousRadius + 0.01)
                previousRadius = layout.orbitRadius
            }
            if !layout.showsMarkers { sawMarkersHidden = true }
            if sawMarkersHidden { XCTAssertFalse(layout.showsMarkers) }
            if !layout.showsOrbit {
                XCTAssertTrue(sawMarkersHidden)
                sawOrbitHidden = true
            }
            if sawOrbitHidden { XCTAssertFalse(layout.showsOrbit) }
        }
        XCTAssertTrue(sawMarkersHidden)
    }

    /// The labels (drawn in front of the scene) end 6 pt above the gem bed
    /// and above the settled gems under them, never over either.
    func testCoreLabelsStayAboveTheBedAndTheSettledGems() {
        let stage: CGFloat = 470
        let floorY: CGFloat = 30
        let floorRow = stage - floorY - Constants.Jar.measuredRadius * 2 - 7
        // A thin bed below the first gem row: the floor row decides.
        let thin = JarLifetimeCoreLabelLimits.resolve(stageHeight: stage, floorY: floorY, bedTop: stage - floorY - 10, pileTop: 0)
        XCTAssertEqual(thin.floor, floorRow, accuracy: 0.001)
        XCTAssertEqual(thin.abovePile, floorRow, accuracy: 0.001)
        // A 60 pt veteran bed rises above the first row: the bed decides.
        let bedTop = stage - floorY - 60
        let veteran = JarLifetimeCoreLabelLimits.resolve(stageHeight: stage, floorY: floorY, bedTop: bedTop, pileTop: 0)
        XCTAssertEqual(veteran.floor, bedTop - JarLifetimeCoreLabelLimits.clearance, accuracy: 0.001)
        // Settled gems under the labels, higher still.
        let piled = JarLifetimeCoreLabelLimits.resolve(stageHeight: stage, floorY: floorY, bedTop: bedTop, pileTop: 130)
        XCTAssertEqual(piled.abovePile, stage - 130 - JarLifetimeCoreLabelLimits.clearance, accuracy: 0.001)
        XCTAssertLessThanOrEqual(piled.abovePile, piled.floor)
    }

    /// On a short stage (an iPhone 12 mini's 375 × 812 pt screen) the stone
    /// gives way a little before the progress markers disappear.
    func testShortStageKeepsTheOrbitMarkersByShrinkingTheStone() {
        let labelHeight = JarLifetimeCoreBackdrop.estimatedLabelHeight
        let core = JarLifetimeCoreBackdrop.coreDiameter(jarWidth: 375 - Constants.Jar.horizontalMargin * 2, level: 1)
        // About 94 pt of column above the labels at 3.75 kg, then about
        // 74 pt with two rows of gems resting under the labels.
        for budget: CGFloat in [94, 74] {
            let layout = JarLifetimeCoreLayout.resolve(
                stageHeight: 384,
                core: core,
                orbitCount: 1,
                topClearance: 150,
                bottomLimit: 150 + JarLifetimeCoreLayout.hudGap + budget + JarLifetimeCoreLayout.labelGap + labelHeight,
                labelHeight: labelHeight
            )
            XCTAssertTrue(layout.showsOrbit, "budget \(budget)")
            XCTAssertFalse(layout.overflows)
            XCTAssertGreaterThanOrEqual(layout.stoneScale, JarLifetimeCoreLayout.orbitStoneScale - 0.001)
            if budget >= 94 { XCTAssertTrue(layout.showsMarkers, "budget \(budget)") }
        }
    }

    /// The pile profile the core's labels read counts resting bodies only,
    /// per column, so a pile at one side never pushes labels in the middle
    /// and a falling gem is never mistaken for the pile.
    @MainActor
    func testSettledPileProfileCountsRestingBodiesPerColumn() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        scene.restore(pebbles: [looseDescriptor()])
        let pebble = try XCTUnwrap(scene.childNode(withName: "//pebble.*") as? PebbleNode)
        pebble.position = CGPoint(x: 60, y: 80)
        pebble.physicsBody?.velocity = .zero
        scene.update(0)
        scene.update(1)
        let top = scene.settledPileTop(minX: 40, maxX: 80)
        XCTAssertEqual(top, ((80 + pebble.radius) / 4).rounded(.up) * 4, accuracy: 0.001)
        XCTAssertEqual(scene.settledPileTop(minX: 250, maxX: 340), 0, "Other columns stay clear")

        pebble.physicsBody?.velocity = CGVector(dx: 0, dy: -400)
        scene.update(2)
        XCTAssertEqual(scene.settledPileTop(minX: 40, maxX: 80), 0, "A falling gem is not the pile")
    }

    /// Bakes follow the scale of the view that shows them (no UIScreen).
    func testArtworkBakesAtTheViewsDisplayScale() {
        let spec = GemArtworkSpec(
            rung: GemCutLadder.standard.loose,
            colors: [GemColorShare(hex: Constants.Color.english, fraction: 1)],
            variant: 0,
            isMuted: false,
            showsDashedRing: false
        )
        XCTAssertEqual(GemArtwork.bodyImage(for: spec, radius: 20, scale: 2).scale, 2)
        XCTAssertEqual(GemArtwork.bodyImage(for: spec, radius: 20, scale: 3).scale, 3)
        XCTAssertEqual(
            GemArtwork.coreImage(shares: [GemColorShare(hex: Constants.Color.english, fraction: 1)], level: 1, scale: 1).scale,
            1
        )
        XCTAssertEqual(GemArtwork.renderScale(0.5), 1)
        XCTAssertEqual(GemArtwork.renderScale(4), 3)
        XCTAssertEqual(GemArtwork.renderScale(.nan), 3)
        let node = PebbleNode(descriptor: looseDescriptor(), reduceMotion: true, artworkScale: 2)
        XCTAssertEqual(node.artworkScale, 2)
    }

    // MARK: Pile light

    /// A completion falling from the mouth never stretches the pile light
    /// over the core and the HUD: only resting bodies shape it, and it
    /// stays a band seated on the floor.
    @MainActor
    func testFallingGemNeverStretchesThePileLight() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        scene.restore(pebbles: [
            looseDescriptor(),
            looseDescriptor(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000002")!)
        ])
        scene.update(1)
        let glow = try XCTUnwrap(scene.childNode(withName: "//jar.pileGlow") as? SKSpriteNode)
        let before = (glow.size, glow.position)
        XCTAssertGreaterThan(glow.alpha, 0)

        scene.dropFromAbove(looseDescriptor(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000003")!))
        scene.update(2)
        let falling = try XCTUnwrap(scene.childNode(withName: "//pebble.C0000000-0000-4000-8000-000000000003") as? PebbleNode)
        XCTAssertFalse(falling.hasLanded)
        falling.position = CGPoint(x: 195, y: Constants.Jar.height - 20)
        falling.physicsBody?.velocity = CGVector(dx: 0, dy: -400)
        scene.update(3)
        XCTAssertEqual(glow.size, before.0, "A falling gem is not the pile")
        XCTAssertEqual(glow.position, before.1)

        // Whatever rests, the light stays a floor band.
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        let outer = JarScene.outerJarRect(sceneSize: scene.size)
        let tall = JarScene.pileLightFrame(
            bodies: CGRect(x: interior.minX, y: interior.minY, width: interior.width, height: interior.height),
            jar: outer,
            interior: interior,
            bedTop: interior.minY + 40
        )
        XCTAssertLessThanOrEqual(tall.height, interior.height * 0.45 + 0.001)
        XCTAssertLessThanOrEqual(tall.width, outer.width * 0.9 + 0.001)
        XCTAssertLessThanOrEqual(tall.midY, interior.minY + 40 + 40 + 0.001)
    }

    // MARK: Pixel helpers

    private struct Sample {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    /// Samples the baked core at a clockwise angle from 12 o'clock and a
    /// fraction of the stone radius.
    private func pixel(in image: CGImage, clockwiseDegrees: CGFloat, radiusFraction: CGFloat) throws -> Sample {
        let width = image.width
        let height = image.height
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let stoneRadius = CGFloat(width) * JarLifetimeCoreLayout.stoneRadiusFactor
        let radians = clockwiseDegrees * .pi / 180
        let x = Int((CGFloat(width) / 2 + sin(radians) * stoneRadius * radiusFraction).rounded())
        // Row 0 of the bitmap is the top of the image.
        let y = Int((CGFloat(height) / 2 - cos(radians) * stoneRadius * radiusFraction).rounded())
        let offset = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        let alpha = max(CGFloat(pixels[offset + 3]) / 255, 0.001)
        return Sample(
            red: CGFloat(pixels[offset]) / 255 / alpha,
            green: CGFloat(pixels[offset + 1]) / 255 / alpha,
            blue: CGFloat(pixels[offset + 2]) / 255 / alpha
        )
    }
}
