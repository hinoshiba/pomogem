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
        "aggregate.countPlate",
        "aggregate.count"
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
        atlas.removeImages(named: (0 ..< count).map { "test.budget.\($0)" })
    }

    /// The rubble baked into one sprite draws what its eight shape nodes
    /// drew (only antialiasing along edges may differ slightly).
    @MainActor
    func testBakedRubbleMatchesTheFormerShapeNodes() throws {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        let scale = view.contentScaleFactor
        for obstacle in [
            ScreenTimeObstacleDescriptor(level: 0, slot: 3, representedUnits: 1, isHistoryPile: false),
            ScreenTimeObstacleDescriptor(level: 2, slot: 7, representedUnits: 100, isHistoryPile: false),
            ScreenTimeObstacleDescriptor(level: 4, slot: 1, representedUnits: 10_000, isHistoryPile: true)
        ] {
            let radius = obstacle.radius
            let legacy = legacyRubble(obstacle, radius: radius)
            let variations = ScreenTimeObstacleAppearance.variations(descriptor: obstacle)
            let baked = SKTexture(image: ScreenTimeObstacleAppearance.image(
                variations: variations,
                radius: radius,
                scale: scale
            ))
            baked.filteringMode = .linear
            let before = try render(legacy, in: view)
            let after = try render(
                SKSpriteNode(texture: baked, size: ScreenTimeObstacleAppearance.spriteSize(radius: radius)),
                in: view
            )
            let difference = compare(before, after)
            // Measured at 1×: mean 0.3–0.9, under 0.2 % of pixels beyond
            // 48/255 (edge antialiasing and sub-pixel placement only). A
            // flipped, recoloured or missing part is far above either bound.
            XCTAssertLessThan(difference.mean, 1.5, "Mean channel difference for level \(obstacle.level)")
            XCTAssertLessThan(
                differingPixelShare(before, after, threshold: 48),
                0.01,
                "Only edge antialiasing may differ (level \(obstacle.level))"
            )
        }
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

    /// The rubble exactly as it was built before the bake (outline, six
    /// facets and the crack as shape nodes, no count).
    @MainActor
    private func legacyRubble(_ descriptor: ScreenTimeObstacleDescriptor, radius: CGFloat) -> SKNode {
        let bytes = Array(descriptor.id.uuidString.utf8)
        let points: [CGPoint] = (0 ..< 12).map { index in
            let angle = CGFloat(index) / 12 * .pi * 2
            let variation = CGFloat(bytes[index % bytes.count] % 11) / 100
            let scale: CGFloat = index.isMultiple(of: 3) ? 0.78 + variation : 0.90 + variation
            return CGPoint(x: cos(angle) * radius * scale, y: sin(angle) * radius * scale)
        }
        let outline = CGMutablePath()
        outline.move(to: points[0])
        points.dropFirst().forEach { outline.addLine(to: $0) }
        outline.closeSubpath()
        let node = SKShapeNode(path: outline)
        node.fillColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        node.strokeColor = UIColor(red: 0.39, green: 0.38, blue: 0.42, alpha: 1)
        node.lineWidth = 1.2
        node.glowWidth = 0
        for index in stride(from: 0, to: points.count, by: 2) {
            let facetPath = CGMutablePath()
            facetPath.move(to: CGPoint(x: -radius * 0.08, y: radius * 0.06))
            facetPath.addLine(to: points[index])
            facetPath.addLine(to: points[(index + 1) % points.count])
            facetPath.closeSubpath()
            let facet = SKShapeNode(path: facetPath)
            facet.fillColor = UIColor(white: index < 6 ? 0.36 : 0.05, alpha: 0.70)
            facet.strokeColor = UIColor(white: 0.48, alpha: 0.25)
            facet.lineWidth = 0.5
            facet.zPosition = 0.1
            node.addChild(facet)
        }
        let crackPath = CGMutablePath()
        crackPath.move(to: CGPoint(x: -radius * 0.5, y: radius * 0.45))
        crackPath.addLine(to: CGPoint(x: radius * 0.1, y: radius * 0.08))
        crackPath.addLine(to: CGPoint(x: -radius * 0.02, y: -radius * 0.52))
        let crack = SKShapeNode(path: crackPath)
        crack.strokeColor = UIColor(white: 0.02, alpha: 0.92)
        crack.lineWidth = max(1, radius * 0.08)
        crack.zPosition = 0.2
        node.addChild(crack)
        return node
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
