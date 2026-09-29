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

    /// Whether Home's own sum is the whole lifetime while pending: no
    /// aggregate is accepted then, so only a complete candidate page that
    /// fits in the jar's cap covers every session. A page of an earlier
    /// presentation generation proves nothing about the current one (Home
    /// withholds its sessions), and claiming coverage for it presented
    /// 「この端末で確認済み 0粒」 as an exact total (device-verify-2 P2).
    static func deviceCoversEverySession(
        pageIsCurrent: Bool,
        pageIsComplete: Bool,
        membershipIsComplete: Bool,
        acceptedAggregateCount: Int,
        candidateCount: Int,
        presentedCount: Int
    ) -> Bool {
        pageIsCurrent
            && pageIsComplete
            && membershipIsComplete
            && acceptedAggregateCount == 0
            && candidateCount == presentedCount
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

/// device-verify-2 P2. What the jar's lifetime readout, its time core and the
/// menu show while Home re-derives them.
///
/// Home reads its session page asynchronously, and every change of the
/// presentation generation — trust revoked for an import or the app's own
/// save, the rolling check, verification completing — retires the page it
/// holds until the new one is read. The jar keeps its gems through that gap
/// (`HomeView.syncScene`), but the readout was computed from the empty page:
/// for about a second after a return to the app the phone said 「再集計中」
/// over 「この端末で確認済み 0粒」 and the time core vanished, which is what
/// sync-03 decided must never replace a value this device can show.
///
/// Every pass therefore takes its readout from one `Source`:
/// - settled inputs (the page is current and no read is retiring a complete
///   one) are presented live, and remembered;
/// - while Home re-derives, the last remembered readout stays on screen as a
///   whole — headline, count, time core and its colour, the crystals and
///   fusion progress the jar describes — so no surface mixes it with the
///   empty page. It is presented under 「iCloudを確認中」 when it was recorded
///   so or Home is pending now: verification completing does not make a
///   pending total a verified one, and once trust is revoked a verified total
///   is only what this device confirmed;
/// - before this Home has presented anything from settled inputs (a launch,
///   or a remount after the background grace) it shows no number at all
///   rather than 「再集計中」 or 0粒: the jar has no gems yet either;
/// - after a failed read, what the inputs prove, as conservative as ever:
///   nothing is in flight that would replace a held value.
///
/// A held readout never crosses into another reset epoch, and nothing is
/// written, exported or shared from it: the verified-mass record reads
/// settled inputs only, and the reward card freezes its values from live
/// inputs, which the policies above keep conservative while unsettled.
enum LifetimeReadoutContinuityPolicy {
    /// Everything the jar and the menu say about the lifetime total.
    struct Readout: Equatable, Sendable {
        /// Presented as while iCloud is checked: 「iCloudを確認中」, 「この端末で
        /// 確認済み N粒」 and the pending VoiceOver wording, no fusion progress.
        var isCloudVerificationPending: Bool
        /// Before this Home's first settled readout: no number is shown.
        var isLoading = false
        /// The jar's headline and VoiceOver mass; nil says 「再集計中」.
        var jarGrams: Int?
        /// The mass the jar's time core is drawn from.
        var jarCoreGrams: Int
        var jarPebbles: Int
        /// The gems the jar's VoiceOver value counts as loose (瓶の整理).
        var jarLoosePebbles: Int
        /// The menu's mass and count, which count saved sessions at once.
        var menuGrams: Int?
        var menuPebbles: Int
        var isLowerBound: Bool
        var jarIsEmpty: Bool
        var coreColorHex: String
        var coreColorShares: [GemColorShare]
        /// The crystals and rare gems the jar's VoiceOver value names.
        var aggregateCount = 0
        var legacyAggregateCount = 0
        var goldPebbleCount = 0
        var prismPebbleCount = 0

        /// The landed totals the time core's progress is described from — the
        /// pre-fusion rail, the jar's VoiceOver and the large-text card — so
        /// they always describe the headline's snapshot. A verified readout's
        /// only: nil while iCloud is checked and before the first read.
        var fusionProgressTotals: HomeProjectionPolicy.Totals? {
            guard !isCloudVerificationPending, !isLoading, let jarGrams else { return nil }
            return .init(grams: jarGrams, pebbleCount: jarPebbles)
        }

        /// Before the first settled readout: nothing claimed, not even an
        /// empty jar.
        static func loading(isCloudVerificationPending: Bool, coreColorHex: String) -> Readout {
            Readout(isCloudVerificationPending: isCloudVerificationPending, isLoading: true,
                    jarGrams: nil, jarCoreGrams: 0, jarPebbles: 0, jarLoosePebbles: 0,
                    menuGrams: nil, menuPebbles: 0, isLowerBound: true, jarIsEmpty: false,
                    coreColorHex: coreColorHex, coreColorShares: [])
        }
    }

    /// A readout presented from settled inputs, and the reset epoch it
    /// describes.
    struct Settled: Equatable, Sendable {
        let readout: Readout
        let epochID: UUID?
    }

    /// Where a pass takes its readout from.
    enum Source: Equatable {
        /// Settled inputs: present them, and remember what is presented.
        case settled
        /// Present the inputs as they are, without remembering them.
        case live
        /// Keep this readout on screen while Home re-derives it.
        case held(Readout)
        /// Nothing presented from settled inputs yet.
        case loading
    }

    /// - Parameters:
    ///   - inputsAreSettled: Home's page belongs to the current presentation
    ///     generation and no read is retiring a complete one.
    ///   - lastReadFailed: the latest read of the page failed and no other has
    ///     started since.
    static func source(
        inputsAreSettled: Bool,
        lastReadFailed: Bool,
        lastSettled: Settled?,
        currentEpochID: UUID?,
        isCloudVerificationPending: Bool
    ) -> Source {
        if inputsAreSettled { return .settled }
        // Nothing in flight would replace a held value: say what the inputs
        // prove (「再集計中」 or a lower bound), never an old total for good.
        if lastReadFailed { return .live }
        guard let lastSettled else { return .loading }
        // Records were reset since: the new epoch's value is re-derived.
        guard lastSettled.epochID == currentEpochID else { return .live }
        var readout = lastSettled.readout
        readout.isCloudVerificationPending = readout.isCloudVerificationPending
            || isCloudVerificationPending
        return .held(readout)
    }
}

/// Keeps `LifetimeReadoutContinuityPolicy.Settled` for Home without observing
/// it. The jar's stage records the readout it presents, on each of Home's
/// passes and on each landing, which re-runs only the stage (`JarStageReader`
/// in HomeView); storing it in observed state would re-evaluate the whole of
/// Home once more each time (device-verify-2 P4 measured that pass at about
/// 100 ms on an iPhone 12 mini). The value is only read by a later pass that
/// something else already invalidated.
@MainActor
final class SettledLifetimeReadoutBox {
    var value: LifetimeReadoutContinuityPolicy.Settled?
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
