import Foundation

/// sync-03, after review of PR #40. What the jar's lifetime headline, the
/// menu and the jar's VoiceOver value say while iCloud verification is
/// pending.
///
/// Pending hides every aggregate (`allowsAggregateSummaries` is false) and
/// Home materialises at most `HomeProjectionPolicy.looseSessionLimit` of the
/// newest sessions, so Home's own sum is the lifetime total only for a small
/// history. Shown as it was, a multi-year jar read 250 kg while verified and
/// at most 32 kg on every return to the app — which looks like data loss, on
/// exactly the long-time users sync-03 is for. The headline is therefore, in
/// order:
/// 1. `.device`: Home's own sum, when it provably covers every current
///    session (the complete candidate page fits inside the jar's cap);
/// 2. `.lastVerified`: the last total Home showed as verified for the same
///    data, plus this device's sessions newer than the newest session that
///    total counted — or Home's own sum if that is larger;
/// 3. `.hidden`: 「再集計中」, exactly as before sync-03.
/// Every shown value keeps the 「iCloudを確認中」 caption; nothing is written,
/// exported or shared from it; the verified value replaces it as soon as
/// verification completes.
enum PendingMassPresentationPolicy {
    /// One session Home currently holds, reduced to what the headline needs.
    struct Session: Equatable, Sendable {
        let id: UUID
        let endAt: Date
        let grams: Int
    }

    enum Headline: Equatable, Sendable {
        /// Home's own sum, which covers every current session: exact.
        case device(grams: Int, pebbleCount: Int)
        /// The last verified total plus newer sessions on this device.
        case lastVerified(grams: Int, pebbleCount: Int, isLowerBound: Bool)
        /// Nothing this device can stand behind: 「再集計中」.
        case hidden

        var grams: Int? {
            switch self {
            case let .device(grams, _), let .lastVerified(grams, _, _): grams
            case .hidden: nil
            }
        }

        var pebbleCount: Int? {
            switch self {
            case let .device(_, count), let .lastVerified(_, count, _): count
            case .hidden: nil
            }
        }

        var isLowerBound: Bool {
            if case let .lastVerified(_, _, isLowerBound) = self { return isLowerBound }
            return false
        }
    }

    static func headline(
        lastVerified: VerifiedMassRecord?,
        currentEpochID: UUID?,
        deviceSessions: [Session],
        deviceTotals: HomeProjectionPolicy.Totals,
        deviceCoversEverySession: Bool
    ) -> Headline {
        if deviceCoversEverySession {
            return .device(grams: deviceTotals.grams, pebbleCount: deviceTotals.pebbleCount)
        }
        guard let record = lastVerified?.describing(epochID: currentEpochID, sessions: deviceSessions) else {
            return .hidden
        }
        let newer = deviceSessions.filter { $0.endAt > record.frontierEndAt && $0.id != record.frontierSessionID }
        let grams = NonnegativeIntPolicy.sum([record.grams] + newer.map(\.grams))
        let pebbleCount = NonnegativeIntPolicy.sum([record.pebbleCount, newer.count])
        guard deviceTotals.grams <= grams else {
            // The last verified total was itself partial; never show less than
            // this device can already count.
            return .lastVerified(grams: deviceTotals.grams,
                                 pebbleCount: max(pebbleCount, deviceTotals.pebbleCount),
                                 isLowerBound: true)
        }
        return .lastVerified(grams: grams, pebbleCount: pebbleCount, isLowerBound: record.isLowerBound)
    }

    /// The record a verified Home leaves for the next pending phase.
    /// `countedSessions` are the sessions the total counts, loose or inside an
    /// accepted aggregate, so the frontier is the newest thing it counted.
    /// While pending every session is loose again: a session newer than the
    /// frontier that the total already held (an aggregate reaching past every
    /// session Home can name) would be counted twice, so such a total is not
    /// recorded and the previous record, if any, stays.
    static func record(
        grams: Int,
        pebbleCount: Int,
        isLowerBound: Bool,
        epochID: UUID?,
        countedSessions: [Session],
        newestAggregatedEnd: Date?
    ) -> VerifiedMassRecord? {
        guard let frontier = countedSessions.max(by: { lhs, rhs in
            lhs.endAt == rhs.endAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.endAt < rhs.endAt
        }) else { return nil }
        if let newestAggregatedEnd, newestAggregatedEnd > frontier.endAt { return nil }
        return VerifiedMassRecord(grams: max(0, grams), pebbleCount: max(0, pebbleCount),
                                  isLowerBound: isLowerBound, epochID: epochID,
                                  frontierSessionID: frontier.id, frontierEndAt: frontier.endAt)
    }
}

/// The last lifetime total Home presented as verified, kept per account on
/// this device only (`UserDefaults`, scoped by `AccountScopedLocalState`;
/// complete deletion removes it with every other default). It is a number
/// and two identifiers — no theme, memo or session content.
///
/// It describes this device's data only while its newest counted session is
/// still one of Home's current sessions in the same reset epoch: a records
/// reset, a complete deletion, a replaced dataset or another account's store
/// does not contain that session, so the record is ignored there.
struct VerifiedMassRecord: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    let grams: Int
    let pebbleCount: Int
    let isLowerBound: Bool
    let epochID: UUID?
    let frontierSessionID: UUID
    let frontierEndAt: Date

    func describing(epochID: UUID?, sessions: [PendingMassPresentationPolicy.Session]) -> Self? {
        guard formatVersion == Self.currentFormatVersion, grams >= 0, pebbleCount >= 0,
              self.epochID == epochID,
              sessions.contains(where: { $0.id == frontierSessionID })
        else { return nil }
        return self
    }
}

/// Reads and writes `VerifiedMassRecord`. Best effort: a missing or unreadable
/// record only means the pending headline falls back to 「再集計中」.
enum VerifiedMassRecordStore {
    static let defaultsBase = "home.last-verified-mass.v1"

    static func load(defaults: UserDefaults = .standard) -> VerifiedMassRecord? {
        let key = AccountScopedLocalState.defaultsKey(base: defaultsBase, defaults: defaults)
        guard let data = defaults.data(forKey: key), data.count <= 4_096 else { return nil }
        return try? JSONDecoder().decode(VerifiedMassRecord.self, from: data)
    }

    static func save(_ record: VerifiedMassRecord, defaults: UserDefaults = .standard) {
        let key = AccountScopedLocalState.defaultsKey(base: defaultsBase, defaults: defaults)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }
}
