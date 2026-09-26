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
        XCTAssertEqual(pebble.jarScale, 1, "A node built without a jar is at the shipping size")
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
    /// D26 (b): the count is a small engraved copper tag (the collar's
    /// material), upright below the table, with exactly the former text. It
    /// keeps its own on-screen size at every jar scale.
    func testAggregateCountIsASmallEngravedCopperTagBelowTheTable() throws {
        let descriptor = aggregateDescriptor(level: 2)
        let pebble = PebbleNode(descriptor: descriptor, reduceMotion: true)
        XCTAssertEqual(pebble.gemRung?.cut, .brilliant)
        XCTAssertNil(pebble.childNode(withName: "aggregate.count"), "No live label")
        XCTAssertNil(pebble.childNode(withName: "aggregate.countPlate"), "No ink pill")
        let tag = try XCTUnwrap(pebble.childNode(withName: "aggregate.tag") as? SKSpriteNode)
        XCTAssertEqual(pebble.aggregateTagText, "×100")
        XCTAssertEqual(pebble.aggregateTagText, AggregatePresentation.countLabel(100))
        XCTAssertEqual(tag.blendMode, .alpha)
        XCTAssertGreaterThan(tag.zPosition, try XCTUnwrap(pebble.childNode(withName: "gem.body")).zPosition)
        // `size` is the sprite's scaled size (its counter-scale included).
        let onScreen = tag.size.height * pebble.xScale
        XCTAssertLessThanOrEqual(onScreen, 15, "A small tag, not a plate")

        // Copper, not black: the tag's mean colour is warm and mid-light.
        let image = GemArtwork.countEngravingImage(text: "×100", fontSize: 9, style: .copperTag, scale: 2)
        let mean = try meanColor(of: image)
        XCTAssertGreaterThan(mean.red, mean.green)
        XCTAssertGreaterThan(mean.green, mean.blue)
        XCTAssertGreaterThan(0.2126 * mean.red + 0.7152 * mean.green + 0.0722 * mean.blue, 0.35)

        pebble.zRotation = .pi / 3
        pebble.updatePresentationLighting(horizontal: 0.4)
        XCTAssertEqual(tag.zRotation, -pebble.zRotation, accuracy: 0.001)
        // In screen space the tag stays below the centre after rotation.
        let cosine = cos(pebble.zRotation)
        let sine = sin(pebble.zRotation)
        let screenY = sine * tag.position.x + cosine * tag.position.y
        let screenX = cosine * tag.position.x - sine * tag.position.y
        XCTAssertEqual(screenY, -descriptor.radius * PebbleNode.aggregatePlateDrop, accuracy: 0.01)
        XCTAssertEqual(screenX, 0, accuracy: 0.01)

        // A large young jar never turns it into a big number.
        let scaled = PebbleNode(descriptor: descriptor, reduceMotion: true, jarScale: JarScalePolicy.maximumScale)
        let scaledTag = try XCTUnwrap(scaled.childNode(withName: "aggregate.tag") as? SKSpriteNode)
        XCTAssertEqual(scaled.xScale, JarScalePolicy.maximumScale, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(scaledTag.size.height * scaled.xScale, 15)
        XCTAssertLessThanOrEqual(scaledTag.size.height * scaled.xScale, onScreen * 1.4)
        scaled.transitionJarScale(to: 1.2, duration: 0)
        XCTAssertEqual(scaled.xScale, 1.2, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(scaledTag.size.height * scaled.xScale, 15)
    }

    private func meanColor(of image: UIImage) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = (red: CGFloat.zero, green: CGFloat.zero, blue: CGFloat.zero, alpha: CGFloat.zero)
        for index in stride(from: 0, to: data.count, by: 4) {
            sum.red += CGFloat(data[index])
            sum.green += CGFloat(data[index + 1])
            sum.blue += CGFloat(data[index + 2])
            sum.alpha += CGFloat(data[index + 3])
        }
        let alpha = max(sum.alpha, 1)
        return (sum.red / alpha, sum.green / alpha, sum.blue / alpha)
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

        // The stone's colour is a field: the same proportions laid out in
        // hue order from 7:30, starting after the widest hue gap, so it
        // reads as a few large colour fields (not twenty alternating wedges).
        let field = GemArtwork.CoreColorField(shares: GemArtwork.quantizedCoreShares([
            GemColorShare(hex: "#E85D4A", fraction: 0.5),
            GemColorShare(hex: "#4D7CDE", fraction: 0.3),
            GemColorShare(hex: "#8A6FD1", fraction: 0.2)
        ]))
        XCTAssertEqual(field.arcs.map(\.hex), ["#4D7CDE", "#8A6FD1", "#E85D4A"], "Hue order after the widest gap")
        XCTAssertEqual(field.arcs.first?.start ?? 0, GemArtwork.CoreColorField.startTurn, accuracy: 0.000_1)
        for (arc, fraction) in zip(field.arcs, [0.3, 0.2, 0.5]) {
            XCTAssertEqual(arc.end - arc.start, CGFloat(fraction), accuracy: 0.000_1, "Spans keep the shares")
        }
        // Distant hues meet in a pale seam (never grey, never a rainbow).
        let seam = field.color(atTurn: field.arcs[2].start).hsb
        XCTAssertLessThan(seam.saturation, 0.3)
        XCTAssertGreaterThan(seam.brightness, 0.9)

        // The baked stone really is painted by the field: coral and blue
        // halves put blue up the left side and coral down the right.
        let halves = [
            GemColorShare(hex: "#E85D4A", fraction: 0.5),
            GemColorShare(hex: "#4D7CDE", fraction: 0.5)
        ]
        let image = try XCTUnwrap(GemArtwork.coreImage(shares: halves, level: 1, scale: 1).cgImage)
        let right = try pixel(in: image, clockwiseDegrees: 99, radiusFraction: 0.55)
        let left = try pixel(in: image, clockwiseDegrees: 279, radiusFraction: 0.55)
        XCTAssertGreaterThan(right.red, right.blue, "3 o'clock is coral")
        XCTAssertGreaterThan(left.blue, left.red, "9 o'clock is blue")
        // The two halo lobes carry the colour of their own side.
        let lobes = GemArtwork.coreHaloLobeColors(shares: halves)
        let leftLobe = GemColor(lobes.left)
        let rightLobe = GemColor(lobes.right)
        XCTAssertGreaterThan(leftLobe.blue, leftLobe.red)
        XCTAssertGreaterThan(rightLobe.red, rightLobe.blue)

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
        // A wide white-hot heart: white at the centre and still pale a
        // fifth of the way out.
        let heart = try pixel(in: coral, clockwiseDegrees: 0, radiusFraction: 0.02)
        XCTAssertGreaterThan(heart.luminance, 0.92)
        let plateau = try pixel(in: coral, clockwiseDegrees: 30, radiusFraction: 0.20)
        XCTAssertGreaterThan(plateau.luminance, 0.72)

        // The colourless vessel is a clear crystal from the first day: pale
        // ice facets (never a grey, dull stone), lit facets paler still.
        let vessel = try XCTUnwrap(GemArtwork.vesselImage(litFacets: 5, scale: 1).cgImage)
        let unlit = try pixel(in: vessel, clockwiseDegrees: 279, radiusFraction: 0.55)
        let lit = try pixel(in: vessel, clockwiseDegrees: 81, radiusFraction: 0.55)
        XCTAssertGreaterThan(unlit.luminance, 0.5)
        XCTAssertGreaterThan(lit.luminance, unlit.luminance)
        for sample in [unlit, lit] {
            XCTAssertLessThan(max(sample.red, sample.green, sample.blue) - min(sample.red, sample.green, sample.blue), 0.2, "No theme colour")
        }
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

    /// A new bed bakes off the main thread; the bed on screen stays until
    /// the new texture, size and position change together.
    @MainActor
    func testGemBedBakesOffTheMainThreadAndKeepsThePreviousBed() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.bakesGemBedInBackground = true
        // A colour no other test bakes, so both bakes are real misses.
        let shares = [GemColorShare(hex: "#7A5C3E", fraction: 0.7), GemColorShare(hex: "#3E7A5C", fraction: 0.3)]
        let bed = try XCTUnwrap(scene.childNode(withName: "//jar.gemBed") as? SKSpriteNode)
        func waitForBake() {
            let done = expectation(for: NSPredicate { _, _ in !scene.isGemBedBaking }, evaluatedWith: nil)
            wait(for: [done], timeout: 5)
        }
        scene.gemBed = JarGemBedPresentation.state(totalGrams: 3_750, colorShares: shares)
        waitForBake()
        XCTAssertFalse(bed.isHidden)
        let first = (bed.texture, bed.size)
        scene.gemBed = JarGemBedPresentation.state(totalGrams: 2_500_000, colorShares: shares)
        XCTAssertTrue(scene.isGemBedBaking)
        XCTAssertTrue(bed.texture === first.0, "The previous bed stays while the new one bakes")
        XCTAssertEqual(bed.size, first.1)
        waitForBake()
        XCTAssertFalse(bed.texture === first.0)
        XCTAssertGreaterThan(bed.size.height, first.1.height)
    }

    /// A clamped display scale (NaN, 4 …) still re-bakes the bed at the
    /// resolved scale (the bed bakes at half of it, softly out of focus).
    @MainActor
    func testClampedArtworkScaleStillRebakesTheBed() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.bakesGemBedInBackground = false
        scene.artworkScale = 2
        scene.gemBed = JarGemBedPresentation.state(
            totalGrams: 3_750,
            colorShares: [GemColorShare(hex: Constants.Color.english, fraction: 1)]
        )
        let bed = try XCTUnwrap(scene.childNode(withName: "//jar.gemBed") as? SKSpriteNode)
        let atTwo = try XCTUnwrap(bed.texture?.cgImage().width)
        XCTAssertEqual(CGFloat(atTwo), bed.size.width * GemArtwork.bedRenderScale(2), accuracy: 2)
        scene.artworkScale = .nan
        XCTAssertEqual(scene.artworkScale, 3)
        let atThree = try XCTUnwrap(bed.texture?.cgImage().width)
        XCTAssertEqual(CGFloat(atThree), bed.size.width * GemArtwork.bedRenderScale(3), accuracy: 2)
        XCTAssertNotEqual(atTwo, atThree)
    }

    /// Ten bodies fusing into one, or Screen Time obstacles arriving, leave
    /// the bed exactly as it was: same texture, size, position and light.
    @MainActor
    func testFusionAndObstaclesDoNotChangeTheGemBed() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        scene.bakesGemBedInBackground = false
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

    /// The orbit column never crosses the measured HUD, at every stage
    /// height and HUD size (default, xxxL, AX sizes with the rail). The
    /// column stays above the gem bed (it is drawn behind the scene); the
    /// labels, drawn in front, hang right under the stone (over the orbit's
    /// lower arc since round 12) and stay above the floor row. Short bands
    /// tighten the orbit, then hide markers, then the orbit.
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
                            let shownStone = stone * layout.stoneScale
                            XCTAssertEqual(layout.labelTop, layout.centerY + shownStone + JarLifetimeCoreLayout.labelGap, accuracy: 0.01, context)
                            XCTAssertLessThanOrEqual(layout.labelTop + labelHeight, labelBottom + 0.5, context)
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
        let floorRow = stage - floorY - JarLifetimeCoreLabelLimits.floorRowHeight - 7
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

    // MARK: Jar-wide scale (D4)

    @MainActor
    private func scaleScene() -> JarScene {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        scene.bakesGemBedInBackground = false
        return scene
    }

    @MainActor
    private func scenePebbles(_ scene: JarScene) -> [PebbleNode] {
        scene.children.flatMap(\.children).compactMap { $0 as? PebbleNode }
    }

    private func looseSeries(_ count: Int, from start: Int = 0, minutes: Int = 25) -> [PebbleDescriptor] {
        (start ..< start + count).map { index in
            PebbleDescriptor(
                id: UUID(uuidString: String(format: "D4000000-0000-4000-8000-%012X", index + 1))!,
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: minutes * Constants.Mass.gramsPerMinute,
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            )
        }
    }

    /// Six ×100 and five ×10 roots: with nine or ten loose gems the jar's
    /// scale is set by its area budget (below the maximum).
    private func budgetBoundRoots() -> [PebbleDescriptor] {
        [2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1].enumerated().map { index, level in
            aggregateDescriptor(level: level, idSuffix: 0xD400 + index)
        }
    }

    @MainActor
    func testRestoreShowsEveryBodyAtOneJarScaleAndKeepsFusionUnscaled() throws {
        let scene = scaleScene()
        scene.restore(pebbles: looseSeries(5))
        XCTAssertEqual(scene.jarScale, JarScalePolicy.maximumScale, "A young jar shows large jewels")
        for pebble in scenePebbles(scene) {
            XCTAssertEqual(pebble.jarScale, scene.jarScale)
            XCTAssertEqual(pebble.xScale, scene.jarScale, accuracy: 0.000_1)
            XCTAssertEqual(pebble.localRadius, pebble.descriptor.radius, "The stored geometry is unscaled")
            XCTAssertEqual(pebble.radius, pebble.descriptor.radius * scene.jarScale, accuracy: 0.000_1)
            XCTAssertEqual(pebble.sensoryRadius, pebble.descriptor.radius, "Sound and haptics hear the unscaled gem")
            // The body is baked for the size it shows (crisp, not upscaled).
            let body = try XCTUnwrap(pebble.childNode(withName: "gem.body") as? SKSpriteNode)
            let name = try XCTUnwrap(GemTextureAtlas.shared.textureName(of: body))
            XCTAssertTrue(name.contains("|r\(GemArtwork.sizeBucket(radius: pebble.radius))|"), name)
        }
        // A heavy jar beyond the budget shows the shipping size.
        let heavy = scaleScene()
        heavy.restore(pebbles: GemShowcaseUITestFixture.worstCaseDescriptors())
        XCTAssertEqual(heavy.jarScale, 1)
        XCTAssertTrue(scenePebbles(heavy).allSatisfy { $0.xScale == 1 && $0.radius == $0.descriptor.radius })

        // Fusion never sees the scale: the same ten sources, the same grams
        // and the same unscaled radii as the shipping jar.
        let fusing = scaleScene()
        var requests: [JarAggregateRequest] = []
        fusing.onAggregateRequested = { requests.append($0) }
        let ten = looseSeries(10)
        fusing.restore(pebbles: ten)
        XCTAssertGreaterThan(fusing.jarScale, 1)
        fusing.update(0)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(Set(request.pebbles.map(\.id)), Set(ten.map(\.id)))
        XCTAssertEqual(request.pebbles.map(\.radius), ten.map(\.radius))
        XCTAssertEqual(request.grams, 10 * Constants.Mass.measuredPebbleGrams)
    }

    /// Ten bodies becoming one lowers A0: the crystal is born at the new
    /// scale and every other body grows toward it (fusion adds, it never
    /// empties the jar).
    @MainActor
    func testFusionLetsTheWholePileGrowBack() throws {
        let scene = scaleScene()
        scene.onAggregateRequested = { _ in }
        scene.restore(pebbles: budgetBoundRoots() + looseSeries(10))
        let before = scene.jarScale
        XCTAssertLessThan(before, JarScalePolicy.maximumScale, "The budget sets this jar's scale")
        XCTAssertGreaterThan(before, 1)
        let changes = scene.jarScaleChangeCount
        scene.update(0)
        XCTAssertEqual(scene.physicalAggregateCount, 12, "Ten loose gems fused into one more ×10")
        XCTAssertGreaterThanOrEqual(
            scene.jarScale,
            before * JarScalePolicy.rungRatio * JarScalePolicy.rungRatio - 0.000_1,
            "Visibly larger"
        )
        XCTAssertEqual(scene.jarScaleChangeCount, changes + 1)
        for pebble in scenePebbles(scene) where !pebble.isRemovedForBake {
            XCTAssertEqual(pebble.jarScale, scene.jarScale, accuracy: 0.000_1)
        }
    }

    /// The incoming gem counts toward A0 at once and falls at the scale the
    /// pile takes when it lands; the pile itself waits for the landing.
    @MainActor
    func testIncomingGemFallsAtTheScaleThePileTakesWhenItLands() throws {
        let scene = scaleScene()
        scene.restore(pebbles: budgetBoundRoots() + looseSeries(9))
        let before = scene.jarScale
        let incoming = looseSeries(1, from: 50, minutes: 120)[0]
        scene.drop(incoming)
        scene.update(0)
        let node = try XCTUnwrap(scene.childNode(withName: "//pebble.\(incoming.id.uuidString)") as? PebbleNode)
        XCTAssertLessThan(node.jarScale, before, "The new gem already has the landed size")
        XCTAssertEqual(scene.jarScale, before, "The pile changes only when it lands")
        XCTAssertTrue(scenePebbles(scene).filter { $0 !== node }.allSatisfy { $0.jarScale == before })
    }

    /// Restoring the same content twice resolves the same scale and changes
    /// nothing the second time; an animated transition ends exactly at its
    /// target, and the scene finishes one before it freezes.
    @MainActor
    func testTransitionsSettleAtTheirTargetWithoutOscillating() throws {
        let scene = scaleScene()
        let content = budgetBoundRoots() + looseSeries(9)
        scene.restore(pebbles: content)
        let first = scene.jarScale
        let changes = scene.jarScaleChangeCount
        scene.restore(pebbles: content)
        XCTAssertEqual(scene.jarScale, first)
        XCTAssertEqual(scene.jarScaleChangeCount, changes)

        let pebble = PebbleNode(descriptor: looseDescriptor(), reduceMotion: true, jarScale: 1.5)
        pebble.transitionJarScale(to: 2, duration: 0.5)
        XCTAssertTrue(pebble.isTransitioningJarScale)
        XCTAssertEqual(pebble.jarScaleTarget, 2)
        pebble.finishJarScaleTransition()
        XCTAssertFalse(pebble.isTransitioningJarScale)
        XCTAssertEqual(pebble.jarScale, 2)
        XCTAssertEqual(pebble.xScale, 2, accuracy: 0.000_1)
        // A second request for the same target leaves it alone.
        pebble.transitionJarScale(to: 2, duration: 0.5)
        XCTAssertFalse(pebble.isTransitioningJarScale)
        // Shake impulses see the unscaled mass.
        let reference = PebbleNode(descriptor: looseDescriptor(), reduceMotion: true)
        XCTAssertEqual(pebble.presentationMass, reference.presentationMass, accuracy: reference.presentationMass * 0.01)
    }

    /// Large gems are lit from within: a rotation-invariant additive glow
    /// over the facets, tinted pale in the gem's own hue. It has no
    /// direction (a rolling gem never turns its light), follows Reduce
    /// Transparency and snapshots, and a black stone never gets one.
    @MainActor
    func testLargeGemsGlowFromWithinWithoutDirectionalLight() throws {
        // 標準: Reduce Motion implies 控えめ, which dims the inner light
        // (JarEffectsIntensityTests).
        let pebble = PebbleNode(descriptor: looseDescriptor(), reduceMotion: false, jarScale: JarScalePolicy.maximumScale)
        let glow = try XCTUnwrap(pebble.childNode(withName: "gem.innerGlow") as? SKSpriteNode)
        let body = try XCTUnwrap(pebble.childNode(withName: "gem.body"))
        XCTAssertEqual(glow.blendMode, .add)
        XCTAssertEqual(GemTextureAtlas.shared.textureName(of: glow), GemTextureAtlas.SharedName.innerGlow)
        XCTAssertGreaterThan(glow.zPosition, body.zPosition, "Over the facets")
        XCTAssertEqual(glow.size.width, pebble.localRadius * 2, accuracy: 0.001)
        XCTAssertEqual(glow.alpha, PebbleNode.looseInnerGlowAlpha, accuracy: 0.001)
        let tint = GemColor(glow.color)
        XCTAssertLessThanOrEqual(tint.hsb.saturation, 0.37, "Pale")
        XCTAssertEqual(tint.hsb.brightness, 1, accuracy: 0.01)

        // Symmetric: the luminance centroid is the centre.
        let image = try XCTUnwrap(GemArtwork.innerGlowImage.cgImage)
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        for row in 0 ..< height {
            for column in 0 ..< width {
                let value = CGFloat(data[(row * width + column) * 4 + 3])
                total += value
                x += value * CGFloat(column)
                y += value * CGFloat(row)
            }
        }
        XCTAssertEqual(x / total, CGFloat(width - 1) / 2, accuracy: CGFloat(width) * 0.01)
        XCTAssertEqual(y / total, CGFloat(height - 1) / 2, accuracy: CGFloat(height) * 0.01)

        pebble.setSnapshotBlending(true)
        XCTAssertEqual(glow.blendMode, .alpha)
        pebble.setSnapshotBlending(false)
        XCTAssertEqual(glow.blendMode, .add)
        pebble.setReduceTransparency(true)
        XCTAssertLessThan(glow.alpha, PebbleNode.looseInnerGlowAlpha)

        let stone = PebbleNode(
            descriptor: PebbleDescriptor(screenTimeObstacle: ScreenTimeObstacleProjection.decimalRoots(totalUnits: 10)[0]),
            reduceMotion: true
        )
        XCTAssertNil(stone.childNode(withName: "//gem.innerGlow"), "Black stones never glow")
    }

    // MARK: Black stones (D26 (a))

    /// Irregular matte obsidian: no bright pixel, no rim, an uneven outline
    /// of 9–11 corners inside the collision circle, and the count only as a
    /// small, low-contrast engraving below the centre.
    @MainActor
    func testBlackStonesAreIrregularMatteObsidianWithASmallEngravedCount() throws {
        for (units, level) in [(1, 0), (10, 1), (1_000, 3)] {
            let stone = try XCTUnwrap(ScreenTimeObstacleProjection.decimalRoots(totalUnits: units).first)
            XCTAssertEqual(stone.level, level)
            let variations = ScreenTimeObstacleAppearance.variations(descriptor: stone)
            let outline = ScreenTimeObstacleAppearance.outline(variations: variations, radius: stone.radius)
            XCTAssertTrue((9 ... 11).contains(outline.count))
            let reaches = outline.map { hypot($0.x, $0.y) / stone.radius }
            XCTAssertTrue(reaches.allSatisfy { $0 <= 1 }, "Inside the collision circle")
            XCTAssertGreaterThan((reaches.max() ?? 0) - (reaches.min() ?? 0), 0.04, "Uneven, never a coin or a chip")

            let image = ScreenTimeObstacleAppearance.image(variations: variations, radius: stone.radius, scale: 2)
            let luminance = try luminanceStatistics(of: image)
            XCTAssertLessThan(luminance.maximum, 0.40, "Matte: no highlight")
            XCTAssertLessThan(luminance.mean, 0.16, "Dark obsidian")

            let pebble = PebbleNode(descriptor: PebbleDescriptor(screenTimeObstacle: stone), reduceMotion: true)
            let count = pebble.childNode(withName: ScreenTimeObstacleAppearance.countName) as? SKSpriteNode
            if level == 0 {
                XCTAssertNil(count, "A single ten-minute stone carries no number")
            } else {
                let count = try XCTUnwrap(count)
                XCTAssertLessThanOrEqual(count.size.height, 10, "Small")
                XCTAssertLessThan(count.position.y, -stone.radius * 0.3, "Below the centre, not a centred number")
                let text = try XCTUnwrap(ScreenTimeObstacleAppearance.countText(descriptor: stone))
                let engraving = GemArtwork.countEngravingImage(text: text, fontSize: 7, style: .stone, scale: 2)
                XCTAssertLessThan(try luminanceStatistics(of: engraving).maximum, 0.45, "Low contrast")
            }
            // VoiceOver keeps the full count.
            XCTAssertTrue(pebble.descriptor.accessibilityDescription.contains(stone.representedUnits.formatted()))
        }
    }

    /// Luminance (straight alpha) over the opaque pixels of an image.
    private func luminanceStatistics(of image: UIImage) throws -> (mean: CGFloat, maximum: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total: CGFloat = 0
        var count: CGFloat = 0
        var maximum: CGFloat = 0
        for index in stride(from: 0, to: data.count, by: 4) where data[index + 3] > 200 {
            let alpha = CGFloat(data[index + 3])
            let value = (0.2126 * CGFloat(data[index]) + 0.7152 * CGFloat(data[index + 1]) + 0.0722 * CGFloat(data[index + 2])) / alpha
            total += value
            count += 1
            maximum = max(maximum, value)
        }
        return (count > 0 ? total / count : 0, maximum)
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

// MARK: - Round 12 (the round-3 review's fixes)

extension GemBrillianceTests {
    /// The pile steps down for a band it rests over, never below that
    /// band's floor; an optional band (the name plate) is worth a smaller
    /// pile only when its floor really clears it.
    func testPileClearanceStepsDownOnlyAsFarAsItsFloor() {
        let core = JarPileClearance(minX: 0, maxX: 100, ceiling: 200, minimumScale: 2)
        XCTAssertNil(core.steppedScale(current: 2.4, top: 201, floor: 20), "Within the tolerance")
        // 180 / 240 of the height would need 1.8: the floor holds at 2.0.
        XCTAssertEqual(core.steppedScale(current: JarScalePolicy.maximumScale, top: 260, floor: 20), 2)
        // At least one rung, even for a hair over the ceiling.
        let hair = core.steppedScale(current: JarScalePolicy.maximumScale, top: 205, floor: 20)
        XCTAssertEqual(hair ?? 0, JarScalePolicy.rung(atOrBelow: JarScalePolicy.maximumScale / JarScalePolicy.rungRatio), accuracy: 0.000_1)
        XCTAssertNil(core.steppedScale(current: 2, top: 260, floor: 20), "Nothing below the floor")
        XCTAssertTrue(core.fits(top: 150, floor: 20, current: 2, grown: 2.16))
        XCTAssertFalse(core.fits(top: 190, floor: 20, current: 2, grown: 2.16))

        let plate = JarPileClearance(
            minX: 0, maxX: 100, ceiling: 200,
            minimumScale: JarPileClearance.namePlateMinimumScale,
            isOptional: true
        )
        XCTAssertEqual(
            JarPileClearance.namePlateMinimumScale,
            JarScalePolicy.maximumScale / pow(JarScalePolicy.rungRatio, 2),
            accuracy: 0.000_1,
            "At most two rungs smaller for the plate"
        )
        XCTAssertNil(plate.steppedScale(current: JarScalePolicy.maximumScale, top: 260, floor: 20), "Out of reach: the plate hides instead")
        let reachable = plate.steppedScale(current: JarScalePolicy.maximumScale, top: 205, floor: 20)
        XCTAssertNotNil(reachable)
        XCTAssertGreaterThanOrEqual(reachable ?? 0, JarPileClearance.namePlateMinimumScale - 0.000_1)
    }

    /// Home keeps the pile under the core (down to 2.0), under the name
    /// plate (optional) and under the HUD's value (down to 1.0).
    func testPileClearancesCoverTheCoreThePlateAndTheHUD() {
        let stage = CGSize(width: 402, height: 426)
        let clearances = JarSpriteView.pileClearances(
            stageSize: stage,
            coreDisc: (center: CGPoint(x: 201, y: 150), radius: 36),
            namePlate: (top: 192, height: 20, halfWidth: 42),
            hudBottom: 100
        )
        XCTAssertEqual(clearances.count, 3)
        let core = clearances[0]
        XCTAssertEqual(core.ceiling, (426 - 150 - 36 * 0.45).rounded())
        XCTAssertEqual(core.minimumScale, JarPileClearance.coreMinimumScale)
        XCTAssertEqual(core.minX, 165)
        XCTAssertEqual(core.maxX, 237)
        XCTAssertFalse(core.isOptional)
        let plate = clearances[1]
        XCTAssertEqual(plate.ceiling, 426 - 192 - 20 - JarLifetimeCoreLabelLimits.clearance)
        XCTAssertTrue(plate.isOptional)
        let hud = clearances[2]
        XCTAssertEqual(hud.ceiling, 426 - 100 - 8)
        XCTAssertEqual(hud.minimumScale, JarScalePolicy.minimumScale)
        XCTAssertTrue(JarSpriteView.pileClearances(stageSize: .zero, coreDisc: nil, hudBottom: 100).isEmpty)
    }

    /// The core is the jar's protagonist: never smaller than 1.25 loose
    /// gems at the largest scale or 0.21 of the jar, never above 0.24.
    func testTheCoreStoneStaysLargerThanTheLooseGems() {
        let looseGem = Constants.Jar.measuredRadius * 2 * JarScalePolicy.maximumScale
        for width: CGFloat in [343, 358, 370] {
            let minimum = JarLifetimeCoreBackdrop.minimumStoneDiameter(jarWidth: width)
            XCTAssertGreaterThanOrEqual(minimum, min(width * 0.24, looseGem * 1.25) - 0.01)
            XCTAssertGreaterThanOrEqual(minimum, width * 0.21 - 0.01)
            XCTAssertLessThanOrEqual(minimum, width * 0.24 + 0.01)
            // The layout never shows the stone below that size.
            let core = JarLifetimeCoreBackdrop.coreDiameter(jarWidth: width, level: 1)
            let layout = JarLifetimeCoreLayout.resolve(
                stageHeight: 426, core: core, orbitCount: 1, topClearance: 150,
                bottomLimit: 330, labelHeight: JarLifetimeCoreBackdrop.estimatedLabelHeight,
                minimumStoneDiameter: minimum
            )
            let shown = core * JarLifetimeCoreLayout.stoneRadiusFactor * 2 * layout.stoneScale
            XCTAssertGreaterThanOrEqual(shown, min(minimum, core * JarLifetimeCoreLayout.stoneRadiusFactor * 2) - 0.01)
        }
    }

    /// The core shows at most four colour fields: small themes widen the
    /// kept colour nearest in hue, and the spans still add up.
    func testTheCoreShowsAFewLargeColourFields() {
        let shares = [
            GemColorShare(hex: Constants.Color.english, fraction: 0.33),
            GemColorShare(hex: Constants.Color.mathematics, fraction: 0.20),
            GemColorShare(hex: Constants.Color.socialStudies, fraction: 0.20),
            GemColorShare(hex: Constants.Color.japanese, fraction: 0.13),
            GemColorShare(hex: Constants.Color.science, fraction: 0.07)
        ]
        let fields = GemArtwork.CoreColorField.fieldShares(shares)
        XCTAssertEqual(fields.count, 3, "A fourth field needs 15 %")
        XCTAssertEqual(fields.reduce(0) { $0 + $1.fraction }, 0.93, accuracy: 0.000_1)
        XCTAssertEqual(Set(fields.map(\.hex)), [Constants.Color.english, Constants.Color.mathematics, Constants.Color.socialStudies])
        // Green joins blue (the nearest hue), magenta joins coral.
        XCTAssertEqual(fields.first { $0.hex == Constants.Color.mathematics }?.fraction ?? 0, 0.27, accuracy: 0.000_1)
        XCTAssertEqual(fields.first { $0.hex == Constants.Color.english }?.fraction ?? 0, 0.46, accuracy: 0.000_1)
        let four = GemArtwork.CoreColorField.fieldShares(shares.map {
            $0.hex == Constants.Color.japanese ? GemColorShare(hex: $0.hex, fraction: 0.18) : $0
        })
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(GemArtwork.CoreColorField.fieldShares(shares, fourthShare: nil).count, 3, "A crystal keeps three")
        let field = GemArtwork.CoreColorField(shares: GemArtwork.quantizedCoreShares(shares))
        XCTAssertLessThanOrEqual(field.arcs.count, 4)
        XCTAssertEqual(field.arcs.last!.end - field.arcs.first!.start, 1, accuracy: 0.000_1)
    }

    /// The scene's light fades out before the SKView's edge (no visible
    /// rectangle) and the bottle itself is never dimmed.
    func testTheLightBoundsFadeBeforeTheViewEdge() throws {
        let stage = CGSize(width: 402, height: 460)
        let outer = JarScene.outerJarRect(sceneSize: stage)
        let base = stage.height - outer.minY
        let top = stage.height - outer.maxY
        func column(_ x: CGFloat) -> CGFloat {
            JarLightBounds.coverage(at: x, length: stage.width, keepFrom: outer.minX - JarLightBounds.clearance, to: outer.maxX + JarLightBounds.clearance)
        }
        func row(_ y: CGFloat) -> CGFloat {
            JarLightBounds.coverage(at: y, length: stage.height, keepFrom: top - JarLightBounds.clearance, to: base)
        }
        XCTAssertEqual(column(0.5), 0, accuracy: 0.001)
        XCTAssertEqual(column(stage.width - 0.5), 0, accuracy: 0.001)
        XCTAssertEqual(row(stage.height - 0.5), 0, accuracy: 0.001)
        XCTAssertEqual(column(outer.minX), 1)
        XCTAssertEqual(column(stage.width / 2), 1)
        XCTAssertEqual(row(base - 0.5), 1, "The glass base keeps its light")
        XCTAssertEqual(row(top), 1)
        // A smooth ramp: no step larger than a few percent per point.
        var previous = column(0.5)
        for x in stride(from: CGFloat(1.5), through: outer.minX, by: 1) {
            let value = column(x)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThan(value - previous, 0.2)
            previous = value
        }
        let image = JarLightBounds.image(stageSize: stage)
        XCTAssertEqual(image.size, CGSize(width: 402, height: 460))
        XCTAssertTrue(JarLightBounds.image(stageSize: stage) === image, "Baked once per stage size")
    }

    /// The fusion sheet and the Overview lens lay the ten in a loose bowl
    /// under the crystal, never an even wheel around it.
    func testTheTenSourcesRestInABowlNotAWheel() {
        let slots = (0 ..< 10).map { FusionOrbitStage.sourceSlot(index: $0, count: 10) }
        for slot in slots {
            // y down: from a little above 9 o'clock, under, to a little
            // above 3 o'clock; nothing over the crystal.
            XCTAssertGreaterThanOrEqual(slot.degrees, -16)
            XCTAssertLessThanOrEqual(slot.degrees, 196)
            XCTAssertLessThanOrEqual(slot.reach, 1)
            XCTAssertGreaterThanOrEqual(slot.reach, 0.85)
        }
        let gaps = zip(slots, slots.dropFirst()).map { $0.degrees - $1.degrees }
        XCTAssertTrue(gaps.allSatisfy { $0 > 10 }, "In order, left to right")
        XCTAssertGreaterThan(Set(gaps.map { ($0 * 10).rounded() }).count, 1, "Not evenly spaced")
        XCTAssertGreaterThan(Set(slots.map(\.reach)).count, 1, "Not one radius")
    }

    /// Only the emphasised crystal's copper tag shows at full size.
    @MainActor
    func testOnlyTheEmphasisedCrystalShowsAFullSizeTag() throws {
        let pebble = PebbleNode(descriptor: aggregateDescriptor(level: 1), reduceMotion: true, jarScale: 2)
        let tag = try XCTUnwrap(pebble.childNode(withName: "aggregate.tag") as? SKSpriteNode)
        XCTAssertEqual(tag.xScale, 0.5, accuracy: 0.000_1)
        pebble.setPileEmphasis(false)
        XCTAssertEqual(tag.xScale, 0.5 * PebbleNode.quietTagScale, accuracy: 0.000_1)
        XCTAssertEqual(tag.alpha, PebbleNode.quietTagAlpha, accuracy: 0.000_1)
        XCTAssertEqual(pebble.aggregateTagText, "×10", "The text never changes")
        pebble.setPileEmphasis(true)
        XCTAssertEqual(tag.xScale, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(tag.alpha, 1, accuracy: 0.000_1)
    }
}
