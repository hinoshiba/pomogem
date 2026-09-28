import XCTest
@testable import PomoGem

/// The reward-moment vocabulary, the jar HUD's honest timing and the delayed
/// manual save (walk-std-08, walk-std-09, dev-D7, history-02).
@MainActor
final class RewardVocabularyAndHUDTests: XCTestCase {
    // MARK: One vocabulary

    /// Retired nouns must not come back in user-facing text. Only string
    /// literals are read, so comments may still explain the history.
    func testShippingCopyUsesOneNounForEachThing() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let retired: [String: String] = [
            "成果の星": "記念石",
            "成果の石": "記念石",
            "まとまり粒": "結晶",
            "まとまり結晶": "結晶",
            "つぶ": "粒",
            "完走ポモ": "完走した回数",
            "戻った回数": "完走した回数",
            "物理履歴": "粒の数",
            "巡目": "N杯目",
            "成果名": "成果メモ"
        ]
        // Debug-only fixtures never ship. No shipping file is exempt: the
        // last one, PebbleNode's per-gem VoiceOver text, now uses the final
        // nouns too.
        var scannedFileCount = 0
        var findings: [String] = []
        for directory in ["PomoGem", "PomoGemWidgets", "PomoGemScreenTimeMonitor", "Shared"] {
            let url = projectRoot.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let fileURL as URL in enumerator
            where fileURL.pathExtension == "swift"
                && !fileURL.path.contains("/PomoGem/Debug/") {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                scannedFileCount += 1
                for literal in SwiftStringLiteralScanner.literals(in: source) {
                    for (old, new) in retired where literal.text.contains(old) {
                        findings.append(
                            "\(fileURL.lastPathComponent):\(literal.line) 「\(old)」 → 「\(new)」"
                        )
                    }
                }
            }
        }

        XCTAssertGreaterThan(scannedFileCount, 100)
        XCTAssertEqual(findings, [], "Use the one app-wide noun")
    }

    /// The per-body VoiceOver text in PebbleNode, the lint's last exemption,
    /// speaks the final nouns: 粒, 結晶, 記念石 and 勉強アプリの粒.
    func testJarBodiesSpeakTheFinalNouns() {
        func gem(_ source: SessionSource) -> PebbleDescriptor {
            PebbleDescriptor(subjectName: "英語", colorHex: Constants.Color.english, source: source, kind: .normal, grams: 250)
        }
        XCTAssertEqual(gem(.timer).accessibilityDescription, "英語、実測の粒、250グラム")
        XCTAssertEqual(gem(.manual).accessibilityDescription, "英語、自己申告の粒、250グラム")
        XCTAssertEqual(gem(.screenTime).accessibilityDescription, "英語、勉強アプリの粒、250グラム")

        let stone = PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )
        XCTAssertEqual(stone.accessibilityDescription, "英語、試験合格の記念石、質量には含まれません")

        func crystal(level: Int, pebbles: Int, children: Int, manual: Int) -> AggregateMetadata {
            AggregateMetadata(
                level: level,
                pebbleCount: pebbles,
                childAggregateCount: children,
                colorMix: [StratumColorFraction(hex: Constants.Color.english, fraction: 1)],
                subjectMix: [
                    AggregateSubjectFraction(name: "英語", colorHex: Constants.Color.english, pebbleCount: pebbles - 4),
                    AggregateSubjectFraction(name: "数学", colorHex: Constants.Color.mathematics, pebbleCount: 4)
                ],
                periodStart: Date(timeIntervalSince1970: 100),
                periodEnd: Date(timeIntervalSince1970: 200),
                sessionIDs: [],
                measuredPebbleCount: pebbles - manual,
                manualPebbleCount: manual,
                goldPebbleCount: 1,
                prismPebbleCount: 2
            )
        }
        XCTAssertEqual(
            crystal(level: 1, pebbles: 10, children: 0, manual: 0).accessibilityDescription(presentsRareRewards: false),
            "英語など、10粒を含む結晶、実測10粒"
        )
        XCTAssertEqual(
            crystal(level: 2, pebbles: 100, children: 10, manual: 3).accessibilityDescription(presentsRareRewards: false),
            "英語など、100粒、10個の結晶を含む結晶、実測97粒、自己申告3粒"
        )
        let ten = crystal(level: 1, pebbles: 10, children: 0, manual: 0)
        let descriptor = PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: ten,
            grams: 2_500
        )
        XCTAssertEqual(
            descriptor.accessibilityDescription,
            RareRewardReleasePolicy.isEnabled
                ? "英語など、10粒を含む結晶、実測10粒、金1粒、虹2粒、2,500グラム"
                : "英語など、10粒を含む結晶、実測10粒、2,500グラム"
        )
    }

    // MARK: HUD (walk-std-09)

    // The time core's single label block and where it hangs under the stone
    // are #47's (`JarLifetimeCoreLayout`, pinned in GemBrillianceTests).

    func testCycleChipStaysAboveTheHUDAtEveryStageHeight() {
        // Home's stage runs from 300 pt (accessibility sizes, home-03) to
        // 520 pt, taller than the 420 pt bottle. The chip is about 22 pt
        // tall; its lower edge must clear 「積み上げた集中」 at the HUD's top.
        for stageHeight in stride(from: CGFloat(300), through: 560, by: 4) {
            let chipCenter = JarAccumulationPresenceLayoutPresentation.cycleChipCenterY(
                stageHeight: stageHeight,
                showsLifetimeCore: true
            )
            XCTAssertLessThanOrEqual(
                chipCenter + 11 + 8,
                HomeView.jarMetricHUDTopInset(stageHeight: stageHeight),
                "stage \(stageHeight)"
            )
            XCTAssertGreaterThan(chipCenter, 11, "stage \(stageHeight)")
        }
    }

    // MARK: dev-D7

    func testTheJarReadoutCountsAGemWhenItLands() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        func session(minutesAgo: Double) -> StudySession {
            StudySession(
                startAt: end.addingTimeInterval(-minutesAgo * 60 - 1_500),
                endAt: end.addingTimeInterval(-minutesAgo * 60),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "landed-totals"
            )
        }
        let earlier = session(minutesAgo: 60)
        let justCompleted = session(minutesAgo: 0)
        let loose = [justCompleted, earlier]

        XCTAssertEqual(
            HomeProjectionPolicy.landedTotals(
                roots: [],
                looseSessions: loose,
                unlandedSessionIDs: [justCompleted.id]
            ),
            HomeProjectionPolicy.Totals(grams: 250, pebbleCount: 1),
            "Behind the completion card, the jar still reads what it holds"
        )
        XCTAssertEqual(
            HomeProjectionPolicy.landedTotals(
                roots: [],
                looseSessions: loose,
                unlandedSessionIDs: []
            ),
            HomeProjectionPolicy.totals(roots: [], looseSessions: loose),
            "Once it lands, the readout is the full total again"
        )
        XCTAssertEqual(
            HomeProjectionPolicy.landedTotals(
                roots: [],
                looseSessions: loose,
                unlandedSessionIDs: [UUID()]
            ),
            HomeProjectionPolicy.totals(roots: [], looseSessions: loose),
            "A receipt whose session is not a loose gem changes nothing"
        )
    }

    /// Not only timer completions: a queued Screen Time gem and a manual gem
    /// that is still falling join the readout when they land too.
    func testEveryGemThatHasNotLandedIsLeftOutOfTheReadout() {
        func receipt(_ id: UUID, phase: PendingRewardDropPhase?) -> PendingRewardReceipt {
            PendingRewardReceipt(
                id: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                breakMinutes: 5, grams: 250, subjectName: "英語", colorHex: "#3FA57C",
                weeklyCompletionCount: 1, kind: .normal, totalPebbleCount: 1,
                projectionIsLowerBound: false, dropPhase: phase
            )
        }
        let behindCard = UUID()
        let falling = UUID()
        let cardOnly = UUID()
        let marker = UUID()
        let screenTime = UUID()
        let manual = UUID()

        XCTAssertEqual(
            HomeProjectionPolicy.unlandedSessionIDs(
                rewardReceipts: [
                    receipt(behindCard, phase: .awaitingAcknowledgement),
                    receipt(falling, phase: .awaitingLanding),
                    receipt(cardOnly, phase: nil)
                ],
                completionMarker: marker.uuidString,
                screenTimeDrops: [screenTime],
                fallingManualEntries: [manual]
            ),
            [behindCard, falling, marker, screenTime, manual],
            "A receipt kept only for its card has already landed"
        )
        XCTAssertEqual(
            HomeProjectionPolicy.unlandedSessionIDs(
                rewardReceipts: [],
                completionMarker: "not-a-uuid",
                screenTimeDrops: [],
                fallingManualEntries: []
            ),
            []
        )
    }

    // MARK: history-02

    func testManualEntryWaitsLongerForAssistiveTechnology() {
        XCTAssertEqual(
            ManualEntryUndoPolicy.window(assistiveTechnologyIsRunning: false),
            .seconds(5)
        )
        XCTAssertEqual(
            ManualEntryUndoPolicy.window(assistiveTechnologyIsRunning: true),
            .seconds(15)
        )
    }

    /// Home also commits from `onDisappear`, which an account change runs
    /// after closing the account boundary. A pending entry is written only
    /// into the account it was confirmed under.
    func testPendingManualEntryIsNeverWrittenAcrossTheAccountBoundary() throws {
        let suiteName = "RewardVocabularyAndHUDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fingerprint = String(repeating: "a", count: 64)
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(), accountFingerprint: fingerprint
        ))
        let other = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(), accountFingerprint: fingerprint
        ))

        // Local mode without a cloud boundary: nothing to cross.
        AccountScopedLocalState.useUnscopedLocalMode(standardDefaults: defaults)
        let local = ManualEntryAccountScope.current(defaults: defaults)
        XCTAssertFalse(local.boundaryIsClosed)
        XCTAssertTrue(ManualEntryUndoPolicy.mayCommit(confirmedUnder: local, now: local))

        try AccountScopedLocalState.activate(binding, standardDefaults: defaults)
        let confirmed = ManualEntryAccountScope.current(defaults: defaults)
        XCTAssertEqual(confirmed.binding, binding)
        XCTAssertTrue(ManualEntryUndoPolicy.mayCommit(
            confirmedUnder: confirmed,
            now: .current(defaults: defaults)
        ), "Same account, boundary open: saved as before")
        XCTAssertFalse(ManualEntryUndoPolicy.mayCommit(confirmedUnder: local, now: confirmed),
                       "Confirmed in local mode, the store is now an account's")

        // CKAccountChanged: the boundary closes before Home is torn down.
        AccountScopedLocalState.beginCloudBoundary(standardDefaults: defaults)
        let closed = ManualEntryAccountScope.current(defaults: defaults)
        XCTAssertTrue(closed.boundaryIsClosed)
        XCTAssertFalse(ManualEntryUndoPolicy.mayCommit(confirmedUnder: confirmed, now: closed))
        XCTAssertFalse(ManualEntryUndoPolicy.mayCommit(confirmedUnder: closed, now: closed),
                       "Nothing is written while no account is mounted")

        // Another account mounted in between.
        try AccountScopedLocalState.activate(other, standardDefaults: defaults)
        XCTAssertFalse(ManualEntryUndoPolicy.mayCommit(
            confirmedUnder: confirmed,
            now: .current(defaults: defaults)
        ))

        // A local-only namespace is an account scope too.
        let namespace = AccountDataNamespace()
        AccountScopedLocalState.activateLocalOnly(namespace: namespace, standardDefaults: defaults)
        let localOnly = ManualEntryAccountScope.current(defaults: defaults)
        XCTAssertEqual(localOnly.namespace, namespace)
        XCTAssertFalse(localOnly.boundaryIsClosed)
        XCTAssertTrue(ManualEntryUndoPolicy.mayCommit(confirmedUnder: localOnly, now: localOnly))
    }
}
