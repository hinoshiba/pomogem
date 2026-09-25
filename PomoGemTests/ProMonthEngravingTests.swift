import SpriteKit
import XCTest
@testable import PomoGem

/// D21 (Docs/GemExperienceDesign.md §7.2, §11): Pro's promised
/// 「まとまり粒の月刻印」 is always visible — the crystal's month ("2026.9")
/// engraved under its ×N on the same copper tag. Pro adds no new look: the
/// cut, light, halo and size of a crystal never depend on Pro.
@MainActor
final class ProMonthEngravingTests: XCTestCase {
    private func septemberNoon(year: Int = 2026, month: Int = 9) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))!
    }

    private func crystal(level: Int = 1, createdAt: Date, suffix: Int = 1) -> PebbleDescriptor {
        let pebbleCount = Int(pow(10, Double(level)))
        return PebbleDescriptor(
            id: UUID(uuidString: String(format: "D2100000-0000-4000-8000-%012X", suffix))!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: AggregateMetadata(
                level: level,
                pebbleCount: pebbleCount,
                childAggregateCount: level == 1 ? 0 : 10,
                colorMix: [StratumColorFraction(hex: Constants.Color.english, fraction: 1)],
                subjectMix: [AggregateSubjectFraction(name: "英語", colorHex: Constants.Color.english, pebbleCount: pebbleCount)],
                periodStart: createdAt.addingTimeInterval(-86_400),
                periodEnd: createdAt,
                sessionIDs: [],
                measuredPebbleCount: pebbleCount,
                manualPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0
            ),
            grams: pebbleCount * Constants.Mass.measuredPebbleGrams,
            createdAt: createdAt
        )
    }

    func testProEngravesTheMonthUnderTheCountAndKeepsTheCountWhereItWas() throws {
        let descriptor = crystal(createdAt: septemberNoon())
        let free = PebbleNode(descriptor: descriptor, reduceMotion: true)
        let pro = PebbleNode(descriptor: descriptor, reduceMotion: true, showsMonthEngraving: true)

        XCTAssertNil(free.aggregateTagMonth)
        XCTAssertEqual(pro.aggregateTagMonth, "2026.9")
        XCTAssertEqual(pro.aggregateTagText, free.aggregateTagText, "The count is the same text")

        let freeTag = try XCTUnwrap(free.childNode(withName: "aggregate.tag") as? SKSpriteNode)
        let proTag = try XCTUnwrap(pro.childNode(withName: "aggregate.tag") as? SKSpriteNode)
        // Without Pro the tag is exactly the D26 tag.
        let fontSize = GemArtwork.countTagFontSize(sceneRadius: descriptor.radius)
        XCTAssertEqual(freeTag.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(
            GemTextureAtlas.shared.textureName(of: freeTag),
            GemArtwork.countEngravingTextureName(text: "×10", fontSize: fontSize, style: .copperTag, scale: PebbleNode.defaultArtworkScale)
        )
        XCTAssertEqual(freeTag.size, GemArtwork.countEngravingSize(text: "×10", fontSize: fontSize, style: .copperTag))

        // With Pro: one sprite, taller, the count line still 0.40R below the
        // centre (the month hangs below it), and still a small tag.
        XCTAssertGreaterThan(proTag.size.height, freeTag.size.height)
        XCTAssertEqual(proTag.position, freeTag.position)
        let countLine = GemArtwork.countEngravingCountLineHeight(fontSize: fontSize)
        let top = proTag.position.y + (1 - proTag.anchorPoint.y) * proTag.size.height
        XCTAssertEqual(top - countLine / 2, proTag.position.y, accuracy: 0.01, "Count line centred where it was")
        XCTAssertEqual(proTag.blendMode, .alpha)
        XCTAssertLessThanOrEqual(proTag.size.height * pro.xScale, 24, "Still a maker's tag")
        let scaled = PebbleNode(descriptor: descriptor, reduceMotion: true, jarScale: JarScalePolicy.maximumScale, showsMonthEngraving: true)
        let scaledTag = try XCTUnwrap(scaled.childNode(withName: "aggregate.tag") as? SKSpriteNode)
        XCTAssertLessThanOrEqual(scaledTag.size.height * scaled.xScale, 24, "Counter-scaled at any jar scale")

        // The month line is copper and cut like the count, in its own texture.
        XCTAssertNotEqual(GemTextureAtlas.shared.textureName(of: proTag), GemTextureAtlas.shared.textureName(of: freeTag))
        XCTAssertTrue(GemTextureAtlas.shared.textureName(of: proTag)?.allSatisfy(\.isASCII) ?? false, "Atlas keys stay ASCII")
        let image = GemArtwork.countEngravingImage(text: "×10", fontSize: 9, style: .copperTag, scale: 2, month: "2026.9")
        XCTAssertEqual(image.size, GemArtwork.countEngravingSize(text: "×10", fontSize: 9, style: .copperTag, month: "2026.9"))
    }

    /// No new exclusive look: everything but the tag is the same for Pro.
    func testProAddsNoNewLookToTheCrystal() throws {
        for level in 1 ... 4 {
            let descriptor = crystal(level: level, createdAt: septemberNoon(), suffix: level)
            let free = PebbleNode(descriptor: descriptor, reduceMotion: false)
            let pro = PebbleNode(descriptor: descriptor, reduceMotion: false, showsMonthEngraving: true)
            XCTAssertEqual(pro.gemRung, free.gemRung)
            XCTAssertEqual(pro.radius, free.radius)
            XCTAssertEqual(pro.physicsBody?.mass, free.physicsBody?.mass)
            XCTAssertEqual(pro.gemHaloAlpha, free.gemHaloAlpha, accuracy: 0.0001)
            let freeBody = try XCTUnwrap(free.childNode(withName: "gem.body") as? SKSpriteNode)
            let proBody = try XCTUnwrap(pro.childNode(withName: "gem.body") as? SKSpriteNode)
            XCTAssertEqual(GemTextureAtlas.shared.textureName(of: proBody), GemTextureAtlas.shared.textureName(of: freeBody))
            var freeGlints = 0
            var proGlints = 0
            free.enumerateChildNodes(withName: "//gem.glint") { _, _ in freeGlints += 1 }
            pro.enumerateChildNodes(withName: "//gem.glint") { _, _ in proGlints += 1 }
            XCTAssertEqual(proGlints, freeGlints)
        }
        // Loose gems carry no tag and no month.
        let loose = PebbleNode(
            descriptor: PebbleDescriptor(
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams,
                createdAt: septemberNoon()
            ),
            reduceMotion: true,
            showsMonthEngraving: true
        )
        XCTAssertNil(loose.aggregateTagMonth)
        XCTAssertNil(loose.childNode(withName: "aggregate.tag"))
    }

    func testTheJarFollowsProOnLiveCrystalsBothWays() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptor = crystal(level: 2, createdAt: septemberNoon(year: 2027, month: 1))
        scene.restore(pebbles: [descriptor])
        let node = try XCTUnwrap(scene.childNode(withName: "//pebble.\(descriptor.id.uuidString)") as? PebbleNode)
        XCTAssertNil(node.aggregateTagMonth)

        scene.showsMonthLabels = true
        XCTAssertEqual(node.aggregateTagMonth, "2027.1")
        scene.showsMonthLabels = false
        XCTAssertNil(node.aggregateTagMonth)

        // Bodies built while Pro is on carry it from birth.
        scene.showsMonthLabels = true
        scene.restore(pebbles: [descriptor])
        let rebuilt = try XCTUnwrap(scene.childNode(withName: "//pebble.\(descriptor.id.uuidString)") as? PebbleNode)
        XCTAssertEqual(rebuilt.aggregateTagMonth, "2027.1")
    }

    /// The engraving names the same month as the fusion sheet's Pro label
    /// (`JarAggregateRequest.monthLabel`), with digits only.
    func testHallmarkNamesTheFusionSheetsMonth() {
        let samples = [(2026, 9), (2026, 10), (2026, 12), (2027, 1), (2031, 7)]
        for (year, month) in samples {
            let date = septemberNoon(year: year, month: month)
            let hallmark = GemArtwork.monthHallmark(for: date)
            XCTAssertEqual(hallmark, "\(String(year)).\(String(month))")
            XCTAssertEqual(StrataMath.monthLabel(for: date), "\(String(year))年\(String(month))月")
            XCTAssertTrue(hallmark.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }, "No grouping, no words: \(hallmark)")
        }
    }
}
