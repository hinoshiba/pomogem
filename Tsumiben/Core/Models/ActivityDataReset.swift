import Foundation
import SwiftData

/// Append-only reset intent stored in the same private CloudKit database as
/// activity data. Deleting old rows is only a local cleanup: this marker is the
/// durable rule that rejects an offline device's later re-upload.
@Model
final class ActivityResetMarker {
    var id: UUID = UUID()
    var epochID: UUID = UUID()
    var sequence: Int = 0
    var resetAt: Date = Date(timeIntervalSince1970: 0)
    var writerDeviceID: String = ""

    init(
        id: UUID = UUID(),
        epochID: UUID = UUID(),
        sequence: Int,
        resetAt: Date,
        writerDeviceID: String
    ) {
        self.id = id
        self.epochID = epochID
        self.sequence = max(0, sequence)
        self.resetAt = resetAt
        self.writerDeviceID = writerDeviceID
    }

    var policySnapshot: ActivityResetSnapshot {
        ActivityResetSnapshot(
            id: id,
            epochID: epochID,
            sequence: sequence,
            resetAt: resetAt,
            writerDeviceID: writerDeviceID
        )
    }
}

struct ActivityResetSnapshot: Equatable, Sendable {
    let id: UUID
    let epochID: UUID
    let sequence: Int
    let resetAt: Date
    let writerDeviceID: String
}

enum ActivityEpochState: Equatable, Sendable {
    /// The row belongs to the latest reset generation and may be displayed.
    case current
    /// The row belongs to an older known generation and may be deleted.
    case stale
    /// Its generation marker has not arrived yet. Preserve but quarantine it;
    /// CloudKit does not guarantee record delivery order.
    case awaitingMarker
}

enum ActivityResetPolicy {
    /// This ceiling rejects an impossible/corrupt CloudKit value before it can
    /// pin the Lamport counter at `Int.max`. One million user-initiated resets
    /// is far beyond the supported lifetime of this app.
    static let maximumSupportedSequence = 1_000_000

    static func isSupported(_ marker: ActivityResetSnapshot) -> Bool {
        (0 ... maximumSupportedSequence).contains(marker.sequence)
    }

    /// Reset generations use a Lamport-style sequence, never wall-clock time,
    /// as their primary order. Device clocks can move backwards or years into
    /// the future; allowing `Date.now` to reclassify an observed marker would
    /// resurrect hidden rows or later make maintenance delete the wrong
    /// generation. A device that has observed a winner writes `sequence + 1`;
    /// concurrent offline resets converge through stable identifiers.
    /// `resetAt` remains display/audit metadata only.
    static func currentMarker(
        from values: [ActivityResetSnapshot],
        now _: Date = .now
    ) -> ActivityResetSnapshot? {
        values
            .filter(isSupported)
            .max(by: markerIsOrderedBefore)
    }

    static func currentEpochID(
        from values: [ActivityResetSnapshot],
        now: Date = .now
    ) -> UUID? {
        currentMarker(from: values, now: now)?.epochID
    }

    static func nextSequence(
        from values: [ActivityResetSnapshot],
        now _: Date = .now
    ) -> Int {
        let maximum = values
            .filter(isSupported)
            .map(\.sequence)
            .max() ?? -1
        return maximum >= maximumSupportedSequence
            ? maximumSupportedSequence
            : maximum + 1
    }

    static func state(
        of recordEpochID: UUID?,
        markers: [ActivityResetSnapshot],
        now: Date = .now
    ) -> ActivityEpochState {
        let supportedMarkers = markers.filter(isSupported)
        guard let current = currentMarker(from: supportedMarkers, now: now) else {
            // nil is the pre-reset generation. A non-nil value can arrive
            // before its marker, so it must not be destroyed as "unknown".
            return recordEpochID == nil ? .current : .awaitingMarker
        }
        guard let recordEpochID else { return .stale }
        if recordEpochID == current.epochID { return .current }
        if supportedMarkers.contains(where: { $0.epochID == recordEpochID }) {
            return .stale
        }
        return .awaitingMarker
    }

    static func isCurrent(
        _ recordEpochID: UUID?,
        markers: [ActivityResetSnapshot],
        now: Date = .now
    ) -> Bool {
        state(of: recordEpochID, markers: markers, now: now) == .current
    }

    /// The sort order exactly matches `markerIsOrderedBefore`, allowing launch
    /// and SwiftUI observation to fetch only one stable winner.
    static func currentMarkerDescriptor(
        now _: Date = .now,
        fetchLimit: Int = 1
    ) -> FetchDescriptor<ActivityResetMarker> {
        let maximumSupportedSequence = maximumSupportedSequence
        var descriptor = FetchDescriptor<ActivityResetMarker>(
            predicate: #Predicate {
                $0.sequence >= 0 && $0.sequence <= maximumSupportedSequence
            },
            sortBy: [
                SortDescriptor(\ActivityResetMarker.sequence, order: .reverse),
                SortDescriptor(\ActivityResetMarker.writerDeviceID, order: .reverse),
                SortDescriptor(\ActivityResetMarker.epochID, order: .reverse),
                SortDescriptor(\ActivityResetMarker.id, order: .reverse)
            ]
        )
        descriptor.fetchLimit = max(1, fetchLimit)
        return descriptor
    }

    private static func markerIsOrderedBefore(
        _ lhs: ActivityResetSnapshot,
        _ rhs: ActivityResetSnapshot
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.writerDeviceID != rhs.writerDeviceID {
            return lhs.writerDeviceID < rhs.writerDeviceID
        }
        if lhs.epochID != rhs.epochID {
            return lhs.epochID.uuidString < rhs.epochID.uuidString
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

@MainActor
enum ActivityResetStore {
    /// Reads only the winning reset generation. Most interactive paths need
    /// the current gate, not the complete append-only marker history.
    static func latestSnapshot(
        context: ModelContext,
        now: Date = .now
    ) throws -> ActivityResetSnapshot? {
        let descriptor = ActivityResetPolicy.currentMarkerDescriptor(now: now)
        return try context.fetch(descriptor).first?.policySnapshot
    }

    static func latestEpochID(
        context: ModelContext,
        now: Date = .now
    ) throws -> UUID? {
        try latestSnapshot(context: context, now: now)?.epochID
    }

    static func snapshots(context: ModelContext) throws -> [ActivityResetSnapshot] {
        try context.fetch(FetchDescriptor<ActivityResetMarker>())
            .map(\.policySnapshot)
    }

    static func currentEpochID(
        context: ModelContext,
        now: Date = .now
    ) throws -> UUID? {
        ActivityResetPolicy.currentEpochID(
            from: try snapshots(context: context),
            now: now
        )
    }

    @discardableResult
    static func beginReset(
        context: ModelContext,
        deviceID: String,
        now: Date = .now,
        epochID: UUID = UUID()
    ) throws -> ActivityResetMarker {
        let current = try latestSnapshot(context: context, now: now)
        guard current?.sequence != ActivityResetPolicy.maximumSupportedSequence else {
            throw ActivityResetStoreError.sequenceExhausted
        }
        let marker = ActivityResetMarker(
            epochID: epochID,
            sequence: (current?.sequence ?? -1) + 1,
            resetAt: now,
            writerDeviceID: deviceID
        )
        context.insert(marker)
        return marker
    }
}

enum ActivityResetStoreError: LocalizedError, Equatable {
    case sequenceExhausted

    var errorDescription: String? {
        "記録のリセット履歴が上限に達しました。サポートへお問い合わせください。"
    }
}
