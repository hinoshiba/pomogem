#if DEBUG && targetEnvironment(simulator)
import SpriteKit
import SwiftData
import SwiftUI

/// Deterministic, CloudKit-free jar contents for reviewing gem rendering in
/// the Simulator. Every mode requires the explicit in-memory UI-test launch
/// (`POMOGEM_LOCAL_PREVIEW=1` + `POMOGEM_UI_TEST_MODE=1`), so neither the
/// ordinary Debug simulator store nor any iCloud container is touched. The
/// file is compiled out of Release and of every device build.
///
/// - `first`: one 25-minute completion (the early-effort spotlight state).
/// - `home`: fifteen 25-minute completions, the oldest ten stored as one
///   ×10 aggregate (as the live fusion persists it), five loose gems and the
///   3.75kg time core — the same state as the owner's reference image.
/// - `tiers`: 117 completions stored as ×100 + ×10 + seven loose gems plus
///   one achievement stone (29.25kg core).
/// - `gallery`: no persistence at all. A standalone jar restores one
///   descriptor per visual tier (loose, self-reported, ×10 … ×1万,
///   achievement) plus Screen Time obstacles, for side-by-side inspection.
enum GemShowcaseUITestFixture {
    static let environmentKey = "POMOGEM_UI_TEST_GEM_SHOWCASE"

    enum Mode: String {
        case first
        case home
        /// Mid-load jar for D4's acceptance (a) (Docs/GemExperienceDesign.md
        /// §7.5): 39 completions, three ×10 roots and nine loose gems.
        case midload
        case tiers
        case gallery
        /// Worst case for rendering: the study body ceiling plus the maximum
        /// visible achievements and Screen Time obstacles, all at once.
        case stress
        /// Worst case for capacity (Docs/GemExperienceDesign.md §7.5): nine
        /// loose gems (long ones included), 18 roots, 12 achievement stones
        /// and 36 obstacles in the lowest (320 pt) jar.
        case worstcase
        /// Reward-moment review: nine resting 25-minute gems beside six ×100
        /// and five ×10 roots (a jar whose scale is set by its area budget,
        /// D4), then a tenth completion drops, lands and fuses into ×10
        /// (A1); the pile grows back when the ten become one. Frames of the
        /// landing and the fusion finale are written to the app's tmp
        /// directory (`fx-before-*.png`, `fx-landing-*.png`,
        /// `fx-fusion-*.png`) unless `POMOGEM_UI_TEST_FX_FRAMES=0` asks for
        /// an unstalled recording.
        case fusionfx
        /// Heavy users for the gem bed: 1,004 completions (about 251 kg:
        /// one ×1000 root and four loose gems) and 10,006 completions
        /// (about 2.5 t: one ×1万 root and six loose gems).
        case heavy
        case veteran
        /// Theme tone and mark review (Docs/GemExperienceDesign.md §7.4,
        /// §7.12): one 25-minute gem in each `SubjectPalette` colour, two
        /// off-palette legacy colours, and ×10 crystals that mix palette
        /// colours, under a core whose fan holds seven themes (top five +
        /// その他). Turn on Differentiate Without Color to see the marks.
        case palette
    }

    static var modeForCurrentProcess: Mode? {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = ProcessInfo.processInfo.environment[environmentKey]
        else { return nil }
        return Mode(rawValue: value)
    }

    static var showsGalleryForCurrentProcess: Bool {
        modeForCurrentProcess == .gallery
            || modeForCurrentProcess == .stress
            || modeForCurrentProcess == .worstcase
            || modeForCurrentProcess == .fusionfx
            || modeForCurrentProcess == .palette
    }

    /// Subject order chosen so the reference state mixes coral, blue and
    /// violet gems like the owner's mood image.
    private static let subjectCycle = [0, 1, 4, 0, 2, 1, 0, 3, 4, 0, 1, 2, 0, 4, 1]

    private static var sessionCount: Int? {
        switch modeForCurrentProcess {
        case .first: 1
        case .home: 15
        case .midload: 39
        case .tiers: 117
        case .heavy: 1_004
        case .veteran: 10_006
        case .gallery, .stress, .worstcase, .fusionfx, .palette, nil: nil
        }
    }

    /// Inserts completed sessions into the in-memory preview store once.
    @MainActor
    static func seedIfNeeded(context: ModelContext) throws {
        guard let count = sessionCount else { return }
        var existingSessions = FetchDescriptor<StudySession>()
        existingSessions.fetchLimit = 1
        guard try context.fetch(existingSessions).isEmpty else { return }

        let presets = SeedData.subjects
        var subjects: [Subject] = []
        for (index, preset) in presets.enumerated() {
            let presetID = preset.id
            var descriptor = FetchDescriptor<Subject>(
                predicate: #Predicate { $0.id == presetID }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                subjects.append(existing)
            } else {
                let subject = Subject(
                    id: preset.id,
                    name: preset.name,
                    colorHex: preset.colorHex,
                    sortOrder: index
                )
                context.insert(subject)
                subjects.append(subject)
            }
        }

        let calendar = Calendar(identifier: .gregorian)
        let end = calendar.startOfDay(for: .now).addingTimeInterval(-3_600)
        // Pre-baked hierarchy: every complete group of ten becomes a stored
        // aggregate, exactly as the live fusion would have persisted it, so
        // the jar opens settled (no celebration sheet) and screenshots are
        // reproducible. `home`: ×10 + 5 loose. `tiers`: ×100 + ×10 + 7 loose.
        let fanIn = Constants.Jar.aggregateFanIn
        let bakedCount = modeForCurrentProcess == .first ? 0 : (count / fanIn) * fanIn
        var planned: [(id: UUID, subject: Subject, start: Date, end: Date)] = []
        for index in 0 ..< count {
            let subject = subjects[subjectCycle[index % subjectCycle.count] % subjects.count]
            let endAt = end.addingTimeInterval(-Double(count - index) * 5_400)
            planned.append((sessionID(index: index), subject, endAt.addingTimeInterval(-1_500), endAt))
            context.insert(StudySession(
                id: sessionID(index: index),
                subject: subject,
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                pebbleKind: .normal,
                grams: 250,
                deviceDayKey: "gem-showcase-\(index / 4)",
                isBaked: index < bakedCount,
                subjectNameSnapshot: subject.name,
                subjectColorHexSnapshot: subject.colorHex,
                subjectIDSnapshot: subject.id
            ))
        }

        func mixes(_ range: Range<Int>) -> (String, String) {
            var countsByHex: [String: Int] = [:]
            var countsBySubject: [String: (hex: String, count: Int)] = [:]
            for index in range {
                let subject = planned[index].subject
                countsByHex[subject.colorHex, default: 0] += 1
                countsBySubject[subject.name] = (subject.colorHex, (countsBySubject[subject.name]?.count ?? 0) + 1)
            }
            let total = Double(max(1, range.count))
            let colorMix = countsByHex
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { StratumColorFraction(hex: $0.key, fraction: Double($0.value) / total) }
            let subjectMix = countsBySubject
                .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
                .map { AggregateSubjectFraction(name: $0.key, colorHex: $0.value.hex, pebbleCount: $0.value.count) }
            return (StrataMath.encodeColorMix(colorMix), StrataMath.encodeSubjectMix(subjectMix))
        }

        func aggregateID(level: Int, index: Int) -> UUID {
            UUID(uuidString: String(format: "6E4D5348-4147-4752-%04X-%012X", level, index))!
        }

        // Every complete group of ten at each level rolls up into the next
        // level (×10 → ×100 → ×1000 → ×1万), exactly as the live fusion
        // persists it; the highest complete level holds the roots.
        var countsByLevel: [Int] = []
        var levelCount = bakedCount / fanIn
        while levelCount > 0 {
            countsByLevel.append(levelCount)
            levelCount /= fanIn
        }
        for (levelIndex, count) in countsByLevel.enumerated() {
            let level = levelIndex + 1
            let size = Int(pow(Double(fanIn), Double(level)))
            let parentCount = levelIndex + 1 < countsByLevel.count ? countsByLevel[levelIndex + 1] : 0
            for group in 0 ..< count {
                let range = group * size ..< (group + 1) * size
                let (colorMix, subjectMix) = mixes(range)
                let parent = group < parentCount * fanIn
                    ? aggregateID(level: level + 1, index: group / fanIn)
                    : nil
                context.insert(AggregatePebble(
                    id: aggregateID(level: level, index: group),
                    createdAt: planned[range.upperBound - 1].end,
                    level: level,
                    pebbleCount: size,
                    childAggregateCount: level == 1 ? 0 : fanIn,
                    grams: size * 250,
                    measuredPebbleCount: size,
                    colorMixJSON: colorMix,
                    subjectMixJSON: subjectMix,
                    periodStart: planned[range.lowerBound].start,
                    periodEnd: planned[range.upperBound - 1].end,
                    sessionIDs: level == 1 ? range.map { planned[$0].id } : [],
                    childAggregateIDs: level == 1 ? [] : (group * fanIn ..< (group + 1) * fanIn).map {
                        aggregateID(level: level - 1, index: $0)
                    },
                    parentAggregateID: parent
                ))
            }
        }
        if modeForCurrentProcess == .tiers, let subject = subjects.first {
            context.insert(AchievementStone(
                id: UUID(uuidString: "6E4D5348-4F57-4341-5345-000000000A01")!,
                subject: subject,
                kind: .examPass,
                achievedAt: end,
                createdAt: end
            ))
        }
        try context.save()
    }

    private static func sessionID(index: Int) -> UUID {
        UUID(uuidString: String(format: "6E4D5348-4F57-4341-5345-%012X", index + 1))!
    }

    // MARK: Gallery

    private static let palette: [(name: String, hex: String)] = [
        ("英語", Constants.Color.english),
        ("数学", Constants.Color.mathematics),
        ("国語", Constants.Color.japanese),
        ("理科", Constants.Color.science),
        ("社会", Constants.Color.socialStudies)
    ]

    /// 116 loose study gems (+ one ×10, ×100 and ×1000 = 119 study bodies,
    /// below the 128 ceiling) and the 12 achievement maximum.
    static func stressDescriptors() -> [PebbleDescriptor] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var descriptors = galleryDescriptors().filter { $0.isAggregate && $0.aggregateLevel <= 3 }
        for index in 0 ..< 116 {
            let item = palette[index % palette.count]
            let minutes = [25, 25, 10, 50, 25, 5][index % 6]
            descriptors.append(PebbleDescriptor(
                id: UUID(uuidString: String(format: "6E4D5348-5354-5245-5353-%012X", index))!,
                subjectName: item.name,
                colorHex: item.hex,
                source: index % 9 == 4 ? .manual : .timer,
                kind: .normal,
                grams: index % 9 == 4 ? ManualDuration.thirtyMinutes.grams : minutes * Constants.Mass.gramsPerMinute,
                createdAt: base.addingTimeInterval(Double(index))
            ))
        }
        for index in 0 ..< Constants.Jar.maximumVisibleAchievementStones {
            descriptors.append(PebbleDescriptor(
                id: UUID(uuidString: String(format: "6E4D5348-5354-4143-4856-%012X", index))!,
                subjectName: "記念",
                colorHex: palette[index % palette.count].hex,
                source: .manual,
                kind: .normal,
                achievementKind: AchievementKind.allCases[index % AchievementKind.allCases.count],
                grams: 0,
                createdAt: base.addingTimeInterval(Double(200 + index))
            ))
        }
        return descriptors
    }

    /// Nine resting 25-minute gems, six ×100 and five ×10 roots for the
    /// reward-moment review.
    static func fusionEffectDescriptors() -> [PebbleDescriptor] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let roots = [2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1].enumerated().map { index, level in
            rootDescriptor(
                id: UUID(uuidString: String(format: "6E4D5348-4658-5254-%04X-%012X", level, index))!,
                level: level,
                paletteIndex: index,
                createdAt: base.addingTimeInterval(Double(index) - 100)
            )
        }
        return roots + (0 ..< 9).map { index in
            let item = palette[subjectCycle[index] % palette.count]
            return PebbleDescriptor(
                id: UUID(uuidString: String(format: "6E4D5348-4658-4658-4658-%012X", index))!,
                subjectName: item.name,
                colorHex: item.hex,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams,
                createdAt: base.addingTimeInterval(Double(index))
            )
        }
    }

    /// Legacy theme colours from the old hue-rotation suggestion (outside
    /// the palette): their marks sit in a ring.
    static let offPaletteHexes = ["#F07A26", "#3AA0E8"]

    /// The palette review jar (`palette`): twelve palette gems, two
    /// off-palette gems and three ×10 crystals of two to four themes.
    static func paletteDescriptors() -> [PebbleDescriptor] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let hexes = SubjectPalette.hexes
        func uuid(_ group: Int, _ index: Int) -> UUID {
            UUID(uuidString: String(format: "6E4D5348-5041-4C45-%04X-%012X", group, index))!
        }
        let mixes: [[(Int, Double)]] = [[(5, 0.6), (10, 0.4)], [(4, 0.5), (9, 0.3), (1, 0.2)], [(0, 0.4), (7, 0.3), (3, 0.2), (6, 0.1)]]
        var descriptors: [PebbleDescriptor] = mixes.enumerated().map { index, mix in
            let colorMix = mix.map { StratumColorFraction(hex: hexes[$0.0 % hexes.count], fraction: $0.1) }
            let metadata = AggregateMetadata(
                level: 1,
                pebbleCount: 10,
                childAggregateCount: 0,
                colorMix: colorMix,
                subjectMix: [],
                periodStart: base,
                periodEnd: base.addingTimeInterval(15_000),
                sessionIDs: (0 ..< 10).map { uuid(0x10 + index, $0) },
                measuredPebbleCount: 10,
                manualPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0
            )
            return PebbleDescriptor(
                id: uuid(0x20, index),
                subjectName: "結晶",
                colorHex: colorMix.first?.hex ?? Constants.Color.english,
                source: .timer,
                kind: .normal,
                aggregate: metadata,
                grams: 10 * Constants.Mass.measuredPebbleGrams,
                createdAt: base.addingTimeInterval(Double(index))
            )
        }
        for (index, hex) in (hexes + offPaletteHexes).enumerated() {
            descriptors.append(PebbleDescriptor(
                id: uuid(0x40, index),
                subjectName: SubjectPalette.swatches.first { $0.hex == hex }?.name ?? "旧色",
                colorHex: hex,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams,
                createdAt: base.addingTimeInterval(Double(10 + index))
            ))
        }
        return descriptors
    }

    static let fusionEffectDrop = PebbleDescriptor(
        id: UUID(uuidString: "6E4D5348-4658-4658-4658-00000000000A")!,
        subjectName: "英語",
        colorHex: Constants.Color.english,
        source: .timer,
        kind: .normal,
        grams: Constants.Mass.measuredPebbleGrams,
        createdAt: Date(timeIntervalSince1970: 1_790_000_100)
    )

    /// A root crystal of `level` (×10, ×100, …) in two palette colours.
    private static func rootDescriptor(id: UUID, level: Int, paletteIndex index: Int, createdAt: Date) -> PebbleDescriptor {
        let pebbleCount = Int(pow(10, Double(level)))
        let item = palette[index % palette.count]
        let mix = [
            StratumColorFraction(hex: item.hex, fraction: 0.6),
            StratumColorFraction(hex: palette[(index + 1) % palette.count].hex, fraction: 0.4)
        ]
        return PebbleDescriptor(
            id: id,
            subjectName: item.name,
            colorHex: item.hex,
            source: .timer,
            kind: .normal,
            aggregate: AggregateMetadata(
                level: level,
                pebbleCount: pebbleCount,
                childAggregateCount: level == 1 ? 0 : 10,
                colorMix: mix,
                subjectMix: [AggregateSubjectFraction(name: item.name, colorHex: item.hex, pebbleCount: pebbleCount)],
                periodStart: createdAt.addingTimeInterval(-Double(pebbleCount) * 1_500),
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

    /// 9 loose (25–120 min), 18 roots from ×10 to ×1万, 12 achievements.
    static func worstCaseDescriptors() -> [PebbleDescriptor] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var descriptors: [PebbleDescriptor] = []
        let rootLevels = [1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5]
        for (index, level) in rootLevels.enumerated() {
            let pebbleCount = Int(pow(10, Double(level)))
            let item = palette[index % palette.count]
            let mix = [
                StratumColorFraction(hex: item.hex, fraction: 0.6),
                StratumColorFraction(hex: palette[(index + 1) % palette.count].hex, fraction: 0.4)
            ]
            descriptors.append(PebbleDescriptor(
                id: UUID(uuidString: String(format: "6E4D5348-5752-5354-%04X-%012X", level, index))!,
                subjectName: item.name,
                colorHex: item.hex,
                source: .timer,
                kind: .normal,
                aggregate: AggregateMetadata(
                    level: level,
                    pebbleCount: pebbleCount,
                    childAggregateCount: level == 1 ? 0 : 10,
                    colorMix: mix,
                    subjectMix: [AggregateSubjectFraction(name: item.name, colorHex: item.hex, pebbleCount: pebbleCount)],
                    periodStart: base,
                    periodEnd: base.addingTimeInterval(Double(pebbleCount) * 1_500),
                    sessionIDs: [],
                    measuredPebbleCount: pebbleCount,
                    manualPebbleCount: 0,
                    goldPebbleCount: 0,
                    prismPebbleCount: 0
                ),
                grams: pebbleCount * Constants.Mass.measuredPebbleGrams,
                createdAt: base.addingTimeInterval(Double(index))
            ))
        }
        for (index, minutes) in [25, 25, 50, 60, 90, 120, 25, 45, 120].enumerated() {
            let item = palette[index % palette.count]
            descriptors.append(PebbleDescriptor(
                id: UUID(uuidString: String(format: "6E4D5348-5752-4C4F-4F53-%012X", index))!,
                subjectName: item.name,
                colorHex: item.hex,
                source: .timer,
                kind: .normal,
                grams: minutes * Constants.Mass.gramsPerMinute,
                createdAt: base.addingTimeInterval(Double(100 + index))
            ))
        }
        for index in 0 ..< Constants.Jar.maximumVisibleAchievementStones {
            descriptors.append(PebbleDescriptor(
                id: UUID(uuidString: String(format: "6E4D5348-5752-4143-4856-%012X", index))!,
                subjectName: "記念",
                colorHex: palette[index % palette.count].hex,
                source: .manual,
                kind: .normal,
                achievementKind: AchievementKind.allCases[index % AchievementKind.allCases.count],
                grams: 0,
                createdAt: base.addingTimeInterval(Double(200 + index))
            ))
        }
        return descriptors
    }

    static func galleryDescriptors() -> [PebbleDescriptor] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var descriptors: [PebbleDescriptor] = []

        func uuid(_ group: Int, _ index: Int) -> UUID {
            UUID(uuidString: String(format: "6E4D5348-4741-4C4C-%04X-%012X", group, index))!
        }

        for level in [4, 3, 2, 1] {
            let pebbleCount = Int(pow(10, Double(level)))
            let mix = palette.enumerated().map { offset, item in
                StratumColorFraction(
                    hex: item.hex,
                    fraction: [0.36, 0.26, 0.16, 0.12, 0.10][offset]
                )
            }
            let rotated = Array(mix[(level % mix.count)...] + mix[..<(level % mix.count)])
            let metadata = AggregateMetadata(
                level: level,
                pebbleCount: pebbleCount,
                childAggregateCount: level == 1 ? 0 : 10,
                colorMix: rotated,
                subjectMix: palette.map {
                    AggregateSubjectFraction(
                        name: $0.name,
                        colorHex: $0.hex,
                        pebbleCount: pebbleCount / palette.count
                    )
                },
                periodStart: base,
                periodEnd: base.addingTimeInterval(Double(pebbleCount) * 1_500),
                sessionIDs: level == 1 ? (0 ..< 10).map { uuid(0x10, $0) } : [],
                measuredPebbleCount: pebbleCount,
                manualPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0
            )
            descriptors.append(PebbleDescriptor(
                id: uuid(0x20, level),
                subjectName: rotated.first.map { hex in
                    palette.first { $0.hex == hex.hex }?.name ?? "英語"
                } ?? "英語",
                colorHex: rotated.first?.hex ?? Constants.Color.english,
                source: .timer,
                kind: .normal,
                aggregate: metadata,
                grams: pebbleCount * Constants.Mass.measuredPebbleGrams,
                createdAt: base.addingTimeInterval(Double(level))
            ))
        }

        descriptors.append(PebbleDescriptor(
            id: uuid(0x30, 1),
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0,
            createdAt: base.addingTimeInterval(10)
        ))

        let looseMinutes = [25, 60, 25, 10, 25, 25, 50]
        for (index, minutes) in looseMinutes.enumerated() {
            let item = palette[index % palette.count]
            descriptors.append(PebbleDescriptor(
                id: uuid(0x40, index),
                subjectName: item.name,
                colorHex: item.hex,
                source: .timer,
                kind: .normal,
                grams: minutes * Constants.Mass.gramsPerMinute,
                createdAt: base.addingTimeInterval(Double(20 + index))
            ))
        }
        descriptors.append(PebbleDescriptor(
            id: uuid(0x50, 1),
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .manual,
            kind: .normal,
            grams: ManualDuration.sixtyMinutes.grams,
            createdAt: base.addingTimeInterval(40)
        ))
        return descriptors
    }
}

/// Standalone jar for the `gallery`, `stress` and `worstcase` modes. It
/// restores fixed descriptors and never installs aggregate persistence
/// callbacks, so no fusion can occur. `POMOGEM_UI_TEST_PRO_MONTHS=1` shows
/// Pro's month engraving on the crystals' tags (D21).
struct GemShowcaseFixtureLaunchView: View {
    private static var mode: GemShowcaseUITestFixture.Mode? { GemShowcaseUITestFixture.modeForCurrentProcess }

    private static var descriptors: [PebbleDescriptor] {
        switch mode {
        case .stress: GemShowcaseUITestFixture.stressDescriptors()
        case .worstcase: GemShowcaseUITestFixture.worstCaseDescriptors()
        case .fusionfx: GemShowcaseUITestFixture.fusionEffectDescriptors()
        case .palette: GemShowcaseUITestFixture.paletteDescriptors()
        default: GemShowcaseUITestFixture.galleryDescriptors()
        }
    }

    /// The worst case uses the lowest jar the design supports (320 pt).
    private static var jarHeight: CGFloat { mode == .worstcase ? 320 : Constants.Jar.height }

    @StateObject private var scene: JarScene = {
        let scene = JarScene(size: CGSize(
            width: Constants.Jar.defaultSceneWidth,
            height: GemShowcaseFixtureLaunchView.jarHeight
        ))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        // D21 review: Pro's month engraving under every crystal's count
        // (the store purchase itself is not simulated).
        scene.showsMonthLabels = ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_PRO_MONTHS"] == "1"
        scene.restore(pebbles: GemShowcaseFixtureLaunchView.descriptors)
        switch GemShowcaseFixtureLaunchView.mode {
        case .fusionfx:
            // Fusion without persistence: the request is simply dropped.
            scene.onAggregateRequested = { _ in }
        case .gallery:
            scene.setScreenTimeObstacles(totalUnits: 12)
        case .palette:
            break
        default:
            // 36 obstacle bodies is the Screen Time projection ceiling.
            scene.setScreenTimeObstacles(totalUnits: 9_999)
        }
        return scene
    }()

    /// Renders the live scene over an opaque night background (so additive
    /// light composites as on screen) and writes it to the tmp directory.
    @MainActor
    private static func writeFrame(of scene: JarScene, name: String) {
        guard let view = scene.view else { return }
        let previous = scene.backgroundColor
        scene.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.13, alpha: 1)
        defer { scene.backgroundColor = previous }
        guard let texture = view.texture(from: scene, crop: scene.snapshotRect) else { return }
        let image = UIImage(cgImage: texture.cgImage())
        try? image.pngData()?.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-\(name).png"))
    }

    /// `POMOGEM_UI_TEST_FX_FRAMES=0` skips the in-app frame writes. Each
    /// write stalls the main thread (`texture(from:)` plus PNG encoding), so
    /// a screen recording (`simctl io recordVideo`) of the reward moment is
    /// only faithful to the live animation without them.
    private static var writesEffectFrames: Bool {
        ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_FX_FRAMES"] != "0"
    }

    /// `POMOGEM_UI_TEST_FX_DELAY=<s>`: when the fusionfx drop (default 4 s)
    /// and the gallery's share snapshot (default 9 s) happen. A delay past
    /// the idle pause reviews both from a stopped render loop (jar-01).
    private static func effectDelay(default seconds: Double) -> Double {
        ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_FX_DELAY"].flatMap(Double.init) ?? seconds
    }

    @MainActor
    private static func captureSequence(of scene: JarScene, prefix: String, offsets: [Int]) {
        guard writesEffectFrames else { return }
        for offset in offsets {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offset)) {
                writeFrame(of: scene, name: String(format: "%@-%04d", prefix, offset))
            }
        }
    }

    var body: some View {
        let descriptors = Self.descriptors
        let grams = descriptors.reduce(0) { $0 + $1.grams }
        let represented = descriptors.reduce(0) { total, descriptor in
            total + (descriptor.aggregate?.pebbleCount ?? (descriptor.isAchievement ? 0 : 1))
        }
        let shares = Self.mode == .palette
            ? zip([0, 1, 5, 9, 3, 10, 7], [0.30, 0.22, 0.16, 0.12, 0.10, 0.06, 0.04]).map {
                GemColorShare(hex: SubjectPalette.hexes[$0.0 % SubjectPalette.hexes.count], fraction: $0.1)
            }
            : [
                GemColorShare(hex: Constants.Color.english, fraction: 0.36),
                GemColorShare(hex: Constants.Color.mathematics, fraction: 0.26),
                GemColorShare(hex: Constants.Color.japanese, fraction: 0.16),
                GemColorShare(hex: Constants.Color.science, fraction: 0.12),
                GemColorShare(hex: Constants.Color.socialStudies, fraction: 0.10)
            ]
        ZStack {
            HomeAtmosphereBackground(atmosphere: .aurora)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text(Self.mode == .worstcase ? "最悪ケース（Debug・320pt）" : (Self.mode == .palette ? "テーマ12色（Debug）" : "宝石ギャラリー（Debug）"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                JarSpriteView(
                    scene: scene,
                    totalGrams: grams,
                    pebbleCount: descriptors.filter { !$0.isAggregate && !$0.isAchievement }.count,
                    achievementCount: descriptors.filter(\.isAchievement).count,
                    aggregateCount: descriptors.filter(\.isAggregate).count,
                    representedPebbleCount: represented,
                    accentHex: Constants.Color.english,
                    lifetimeCoreColorHex: Constants.Color.english,
                    lifetimeCoreColorShares: shares
                )
                .frame(height: Self.jarHeight + 40)
                if Self.mode == .worstcase {
                    // Acceptance: at least 15 % of the interior height stays
                    // free below the mouth once the pile settles.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("口の下の余白 \(Int((scene.pileHeadroomFraction * 100).rounded()))%（基準15%以上）")
                            .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .accessibilityIdentifier("gem.showcase.gallery")
        .task {
            guard Self.mode == .fusionfx else { return }
            var landed = false
            var fused = false
            scene.onLanding = { event in
                guard !landed, event.pebble.id == GemShowcaseUITestFixture.fusionEffectDrop.id else { return }
                landed = true
                Self.captureSequence(of: scene, prefix: "landing", offsets: [0, 80, 160, 320, 560])
            }
            scene.onCapacityEvent = { event in
                guard !fused, case .bakeCompleted = event else { return }
                fused = true
                Self.captureSequence(of: scene, prefix: "fusion", offsets: [0, 80, 160, 320, 560, 1100])
            }
            try? await Task.sleep(for: .seconds(Self.effectDelay(default: 4)))
            Self.captureSequence(of: scene, prefix: "before", offsets: [0])
            scene.performCompletionDrop(GemShowcaseUITestFixture.fusionEffectDrop)
        }
        .task {
            // Share/widget capture check: the same jar exported through
            // JarSnapshotter lands in the app's tmp directory, so it can be
            // compared with a screen capture (additive light must survive).
            guard Self.mode == .gallery else { return }
            try? await Task.sleep(for: .seconds(Self.effectDelay(default: 9)))
            guard let data = try? JarSnapshotter.shared.pngData(
                of: scene,
                options: .share(includesSelfReported: true)
            ) else { return }
            try? data.write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("gem-showcase-snapshot.png"))
        }
    }
}
#endif
