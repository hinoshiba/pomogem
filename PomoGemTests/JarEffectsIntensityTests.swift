import SpriteKit
import XCTest
@testable import PomoGem

/// 演出の強さ (D17, Docs/GemExperienceDesign.md §7.6, §7.10): 控えめ keeps
/// every gem, gram, cut and fusion, but has no spontaneous twinkle, no tilt
/// glints, lighter halos and shorter landing and fusion beats. Reduce
/// Motion implies 控えめ. The preference is device-local.
@MainActor
final class JarEffectsIntensityTests: XCTestCase {
    private func loose(_ index: Int = 1, grams: Int = Constants.Mass.measuredPebbleGrams) -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: String(format: "E1700000-0000-4000-8000-%012X", index))!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: grams,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }

    private func crystal(level: Int) -> PebbleDescriptor {
        let pebbleCount = Int(pow(10, Double(level)))
        return PebbleDescriptor(
            id: UUID(uuidString: String(format: "E1710000-0000-4000-8000-%012X", level))!,
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
                periodStart: Date(timeIntervalSince1970: 100),
                periodEnd: Date(timeIntervalSince1970: 200),
                sessionIDs: [],
                measuredPebbleCount: pebbleCount,
                manualPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0
            ),
            grams: pebbleCount * Constants.Mass.measuredPebbleGrams
        )
    }

    private func glintAlphas(_ pebble: PebbleNode) -> [CGFloat] {
        var alphas: [CGFloat] = []
        pebble.enumerateChildNodes(withName: "//gem.glint") { node, _ in alphas.append(node.alpha) }
        return alphas
    }

    // MARK: Preference

    func testReduceMotionImpliesSubtleAndThePreferenceIsDeviceLocal() throws {
        XCTAssertEqual(JarEffectsIntensity.resolved(preference: .standard, reduceMotion: false), .standard)
        XCTAssertEqual(JarEffectsIntensity.resolved(preference: .standard, reduceMotion: true), .subtle)
        XCTAssertEqual(JarEffectsIntensity.resolved(preference: .subtle, reduceMotion: false), .subtle)
        XCTAssertEqual(JarEffectsIntensity.resolved(preference: .subtle, reduceMotion: true), .subtle)

        let suiteName = "JarEffectsIntensityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(JarEffectsIntensity.stored(in: defaults), .standard, "標準 until chosen")
        defaults.set(JarEffectsIntensity.subtle.rawValue, forKey: JarEffectsIntensity.defaultsKey)
        XCTAssertEqual(JarEffectsIntensity.stored(in: defaults), .subtle)
        defaults.set("loud", forKey: JarEffectsIntensity.defaultsKey)
        XCTAssertEqual(JarEffectsIntensity.stored(in: defaults), .standard, "Unknown values read as 標準")
        // One device key: not scoped to an account and not a synced Prefs field.
        XCTAssertEqual(JarEffectsIntensity.defaultsKey, "jar.effects-intensity")
        XCTAssertFalse(JarEffectsIntensity.defaultsKey.contains(".account."))
        defaults.set(JarEffectsIntensity.subtle.rawValue, forKey: JarEffectsIntensity.defaultsKey)
        XCTAssertEqual(JarEffectsIntensity.current(reduceMotionEnvironment: false, defaults: defaults), .subtle)
        defaults.set(JarEffectsIntensity.standard.rawValue, forKey: JarEffectsIntensity.defaultsKey)
        XCTAssertEqual(JarEffectsIntensity.current(reduceMotionEnvironment: true, defaults: defaults), .subtle)
    }

    func testSubtleCalmsEveryKindOfEffect() {
        let standard = JarEffectsIntensity.standard
        let subtle = JarEffectsIntensity.subtle
        XCTAssertTrue(standard.allowsSpontaneousTwinkle)
        XCTAssertTrue(standard.allowsTiltGlints)
        XCTAssertTrue(standard.allowsBreathing)
        XCTAssertEqual(standard.haloScale, 1)
        XCTAssertEqual(standard.innerGlowScale, 1)
        XCTAssertFalse(subtle.allowsSpontaneousTwinkle)
        XCTAssertFalse(subtle.allowsTiltGlints)
        XCTAssertFalse(subtle.allowsBreathing)
        XCTAssertLessThan(subtle.haloScale, 1)
        XCTAssertLessThan(subtle.innerGlowScale, 1)
        XCTAssertLessThan(subtle.haloScale, subtle.innerGlowScale, "Halos dim more than a gem's own light")

        // Landing: 標準 is the shipped beat; 控えめ is shorter, smaller and
        // flares no star.
        XCTAssertEqual(standard.landing.haloRise + standard.landing.haloFall, 0.44, accuracy: 0.001)
        XCTAssertTrue(standard.landing.flaresStar)
        XCTAssertEqual(standard.landing.sparkCount(standard: 7), 7)
        XCTAssertFalse(subtle.landing.flaresStar)
        XCTAssertEqual(subtle.landing.sparkCount(standard: 6), 3)
        XCTAssertEqual(subtle.landing.sparkCount(standard: 8), 4)
        XCTAssertEqual(subtle.landing.sparkCount(standard: 1), 1, "Never zero")
        XCTAssertLessThan(subtle.landing.duration, standard.landing.duration * 0.6)
        XCTAssertLessThan(subtle.landing.haloSwell, standard.landing.haloSwell)
        XCTAssertLessThan(subtle.landing.pileSwell, standard.landing.pileSwell)
        XCTAssertLessThan(subtle.landing.cameraShake, standard.landing.cameraShake)

        // Fusion: 標準 is the shipped beat (≈ 1.1 s); 控えめ is about half,
        // with no overshoot and no shards.
        XCTAssertEqual(standard.fusion.formation, Constants.Jar.aggregateFormationDuration)
        XCTAssertEqual(standard.fusion.duration, 1.12, accuracy: 0.001)
        XCTAssertEqual(standard.fusion.shardCount, 12)
        XCTAssertEqual(subtle.fusion.shardCount, 0)
        XCTAssertEqual(subtle.fusion.birthOvershoot, 1, "No spring overshoot")
        XCTAssertLessThan(subtle.fusion.ringScale, standard.fusion.ringScale)
        XCTAssertLessThan(subtle.fusion.flashAlpha, standard.fusion.flashAlpha)
        XCTAssertLessThanOrEqual(subtle.fusion.duration, 0.6)

        // The fusion sheet: no rays, a smaller swell, about half as long.
        XCTAssertTrue(standard.fusionSheet.showsRays)
        XCTAssertFalse(subtle.fusionSheet.showsRays)
        XCTAssertLessThan(subtle.fusionSheet.coreSwell, standard.fusionSheet.coreSwell)
        XCTAssertGreaterThan(subtle.fusionSheet.convergedOrbit, standard.fusionSheet.convergedOrbit, "Pulls in less")
        XCTAssertLessThanOrEqual(subtle.fusionSheet.duration, standard.fusionSheet.duration * 0.6)
    }

    // MARK: Gems

    /// Same body, physics and cut; only the light changes.
    func testSubtleGemKeepsItsBodyAndDimsOnlyItsLight() throws {
        for descriptor in [loose(), crystal(level: 2)] {
            let standard = PebbleNode(descriptor: descriptor, reduceMotion: false)
            let subtle = PebbleNode(descriptor: descriptor, reduceMotion: false, effectsIntensity: .subtle)
            XCTAssertEqual(subtle.effects, .subtle)
            XCTAssertEqual(subtle.radius, standard.radius)
            XCTAssertEqual(subtle.physicsBody?.mass, standard.physicsBody?.mass)
            XCTAssertEqual(subtle.gemRung, standard.gemRung)
            let standardBody = try XCTUnwrap(standard.childNode(withName: "gem.body") as? SKSpriteNode)
            let subtleBody = try XCTUnwrap(subtle.childNode(withName: "gem.body") as? SKSpriteNode)
            XCTAssertEqual(
                GemTextureAtlas.shared.textureName(of: subtleBody),
                GemTextureAtlas.shared.textureName(of: standardBody),
                "The same baked body"
            )
            XCTAssertEqual(subtle.gemHaloAlpha, standard.gemHaloAlpha * JarEffectsIntensity.subtle.haloScale, accuracy: 0.0001)
            let standardGlow = try XCTUnwrap(standard.childNode(withName: "gem.innerGlow"))
            let subtleGlow = try XCTUnwrap(subtle.childNode(withName: "gem.innerGlow"))
            XCTAssertEqual(subtleGlow.alpha, standardGlow.alpha * JarEffectsIntensity.subtle.innerGlowScale, accuracy: 0.0001)

            // No spontaneous twinkle; one static star, as with Reduce Motion.
            XCTAssertTrue(standard.canGemTwinkle)
            XCTAssertFalse(subtle.canGemTwinkle)
            subtle.playGemTwinkle(sequence: 1, at: 10)
            XCTAssertFalse(subtle.isGemTwinkling)
            let stars = glintAlphas(subtle)
            XCTAssertEqual(stars.first ?? 0, PebbleNode.reducedMotionStarAlpha, accuracy: 0.001)
            XCTAssertEqual(stars.filter { $0 > 0 }.count, 1)

            // Tilt lights glints at 標準 only.
            var standardPeak: CGFloat = 0
            var subtlePeak: CGFloat = 0
            for step in -50 ... 50 {
                let horizontal = CGFloat(step) / 50
                standard.updatePresentationLighting(horizontal: horizontal)
                subtle.updatePresentationLighting(horizontal: horizontal)
                standardPeak = max(standardPeak, glintAlphas(standard).max() ?? 0)
                XCTAssertEqual(glintAlphas(subtle), stars, "控えめ: tilt never lights a glint")
                subtlePeak = max(subtlePeak, glintAlphas(subtle).max() ?? 0)
            }
            XCTAssertGreaterThan(standardPeak, PebbleNode.glintRestAlpha + 0.3)
            XCTAssertEqual(subtlePeak, PebbleNode.reducedMotionStarAlpha, accuracy: 0.001)
        }
    }

    func testSwitchingTheSettingRelightsALiveGemBothWays() throws {
        let pebble = PebbleNode(descriptor: crystal(level: 1), reduceMotion: false)
        let aura = try XCTUnwrap(pebble.childNode(withName: "aggregate.aura"))
        let standardHalo = pebble.gemHaloAlpha
        XCTAssertTrue(aura.hasActions(), "標準 breathes")
        pebble.playGemTwinkle(sequence: 0, at: 5)
        XCTAssertTrue(pebble.isGemTwinkling)

        pebble.setEffectsIntensity(.subtle)
        XCTAssertFalse(pebble.isGemTwinkling, "A flare in flight settles")
        XCTAssertFalse(aura.hasActions(), "控えめ holds its breath")
        XCTAssertEqual(pebble.gemHaloAlpha, standardHalo * JarEffectsIntensity.subtle.haloScale, accuracy: 0.0001)
        XCTAssertEqual(glintAlphas(pebble).filter { $0 > 0 }.count, 1)

        pebble.setEffectsIntensity(.standard)
        XCTAssertTrue(aura.hasActions())
        XCTAssertEqual(pebble.gemHaloAlpha, standardHalo, accuracy: 0.0001)
        XCTAssertTrue(glintAlphas(pebble).allSatisfy { abs($0 - PebbleNode.glintRestAlpha) < 0.001 })

        // Reduce Motion implies 控えめ whatever the preference.
        pebble.setReduceMotion(true)
        XCTAssertEqual(pebble.effects, .subtle)
        XCTAssertEqual(pebble.gemHaloAlpha, standardHalo * JarEffectsIntensity.subtle.haloScale, accuracy: 0.0001)
    }

    func testSubtleLandingPulseIsShorterAndFlaresNoStar() throws {
        func pulse(_ intensity: JarEffectsIntensity) throws -> (duration: TimeInterval, twinkles: Bool) {
            let pebble = PebbleNode(descriptor: loose(), reduceMotion: false, effectsIntensity: intensity)
            pebble.playLandingPulse()
            let halo = try XCTUnwrap(pebble.childNode(withName: "gem.halo"))
            let action = try XCTUnwrap(halo.action(forKey: PebbleNode.landingPulseKey))
            return (action.duration, pebble.isGemTwinkling)
        }
        let standard = try pulse(.standard)
        let subtle = try pulse(.subtle)
        XCTAssertEqual(standard.duration, 0.44, accuracy: 0.001)
        XCTAssertTrue(standard.twinkles)
        XCTAssertEqual(subtle.duration, 0.26, accuracy: 0.001)
        XCTAssertFalse(subtle.twinkles)

        let reduced = PebbleNode(descriptor: loose(), reduceMotion: true)
        reduced.playLandingPulse()
        XCTAssertNil(reduced.childNode(withName: "gem.halo")?.action(forKey: PebbleNode.landingPulseKey), "Reduce Motion: no pulse")
    }

    // MARK: Scene

    func testSceneAtSubtleNeverTwinklesAndPassesTheSettingToEveryBody() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        scene.restore(pebbles: (1 ... 9).map { loose($0) } + [crystal(level: 2)])
        scene.effectsIntensity = .subtle
        XCTAssertEqual(scene.effects, .subtle)
        var time: TimeInterval = 0
        for _ in 0 ..< 40 {
            time += 0.25
            scene.update(time)
            scene.enumerateChildNodes(withName: "//pebble.*") { node, _ in
                guard let pebble = node as? PebbleNode else { return }
                XCTAssertEqual(pebble.effects, .subtle)
                XCTAssertFalse(pebble.isGemTwinkling, "No spontaneous twinkle at 控えめ")
            }
        }
        // Bodies built after the change take the setting too.
        scene.restore(pebbles: [loose(20)])
        let newcomer = try XCTUnwrap(scene.childNode(withName: "//pebble.\(loose(20).id.uuidString)") as? PebbleNode)
        XCTAssertEqual(newcomer.effectsIntensity, .subtle)

        scene.effectsIntensity = .standard
        XCTAssertEqual(newcomer.effects, .standard)
        scene.reduceMotion = true
        XCTAssertEqual(scene.effects, .subtle, "Reduce Motion implies 控えめ")
        XCTAssertEqual(newcomer.effects, .subtle)
    }

    /// 控えめ: the ten converge faster and the finale has no shards, even
    /// for an A2 crystal (≥ 25 kg), which throws twelve at 標準.
    func testSubtleFusionIsShorterAndThrowsNoShards() throws {
        func fuse(_ intensity: JarEffectsIntensity, prefix: String) throws -> JarScene {
            let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.reduceMotion = false
            scene.effectsIntensity = intensity
            let descriptors = (0 ..< Constants.Jar.aggregateFanIn).map { index in
                PebbleDescriptor(
                    id: UUID(uuidString: String(format: "\(prefix)000000-0000-4000-8000-%012X", index + 1))!,
                    subjectName: "英語",
                    colorHex: Constants.Color.english,
                    source: .timer,
                    kind: .normal,
                    grams: 2_500,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }
            var request: JarAggregateRequest?
            scene.onAggregateRequested = { request = $0 }
            scene.restore(pebbles: descriptors)
            scene.update(0)
            let finished = expectation(description: "fusion \(prefix)")
            DispatchQueue.main.asyncAfter(deadline: .now() + intensity.fusion.formation + 0.08) {
                finished.fulfill()
            }
            wait(for: [finished], timeout: 3)
            XCTAssertNotNil(request, "\(intensity): the ten fused within its formation time")
            return scene
        }

        let standard = try fuse(.standard, prefix: "E3")
        XCTAssertNotNil(standard.childNode(withName: "//drop.fusionFlash"))
        XCTAssertNotNil(standard.childNode(withName: "//drop.fusionShard"))
        XCTAssertNotNil(standard.childNode(withName: "//drop.fusionRing"))

        let subtle = try fuse(.subtle, prefix: "E4")
        XCTAssertNotNil(subtle.childNode(withName: "//drop.fusionFlash"), "Still a visible moment")
        XCTAssertNotNil(subtle.childNode(withName: "//drop.fusionRing"))
        XCTAssertNil(subtle.childNode(withName: "//drop.fusionShard"))
        let flash = try XCTUnwrap(subtle.childNode(withName: "//drop.fusionFlash"))
        XCTAssertLessThanOrEqual(flash.alpha, JarEffectsIntensity.subtle.fusion.flashAlpha + 0.001)
    }

    // MARK: Core and share

    /// The share card's time core draws the same stone with lighter lights.
    func testShareCoreLightsDimAtSubtle() throws {
        func luminance(_ effects: JarEffectsIntensity) throws -> CGFloat {
            let core = JarShareCore(
                shares: [GemColorShare(hex: Constants.Color.english, fraction: 0.6), GemColorShare(hex: Constants.Color.mathematics, fraction: 0.4)],
                level: 2,
                vesselLitFacets: nil,
                diameter: 80,
                effects: effects
            )
            let size = CGSize(width: 240, height: 240)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIColor.black.setFill()
                renderer.fill(CGRect(origin: .zero, size: size))
                JarShareCoreArtwork.draw(core, center: CGPoint(x: 120, y: 120), in: renderer.cgContext, scale: 1)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            var data = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &data,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            // The light around the stone: a ring outside its frame.
            var total: CGFloat = 0
            for row in 0 ..< cgImage.height {
                for column in 0 ..< cgImage.width {
                    let dx = CGFloat(column) - 120
                    let dy = CGFloat(row) - 120
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard distance > 44, distance < 100 else { continue }
                    let index = (row * cgImage.width + column) * 4
                    total += 0.2126 * CGFloat(data[index]) + 0.7152 * CGFloat(data[index + 1]) + 0.0722 * CGFloat(data[index + 2])
                }
            }
            return total
        }
        let standard = try luminance(.standard)
        let subtle = try luminance(.subtle)
        XCTAssertGreaterThan(standard, 0)
        XCTAssertLessThan(subtle, standard * 0.85)
        XCTAssertGreaterThan(subtle, standard * 0.4, "Lighter, not gone")
    }
}
