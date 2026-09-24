import SpriteKit
import XCTest
@testable import PomoGem

/// Rendering-cost invariants of the jar (Docs/GemExperienceDesign.md §7.13).
/// Nothing here may change what the jar shows: these tests pin the per-frame
/// work, the draw order that batching relies on, the idle tilt gate, the
/// atlas and the bounded, pre-baked texture caches.
final class JarRenderingPerformanceTests: XCTestCase {
    // MARK: Per-frame lighting pass

    @MainActor
    func testObstacleCountStaysUprightWithoutANameSearch() throws {
        let scene = makeScene()
        scene.setScreenTimeObstacles(totalUnits: 120)
        let obstacles = pebbles(in: scene).filter { $0.descriptor.isScreenTimeObstacle }
        let counted = try XCTUnwrap(obstacles.first { node in
            node.children.contains { $0.name == ScreenTimeObstacleAppearance.countName }
        })
        let label = try XCTUnwrap(counted.children.first { $0.name == ScreenTimeObstacleAppearance.countName })

        counted.zRotation = 1.1
        counted.updatePresentationLighting(horizontal: 0.3)
        XCTAssertEqual(label.zRotation, -1.1, accuracy: 0.0001)
        counted.zRotation = -2.4
        counted.updatePresentationLighting(horizontal: -0.3)
        XCTAssertEqual(label.zRotation, 2.4, accuracy: 0.0001)
    }

    // MARK: Draw order (the view ignores sibling order)

    /// Every drawn layer of a body, from the back. With
    /// `ignoresSiblingOrder` SpriteKit orders only by global z, so each
    /// layer must be one band that never interleaves with another, and ties
    /// inside a band must follow the order the bodies entered the jar (the
    /// tree order SpriteKit used before).
    private let layerOrder = [
        "pebble.contactShadow",
        "gem.halo",
        "pebble.earlyEffortBloom",
        "pebble.earlyEffortAura",
        "obstacle.shadowHalo",
        "obstacle.body",
        "gem.body",
        "obstacle.count",
        "gem.rig.shade",
        "pebble.dimensionalLight",
        "gem.glint",
        "achievement.markBackdrop",
        "achievement.mark",
        "aggregate.tag"
    ]

    @MainActor
    func testGemLayersStayInOrderedBandsAcrossBodies() throws {
        // Crystals, a stone, self-reported and Screen Time bodies together.
        let crowded = makeScene()
        crowded.restore(pebbles: [
            looseDescriptor(index: 1),
            aggregateDescriptor(),
            looseDescriptor(index: 2, source: .manual),
            achievementDescriptor(),
            looseDescriptor(index: 3),
            looseDescriptor(index: 4, grams: 600)
        ])
        crowded.setScreenTimeObstacles(totalUnits: 120)
        // One or two loose gems add the early-effort bloom and aura.
        let early = makeScene()
        early.restore(pebbles: [looseDescriptor(index: 5), looseDescriptor(index: 6)])
        early.setScreenTimeObstacles(totalUnits: 30)

        for scene in [crowded, early] {
            let order = pebbles(in: scene)
            var bands: [String: [(z: CGFloat, body: Int)]] = [:]
            scene.enumerateChildNodes(withName: "//*") { node, _ in
                guard let name = node.name, self.layerOrder.contains(name),
                      let owner = self.owningPebble(of: node),
                      let index = order.firstIndex(where: { $0 === owner })
                else { return }
                bands[name, default: []].append((self.globalZ(of: node), index))
            }
            let present = layerOrder.filter { bands[$0] != nil }
            XCTAssertGreaterThanOrEqual(present.count, scene === crowded ? 12 : 9)
            for (lower, upper) in zip(present, present.dropFirst()) {
                let top = try XCTUnwrap(bands[lower]?.map(\.z).max())
                let bottom = try XCTUnwrap(bands[upper]?.map(\.z).min())
                XCTAssertLessThan(top, bottom, "\(lower) must stay entirely below \(upper)")
            }
            for name in present {
                let members = try XCTUnwrap(bands[name]).sorted { $0.z < $1.z }
                XCTAssertLessThan(
                    (members.last?.z ?? 0) - (members.first?.z ?? 0),
                    JarZPosition.stackingSpan + 0.000_1
                )
                // Ties resolve in the order the bodies entered the jar.
                for (a, b) in zip(members, members.dropFirst()) {
                    XCTAssertLessThanOrEqual(a.body, b.body, "\(name) keeps insertion order")
                    if a.body != b.body { XCTAssertLessThan(a.z, b.z) }
                }
            }
        }
    }

    @MainActor
    func testStackingSpanFitsBetweenTheCloserLayersOfOneBody() {
        XCTAssertLessThan(JarZPosition.stackingSpan, 0.05, "Closest layers of a body: shade 0.70, light 0.75")
        XCTAssertEqual(JarZPosition.pebble(stackingIndex: 0), JarZPosition.pebble)
        XCTAssertLessThan(JarZPosition.pebble(stackingIndex: 7), JarZPosition.pebble(stackingIndex: 8))
        XCTAssertEqual(
            JarZPosition.pebble(stackingIndex: .max),
            JarZPosition.pebble(stackingIndex: JarZPosition.stackingSlots - 1)
        )
        // Float32 (SpriteKit's z) still separates neighbouring bodies.
        let high = Float(JarZPosition.pebble + 2 + JarZPosition.stackingSpan)
        XCTAssertGreaterThan(Float(JarZPosition.stackingStep), high.ulp * 8)
    }

    // MARK: Atlas

    @MainActor
    func testPackedTexturesDrawTheSamePixelsAsStandAloneOnes() throws {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        let scale = view.contentScaleFactor
        let atlas = GemTextureAtlas.shared
        let descriptor = aggregateDescriptor()
        let aggregate = try XCTUnwrap(descriptor.aggregate)
        let spec = GemArtworkSpec(
            rung: GemCutLadder.standard.rung(aggregateGrams: descriptor.grams),
            colors: GemArtworkSpec.aggregateColors(aggregate.colorMix, fallbackHex: aggregate.dominantColorHex),
            variant: GemArtworkSpec.variant(for: descriptor.id),
            isMuted: false,
            showsDashedRing: false
        )
        let name = GemArtwork.bodyTextureName(for: spec, radius: descriptor.radius, scale: scale)
        let image = GemArtwork.renderBodyImage(for: spec, radius: descriptor.radius, scale: scale)
        atlas.insert([(name, image)])
        atlas.rebuildNow()
        XCTAssertTrue(atlas.isPacked(name))
        XCTAssertTrue(atlas.isPacked(GemTextureAtlas.SharedName.halo))

        let standalone = SKTexture(image: image)
        standalone.filteringMode = .linear
        let packed = atlas.texture(named: name) { image }
        XCTAssertFalse(packed === standalone)
        let size = GemArtwork.bodySpriteSize(radius: descriptor.radius)
        for rotation: CGFloat in [0, 0.7] {
            let before = try render(standalone, size: size, rotation: rotation, in: view)
            let after = try render(packed, size: size, rotation: rotation, in: view)
            let difference = compare(before, after)
            XCTAssertLessThanOrEqual(difference.maximum, 2, "Packing never changes a pixel (rotation \(rotation))")
        }
        let halo = try render(GemArtwork.haloTexture, size: CGSize(width: 60, height: 60), rotation: 0, in: view)
        let packedHalo = try render(
            atlas.texture(named: GemTextureAtlas.SharedName.halo) { GemArtwork.haloImage },
            size: CGSize(width: 60, height: 60),
            rotation: 0,
            in: view
        )
        XCTAssertLessThanOrEqual(compare(halo, packedHalo).maximum, 2)
    }

    @MainActor
    func testSpritesMoveToTheNewPageWithoutChangingTheirSize() throws {
        let atlas = GemTextureAtlas.shared
        let node = PebbleNode(descriptor: looseDescriptor(index: 40, grams: 900), reduceMotion: true)
        let body = try XCTUnwrap(node.childNode(withName: "gem.body") as? SKSpriteNode)
        let name = try XCTUnwrap(atlas.textureName(of: body))
        let size = body.size
        atlas.rebuildNow()
        XCTAssertTrue(atlas.isPacked(name))
        XCTAssertTrue(body.texture === atlas.texture(named: name) { UIImage() })
        XCTAssertEqual(body.size, size)
        XCTAssertEqual(atlas.textureName(of: body), name)
    }

    @MainActor
    func testKeptImagesStayWithinTheirBudget() {
        let atlas = GemTextureAtlas.shared
        // No background repack of ~24 MB of test images between tests.
        let rebuilds = atlas.rebuildsAutomatically
        atlas.rebuildsAutomatically = false
        defer { atlas.rebuildsAutomatically = rebuilds }
        // A body on screen is never evicted, however long ago it was looked up.
        let onScreen = PebbleNode(descriptor: looseDescriptor(index: 41, grams: 830, colorHex: "#5A7D9A"), reduceMotion: true)
        let onScreenBody = onScreen.childNode(withName: "gem.body") as? SKSpriteNode
        let onScreenName = onScreenBody.flatMap { atlas.textureName(of: $0) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let side = 1_024
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        let count = GemTextureAtlas.imageByteBudget / (side * side * 4) + 3
        atlas.insert((0 ..< count).map { ("test.budget.\($0)", image) })
        XCTAssertLessThanOrEqual(atlas.statistics.keptImageBytes, GemTextureAtlas.imageByteBudget)
        XCTAssertTrue(atlas.hasImage(named: GemTextureAtlas.SharedName.halo), "Shared light is pinned")
        XCTAssertTrue(atlas.hasImage(named: "test.budget.\(count - 1)"), "The newest image stays")
        XCTAssertFalse(atlas.hasImage(named: "test.budget.0"), "The least recently used goes first")
        if let onScreenName {
            XCTAssertTrue(atlas.hasImage(named: onScreenName), "A live sprite's image is pinned")
        } else {
            XCTFail("The body registers its atlas name")
        }
        XCTAssertGreaterThanOrEqual(atlas.statistics.liveNames, 1)
        XCTAssertGreaterThanOrEqual(
            atlas.statistics.residentBytes,
            atlas.statistics.keptImageBytes,
            "Resident bytes count the page and stand-alone textures too"
        )
        atlas.removeImages(named: (0 ..< count).map { "test.budget.\($0)" })
        withExtendedLifetime(onScreen) {}
    }

    /// The obsidian rock is one baked sprite per shape, size bucket and
    /// display scale: equal stones share it, and a stone shown at a larger
    /// jar scale gets a bake of that size (crisp), sized back to local
    /// points so it lands on the collision circle.
    @MainActor
    func testBlackStoneBakeIsOneSharedSpritePerShapeAndSize() throws {
        let stone = ScreenTimeObstacleDescriptor(level: 2, slot: 7, representedUnits: 100, isHistoryPile: false)
        let descriptor = PebbleDescriptor(screenTimeObstacle: stone)
        let atlas = GemTextureAtlas.shared
        let first = PebbleNode(descriptor: descriptor, reduceMotion: true, artworkScale: 2)
        let twin = PebbleNode(descriptor: descriptor, reduceMotion: true, artworkScale: 2)
        let rock = try XCTUnwrap(first.childNode(withName: ScreenTimeObstacleAppearance.bodyName) as? SKSpriteNode)
        let twinRock = try XCTUnwrap(twin.childNode(withName: ScreenTimeObstacleAppearance.bodyName) as? SKSpriteNode)
        XCTAssertEqual(atlas.textureName(of: rock), atlas.textureName(of: twinRock))
        XCTAssertFalse(first.children.contains { $0 is SKShapeNode || $0 is SKLabelNode })

        let scale = JarScalePolicy.maximumObstacleScale
        let scaled = PebbleNode(descriptor: descriptor, reduceMotion: true, artworkScale: 2, jarScale: scale)
        let scaledRock = try XCTUnwrap(scaled.childNode(withName: ScreenTimeObstacleAppearance.bodyName) as? SKSpriteNode)
        let name = try XCTUnwrap(atlas.textureName(of: scaledRock))
        XCTAssertEqual(
            name,
            ScreenTimeObstacleAppearance.textureName(
                variations: ScreenTimeObstacleAppearance.variations(descriptor: stone),
                radius: stone.radius * scale,
                scale: 2
            )
        )
        let onScreen = scaledRock.size.width * scaled.xScale
        let baked = ScreenTimeObstacleAppearance.spriteSize(radius: GemArtwork.sizeBucket(radius: stone.radius * scale))
        XCTAssertEqual(onScreen, baked.width, accuracy: 0.01)
    }

    // MARK: Baking ahead

    @MainActor
    func testRestoreBakesEachMissingBodyOnceBeforeCreatingNodes() throws {
        let atlas = GemTextureAtlas.shared
        // Colours no other test uses, so every body is a miss here.
        let descriptors = (0 ..< 12).map {
            looseDescriptor(index: 100 + $0, grams: 710 + $0 * 40, colorHex: ["#6B8E23", "#2E8B8B", "#8B5A2B"][$0 % 3])
        }
        let scene = makeScene()
        scene.artworkScale = 3
        // The bodies bake at the jar scale the restore will resolve (D4).
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        let jarScale = JarScalePolicy.resolvedScale(
            current: 1,
            target: JarScalePolicy.targetScale(
                baseArea: JarScalePolicy.baseArea(radii: descriptors.map(\.radius)),
                interiorArea: interior.width * interior.height
            )
        )
        let requests = descriptors.compactMap { PebbleNode.bakeRequest(for: $0, scale: 3, jarScale: jarScale) }
        XCTAssertEqual(requests.count, descriptors.count)
        let names = Set(requests.map(\.name))
        XCTAssertTrue(names.allSatisfy { !atlas.hasImage(named: $0) })

        let inlineBakes = atlas.onDemandBakeCount
        scene.restore(pebbles: descriptors)
        XCTAssertEqual(scene.jarScale, jarScale)
        XCTAssertTrue(names.allSatisfy { atlas.hasImage(named: $0) })
        // Every body was baked ahead (in parallel) before its node existed:
        // no node had to bake inline.
        XCTAssertEqual(atlas.onDemandBakeCount, inlineBakes, "Bodies bake before their nodes")
        for node in pebbles(in: scene) {
            let body = try XCTUnwrap(node.childNode(withName: "gem.body") as? SKSpriteNode)
            let name = try XCTUnwrap(atlas.textureName(of: body))
            XCTAssertTrue(names.contains(name))
        }

        // The parallel bake draws exactly what the node would have drawn.
        let request = try XCTUnwrap(requests.first)
        let serial = try XCTUnwrap(request.make().cgImage)
        let parallel = try XCTUnwrap(atlas.texture(named: request.name) { UIImage() }.cgImage())
        XCTAssertEqual(serial.width, parallel.width)
        XCTAssertLessThanOrEqual(compare(pixels(of: serial), pixels(of: parallel)).maximum, 1)
    }

    @MainActor
    func testLaunchPreBakeCoversTheStarterGems() throws {
        let requests = PebbleNode.commonBakeRequests(scale: 3)
        XCTAssertEqual(requests.count, SeedData.subjects.count * 2 * GemArtworkSpec.variantCount)
        XCTAssertEqual(Set(requests.map(\.name)).count, requests.count)
        let names = Set(requests.map(\.name))
        for subject in SeedData.subjects {
            for index in 0 ..< 8 {
                let descriptor = PebbleDescriptor(
                    id: UUID(uuidString: String(format: "C5000000-0000-4000-8000-%012X", index))!,
                    subjectName: subject.name,
                    colorHex: subject.colorHex,
                    source: .timer,
                    kind: .normal,
                    grams: Constants.Mass.measuredPebbleGrams
                )
                // At the scale of a young jar, the jar every new person opens.
                let request = try XCTUnwrap(PebbleNode.bakeRequest(
                    for: descriptor,
                    scale: 3,
                    jarScale: JarScalePolicy.maximumScale
                ))
                XCTAssertTrue(names.contains(request.name), "A 25-minute \(subject.name) gem is pre-baked")
            }
        }
    }

    /// A restore right after launch takes over the launch pre-bake instead
    /// of baking the same bodies a second time on every core.
    @MainActor
    func testRestoreTakesOverTheLaunchPreBake() {
        let atlas = GemTextureAtlas.shared
        let counter = BakeCounter()
        let hexes = ["#4F6D3A", "#6D3A4F", "#3A4F6D", "#6D5A3A"]
        let requests = hexes.enumerated().flatMap { index, hex in
            (0 ..< 3).map { size -> GemTextureAtlas.BakeRequest in
                let name = "test.prewarm.\(index).\(size)"
                let spec = GemArtworkSpec(
                    rung: GemCutLadder.standard.loose,
                    colors: [GemColorShare(hex: hex, fraction: 1)],
                    variant: size,
                    isMuted: false,
                    showsDashedRing: false
                )
                return GemTextureAtlas.BakeRequest(name: name) {
                    counter.increment(name)
                    return GemArtwork.renderBodyImage(for: spec, radius: 12 + CGFloat(size) * 3, scale: 2)
                }
            }
        }
        atlas.prewarm(requests)
        atlas.bakeMissing(requests)
        XCTAssertFalse(atlas.isPrewarming)
        XCTAssertTrue(requests.allSatisfy { atlas.hasImage(named: $0.name) })
        XCTAssertTrue(counter.counts.values.allSatisfy { $0 == 1 }, "Each image baked exactly once")
        XCTAssertEqual(counter.counts.count, requests.count)
        atlas.removeImages(named: requests.map(\.name))
    }

    private final class BakeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Int] = [:]
        var counts: [String: Int] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func increment(_ name: String) {
            lock.lock(); storage[name, default: 0] += 1; lock.unlock()
        }
    }

    // MARK: Idle tilt

    @MainActor
    func testIdleJarFollowsTiltOnlyInStepsAboveTheThreshold() throws {
        let scene = makeScene()
        scene.reduceMotion = false
        var clock: TimeInterval = 1_000
        scene.tiltClock = { clock }
        scene.restore(pebbles: [looseDescriptor(index: 7)])
        scene.evaluateInteractionMotionForTesting(currentTime: 100, uptime: 100)
        scene.evaluateInteractionMotionForTesting(currentTime: 110, uptime: 110)
        XCTAssertTrue(scene.isIdlePaused)
        let scale = Constants.Jar.tiltGravityHorizontalScale
        let start = scene.idleTiltFrameCount

        // Hand tremor below the threshold touches no node (no frame).
        scene.setGravityVector(CGVector(dx: 0.012 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.idleTiltFrameCount, start)
        XCTAssertEqual(scene.opticalTiltFraction, 0)

        // A deliberate tilt lights the glints at once.
        scene.setGravityVector(CGVector(dx: 0.2 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.idleTiltFrameCount, start + 1)
        XCTAssertEqual(scene.opticalTiltFraction, 0.2, accuracy: 0.0001)

        // At most one idle tilt frame per 1/30 s.
        scene.setGravityVector(CGVector(dx: 0.3 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.idleTiltFrameCount, start + 1)
        clock += 0.04
        scene.setGravityVector(CGVector(dx: 0.31 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.idleTiltFrameCount, start + 2)
        XCTAssertEqual(scene.opticalTiltFraction, 0.31, accuracy: 0.0001)

        // Levelling the phone brings the light back within the threshold
        // while idle; a sample held back by the gate is caught up the
        // moment the jar wakes, and a reset returns it exactly.
        clock += 0.04
        scene.setGravityVector(CGVector(dx: 0.012 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.opticalTiltFraction, 0.012, accuracy: 0.0001)
        clock += 0.04
        scene.setGravityVector(CGVector(dx: 0.001 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.opticalTiltFraction, 0.012, accuracy: 0.0001, "Under the threshold: no frame")
        scene.resumeSimulation()
        XCTAssertFalse(scene.isIdlePaused)
        XCTAssertEqual(scene.opticalTiltFraction, 0.001, accuracy: 0.0001, "Caught up on wake")
        scene.resetGravity()
        XCTAssertEqual(scene.opticalTiltFraction, 0)

        // An awake jar follows every sample, as before.
        let awake = scene.idleTiltFrameCount
        scene.setGravityVector(CGVector(dx: 0.005 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.opticalTiltFraction, 0.005, accuracy: 0.0001)
        XCTAssertEqual(scene.idleTiltFrameCount, awake)
    }

    // MARK: Helpers

    @MainActor
    private func makeScene() -> JarScene {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        return scene
    }

    @MainActor
    private func pebbles(in scene: JarScene) -> [PebbleNode] {
        scene.children.flatMap { $0.children }.compactMap { $0 as? PebbleNode }
    }

    private func owningPebble(of node: SKNode) -> PebbleNode? {
        var current: SKNode? = node
        while let candidate = current {
            if let pebble = candidate as? PebbleNode { return pebble }
            current = candidate.parent
        }
        return nil
    }

    private func globalZ(of node: SKNode) -> CGFloat {
        var z: CGFloat = 0
        var current: SKNode? = node
        while let candidate = current, !(candidate is SKScene) {
            z += candidate.zPosition
            current = candidate.parent
        }
        return z
    }

    private func looseDescriptor(
        index: Int,
        source: SessionSource = .timer,
        grams: Int = Constants.Mass.measuredPebbleGrams,
        colorHex: String? = nil
    ) -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: String(format: "C4000000-0000-4000-8000-%012X", index))!,
            subjectName: "英語",
            colorHex: colorHex ?? [Constants.Color.english, Constants.Color.science, Constants.Color.japanese][index % 3],
            source: source,
            kind: .normal,
            grams: source == .manual ? ManualDuration.thirtyMinutes.grams : grams,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
        )
    }

    private func achievementDescriptor() -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: "C4000000-0000-4000-8000-0000000000AC")!,
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0,
            createdAt: Date(timeIntervalSince1970: 1_500)
        )
    }

    private func aggregateDescriptor() -> PebbleDescriptor {
        let metadata = AggregateMetadata(
            level: 1,
            pebbleCount: 10,
            childAggregateCount: 0,
            colorMix: [
                StratumColorFraction(hex: Constants.Color.english, fraction: 0.6),
                StratumColorFraction(hex: Constants.Color.mathematics, fraction: 0.4)
            ],
            subjectMix: [AggregateSubjectFraction(name: "英語", colorHex: Constants.Color.english, pebbleCount: 10)],
            periodStart: Date(timeIntervalSince1970: 100),
            periodEnd: Date(timeIntervalSince1970: 200),
            sessionIDs: [],
            measuredPebbleCount: 10,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0
        )
        return PebbleDescriptor(
            id: UUID(uuidString: "C4000000-0000-4000-8000-0000000000A1")!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: metadata,
            grams: 10 * Constants.Mass.measuredPebbleGrams,
            createdAt: Date(timeIntervalSince1970: 900)
        )
    }

    // MARK: Pixels

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    @MainActor
    private func render(_ texture: SKTexture, size: CGSize, rotation: CGFloat, in view: SKView) throws -> Pixels {
        let sprite = SKSpriteNode(texture: texture, size: size)
        sprite.zRotation = rotation
        return try render(sprite, in: view)
    }

    /// Draws `node` at the centre of a 96 pt scene over an opaque night
    /// background (as in the jar) and returns the pixels.
    @MainActor
    private func render(_ node: SKNode, in view: SKView) throws -> Pixels {
        let scene = SKScene(size: CGSize(width: 96, height: 96))
        scene.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.13, alpha: 1)
        node.position = CGPoint(x: 48, y: 48)
        scene.addChild(node)
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        let rendered = try XCTUnwrap(view.texture(from: scene, crop: CGRect(x: 0, y: 0, width: 96, height: 96)))
        return pixels(of: rendered.cgImage())
    }

    private func pixels(of image: CGImage) -> Pixels {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func differingPixelShare(_ a: Pixels, _ b: Pixels, threshold: Int) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        var differing = 0
        for pixel in 0 ..< a.width * a.height {
            let offset = pixel * 4
            let difference = (0 ..< 3).map { abs(Int(a.bytes[offset + $0]) - Int(b.bytes[offset + $0])) }.max() ?? 0
            if difference > threshold { differing += 1 }
        }
        return Double(differing) / Double(max(a.width * a.height, 1))
    }

    private func compare(_ a: Pixels, _ b: Pixels) -> (maximum: Int, mean: Double) {
        guard a.width == b.width, a.height == b.height else { return (255, 255) }
        var maximum = 0
        var total = 0
        for index in a.bytes.indices {
            let difference = abs(Int(a.bytes[index]) - Int(b.bytes[index]))
            maximum = max(maximum, difference)
            total += difference
        }
        return (maximum, Double(total) / Double(max(a.bytes.count, 1)))
    }
}
