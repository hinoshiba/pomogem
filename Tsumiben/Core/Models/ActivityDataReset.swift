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
    static func currentMarker(
        from values: [ActivityResetSnapshot]
    ) -> ActivityResetSnapshot? {
        values.max(by: markerIsOrderedBefore)
    }

    static func currentEpochID(
        from values: [ActivityResetSnapshot]
    ) -> UUID? {
        currentMarker(from: values)?.epochID
    }

    static func nextSequence(
        from values: [ActivityResetSnapshot]
    ) -> Int {
        (values.map(\.sequence).max() ?? -1) + 1
    }

    static func state(
        of recordEpochID: UUID?,
        markers: [ActivityResetSnapshot]
    ) -> ActivityEpochState {
        guard let current = currentMarker(from: markers) else {
            // nil is the pre-reset generation. A non-nil value can arrive
            // before its marker, so it must not be destroyed as "unknown".
            return recordEpochID == nil ? .current : .awaitingMarker
        }
        guard let recordEpochID else { return .stale }
        if recordEpochID == current.epochID { return .current }
        if markers.contains(where: { $0.epochID == recordEpochID }) {
            return .stale
        }
        return .awaitingMarker
    }

    static func isCurrent(
        _ recordEpochID: UUID?,
        markers: [ActivityResetSnapshot]
    ) -> Bool {
        state(of: recordEpochID, markers: markers) == .current
    }

    private static func markerIsOrderedBefore(
        _ lhs: ActivityResetSnapshot,
        _ rhs: ActivityResetSnapshot
    ) -> Bool {
        if lhs.resetAt != rhs.resetAt { return lhs.resetAt < rhs.resetAt }
        // resetAt is primary so a genuinely later offline reset is not beaten
        // merely because that device had not learned a higher remote Lamport
        // sequence yet. Network-correct system time remains a prerequisite.
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
        context: ModelContext
    ) throws -> ActivityResetSnapshot? {
        var descriptor = FetchDescriptor<ActivityResetMarker>(sortBy: [
            SortDescriptor(\ActivityResetMarker.resetAt, order: .reverse),
            SortDescriptor(\ActivityResetMarker.sequence, order: .reverse),
            SortDescriptor(\ActivityResetMarker.writerDeviceID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.epochID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.id, order: .reverse)
        ])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.policySnapshot
    }

    static func latestEpochID(context: ModelContext) throws -> UUID? {
        try latestSnapshot(context: context)?.epochID
    }

    static func snapshots(context: ModelContext) throws -> [ActivityResetSnapshot] {
        try context.fetch(FetchDescriptor<ActivityResetMarker>())
            .map(\.policySnapshot)
    }

    static func currentEpochID(context: ModelContext) throws -> UUID? {
        ActivityResetPolicy.currentEpochID(from: try snapshots(context: context))
    }

    @discardableResult
    static func beginReset(
        context: ModelContext,
        deviceID: String,
        now: Date = .now,
        epochID: UUID = UUID()
    ) throws -> ActivityResetMarker {
        let values = try snapshots(context: context)
        let marker = ActivityResetMarker(
            epochID: epochID,
            sequence: ActivityResetPolicy.nextSequence(from: values),
            resetAt: now,
            writerDeviceID: deviceID
        )
        context.insert(marker)
        return marker
    }
}
