import CoreGraphics
import SwiftData
import SwiftUI
import XCTest
@testable import PomoGem

/// Tests the public artifacts after selection, rather than only the row
/// filter. Personal Screen Time changes must not alter the image or caption
/// supplied to sharing, Photos, or the animated-card renderer.
@MainActor
final class SharePrivacyBoundaryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    func testResolvedHistoryAndAggregateLoadersKeepConflictingPrivateCopiesOut() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let timers = (0..<8).map { number in
            session(number: 300 + number, seconds: 1_500, source: .timer,
                    color: "#327AB8", endingAt: date.addingTimeInterval(Double(number) * 1_800))
        }
        let privateRows = [
            session(number: 100, seconds: 600, source: .screenTime,
                    color: "#FF00F3", endingAt: date, grams: 100),
            // Exact logical-ID checks must also see a copy outside the month.
            session(number: 101, seconds: 600, source: .screenTime,
                    color: "#F903BA", endingAt: date.addingTimeInterval(60 * 86_400), grams: 100)
        ]
        let publicLookingCopies = [
            session(number: 200, seconds: 1_800, source: .manual,
                    color: "#FF00F3", endingAt: date.addingTimeInterval(900)),
            session(number: 201, seconds: 1_500, source: .timerDemoted,
                    color: "#F903BA", endingAt: date.addingTimeInterval(1_800))
        ]
        for index in privateRows.indices { publicLookingCopies[index].id = privateRows[index].id }
        for row in timers + privateRows + publicLookingCopies { context.insert(row) }
        let root = AggregatePebble(
            id: id(500), createdAt: date.addingTimeInterval(60 * 86_400),
            level: 1, pebbleCount: 10, grams: 99_999,
            measuredPebbleCount: 8, manualPebbleCount: 2,
            colorMixJSON: "[{\"hex\":\"#FF00F3\",\"fraction\":1}]",
            periodStart: date, periodEnd: date.addingTimeInterval(60 * 86_400),
            sessionIDs: (timers + privateRows).map(\.id)
        )
        context.insert(root)
        try context.save()
        let interval = try XCTUnwrap(PomoGemCalendar.gregorian.dateInterval(of: .month, for: date))
        let expectedIDs = Set(timers.map(\.id))
        let privateIDs = Set(privateRows.map(\.id))
        let scopes: [ShareScope] = [.all, .month(date), .aggregate(id: root.id, monthLabel: "2099年12月")]

        for scope in scopes {
            let resolved: [StudySession]
            switch scope {
            case .all:
                resolved = try BoundedHistoryPolicy.resolvedSessionPage(
                    context: context, epochID: nil, logicalLimit: 64
                ).sessions
            case .month:
                resolved = try BoundedHistoryPolicy.resolvedSessionPage(
                    context: context, epochID: nil, start: interval.start, end: interval.end,
                    logicalLimit: 64
                ).sessions
            case .aggregate:
                resolved = try root.sessionIDs.compactMap {
                    try BoundedHistoryPolicy.resolvedSession(id: $0, epochID: nil, context: context)
                }
            }
            XCTAssertEqual(resolved.count, 10)
            XCTAssertEqual(
                Set(resolved.filter { privateIDs.contains($0.id) }.map(\.effectiveSource)),
                Set([.manual, .timerDemoted]),
                "Personal canonicalization must remain unchanged in \(scope)"
            )
            let publicCandidates = try ExternalShareSessionLoader.publicCandidates(
                from: resolved, context: context, epochID: nil
            )
            XCTAssertEqual(Set(publicCandidates.map(\.id)), expectedIDs, "\(scope)")
            for includeManual in [false, true] {
                let shared = ShareSelectionModel.make(input(
                    sessions: publicCandidates, aggregates: [root],
                    includeManual: includeManual, scope: scope
                ))
                let reference = ShareSelectionModel.make(input(sessions: timers, includeManual: includeManual))
                XCTAssertEqual(Set(shared.sessions.map(\.id)), expectedIDs)
                XCTAssertEqual(shared.totalGrams, 2_000)
                XCTAssertTrue(shared.aggregates.isEmpty, "Eight public rows must remain loose")
                XCTAssertEqual(caption(shared), caption(reference))
                XCTAssertTrue(
                    try raster(shared, format: .feed, animated: false)
                        == raster(reference, format: .feed, animated: false),
                    "The \(scope) route must render the same public bottle"
                )
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), 12)
        XCTAssertEqual(root.grams, 99_999)
        XCTAssertEqual(Set(privateRows.map(\.effectiveSource)), [.screenTime])
    }

    func testPublicLoaderUsesTheRequestedEpochWithoutSuppressingItsValidRecords() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epoch = id(700)
        let currentTimer = session(number: 600, seconds: 1_500, source: .timer,
                                   color: "#327AB8", endingAt: date)
        currentTimer.dataEpochID = epoch
        let oldPrivate = session(number: 601, seconds: 600, source: .screenTime,
                                 color: "#FF00F3", endingAt: date, grams: 100)
        oldPrivate.id = currentTimer.id
        context.insert(currentTimer)
        context.insert(oldPrivate)
        try context.save()

        let current = try XCTUnwrap(BoundedHistoryPolicy.resolvedSession(
            id: currentTimer.id, epochID: epoch, context: context
        ))
        let legacy = try XCTUnwrap(BoundedHistoryPolicy.resolvedSession(
            id: oldPrivate.id, epochID: nil, context: context
        ))
        XCTAssertEqual(try ExternalShareSessionLoader.publicCandidates(
            from: [current], context: context, epochID: epoch
        ).map(\.id), [currentTimer.id])
        XCTAssertTrue(try ExternalShareSessionLoader.publicCandidates(
            from: [legacy], context: context, epochID: nil
        ).isEmpty)
        XCTAssertTrue(try ExternalShareSessionLoader.publicCandidates(
            from: [current], context: context, epochID: nil
        ).isEmpty, "A candidate from another generation cannot cross the boundary")
    }

    func testPublicLoaderRejectsUnstoredCandidatesAndOversizedReplicaSets() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let candidate = session(number: 800, seconds: 1_500, source: .timer,
                                color: "#327AB8", endingAt: date)
        XCTAssertTrue(try ExternalShareSessionLoader.publicCandidates(
            from: [candidate], context: context, epochID: nil
        ).isEmpty, "An unstored candidate has no proven record origin")
        let maximumCopies = BoundedHistoryPolicy.maximumPhysicalRowsPerLogicalSession
        for number in 0..<maximumCopies {
            let copy = session(number: 900 + number, seconds: 1_500, source: .timer,
                               color: "#327AB8", endingAt: date)
            copy.id = candidate.id
            context.insert(copy)
        }
        try context.save()
        let resolved = try XCTUnwrap(BoundedHistoryPolicy.resolvedSession(
            id: candidate.id, epochID: nil, context: context
        ))
        XCTAssertEqual(try ExternalShareSessionLoader.publicCandidates(
            from: [resolved], context: context, epochID: nil
        ).map(\.id), [candidate.id])

        let extra = session(number: 1_300, seconds: 1_500, source: .timer,
                            color: "#327AB8", endingAt: date)
        extra.id = candidate.id
        context.insert(extra)
        try context.save()
        XCTAssertThrowsError(try ExternalShareSessionLoader.publicCandidates(
            from: [resolved], context: context, epochID: nil
        )) { error in
            XCTAssertEqual(error as? BoundedHistoryPolicy.SessionResolutionError, .logicalReplicaLimitExceeded)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), maximumCopies + 1)
    }

    func testExternalSnapshotRequestsRejectPersonalJarAndMotionBeforeCapture() throws {
        let jar = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        jar.soundEnabled = false
        jar.hapticsEnabled = false
        jar.bakesGemBedInBackground = false
        jar.restore(pebbles: [PebbleDescriptor(session: session(
            number: 60, seconds: 600, source: .screenTime,
            color: "#FF00F3", endingAt: date, grams: 100
        ))])

        for includeManual in [false, true] {
            let options = JarSnapshotOptions.share(includesSelfReported: includeManual)
            XCTAssertTrue(options.isExternalShare)
            XCTAssertThrowsError(try JarSnapshotter.shared.image(of: jar, options: options)) { error in
                guard case JarSnapshotError.personalDataCannotBeShared = error else {
                    return XCTFail("The external snapshot must fail at the privacy boundary: \(error)")
                }
            }
            XCTAssertThrowsError(try JarSnapshotter.shared.pngData(of: jar, options: options)) { error in
                guard case JarSnapshotError.personalDataCannotBeShared = error else {
                    return XCTFail("PNG must use the same privacy boundary: \(error)")
                }
            }
            XCTAssertNil(JarSnapshotter.shared.shareMotion(of: jar, options: options))
        }

        XCTAssertFalse(JarSnapshotOptions.widget.isExternalShare)
        XCTAssertThrowsError(try JarSnapshotter.shared.image(of: jar, options: .widget)) { error in
            guard case JarSnapshotError.sceneNotPresented = error else {
                return XCTFail("The private/internal capture should reach its normal presentation check: \(error)")
            }
        }
    }

    func testPrivateScreenTimeRowsDoNotChangePublicImagesOrCaption() throws {
        let timer = session(number: 1, seconds: 1_500, source: .timer,
                            color: "#327AB8", endingAt: date)
        let manual = session(number: 2, seconds: 1_800, source: .manual,
                             color: "#28A475", endingAt: date.addingTimeInterval(3_600))
        let privateRows = [
            session(number: 3, seconds: 600, source: .screenTime,
                    color: "#FF00F3", endingAt: date.addingTimeInterval(-86_400), grams: 100),
            // The shipped compatibility encoding must remain private too.
            session(number: 4, seconds: 600, source: .manual,
                    color: "#F903BA", endingAt: date.addingTimeInterval(86_400), grams: 100)
        ]
        XCTAssertTrue(privateRows.allSatisfy { $0.effectiveSource == .screenTime })
        let stone = AchievementStone(
            id: id(10), kind: .examPass, note: "A personal achievement note",
            achievedAt: date, subjectNameSnapshot: "User-entered milestone",
            subjectColorHexSnapshot: "#A163CE"
        )

        for includeManual in [false, true] {
            let reference = ShareSelectionModel.make(input(
                sessions: [timer, manual], achievements: [stone], includeManual: includeManual
            ))
            let withPrivate = ShareSelectionModel.make(input(
                sessions: [timer, manual] + privateRows, achievements: [stone],
                includeManual: includeManual
            ))
            XCTAssertEqual(withPrivate.totalGrams, includeManual ? 550 : 250)
            XCTAssertEqual(caption(withPrivate), caption(reference))
            XCTAssertEqual(withPrivate.achievements, reference.achievements)
            try assertSameRenderedOutput(reference, withPrivate)

            // A public completion is a positive control: comparisons must
            // detect genuine changes in both the claim and drawn bottle.
            let additionalTimer = session(number: 5, seconds: 2_700, source: .timer,
                                          color: "#EA9845", endingAt: date.addingTimeInterval(7_200))
            let withPublic = ShareSelectionModel.make(input(
                sessions: [timer, manual, additionalTimer], achievements: [stone],
                includeManual: includeManual
            ))
            XCTAssertNotEqual(caption(withPublic), caption(reference))
            let original = try raster(reference, format: .feed, animated: false)
            let changed = try raster(withPublic, format: .feed, animated: false)
            XCTAssertFalse(original == changed, "A new public gem must change the public image")
        }

        XCTAssertEqual(privateRows.map(\.grams), [100, 100], "Sharing must not mutate personal records")
        XCTAssertEqual(stone.note, "A personal achievement note")
    }

    func testMixedAggregateSummaryCannotChangePublicArtworkOrCaption() throws {
        let publicRows = (0..<10).map { number in
            session(number: 20 + number, seconds: 1_500, source: .timer,
                    color: number.isMultiple(of: 2) ? "#327AB8" : "#28A475",
                    endingAt: date.addingTimeInterval(Double(number) * 1_800))
        }
        let privateRows = [
            session(number: 40, seconds: 600, source: .screenTime,
                    color: "#FF00F3", endingAt: date.addingTimeInterval(86_400), grams: 100),
            session(number: 41, seconds: 600, source: .manual,
                    color: "#F903BA", endingAt: date.addingTimeInterval(-86_400), grams: 100)
        ]
        let aggregateID = id(50)
        let publicProjection = try XCTUnwrap(ShareAggregateVisual(
            externallySharing: aggregateID, members: publicRows
        ))
        let referenceRoot = AggregatePebble(
            id: aggregateID, createdAt: publicProjection.createdAt,
            level: publicProjection.level, pebbleCount: publicProjection.pebbleCount,
            grams: publicProjection.grams, measuredPebbleCount: publicProjection.measuredPebbleCount,
            colorMixJSON: StrataMath.encodeColorMix(publicProjection.colorMix),
            subjectMixJSON: StrataMath.encodeSubjectMix(publicProjection.subjectMix),
            periodStart: publicRows.first!.startAt, periodEnd: publicRows.last!.endAt,
            sessionIDs: publicRows.map(\.id)
        )
        // None of these original summary values may fall back into external
        // output when some members are private or have not been loaded.
        let personalRoot = AggregatePebble(
            id: aggregateID, createdAt: date.addingTimeInterval(86_400),
            level: 8, pebbleCount: 999, grams: 99_999,
            measuredPebbleCount: 999, goldPebbleCount: 99, prismPebbleCount: 99,
            colorMixJSON: "[{\"hex\":\"#FF00F3\",\"fraction\":1}]",
            subjectMixJSON: "[{\"name\":\"Private Screen Time theme\",\"colorHex\":\"#FF00F3\",\"pebbleCount\":999}]",
            periodStart: date.addingTimeInterval(-86_400), periodEnd: date.addingTimeInterval(86_400),
            sessionIDs: (publicRows + privateRows).map(\.id) + [id(42)]
        )

        for includeManual in [false, true] {
            let reference = ShareSelectionModel.make(input(
                sessions: publicRows, aggregates: [referenceRoot], includeManual: includeManual
            ))
            let withPrivate = ShareSelectionModel.make(input(
                sessions: publicRows + privateRows, aggregates: [personalRoot],
                includeManual: includeManual
            ))
            XCTAssertEqual(withPrivate.totalGrams, 2_500)
            XCTAssertEqual(withPrivate.aggregates, reference.aggregates)
            XCTAssertEqual(caption(withPrivate), caption(reference))
            try assertSameRenderedOutput(reference, withPrivate)
        }
        XCTAssertEqual(personalRoot.grams, 99_999, "Public projection must leave the personal summary intact")
    }

    private func assertSameRenderedOutput(
        _ reference: ShareSelectionModel,
        _ withPrivate: ShareSelectionModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for format in ShareComposerView.Format.allCases {
            for animated in [false, true] {
                let original = try raster(reference, format: format, animated: animated)
                let changed = try raster(withPrivate, format: format, animated: animated)
                XCTAssertTrue(
                    original == changed,
                    "Private records changed \(format) output (animated=\(animated))",
                    file: file, line: line
                )
            }
        }
    }

    private func raster(
        _ selection: ShareSelectionModel,
        format: ShareComposerView.Format,
        animated: Bool
    ) throws -> Data {
        let size = ShareCardLayoutPolicy.canvasSize(for: format)
        let card = ShareCardView(
            sessions: selection.sessions, aggregates: selection.aggregates,
            achievements: selection.achievements,
            includesSelfReportedFocus: selection.includesSelfReportedFocus,
            format: format, jarSnapshot: nil, periodLabel: "Public focus",
            hashtags: [], usesAnimatedArtwork: animated, animationPhase: 0.25
        )
        .frame(width: size.width, height: size.height)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, .dark)
        .environment(\.displayScale, 1)
        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data)
        return Data(bytes: bytes, count: context.bytesPerRow * context.height)
    }

    private func caption(_ selection: ShareSelectionModel) -> String {
        ShareCopy.caption(
            subject: "Public focus", grams: ShareMassFormatter.visual(selection.totalGrams),
            focusTime: ShareMassFormatter.focusTime(selection.totalGrams),
            includesSelfReportedFocus: selection.includesSelfReportedFocus,
            achievementCount: selection.achievements.count, hashtags: []
        )
    }

    private func input(
        sessions: [StudySession],
        achievements: [AchievementStone] = [],
        aggregates: [AggregatePebble] = [],
        includeManual: Bool,
        scope: ShareScope = .all
    ) -> ShareSelectionInput {
        ShareSelectionInput(
            scope: scope, includeManual: includeManual, resetSnapshots: [],
            allowsAggregateSummaries: true, acceptsVerifiedAggregateCache: true,
            storedSessions: sessions, looseSessions: sessions,
            storedAchievementStones: achievements, storedAggregatePebbles: aggregates,
            storedStrata: [], acceptedAggregateRootIDs: Set(aggregates.map(\.id)),
            localRepresentedSessionIDs: [], historyPageIsPartial: false,
            loosePageIsPartial: false, aggregatePageIsPartial: false,
            aggregateValidationIsIncomplete: false, allSessionRowCount: sessions.count
        )
    }

    private func session(
        number: Int,
        seconds: Int,
        source: SessionSource,
        color: String,
        endingAt end: Date,
        grams: Int? = nil
    ) -> StudySession {
        let start = end.addingTimeInterval(-Double(seconds))
        return StudySession(
            id: id(number), startAt: start, endAt: end, seconds: seconds,
            source: source, grams: grams, deviceDayKey: FairnessPolicy.deviceDayKey(for: start),
            subjectNameSnapshot: source == .timer ? "Public timer" : "Personal record",
            subjectColorHexSnapshot: color, syncRecordID: id(number + 100)
        )
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "A0000000-0000-0000-0000-%012d", number))!
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Subject.self, StudySession.self, AchievementStone.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "SharePrivacyBoundaryTests-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }
}
