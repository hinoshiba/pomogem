import CloudKit
import CryptoKit
import Foundation
import XCTest

/// Opt-in, read-only evidence from the signed host's actual private database.
/// This test never opens a ModelContainer, inserts fixtures, or changes CloudKit.
/// The runner must independently inspect the host's signed iCloud environment;
/// neither a Debug/Release label nor this test's environment variables prove it.
///
/// POMOGEM_REAL_CLOUD_EVIDENCE=1 enables the test on a physical device.
/// POMOGEM_AUDIT_PREFIX selects an ASCII PomoGemAudit-prefixed UI-created subject.
/// POMOGEM_AUDIT_PHASE is observe (default), uploaded, reset, timer, empty,
/// or subject-deleted.
/// POMOGEM_AUDIT_EXPECTED_SECONDS optionally selects a manual session duration.
/// reset requires POMOGEM_AUDIT_EXPECTED_RESET_EPOCH_SHA256 or
/// POMOGEM_AUDIT_RESET_SEQUENCE_AFTER (a strictly exceeded recorded baseline).
/// timer requires POMOGEM_AUDIT_EXPECTED_TIMER_SESSION_SHA256; an optional
/// POMOGEM_AUDIT_EXPECTED_TIMER_STATUS selects a specific raw record status.
/// UUID fingerprints hash the uppercase UUID.uuidString. Timer evidence proves
/// matching row presence, not the effective state of concurrent timer replicas.
/// subject-deleted requires POMOGEM_AUDIT_EXPECTED_SUBJECT_RECORD_SHA256 and
/// POMOGEM_AUDIT_EXPECTED_SECONDS. Capture the original Subject recordFingerprint
/// from taggedSubjectRecords in observe/uploaded BEFORE deleting its theme.
/// This fingerprint hashes the exact CKRecord recordName, not the logical UUID.
/// The phase requires that same row's Date tombstone, no active tagged Subject,
/// and the retained manual duration. UI restore separately verifies 300g/settings.
/// empty requires zero live records, including unknown types, and no skipped zones.
/// POMOGEM_AUDIT_TIMEOUT_SECONDS bounds the entire attempt (default 120; max 600).
/// Run uploaded before uninstall, then verify the same synthetic data in the UI
/// after a full reinstall. This test alone proves server presence, not UI import.
final class RealDeviceCloudEvidenceTests: XCTestCase {
    func testPrivateCloudServerEvidence() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real CloudKit evidence requires a physical device")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_CLOUD_EVIDENCE"] == "1" else {
            throw XCTSkip("Real CloudKit evidence is explicitly opt-in")
        }
        let prefix = environment["POMOGEM_AUDIT_PREFIX"] ?? "PomoGemAudit"
        guard prefix.hasPrefix("PomoGemAudit"), prefix.count <= 80,
              prefix.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
              }),
              let phase = EvidencePhase(rawValue: environment["POMOGEM_AUDIT_PHASE"] ?? "observe") else {
            return XCTFail("Invalid cloud evidence prefix or phase configuration")
        }
        let expectedSeconds = environment["POMOGEM_AUDIT_EXPECTED_SECONDS"].flatMap(Int.init)
        if environment["POMOGEM_AUDIT_EXPECTED_SECONDS"] != nil,
           expectedSeconds.map({ $0 > 0 }) != true {
            return XCTFail("Expected seconds must be a positive integer")
        }
        let resetEpoch = environment["POMOGEM_AUDIT_EXPECTED_RESET_EPOCH_SHA256"]?.lowercased()
        let timerSession = environment["POMOGEM_AUDIT_EXPECTED_TIMER_SESSION_SHA256"]?.lowercased()
        let subjectRecord = environment["POMOGEM_AUDIT_EXPECTED_SUBJECT_RECORD_SHA256"]?.lowercased()
        let resetSequenceAfter = environment["POMOGEM_AUDIT_RESET_SEQUENCE_AFTER"].flatMap(Int.init)
        let timerStatus = environment["POMOGEM_AUDIT_EXPECTED_TIMER_STATUS"]
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard [resetEpoch, timerSession, subjectRecord].compactMap({ $0 }).allSatisfy({
            $0.count == 64 && $0.unicodeScalars.allSatisfy { hex.contains($0) }
        }), (timerStatus.map({ EvidenceTimerRecord.knownStatuses.contains($0) }) ?? true) else {
            return XCTFail("Expected identities must be SHA256 hex fingerprints and timer status must be a known status")
        }
        if environment["POMOGEM_AUDIT_RESET_SEQUENCE_AFTER"] != nil,
           resetSequenceAfter.map({ $0 >= -1 }) != true {
            return XCTFail("Reset sequence baseline must be an integer of at least -1")
        }
        if phase == .reset, resetEpoch == nil && resetSequenceAfter == nil {
            return XCTFail("Reset evidence requires an expected epoch fingerprint or a recorded sequence baseline")
        }
        if phase == .timer, timerSession == nil {
            return XCTFail("Timer evidence requires an expected session fingerprint")
        }
        if phase == .subjectDeleted, subjectRecord == nil || expectedSeconds == nil {
            return XCTFail("Subject deletion evidence requires the original record fingerprint and retained manual duration")
        }
        if phase == .uploaded || phase == .subjectDeleted,
           environment["POMOGEM_AUDIT_PREFIX"] == nil || prefix == "PomoGemAudit" {
            return XCTFail("Uploaded/deleted subject evidence requires an explicit prefix unique to this audit run")
        }
        let expectations = EvidenceExpectations(
            manualSeconds: expectedSeconds, resetEpochFingerprint: resetEpoch,
            resetSequenceAfter: resetSequenceAfter, timerSessionFingerprint: timerSession,
            timerStatus: timerStatus, subjectRecordFingerprint: subjectRecord
        )
        let timeout = environment["POMOGEM_AUDIT_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 120
        guard timeout.isFinite, (15 ... 600).contains(timeout) else {
            return XCTFail("Cloud evidence timeout must be between 15 and 600 seconds")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let container = CKContainer(identifier: "iCloud.com.hinoshiba.pomogem")
        var report = EvidenceReport(phase: phase.rawValue, prefixFingerprint: evidenceHash(prefix), expectations: expectations)
        do {
            // Identity values exist only in memory and are never included in evidence.
            let identity = try await RealDeviceCloudEvidenceReader.accountIdentity(container, deadline: deadline)
            repeat {
                try Task.checkCancellation()
                let snapshot = try await RealDeviceCloudEvidenceReader.serverSnapshot(container.privateCloudDatabase, prefix: prefix, deadline: deadline)
                let after = try await RealDeviceCloudEvidenceReader.accountIdentity(container, deadline: deadline)
                guard identity == after else {
                    throw EvidenceFailure(stage: "identityAfterRead", kind: "accountChanged")
                }
                report.attempts += 1
                report.accountStable = true
                report.snapshot = snapshot
                report.expectationSatisfied = snapshot.satisfies(phase, expectations: expectations)
                if report.expectationSatisfied { break }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 5 { break }
                try await Task.sleep(for: .seconds(min(5, remaining)))
            } while deadline.timeIntervalSinceNow > 0
            publish(report)
            XCTAssertTrue(report.expectationSatisfied, "Cloud server evidence did not satisfy the requested phase; see sanitized JSON attachment")
        } catch {
            report.failure = EvidenceFailure.sanitized(error, stage: "evidence")
            publish(report)
            XCTFail("Cloud server evidence failed; see sanitized stage and numeric codes in JSON attachment")
        }
        #endif
    }

    func testSessionSourceDecoderAcceptsSecureArchivedNSString() throws {
        for source in ["timer", "manual", "timerDemoted"] {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: source as NSString, requiringSecureCoding: true
            )
            let decoded = EvidenceRow.decodeSource(data as NSData)
            XCTAssertEqual(decoded.value, source)
            XCTAssertEqual(decoded.encoding, "keyedArchiveString")
        }
    }

    func testSessionSourceDecoderRejectsUnknownAndOversizedArchivedStrings() throws {
        let unknown = try NSKeyedArchiver.archivedData(
            withRootObject: "synthetic-unrecognized-source" as NSString, requiringSecureCoding: true
        )
        let decoded = EvidenceRow.decodeSource(unknown as NSData)
        XCTAssertEqual(decoded.value, "unknown")
        XCTAssertEqual(decoded.encoding, "keyedArchiveUnknownString")
        XCTAssertFalse(decoded.encoding.contains("synthetic-unrecognized-source"))
        let oversized = try NSKeyedArchiver.archivedData(
            withRootObject: String(repeating: "x", count: 6_000) as NSString,
            requiringSecureCoding: true
        )
        XCTAssertGreaterThan(oversized.count, 4_096)
        XCTAssertEqual(EvidenceRow.decodeSource(oversized as NSData).value, "unknown")
        XCTAssertEqual(EvidenceRow.decodeSource(oversized as NSData).encoding, "oversizedData")
    }

    func testSessionSourceDecoderKeepsKnownFormatsAndReportsOnlyRootKinds() throws {
        let jsonString = try JSONEncoder().encode("manual")
        XCTAssertEqual(EvidenceRow.decodeSource(jsonString as NSData).value, "manual")
        let plist = try PropertyListSerialization.data(fromPropertyList: "manual", format: .binary, options: 0)
        XCTAssertEqual(EvidenceRow.decodeSource(plist as NSData).value, "manual")
        let jsonObject = try JSONSerialization.data(withJSONObject: ["synthetic": "manual"])
        XCTAssertEqual(EvidenceRow.decodeSource(jsonObject as NSData).encoding, "jsonDictionary")
        let plistArray = try PropertyListSerialization.data(fromPropertyList: ["manual"], format: .binary, options: 0)
        XCTAssertEqual(EvidenceRow.decodeSource(plistArray as NSData).encoding, "propertyListArray")
    }

    private func publish(_ report: EvidenceReport) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "PomoGemCloudServerEvidence"
            attachment.lifetime = .keepAlways
            add(attachment)
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try data.write(to: documents.appendingPathComponent("PomoGemCloudEvidence.json"), options: [.atomic, .completeFileProtection])
            print("POMOGEM_CLOUD_SERVER_EVIDENCE " + String(decoding: data, as: UTF8.self))
        } catch {
            XCTFail("Could not encode or save the sanitized cloud evidence report")
        }
    }
}

/// Read-only test support shared by physical-device lifecycle tests. Identity
/// fingerprints are comparison values only and must never be printed.
enum RealDeviceCloudEvidenceReader {
    static func accountFingerprint(deadline: Date) async throws -> String {
        try requireOptIn()
        let container = CKContainer(identifier: "iCloud.com.hinoshiba.pomogem")
        let identity = try await accountIdentity(container, deadline: deadline)
        return evidenceHash(["iCloud.com.hinoshiba.pomogem", identity.zoneID.ownerName,
                             identity.zoneID.zoneName, identity.recordName].joined(separator: "\u{0}"))
    }

    static func waitForUploaded(prefix: String, expectedSeconds: Int, deadline: Date) async throws -> Bool {
        try requireOptIn()
        guard prefix.hasPrefix("PomoGemAudit"), prefix != "PomoGemAudit", expectedSeconds > 0 else {
            throw EvidenceFailure(stage: "uploadWitness", kind: "invalidConfiguration")
        }
        let container = CKContainer(identifier: "iCloud.com.hinoshiba.pomogem")
        let before = try await accountIdentity(container, deadline: deadline)
        let expected = EvidenceExpectations(manualSeconds: expectedSeconds, resetEpochFingerprint: nil,
                                            resetSequenceAfter: nil, timerSessionFingerprint: nil, timerStatus: nil,
                                            subjectRecordFingerprint: nil)
        repeat {
            try Task.checkCancellation()
            let snapshot = try await serverSnapshot(container.privateCloudDatabase, prefix: prefix, deadline: deadline)
            let after = try await accountIdentity(container, deadline: deadline)
            guard before == after else { throw EvidenceFailure(stage: "uploadWitness", kind: "accountChanged") }
            if snapshot.satisfies(.uploaded, expectations: expected) { return true }
            guard deadline.timeIntervalSinceNow > 5 else { return false }
            try await Task.sleep(for: .seconds(5))
        } while deadline.timeIntervalSinceNow > 0
        return false
    }

    /// Seed precondition only. Allows the known default zone but does not claim
    /// that zone is empty. A preexisting Core Data dataset has a custom zone.
    static func requireNoCustomZones(deadline: Date) async throws {
        try requireOptIn()
        let container = CKContainer(identifier: "iCloud.com.hinoshiba.pomogem")
        let before = try await accountIdentity(container, deadline: deadline)
        let zones = try await fetchZones(container.privateCloudDatabase, deadline: deadline)
        guard zones.allSatisfy({ $0.zoneID == CKRecordZone.default().zoneID }) else {
            throw EvidenceFailure(stage: "seedPrecondition", kind: "customZoneAlreadyExists")
        }
        let after = try await accountIdentity(container, deadline: deadline)
        guard before == after else { throw EvidenceFailure(stage: "seedPrecondition", kind: "accountChanged") }
    }

    private static func requireOptIn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real CloudKit evidence requires a physical device")
        #else
        guard ProcessInfo.processInfo.environment["POMOGEM_REAL_CLOUD_EVIDENCE"] == "1" else {
            throw XCTSkip("Real CloudKit evidence is explicitly opt-in")
        }
        #endif
    }

    fileprivate static func accountIdentity(_ container: CKContainer, deadline: Date) async throws -> CKRecord.ID {
        let status: CKAccountStatus = try await evidenceRead(stage: "accountStatus", deadline: deadline) { finish in
            container.accountStatus { status, error in
                if let error { finish(.failure(error)) } else { finish(.success(status)) }
            }
            return nil
        }
        guard status == .available else {
            throw EvidenceFailure(stage: "accountStatus", kind: "unavailable", accountStatusCode: status.rawValue)
        }
        return try await evidenceRead(stage: "identity", deadline: deadline) { finish in
            container.fetchUserRecordID { recordID, error in
                if let error { finish(.failure(error)) }
                else if let recordID { finish(.success(recordID)) }
                else { finish(.failure(EvidenceFailure(stage: "identity", kind: "missingResult"))) }
            }
            return nil
        }
    }

    fileprivate static func serverSnapshot(_ database: CKDatabase, prefix: String, deadline: Date) async throws -> EvidenceSnapshot {
        let zones = try await fetchZones(database, deadline: deadline)
        // The default zone cannot provide zone changes. Core Data uses custom
        // zones with fetchChanges capability. Report skipped zones explicitly.
        let readable = zones.filter { $0.capabilities.contains(.fetchChanges) }
        var rows: [EvidenceRow] = []
        for zone in readable {
            let fetched: [EvidenceRow] = try await evidenceRead(stage: "fetchZoneChanges", deadline: deadline) { finish in
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                configuration.previousServerChangeToken = nil
                configuration.resultsLimit = 200
                configuration.desiredKeys = [
                    "CD_entityName", "CD_id", "CD_name", "CD_deletedAt", "CD_subjectNameSnapshot",
                    "CD_source", "CD_seconds", "CD_dataEpochID", "CD_epochID",
                    "CD_sequence", "CD_statusRaw", "CD_sessionID", "CD_revision", "CD_ownershipSequence"
                ]
                let operation = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: [zone.zoneID], configurationsByRecordZoneID: [zone.zoneID: configuration]
                )
                configure(operation, deadline: deadline)
                // CloudKit exhausts every page; final moreComing must be false.
                operation.fetchAllChanges = true
                let values = EvidenceLocked(EvidenceZoneAccumulator())
                operation.recordWasChangedBlock = { recordID, result in
                    values.withValue { value in
                        guard value.failure == nil else { return }
                        switch result {
                        case let .success(record):
                            guard value.rows.count < 100_000 else {
                                value.failure = EvidenceFailure(stage: "fetchZoneChanges", kind: "recordLimit")
                                return
                            }
                            value.rows[recordID] = EvidenceRow(record, prefix: prefix)
                        case let .failure(error): value.failure = error
                        }
                    }
                }
                operation.recordWithIDWasDeletedBlock = { recordID, _ in
                    values.withValue { value in
                        _ = value.rows.removeValue(forKey: recordID)
                    }
                }
                operation.recordZoneFetchResultBlock = { _, result in
                    values.withValue { value in
                        switch result {
                        case let .success(page): value.finishedAllPages = !page.moreComing
                        case let .failure(error): value.failure = value.failure ?? error
                        }
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    let value = values.withValue { $0 }
                    if let failure = value.failure { finish(.failure(failure)) }
                    else if case let .failure(error) = result { finish(.failure(error)) }
                    else if !value.finishedAllPages {
                        finish(.failure(EvidenceFailure(stage: "fetchZoneChanges", kind: "incompletePagination")))
                    } else { finish(.success(Array(value.rows.values))) }
                }
                database.add(operation)
                return operation
            }
            rows.append(contentsOf: fetched)
        }
        return EvidenceSnapshot(rows: rows, zoneCount: zones.count, readableZoneCount: readable.count)
    }

    private static func fetchZones(_ database: CKDatabase, deadline: Date) async throws -> [CKRecordZone] {
        return try await evidenceRead(stage: "fetchZones", deadline: deadline) { finish in
            let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            configure(operation, deadline: deadline)
            let values = EvidenceLocked((zones: [CKRecordZone](), error: Optional<Error>.none))
            operation.perRecordZoneResultBlock = { _, result in
                values.withValue { value in
                    switch result {
                    case let .success(zone): value.zones.append(zone)
                    case let .failure(error): value.error = value.error ?? error
                    }
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                let value = values.withValue { $0 }
                if let error = value.error { finish(.failure(error)) }
                else { finish(result.map { value.zones }) }
            }
            database.add(operation)
            return operation
        }
    }
}

private enum EvidencePhase: String {
    case observe, uploaded, reset, timer, empty
    case subjectDeleted = "subject-deleted"
}

private struct EvidenceExpectations: Encodable {
    let manualSeconds: Int?
    let resetEpochFingerprint: String?
    let resetSequenceAfter: Int?
    let timerSessionFingerprint: String?
    let timerStatus: String?
    let subjectRecordFingerprint: String?
}

private struct EvidenceReport: Encodable {
    let formatVersion = 3
    let source = "livePrivateCloudKitZoneChanges"
    let verifiesLocalImport = false
    let verifiesDeletionOperation = false
    let resolvesEffectiveTimerState = false
    let environmentMustBeVerifiedFromSignedHost = true
    let phase: String
    let prefixFingerprint: String
    let expectations: EvidenceExpectations
    var attempts = 0
    var accountStable = false
    var expectationSatisfied = false
    var snapshot: EvidenceSnapshot?
    var failure: EvidenceFailure?
}

private struct EvidenceSnapshot: Encodable {
    let capturedAt = ISO8601DateFormatter().string(from: Date())
    let zoneCount: Int
    let readableZoneCount: Int
    let skippedZonesWithoutChangeCapability: Int
    let coversAllReturnedZones: Bool
    let observedLiveRecordCount: Int
    let entityCounts: [String: Int]
    let taggedActiveSubjects: Int
    let taggedSubjectRecords: [EvidenceSubjectRecord]
    let taggedStudySessions: Int
    let taggedManualSessions: Int
    let taggedManualSessionSeconds: [Int]
    let taggedSessionSourceEncodings: [String: Int]
    let taggedRecordFingerprints: [String]
    let resetSequences: [Int]
    let resetMarkers: [EvidenceResetMarker]
    let epochCountsByEntity: [String: [String: Int]]
    let timerStatusCounts: [String: Int]
    let timerRecords: [EvidenceTimerRecord]

    init(rows: [EvidenceRow], zoneCount: Int, readableZoneCount: Int) {
        self.zoneCount = zoneCount
        self.readableZoneCount = readableZoneCount
        skippedZonesWithoutChangeCapability = zoneCount - readableZoneCount
        coversAllReturnedZones = zoneCount == readableZoneCount
        observedLiveRecordCount = rows.count
        entityCounts = Dictionary(grouping: rows, by: \.entity).mapValues(\.count)
        taggedActiveSubjects = rows.filter(\.taggedActiveSubject).count
        taggedSubjectRecords = rows.filter(\.taggedSubject).map {
            EvidenceSubjectRecord(recordFingerprint: $0.fingerprint,
                                  subjectIDFingerprint: $0.subjectIDFingerprint,
                                  deletionState: $0.subjectDeletionState)
        }.sorted { $0.recordFingerprint < $1.recordFingerprint }
        let sessions = rows.filter(\.taggedSession)
        taggedStudySessions = sessions.count
        let manual = sessions.filter { $0.source == "manual" }
        taggedManualSessions = manual.count
        taggedManualSessionSeconds = manual.compactMap(\.seconds).sorted()
        taggedSessionSourceEncodings = Dictionary(grouping: sessions, by: \.sourceEncoding).mapValues(\.count)
        taggedRecordFingerprints = rows.filter { $0.taggedActiveSubject || $0.taggedSession }.map(\.fingerprint).sorted()
        resetSequences = rows.filter { $0.entity == "ActivityResetMarker" }.compactMap(\.sequence).sorted()
        resetMarkers = rows.filter { $0.entity == "ActivityResetMarker" }.map {
            EvidenceResetMarker(sequence: $0.sequence, epochFingerprint: $0.epochFingerprint)
        }.sorted { ($0.sequence ?? -1, $0.epochFingerprint) < ($1.sequence ?? -1, $1.epochFingerprint) }
        let epochRows = rows.filter { ["StudySession", "ActivityResetMarker", "SyncedFocusTimer", "FocusTimerDeviceClaim"].contains($0.entity) }
        epochCountsByEntity = Dictionary(grouping: epochRows, by: \.entity).mapValues { values in
            Dictionary(grouping: values, by: \.epochFingerprint).mapValues(\.count)
        }
        timerStatusCounts = Dictionary(grouping: rows.filter { $0.entity == "SyncedFocusTimer" }, by: \.status).mapValues(\.count)
        timerRecords = rows.filter { $0.entity == "SyncedFocusTimer" }.map {
            EvidenceTimerRecord(sessionFingerprint: $0.sessionFingerprint, status: $0.status,
                                epochFingerprint: $0.epochFingerprint, revision: $0.revision,
                                ownershipSequence: $0.ownershipSequence)
        }.sorted { ($0.sessionFingerprint, $0.revision ?? -1, $0.status) < ($1.sessionFingerprint, $1.revision ?? -1, $1.status) }
    }

    func satisfies(_ phase: EvidencePhase, expectations: EvidenceExpectations) -> Bool {
        switch phase {
        case .observe: return true
        case .uploaded:
            return taggedActiveSubjects > 0 && taggedManualSessions > 0
                && (expectations.manualSeconds.map { taggedManualSessionSeconds.contains($0) } ?? true)
        case .reset:
            guard expectations.resetEpochFingerprint != nil || expectations.resetSequenceAfter != nil else { return false }
            return resetMarkers.contains { marker in
                (expectations.resetEpochFingerprint.map { marker.epochFingerprint == $0 } ?? true)
                    && (expectations.resetSequenceAfter.map { (marker.sequence ?? -1) > $0 } ?? true)
            }
        case .timer:
            guard let expectedSession = expectations.timerSessionFingerprint else { return false }
            return timerRecords.contains { timer in
                timer.sessionFingerprint == expectedSession
                    && (expectations.timerStatus.map { timer.status == $0 }
                        ?? ["running", "paused", "completionPending"].contains(timer.status))
            }
        case .subjectDeleted:
            guard let subjectRecord = expectations.subjectRecordFingerprint,
                  let manualSeconds = expectations.manualSeconds else { return false }
            return taggedActiveSubjects == 0 && taggedManualSessions == 1
                && taggedManualSessionSeconds == [manualSeconds]
                && taggedSubjectRecords.contains {
                    $0.recordFingerprint == subjectRecord && $0.deletionState == "deleted"
                }
        case .empty: return coversAllReturnedZones && observedLiveRecordCount == 0
        }
    }
}

private struct EvidenceSubjectRecord: Encodable {
    let recordFingerprint: String
    let subjectIDFingerprint: String
    let deletionState: String
}

private struct EvidenceResetMarker: Encodable {
    let sequence: Int?
    let epochFingerprint: String
}

private struct EvidenceTimerRecord: Encodable {
    static let knownStatuses = ["running", "paused", "completionPending", "completed", "cancelled"]
    let sessionFingerprint: String
    let status: String
    let epochFingerprint: String
    let revision: Int?
    let ownershipSequence: Int?
}

private struct EvidenceRow {
    let entity: String
    let taggedSubject: Bool
    let taggedActiveSubject: Bool
    let subjectIDFingerprint: String
    let subjectDeletionState: String
    let taggedSession: Bool
    let source: String
    let sourceEncoding: String
    let seconds: Int?
    let sequence: Int?
    let revision: Int?
    let ownershipSequence: Int?
    let epochFingerprint: String
    let sessionFingerprint: String
    let status: String
    let fingerprint: String

    init(_ record: CKRecord, prefix: String) {
        let known = ["Subject", "StudySession", "AchievementStone", "Prefs", "ActivityResetMarker", "SyncedFocusTimer", "FocusTimerDeviceClaim"]
        let candidate = (record["CD_entityName"] as? String) ?? String(record.recordType.dropFirst(record.recordType.hasPrefix("CD_") ? 3 : 0))
        entity = known.contains(candidate) ? candidate : "other"
        taggedSubject = entity == "Subject" && (record["CD_name"] as? String)?.hasPrefix(prefix) == true
        taggedActiveSubject = taggedSubject && record["CD_deletedAt"] == nil
        if record["CD_deletedAt"] == nil { subjectDeletionState = "active" }
        else if record["CD_deletedAt"] is Date { subjectDeletionState = "deleted" }
        else { subjectDeletionState = "unreadable" }
        if let raw = record["CD_id"] as? String, let uuid = UUID(uuidString: raw) {
            subjectIDFingerprint = evidenceHash(uuid.uuidString)
        } else { subjectIDFingerprint = "unreadable" }
        taggedSession = entity == "StudySession" && (record["CD_subjectNameSnapshot"] as? String)?.hasPrefix(prefix) == true
        let decoded = Self.decodeSource(record["CD_source"])
        source = decoded.value
        sourceEncoding = decoded.encoding
        seconds = (record["CD_seconds"] as? NSNumber)?.intValue
        sequence = (record["CD_sequence"] as? NSNumber)?.intValue
        revision = (record["CD_revision"] as? NSNumber)?.intValue
        ownershipSequence = (record["CD_ownershipSequence"] as? NSNumber)?.intValue
        let epochField = entity == "ActivityResetMarker" ? "CD_epochID" : "CD_dataEpochID"
        if record[epochField] == nil { epochFingerprint = "legacy" }
        else if let raw = record[epochField] as? String, let uuid = UUID(uuidString: raw) {
            epochFingerprint = evidenceHash(uuid.uuidString)
        } else { epochFingerprint = "unreadable" }
        if let raw = record["CD_sessionID"] as? String, let uuid = UUID(uuidString: raw) {
            sessionFingerprint = evidenceHash(uuid.uuidString)
        } else { sessionFingerprint = "unreadable" }
        let rawStatus = record["CD_statusRaw"] as? String ?? "unknown"
        status = EvidenceTimerRecord.knownStatuses.contains(rawStatus) ? rawStatus : "unknown"
        // Only fingerprints of explicitly tagged synthetic rows are exported.
        fingerprint = evidenceHash(record.recordID.recordName)
    }

    fileprivate static func decodeSource(_ field: CKRecordValue?) -> (value: String, encoding: String) {
        let allowed = ["timer", "manual", "timerDemoted"]
        if let value = field as? String {
            return (allowed.contains(value) ? value : "unknown", "string")
        }
        if let data = field as? Data {
            guard data.count <= 4096 else { return ("unknown", "oversizedData") }
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                if let value = json as? String, allowed.contains(value) { return (value, "jsonString") }
                return ("unknown", "json" + rootKind(json))
            }
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                if let value = plist as? String, allowed.contains(value) { return (value, "propertyListString") }
                if let archive = plist as? [String: Any], archive["$archiver"] as? String == "NSKeyedArchiver" {
                    // A CloudKit transformable payload can be an
                    // NSString archive. Decode only that secure class, bounded
                    // above, and accept only the three actual SessionSource values.
                    if let value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data) {
                        return allowed.contains(value as String)
                            ? (value as String, "keyedArchiveString")
                            : ("unknown", "keyedArchiveUnknownString")
                    }
                    return ("unknown", "keyedArchiveUnsupported")
                }
                return ("unknown", "propertyList" + rootKind(plist))
            }
            return ("unknown", "unrecognizedData")
        }
        return ("unknown", field == nil ? "missing" : "unrecognizedType")
    }

    private static func rootKind(_ value: Any) -> String {
        switch value {
        case is String: return "String"
        case is [String: Any]: return "Dictionary"
        case is [Any]: return "Array"
        case is NSNumber: return "Number"
        case is Data: return "Data"
        case is Date: return "Date"
        case is NSNull: return "Null"
        default: return "Other"
        }
    }
}

private struct EvidenceZoneAccumulator {
    var rows: [CKRecord.ID: EvidenceRow] = [:]
    var finishedAllPages = false
    var failure: Error?
}

private struct EvidenceFailure: Error, Encodable {
    let stage: String
    let kind: String
    var accountStatusCode: Int? = nil
    var cloudKitCodes: [Int] = []
    var retryAfterSeconds: Double? = nil

    static func sanitized(_ error: Error, stage: String) -> Self {
        if let existing = error as? Self { return existing }
        if error is CancellationError { return Self(stage: stage, kind: "cancelled") }
        let nsError = error as NSError
        var codes: Set<Int> = []
        func collect(_ error: NSError, depth: Int) {
            guard depth < 4 else { return }
            if error.domain == CKErrorDomain { codes.insert(error.code) }
            if let partials = error.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
                for value in partials.allValues {
                    if let child = value as? NSError { collect(child, depth: depth + 1) }
                }
            }
        }
        collect(nsError, depth: 0)
        let delay = (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        return Self(stage: stage, kind: codes.isEmpty ? "nonCloudKitError" : "cloudKitError", cloudKitCodes: codes.sorted(), retryAfterSeconds: delay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }
}

private func evidenceHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func configure(_ operation: CKOperation, deadline: Date) {
    let remaining = max(0.1, deadline.timeIntervalSinceNow)
    operation.configuration.timeoutIntervalForRequest = min(15, remaining)
    operation.configuration.timeoutIntervalForResource = min(30, remaining)
    operation.qualityOfService = .userInitiated
}

private final class EvidenceLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// A real deadline must not wait for CloudKit to acknowledge cancellation.
/// Late callbacks are discarded and cannot resume the continuation twice.
private final class EvidenceCompletion<Value>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
        var cancel: (() -> Void)?
    }
    private let state = EvidenceLocked(State())
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = state.withValue { state -> Result<Value, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func installCancellation(_ cancel: @escaping () -> Void) {
        let finished = state.withValue { state in
            if state.result != nil { return true }
            state.cancel = cancel
            return false
        }
        if finished { cancel() }
    }
    func finish(_ result: Result<Value, Error>) {
        let completion = state.withValue { state -> (CheckedContinuation<Value, Error>?, (() -> Void)?) in
            guard state.result == nil else { return (nil, nil) }
            state.result = result
            let completion = (state.continuation, state.cancel)
            state.continuation = nil
            state.cancel = nil
            return completion
        }
        completion.1?()
        completion.0?.resume(with: result)
    }
}

private func evidenceRead<Value>(
    stage: String,
    deadline: Date,
    start: (@escaping (Result<Value, Error>) -> Void) -> CKOperation?
) async throws -> Value {
    let remaining = min(40, deadline.timeIntervalSinceNow)
    guard remaining > 0 else { throw EvidenceFailure(stage: stage, kind: "deadline") }
    let completion = EvidenceCompletion<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let timeout = DispatchWorkItem {
                completion.finish(.failure(EvidenceFailure(stage: stage, kind: "deadline")))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + remaining, execute: timeout)
            let operation = start { result in
                completion.finish(result.mapError { EvidenceFailure.sanitized($0, stage: stage) })
            }
            completion.installCancellation { timeout.cancel(); operation?.cancel() }
        }
    } onCancel: {
        completion.finish(.failure(EvidenceFailure(stage: stage, kind: "cancelled")))
    }
}
