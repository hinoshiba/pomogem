import Foundation
import CoreGraphics

/// A ten-minute distraction unit has its own decimal hierarchy. These values
/// are presentation only: they never become StudySession or AggregatePebble.
struct ScreenTimeObstacleDescriptor: Identifiable, Equatable, Sendable {
    let level: Int
    let slot: Int
    let representedUnits: Int
    let isHistoryPile: Bool

    var id: UUID {
        // A private namespace prevents collision with the study stream. Ordinary
        // roots retain identity as later units arrive; a compact history pile
        // changes identity only when its exact represented amount changes.
        let value = UInt64(representedUnits)
        return UUID(uuid: (
            0x53, 0x54, 0x4F, 0x42, UInt8(level), UInt8(slot),
            isHistoryPile ? 0x41 : 0x40, 0x80,
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ))
    }

    var radius: CGFloat {
        isHistoryPile ? 26 : 10 + CGFloat(min(level, 5)) * 2.6
    }

    var accessibilityDescription: String {
        "寄り道の黒い石、10分の石\(representedUnits.formatted())個分。勉強の積み上げには含まれません"
    }
}

enum ScreenTimeObstacleProjection {
    static let fusionFanIn = 10
    static let maximumVisibleBodies = 36
    static let maximumDecimalRoots = String(Int.max).count * 9

    /// At most nine roots remain at every level. Division avoids overflowing
    /// when the input reaches Int.max; the power advances only if needed.
    static func decimalRoots(totalUnits: Int) -> [ScreenTimeObstacleDescriptor] {
        var remaining = max(0, totalUnits)
        var power = 1
        var level = 0
        var result: [ScreenTimeObstacleDescriptor] = []
        while remaining > 0 {
            let digit = remaining % fusionFanIn
            for slot in 0..<digit {
                result.append(ScreenTimeObstacleDescriptor(
                    level: level,
                    slot: slot,
                    representedUnits: power,
                    isHistoryPile: false
                ))
            }
            remaining /= fusionFanIn
            if remaining > 0 {
                power *= fusionFanIn
                level += 1
            }
        }
        return result
    }

    /// Keep recent, small roots individually touchable. When decades of roots
    /// would exceed the physics budget, one history body represents the exact
    /// remaining black roots. This is a bounded view of the same hierarchy,
    /// not another fusion rule or a loss of recorded distraction time.
    static func visibleDescriptors(totalUnits: Int) -> [ScreenTimeObstacleDescriptor] {
        let roots = decimalRoots(totalUnits: totalUnits)
        guard roots.count > maximumVisibleBodies else { return roots }
        let visible = Array(roots.prefix(maximumVisibleBodies - 1))
        let remainder = roots.dropFirst(visible.count)
        let units = remainder.reduce(0) { $0 + $1.representedUnits }
        return visible + [ScreenTimeObstacleDescriptor(
            level: remainder.first?.level ?? 0,
            slot: 0,
            representedUnits: units,
            isHistoryPile: true
        )]
    }
}

extension PebbleDescriptor {
    init(screenTimeObstacle obstacle: ScreenTimeObstacleDescriptor) {
        self.init(
            id: obstacle.id,
            subjectName: "寄り道",
            colorHex: "27262D",
            source: .manual,
            kind: .normal,
            grams: 0,
            radius: obstacle.radius,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            screenTimeObstacle: obstacle
        )
    }
}
