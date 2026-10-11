import Foundation

/// A visual portion of credited focus time, never an owner of study records.
/// Stable, reserved IDs let a crystal keep its position while new time arrives.
struct TimeFusionUnit: Identifiable, Equatable, Sendable {
    let level: Int
    let grams: Int
    let ordinal: Int

    var id: UUID {
        let value = UInt64(max(0, grams))
        return UUID(uuid: (
            0x54, 0x49, 0x4D, 0x45, UInt8(clamping: level), UInt8(clamping: ordinal),
            0x46, 0x80,
            UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
        ))
    }
}

struct TimeFusionSnapshot: Equatable, Sendable {
    let totalGrams: Int
    let remainderGrams: Int
    let crystals: [TimeFusionUnit]

    var representedGrams: Int {
        NonnegativeIntPolicy.sum(crystals.map(\.grams) + [remainderGrams])
    }

    var nextCrystalRemainingGrams: Int {
        TimeFusionPolicy.firstCrystalGrams - remainderGrams
    }

    /// Even a malformed Int.max total remains within the physics budget. The
    /// last summary preserves the exact time of the least significant roots.
    var visibleCrystals: [TimeFusionUnit] {
        let limit = TimeFusionPolicy.maximumVisibleCrystals
        guard crystals.count > limit else { return crystals }
        let descending = crystals.sorted { $0.level > $1.level }
        let kept = Array(descending.prefix(limit - 1))
        let overflow = NonnegativeIntPolicy.sum(descending.dropFirst(limit - 1).map(\.grams))
        return kept + [TimeFusionUnit(level: 0, grams: overflow, ordinal: 254)]
    }
}

struct TimeFusionTransition: Equatable, Sendable {
    let beforeGrams: Int
    let afterGrams: Int
    let destinationLevel: Int
    /// Newly crossed 250-minute boundaries, including those carried upward.
    let newCrystalCount: Int
}

/// Display composition depends only on total credited time. No session is
/// split, mutated or claimed by these units; the existing tree stays a bounded
/// history index. Ten 10-minute records and two 50-minute records yield the
/// identical snapshot, including the exact remainder for the next crystal.
enum TimeFusionPolicy {
    static let firstCrystalGrams = 250 * Constants.Mass.gramsPerMinute
    static let maximumVisibleCrystals = 63
    static let colorHex = Constants.Color.auroraCool

    static func snapshot(totalGrams rawGrams: Int) -> TimeFusionSnapshot {
        let grams = max(0, rawGrams)
        var remaining = grams / firstCrystalGrams
        var unitGrams = firstCrystalGrams
        var level = 1
        var crystals: [TimeFusionUnit] = []
        while remaining > 0 {
            for ordinal in 0..<(remaining % 10) {
                crystals.append(TimeFusionUnit(level: level, grams: unitGrams, ordinal: ordinal))
            }
            remaining /= 10
            if remaining > 0 {
                // The quotient proves the next power fits in the input Int.
                unitGrams *= 10
                level += 1
            }
        }
        return TimeFusionSnapshot(
            totalGrams: grams,
            remainderGrams: grams % firstCrystalGrams,
            crystals: crystals
        )
    }

    static func transition(from rawBefore: Int, to rawAfter: Int) -> TimeFusionTransition? {
        let before = max(0, rawBefore)
        let after = max(0, rawAfter)
        let earned = after / firstCrystalGrams - before / firstCrystalGrams
        guard earned > 0 else { return nil }
        var level = 1
        var threshold = firstCrystalGrams
        while threshold <= Int.max / 10 {
            let next = threshold * 10
            guard after / next > before / next else { break }
            level += 1
            threshold = next
        }
        return TimeFusionTransition(
            beforeGrams: before, afterGrams: after,
            destinationLevel: level, newCrystalCount: earned
        )
    }

    static func isProjectionID(_ id: UUID) -> Bool {
        let bytes = id.uuid
        return bytes.0 == 0x54 && bytes.1 == 0x49 && bytes.2 == 0x4D
            && bytes.3 == 0x45 && bytes.6 == 0x46 && bytes.7 == 0x80
    }
}
