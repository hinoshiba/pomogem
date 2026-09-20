import Foundation

/// Read-only pre-flight evidence about the iCloud dataset that a device →
/// iCloud overwrite would destroy.
///
/// Nobody may authorize deleting contents the app never enumerated, so the
/// overwrite affordance stays disabled until this value exists. It is evidence,
/// never a permit: producing it authorizes nothing, reserves nothing and
/// changes nothing. One read-only server snapshot, no container, no journal,
/// no checkpoint, no file write.
struct StorageTransferCloudPreview: Equatable, Sendable {
    /// One entry per mirrored model — every `PomoGemStorageSnapshot.cloudModelNames`
    /// key is present, including models with zero rows. Local-only models are
    /// excluded because the server never holds them.
    let recordCounts: [String: Int]
    /// The newest finite, non-future timestamp carried by any date field of a
    /// **mirrored** row, or nil when the dataset holds no such row. This is a
    /// property of the DATA, not a sync clock: CloudKit modification times are
    /// deliberately not read here.
    ///
    /// Two restrictions make the two sides of the comparison comparable, and
    /// both are load-bearing rather than tidy:
    ///
    /// * **Mirrored models only.** The iCloud side can only ever hold the 7
    ///   mirrored models; the device side is captured from BOTH stores and also
    ///   holds `AggregatePebble`, `Stratum`, `Bedrock` and `GachaState`, whose
    ///   timestamps are derivation times rewritten whenever the projection is
    ///   rebuilt — effectively "now". Including them would render a stale
    ///   device as the newer side.
    /// * **Nothing in the future.** `AggregatePebble.periodEnd` is the END of a
    ///   covered period and `SyncedFocusTimer.scheduledEndAt` is a deadline, so
    ///   a raw maximum is not a 「最終記録」. A timestamp the clock has not
    ///   reached is not evidence about which dataset is newer.
    let latestRecordAt: Date?
    /// Distinct writer identifiers other than this device, after the
    /// synthetic/audit ignore list. Absence of evidence is not evidence of
    /// absence — a device that has never written still does not appear, so the
    /// UI copy must never phrase a zero as a guarantee.
    let otherDeviceIDs: Int
    /// Distinct writer identifiers dropped by the ignore list, so the fixture
    /// state and the review notes can state the raw and the filtered number.
    let ignoredWriterIDs: Int

    /// The only two models whose writer identifier is a durable witness that a
    /// DIFFERENT installation wrote into this dataset. `SyncedFocusTimer`
    /// is deliberately excluded: its `writerDeviceID` is rewritten by whichever
    /// device currently owns the timer, so it witnesses the present owner
    /// rather than a distinct past writer.
    static let witnessFields: [String: String] = [
        "ActivityResetMarker": "writerDeviceID",
        "FocusTimerDeviceClaim": "deviceID"
    ]

    /// Pure, synchronous and total: the whole policy is visible here so the
    /// UI copy and the review notes can be checked against it.
    static func make(snapshot: PomoGemStorageSnapshot,
                     localDeviceID: String,
                     now: Date = .now,
                     ignoring ignoredIDs: Set<String> = StorageTransferCloudPreviewPolicy.ignoredWriterIDs) -> Self {
        let local = StorageTransferCloudPreviewPolicy.normalize(localDeviceID)
        var counts = Dictionary(uniqueKeysWithValues: PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        var latest: Date?
        var others: Set<String> = []
        var ignored: Set<String> = []
        for row in snapshot.records {
            // Counts and dates are both restricted to the mirrored models, in
            // one branch, so the two cannot drift apart again: the device side
            // and the iCloud side must be reduced over the same models or the
            // comparison a deletion is chosen from is not a comparison.
            if counts[row.entity] != nil {
                counts[row.entity, default: 0] += 1
                for value in row.fields.values {
                    guard case .dateBits(let bits) = value else { continue }
                    let interval = Double(bitPattern: bits)
                    guard interval.isFinite else { continue }
                    let date = Date(timeIntervalSinceReferenceDate: interval)
                    guard date <= now else { continue }
                    if let current = latest { latest = max(current, date) } else { latest = date }
                }
            }
            guard let field = witnessFields[row.entity],
                  case .string(let raw)? = row.fields[field] else { continue }
            let writer = StorageTransferCloudPreviewPolicy.normalize(raw)
            guard !writer.isEmpty, writer != local else { continue }
            if ignoredIDs.contains(writer) { ignored.insert(writer) } else { others.insert(writer) }
        }
        return Self(recordCounts: counts, latestRecordAt: latest,
                    otherDeviceIDs: others.count, ignoredWriterIDs: ignored.count)
    }
}

enum StorageTransferCloudPreviewPolicy {
    /// This repository's own audits wrote these writer identifiers into LIVE
    /// device state: `INVESTIGATION-STATE.md` L2 records a shipping
    /// `CloudOffline/access-v1.json` on the single test iPhone whose
    /// `resetBaseline.writerDeviceID` is `"audit-synthetic"`. Counting such a
    /// row would tell a genuinely single-device account that another device
    /// exists, and that false witness would be shown at the exact moment a
    /// destructive choice is made. The list is explicit, not a pattern, so a
    /// real device identifier (a lowercase UUID) can never be filtered out by
    /// accident. Both the raw and the filtered number are reported.
    static let ignoredWriterIDs: Set<String> = [
        "audit-synthetic", "synthetic", "synthetic-writer", "storage-transfer-placeholder"
    ]

    /// The pre-flight runs BEFORE the user has consented to anything, so it may
    /// not spend the 180 s the post-purge verification read is allowed to. A
    /// slow or offline account fails fast and the overwrite simply stays
    /// disabled with an explicit "could not read" message.
    static let timeout: TimeInterval = 45

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension StorageTransferRuntime {
    /// Live pre-flight. Read-only by construction: `readSnapshot` performs no
    /// write, opens no CoreData container and re-verifies the account identity
    /// before and after the read.
    func previewCloudDataset(binding: ActiveAccountLocalBinding,
                             localDeviceID: String = FocusDeviceIdentity.current(),
                             timeout: TimeInterval = StorageTransferCloudPreviewPolicy.timeout,
                             validateAccess: @escaping @MainActor () throws -> Void) async throws -> StorageTransferCloudPreview {
        try await previewCloudDataset(localDeviceID: localDeviceID, readSnapshot: {
            try await CloudStorageTransferCloudKit(timeout: timeout)
                .readSnapshot(expectedBinding: binding, validateTransfer: validateAccess).snapshot
        }, validateAccess: validateAccess)
    }

    /// The injectable core. A failed read is surfaced, never swallowed and
    /// never reported as an empty dataset — "we could not look" and "there is
    /// nothing there" must not be confusable before a deletion.
    func previewCloudDataset(localDeviceID: String,
                             readSnapshot: () async throws -> PomoGemStorageSnapshot,
                             validateAccess: @escaping @MainActor () throws -> Void) async throws -> StorageTransferCloudPreview {
        try Task.checkCancellation()
        try validateAccess()
        let snapshot = try await readSnapshot()
        try Task.checkCancellation()
        try validateAccess()
        return StorageTransferCloudPreview.make(snapshot: snapshot, localDeviceID: localDeviceID)
    }
}
