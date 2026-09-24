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
        case tiers
        case gallery
        /// Worst case for rendering: the study body ceiling plus the maximum
        /// visible achievements and Screen Time obstacles, all at once.
        case stress
    }

    static var modeForCurrentProcess: Mode? {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = ProcessInfo.processInfo.environment[environmentKey]
        else { return nil }
        return Mode(rawValue: value)
    }

    static var showsGalleryForCurrentProcess: Bool {
        modeForCurrentProcess == .gallery || modeForCurrentProcess == .stress
    }

    /// Subject order chosen so the reference state mixes coral, blue and
    /// violet gems like the owner's mood image.
    private static let subjectCycle = [0, 1, 4, 0, 2, 1, 0, 3, 4, 0, 1, 2, 0, 4, 1]

    private static var sessionCount: Int? {
        switch modeForCurrentProcess {
        case .first: 1
        case .home: 15
        case .tiers: 117
        case .gallery, .stress, nil: nil
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

        let levelOneCount = bakedCount / fanIn
        // Level-2 roots absorb complete groups of ten level-1 aggregates.
        let levelTwoCount = levelOneCount / fanIn
        for group in 0 ..< levelOneCount {
            let range = group * fanIn ..< (group + 1) * fanIn
            let (colorMix, subjectMix) = mixes(range)
            let parent = group < levelTwoCount * fanIn ? aggregateID(level: 2, index: group / fanIn) : nil
            context.insert(AggregatePebble(
                id: aggregateID(level: 1, index: group),
                createdAt: planned[range.upperBound - 1].end,
                level: 1,
                pebbleCount: fanIn,
                grams: fanIn * 250,
                measuredPebbleCount: fanIn,
                colorMixJSON: colorMix,
                subjectMixJSON: subjectMix,
                periodStart: planned[range.lowerBound].start,
                periodEnd: planned[range.upperBound - 1].end,
                sessionIDs: range.map { planned[$0].id },
                parentAggregateID: parent
            ))
        }
        for group in 0 ..< levelTwoCount {
            let size = fanIn * fanIn
            let range = group * size ..< (group + 1) * size
            let (colorMix, subjectMix) = mixes(range)
            context.insert(AggregatePebble(
                id: aggregateID(level: 2, index: group),
                createdAt: planned[range.upperBound - 1].end,
                level: 2,
                pebbleCount: size,
                childAggregateCount: fanIn,
                grams: size * 250,
                measuredPebbleCount: size,
                colorMixJSON: colorMix,
                subjectMixJSON: subjectMix,
                periodStart: planned[range.lowerBound].start,
                periodEnd: planned[range.upperBound - 1].end,
                childAggregateIDs: (group * fanIn ..< (group + 1) * fanIn).map {
                    aggregateID(level: 1, index: $0)
                }
            ))
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

/// Standalone jar for the `gallery` mode. It restores fixed descriptors and
/// never installs aggregate persistence callbacks, so no fusion can occur.
struct GemShowcaseFixtureLaunchView: View {
    @StateObject private var scene: JarScene = {
        let scene = JarScene(size: CGSize(
            width: Constants.Jar.defaultSceneWidth,
            height: Constants.Jar.height
        ))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let isStress = GemShowcaseUITestFixture.modeForCurrentProcess == .stress
        scene.restore(pebbles: isStress
            ? GemShowcaseUITestFixture.stressDescriptors()
            : GemShowcaseUITestFixture.galleryDescriptors())
        // 36 obstacle bodies is the Screen Time projection ceiling.
        scene.setScreenTimeObstacles(totalUnits: isStress ? 9_999 : 12)
        return scene
    }()

    var body: some View {
        let descriptors = GemShowcaseUITestFixture.modeForCurrentProcess == .stress
            ? GemShowcaseUITestFixture.stressDescriptors()
            : GemShowcaseUITestFixture.galleryDescriptors()
        let grams = descriptors.reduce(0) { $0 + $1.grams }
        ZStack {
            HomeAtmosphereBackground(atmosphere: .aurora)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text("宝石ギャラリー（Debug）")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                JarSpriteView(
                    scene: scene,
                    totalGrams: grams,
                    pebbleCount: descriptors.count,
                    achievementCount: 1,
                    aggregateCount: 4,
                    representedPebbleCount: 11_110 + 8,
                    accentHex: Constants.Color.english,
                    lifetimeCoreColorHex: Constants.Color.english
                )
                .frame(height: 460)
            }
            .padding(.horizontal, 8)
        }
        .accessibilityIdentifier("gem.showcase.gallery")
    }
}
#endif
