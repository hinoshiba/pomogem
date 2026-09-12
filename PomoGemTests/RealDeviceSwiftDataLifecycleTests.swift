import CloudKit
import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import PomoGem

/// Hosted integration evidence, not a UI journey. Run one phase per host process:
/// POMOGEM_REAL_SWIFTDATA_LIFECYCLE=1
/// POMOGEM_SWIFTDATA_PHASE=seed | seed-reset-history | observe | restore
/// POMOGEM_AUDIT_PREFIX=PomoGemAudit-20260912A (reuse across the round trip)
/// POMOGEM_AUDIT_TIMEOUT_SECONDS=240 (30...600)
/// POMOGEM_SWIFTDATA_EXPORT_HOLD_SECONDS=120 (seed phases only, 0...120)
///
/// Independently verify the signed Release host uses CloudKit Production. Keep
/// the ordinary app at its initial storage chooser, then terminate the host
/// after each phase. Seed writes real records and holds the container for export;
/// separately run RealDeviceCloudEvidenceTests.uploaded before uninstalling.
/// Restore requires an absent audit directory, created only by a full uninstall
/// or an operator action outside this test. Retain independent uninstall evidence.
/// Restore/observe never seed rows, run bootstrap, or complete onboarding.
/// seed-reset-history uses the lower-level shipping reset writer to manufacture
/// old-version history in an independently verified empty account. This audit
/// setup deliberately bypasses user-reset admission; it does NOT demonstrate
/// that the shipping iCloud reset button is available. Confirm the uploaded
/// marker fingerprints with the independent server evidence test, then uninstall
/// and use the ordinary UI restore phase to exercise the shipping history gate.
/// observe recognizes this dataset through its local manifest; hosted restore
/// continues to expect the ordinary seed dataset without reset markers.
@MainActor
final class RealDeviceSwiftDataLifecycleTests: XCTestCase {
    private enum Phase: String {
        case seed, observe, restore
        case seedResetHistory = "seed-reset-history"

        var createsSeed: Bool { self == .seed || self == .seedResetHistory }
    }
    private enum Failure: String, Error {
        case invalidConfiguration, normalStoreAlreadySelected, containerAlreadyOpened
        case existingAuditDirectory, missingAuditStore, wrongManifest, accountChanged
        case unexpectedServerZones, deadline, unexpectedLocalData
        case duplicateAuditRows, incompleteLocalEvidence
    }

    // SwiftData may retain its mirroring container after test-local references
    // disappear. Never construct a second container in the same host process.
    private static var hasOpenedContainer = false

    func testShippingSwiftDataCloudRoundTrip() async throws {
        #if targetEnvironment(simulator) || DEBUG
        throw XCTSkip("This integration test requires a signed Release host on a physical iPhone")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_SWIFTDATA_LIFECYCLE"] == "1" else {
            throw XCTSkip("Real SwiftData/CloudKit integration is explicitly opt-in")
        }
        executionTimeAllowance = 720
        let prefix = environment["POMOGEM_AUDIT_PREFIX"] ?? "PomoGemAudit-20260912A"
        guard let phase = Phase(rawValue: environment["POMOGEM_SWIFTDATA_PHASE"] ?? ""),
              prefix.hasPrefix("PomoGemAudit-"),
              prefix.range(of: "^[A-Za-z0-9_-]{16,40}$", options: .regularExpression) != nil,
              SubjectNamePolicy.validated(prefix) == prefix,
              !environment.keys.contains(where: {
                  $0.hasPrefix("POMOGEM_UI_TEST") || $0 == "POMOGEM_LOCAL_PREVIEW"
                      || $0 == "XCODE_RUNNING_FOR_PREVIEWS"
              }) else { throw Failure.invalidConfiguration }
        let timeout = Double(environment["POMOGEM_AUDIT_TIMEOUT_SECONDS"] ?? "240") ?? .nan
        let exportHold = Double(environment["POMOGEM_SWIFTDATA_EXPORT_HOLD_SECONDS"] ?? "120") ?? .nan
        guard timeout.isFinite, (30 ... 600).contains(timeout),
              exportHold.isFinite, (0 ... 120).contains(exportHold) else {
            throw Failure.invalidConfiguration
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var report = Report(phase: phase.rawValue, prefixFingerprint: Self.hash(prefix))
        var stage = "initialAccount"
        do {
            try requireInitialChooser()
            let identity = try await verifiedAccount(deadline: deadline)
            let accountFingerprint = Self.hash([
                CloudSyncConfiguration.synchronizedDataContainerIdentifier,
                identity.zoneID.ownerName, identity.zoneID.zoneName, identity.recordName
            ].joined(separator: "\u{0}"))
            stage = "auditDirectory"
            let plan = try prepareDirectory(phase: phase, prefix: prefix, accountFingerprint: accountFingerprint)
            let resetHistory = plan.manifest.origin == Phase.seedResetHistory.rawValue
            report.openedFreshDirectory = plan.createdFresh
            report.auditInstallationFingerprint = Self.hash(plan.manifest.installationID.uuidString)
            report.modelsHistoricalResetEpochs = resetHistory
            report.expectedResetSequences = resetHistory ? [0, 1, 2] : []
            report.expectedCurrentEpochFingerprint = Self.resetEpoch(prefix, history: resetHistory).map { Self.hash($0.uuidString) }

            // Seed is deliberately restricted to a previously empty source
            // account. Do not infer emptiness from an unhydrated local replica.
            if phase.createsSeed {
                stage = "emptyServerZones"
                try await requireNoCustomZones(deadline: deadline)
            }
            try requireInitialChooser()
            guard !Self.hasOpenedContainer else { throw Failure.containerAlreadyOpened }
            Self.hasOpenedContainer = true
            stage = "mountShippingTopology"
            let container = try ModelContainer(
                for: PersistenceStoreTopology.shippingSchema,
                configurations: [
                    ModelConfiguration(
                        PersistenceStoreTopology.cloudStoreName,
                        schema: PersistenceStoreTopology.cloudSchema,
                        url: plan.sourceURL,
                        cloudKitDatabase: .private(CloudSyncConfiguration.synchronizedDataContainerIdentifier)
                    ),
                    ModelConfiguration(
                        PersistenceStoreTopology.localProjectionStoreName,
                        schema: PersistenceStoreTopology.localProjectionSchema,
                        url: plan.projectionURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            defer { withExtendedLifetime(container) {} }
            guard try await verifiedAccount(deadline: deadline) == identity else { throw Failure.accountChanged }
            try requireInitialChooser()

            if phase.createsSeed {
                stage = "seedRealModels"
                try seed(container: container, prefix: prefix, resetHistory: resetHistory)
                report.createdSourceRows = resetHistory ? 6 : 3
                report.local = try snapshot(container: container, prefix: prefix, resetHistory: resetHistory)
                guard report.local?.matchesExpectedData == true else { throw Failure.incompleteLocalEvidence }
                stage = "allowFrameworkExport"
                let holdDeadline = min(deadline, clock.now.advanced(by: .seconds(exportHold)))
                let holdStart = clock.now
                while clock.now < holdDeadline {
                    try Task.checkCancellation()
                    try requireInitialChooser()
                    try await Task.sleep(for: .seconds(1))
                }
                report.exportHoldSeconds = Int(holdStart.duration(to: clock.now).components.seconds)
                // This delay is not an upload acknowledgment. The independent
                // server evidence runner must confirm before app removal.
                report.requiresIndependentUploadEvidence = true
            } else {
                stage = "waitForSwiftDataImport"
                repeat {
                    try Task.checkCancellation()
                    try requireInitialChooser()
                    report.local = try snapshot(container: container, prefix: prefix, resetHistory: resetHistory)
                    report.localReadAttempts += 1
                    if report.local?.matchesExpectedData == true { break }
                    guard clock.now < deadline else { throw Failure.deadline }
                    try await Task.sleep(for: .seconds(1))
                } while true
                report.importObservedInFreshStore = phase == .restore && plan.createdFresh
            }
            stage = "finalAccount"
            guard try await verifiedAccount(deadline: deadline) == identity else { throw Failure.accountChanged }
            try Task.checkCancellation()
            try requireInitialChooser()
            report.accountStable = true
            report.succeeded = true
            try publish(report)
        } catch {
            report.failureStage = stage
            report.failureKind = (error as? Failure)?.rawValue
                ?? (error is CancellationError ? "cancelled" : "frameworkError")
            let nsError = error as NSError
            if [CKErrorDomain, NSCocoaErrorDomain, NSURLErrorDomain].contains(nsError.domain) {
                report.frameworkErrorCode = nsError.code
            }
            try publish(report)
            XCTFail("Real SwiftData lifecycle evidence failed; see sanitized JSON attachment")
        }
        #endif
    }

    private func requireInitialChooser() throws {
        guard PersistenceDeploymentState.load() == .unselected,
              PersistenceDeploymentState.loadMountState() == .unrecorded,
              AccountScopedLocalState.activeNamespace() == nil else {
            throw Failure.normalStoreAlreadySelected
        }
    }

    private func remaining(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
        let duration = ContinuousClock().now.duration(to: deadline).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard seconds > 0 else { throw Failure.deadline }
        return seconds
    }

    private func verifiedAccount(deadline: ContinuousClock.Instant) async throws -> CKRecord.ID {
        try Task.checkCancellation()
        return try await CloudAccountIdentityVerifier.verify(
            using: .live(containerIdentifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier),
            timeout: min(45, remaining(until: deadline)),
            retryDelay: 0.5
        )
    }

    private func requireNoCustomZones(deadline: ContinuousClock.Instant) async throws {
        let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        let timeout = min(30, try remaining(until: deadline))
        operation.configuration.timeoutIntervalForRequest = min(15, timeout)
        operation.configuration.timeoutIntervalForResource = timeout
        let result = ZoneResult()
        operation.perRecordZoneResultBlock = { _, value in result.receive(value) }
        operation.fetchRecordZonesResultBlock = { value in result.finish(value) }
        defer { operation.cancel() }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            result.finish(.failure(Failure.deadline))
            operation.cancel()
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier)
                    .privateCloudDatabase.add(operation)
            }
        } onCancel: {
            result.finish(.failure(CancellationError()))
            operation.cancel()
        }
        try Task.checkCancellation()
        guard result.permitsSeed else { throw Failure.unexpectedServerZones }
    }

    private struct Manifest: Codable {
        let version: Int
        let prefix: String
        let accountFingerprint: String
        let installationID: UUID
        let origin: String
    }
    private struct DirectoryPlan {
        let manifest: Manifest
        let sourceURL: URL
        let projectionURL: URL
        let createdFresh: Bool
    }

    private func prepareDirectory(phase: Phase, prefix: String, accountFingerprint: String) throws -> DirectoryPlan {
        let files = FileManager.default
        let documents = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("RealDeviceSwiftDataAudit", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
        let source = directory.appendingPathComponent("source.store")
        let projection = directory.appendingPathComponent("projection.store")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let exists = files.fileExists(atPath: directory.path)
        let manifest: Manifest
        if phase == .observe {
            guard exists, files.fileExists(atPath: source.path), files.fileExists(atPath: projection.path) else {
                throw Failure.missingAuditStore
            }
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.version == 1, manifest.prefix == prefix,
                  manifest.accountFingerprint == accountFingerprint else { throw Failure.wrongManifest }
        } else {
            guard !exists else { throw Failure.existingAuditDirectory }
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            manifest = Manifest(version: 1, prefix: prefix, accountFingerprint: accountFingerprint,
                                installationID: UUID(), origin: phase.rawValue)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtection])
        }
        return DirectoryPlan(manifest: manifest, sourceURL: source, projectionURL: projection, createdFresh: !exists)
    }

    private func seed(container: ModelContainer, prefix: String, resetHistory: Bool) throws {
        try requireInitialChooser()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard try context.fetchCount(FetchDescriptor<Subject>()) == 0,
              try context.fetchCount(FetchDescriptor<StudySession>()) == 0,
              try context.fetchCount(FetchDescriptor<Prefs>()) == 0,
              try context.fetchCount(FetchDescriptor<ActivityResetMarker>()) == 0 else {
            throw Failure.unexpectedLocalData
        }
        let now = Date.now
        let currentEpochID = Self.resetEpoch(prefix, history: resetHistory)
        if resetHistory {
            // The normal cloud reset is intentionally unavailable. This is
            // operator-only setup of legacy history using the shipping writer
            // and genuine SwiftData encoding, never direct CloudKit records.
            // All rows are committed together after the local invariants pass.
            for sequence in 0 ... 2 {
                let marker = try ActivityResetStore.beginReset(
                    context: context, deviceID: Self.writerID(prefix),
                    now: now.addingTimeInterval(Double(sequence - 2)),
                    epochID: Self.id(prefix, "reset-epoch-\(sequence)")
                )
                marker.id = Self.id(prefix, "reset-marker-\(sequence)")
                guard marker.sequence == sequence else {
                    context.rollback()
                    throw Failure.unexpectedLocalData
                }
            }
        }
        let duration = ManualDuration.thirtyMinutes
        let decision = FairnessPolicy.consumeManualEntry(state: ManualCounterState(dayKey: "", usedToday: 0), at: now)
        guard decision.isAllowed else { throw Failure.unexpectedLocalData }
        let subject = Subject(id: Self.id(prefix, "subject"), name: prefix,
                              colorHex: Constants.Color.english, sortOrder: 0)
        context.insert(subject)
        let writer = try PrefsSyncPolicy.mutate(
            .keepScreenAwake, context: context, writerID: Self.writerID(prefix), currentEpochID: currentEpochID
        ) { $0.keepScreenAwake = false }
        writer.manualDayKey = decision.state.dayKey
        writer.manualUsedToday = decision.state.usedToday
        context.insert(StudySession(
            id: Self.id(prefix, "session"), subject: subject,
            startAt: now.addingTimeInterval(-TimeInterval(duration.seconds)), endAt: now,
            seconds: duration.seconds, source: .manual, grams: duration.grams,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: now), dataEpochID: currentEpochID
        ))
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private struct LocalSnapshot: Encodable {
        let subjectCount: Int
        let sessionCount: Int
        let preferencesCount: Int
        let resetMarkerCount: Int
        let resetSequences: [Int]
        let resetMarkers: [ResetMarkerEvidence]
        let currentResetSequence: Int?
        let currentResetEpochFingerprint: String?
        let sessionEpochFingerprint: String?
        let preferencesEpochFingerprint: String?
        let resetHistoryMatchesExpected: Bool
        let sessionEpochMatchesExpected: Bool
        let preferencesEpochMatchesExpected: Bool
        let validManualSessions: Int
        let subjectIdentityMatches: Bool
        let sessionIdentityMatches: Bool
        let subjectRelationshipMatches: Bool
        let explicitKeepAwakeOff: Bool
        let onboardingRemainsIncomplete: Bool
        let contextHasChanges: Bool
        var matchesExpectedData: Bool {
            subjectCount == 1 && sessionCount == 1 && preferencesCount == 1
                && resetHistoryMatchesExpected && sessionEpochMatchesExpected
                && preferencesEpochMatchesExpected && validManualSessions == 1
                && subjectIdentityMatches && sessionIdentityMatches && subjectRelationshipMatches
                && explicitKeepAwakeOff && onboardingRemainsIncomplete && !contextHasChanges
        }
    }

    private struct ResetMarkerEvidence: Encodable {
        let sequence: Int
        let markerFingerprint: String
        let epochFingerprint: String
    }

    private func snapshot(container: ModelContainer, prefix: String, resetHistory: Bool) throws -> LocalSnapshot {
        // A fresh read context observes importer commits without retaining stale
        // query handles. No source or projection writes occur in this path.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let writerID = Self.writerID(prefix)
        var subjectsQuery = FetchDescriptor<Subject>(predicate: #Predicate { $0.name == prefix })
        subjectsQuery.fetchLimit = 3
        var sessionsQuery = FetchDescriptor<StudySession>(predicate: #Predicate { $0.subjectNameSnapshot == prefix })
        sessionsQuery.fetchLimit = 3
        var prefsQuery = FetchDescriptor<Prefs>(predicate: #Predicate { $0.settingsWriterID == writerID })
        prefsQuery.fetchLimit = 3
        let subjects = try context.fetch(subjectsQuery)
        let sessions = try context.fetch(sessionsQuery)
        let prefs = try context.fetch(prefsQuery)
        guard subjects.count <= 1, sessions.count <= 1, prefs.count <= 1 else { throw Failure.duplicateAuditRows }
        let subjectID = Self.id(prefix, "subject")
        let expectedEpoch = Self.resetEpoch(prefix, history: resetHistory)
        var markersQuery = FetchDescriptor<ActivityResetMarker>(sortBy: [SortDescriptor(\ActivityResetMarker.sequence)])
        markersQuery.fetchLimit = 4
        let markers = try context.fetch(markersQuery)
        let markerCount = try context.fetchCount(FetchDescriptor<ActivityResetMarker>())
        let expectedSequences = resetHistory ? [0, 1, 2] : []
        let currentMarker = try ActivityResetStore.latestSnapshot(context: context)
        let markerHistoryMatches = markerCount == expectedSequences.count
            && markers.map(\.sequence) == expectedSequences
            && markers.allSatisfy {
                $0.id == Self.id(prefix, "reset-marker-\($0.sequence)")
                    && $0.epochID == Self.id(prefix, "reset-epoch-\($0.sequence)")
                    && $0.writerDeviceID == Self.writerID(prefix)
            }
        return LocalSnapshot(
            subjectCount: subjects.count, sessionCount: sessions.count, preferencesCount: prefs.count,
            resetMarkerCount: markerCount,
            resetSequences: markers.map(\.sequence),
            resetMarkers: markers.map {
                ResetMarkerEvidence(sequence: $0.sequence, markerFingerprint: Self.hash($0.id.uuidString),
                                    epochFingerprint: Self.hash($0.epochID.uuidString))
            },
            currentResetSequence: currentMarker?.sequence,
            currentResetEpochFingerprint: currentMarker.map { Self.hash($0.epochID.uuidString) },
            sessionEpochFingerprint: sessions.first.flatMap(\.dataEpochID).map { Self.hash($0.uuidString) },
            preferencesEpochFingerprint: prefs.first.flatMap(\.activityEpochID).map { Self.hash($0.uuidString) },
            resetHistoryMatchesExpected: markerHistoryMatches,
            sessionEpochMatchesExpected: sessions.first.map { $0.dataEpochID == expectedEpoch } ?? false,
            preferencesEpochMatchesExpected: prefs.first.map { $0.activityEpochID == expectedEpoch } ?? false,
            validManualSessions: sessions.filter {
                $0.source == .manual && $0.seconds == 1_800 && $0.grams == 300
                    && $0.dataEpochID == expectedEpoch && StudySessionIntegrityPolicy.isSupported($0)
            }.count,
            subjectIdentityMatches: subjects.first?.id == subjectID && subjects.first?.deletedAt == nil,
            sessionIdentityMatches: sessions.first?.id == Self.id(prefix, "session"),
            subjectRelationshipMatches: sessions.first?.subject?.id == subjectID
                && sessions.first?.subjectIDSnapshot == subjectID,
            explicitKeepAwakeOff: prefs.first.map { !$0.keepScreenAwake && $0.keepScreenAwakeRevision > 0 } ?? false,
            onboardingRemainsIncomplete: prefs.first.map { !$0.hasCompletedOnboarding } ?? false,
            contextHasChanges: context.hasChanges
        )
    }

    private struct Report: Encodable {
        let formatVersion = 2
        let source = "hostedReleaseShippingSwiftDataCloudKitIntegration"
        let verifiesOrdinaryApplicationUI = false
        let environmentRequiresIndependentSignatureVerification = true
        let verifiesServerUpload = false
        let verifiesUserCloudResetAvailability = false
        let phase: String
        let prefixFingerprint: String
        var auditInstallationFingerprint: String?
        var openedFreshDirectory = false
        var modelsHistoricalResetEpochs = false
        var expectedResetSequences: [Int] = []
        var expectedCurrentEpochFingerprint: String?
        var importObservedInFreshStore = false
        var createdSourceRows = 0
        var requiresIndependentUploadEvidence = false
        var exportHoldSeconds = 0
        var localReadAttempts = 0
        var accountStable = false
        var local: LocalSnapshot?
        var succeeded = false
        var failureStage: String?
        var failureKind: String?
        var frameworkErrorCode: Int?
    }

    private func publish(_ report: Report) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "PomoGemSwiftDataLifecycleEvidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try data.write(to: documents.appendingPathComponent("PomoGemSwiftDataLifecycleEvidence.json"), options: [.atomic, .completeFileProtection])
        print("POMOGEM_SWIFTDATA_LIFECYCLE_EVIDENCE " + String(decoding: data, as: UTF8.self))
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func writerID(_ prefix: String) -> String { "hosted-audit-" + hash(prefix) }
    private static func resetEpoch(_ prefix: String, history: Bool) -> UUID? {
        history ? id(prefix, "reset-epoch-2") : nil
    }
    private static func id(_ prefix: String, _ role: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(prefix):\(role)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return UUID(uuidString: hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-"
                    + hex[6..<8].joined() + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined())!
    }

    private final class ZoneResult: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        private var sawDefault = false
        private var sawCustom = false
        private var completion: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?
        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if let completion {
                lock.unlock()
                continuation.resume(with: completion)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard completion == nil else { lock.unlock(); return }
            completion = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
        func receive(_ result: Result<CKRecordZone, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard completion == nil else { return }
            switch result {
            case let .success(zone):
                if zone.zoneID == CKRecordZone.default().zoneID { sawDefault = true }
                else { sawCustom = true }
            case .failure: failed = true
            }
        }
        var permitsSeed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !failed && !sawCustom && sawDefault
        }
    }
}
