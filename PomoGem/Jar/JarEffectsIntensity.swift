import CoreGraphics
import Foundation
import UIKit

/// 演出の強さ (Docs/GemExperienceDesign.md §7.6, §7.10, D17): how much light
/// and motion the jar's rewards use on this iPhone.
///
/// - 標準 (`standard`) shows every effect, exactly as before the setting.
/// - 控えめ (`subtle`) keeps the same gems, grams, cuts and fusions, but has
///   no spontaneous twinkle, no tilt glints (one static star per gem, the
///   Reduce Motion star), lighter halos, no slow breathing, and shorter
///   landing and fusion beats.
///
/// Reduce Motion always implies 控えめ (`resolved`). The preference is a
/// device-local display setting, like the timer's default orientation: it
/// lives in `UserDefaults.standard` under one key that is not per account,
/// never synced and not part of any schema, and a data reset keeps it (the
/// rare-reward "quiet" mode is a separate, synced choice).
enum JarEffectsIntensity: String, CaseIterable, Identifiable, Sendable {
    case standard
    case subtle

    var id: String { rawValue }

    static let defaultsKey = "jar.effects-intensity"

    /// The stored preference; anything unknown reads as 標準.
    static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .standard
    }

    /// What the device shows: Reduce Motion implies 控えめ.
    static func resolved(preference: Self, reduceMotion: Bool) -> Self {
        reduceMotion ? .subtle : preference
    }

    /// For art drawn outside a window (share-card export), where SwiftUI's
    /// environment may not carry the system setting: the stored preference
    /// under the environment's or the system's Reduce Motion.
    @MainActor
    static func current(
        reduceMotionEnvironment: Bool,
        defaults: UserDefaults = .standard
    ) -> Self {
        resolved(
            preference: stored(in: defaults),
            reduceMotion: reduceMotionEnvironment || UIAccessibility.isReduceMotionEnabled
        )
    }

    var isSubtle: Bool { self == .subtle }

    // MARK: Light

    /// Spontaneous flares (§7.6: at most three at once, 0.6 s apart).
    var allowsSpontaneousTwinkle: Bool { self == .standard }
    /// Glints that catch the light as the phone tilts. 控えめ keeps one
    /// static star per gem instead (`PebbleNode.reducedMotionStarAlpha`).
    var allowsTiltGlints: Bool { self == .standard }
    /// Slow repeating breaths (crystal and early-effort auras, the time
    /// core, the Overview crystal, the share GIF's stone).
    var allowsBreathing: Bool { self == .standard }
    /// Additive halos: the gems' halo and early-effort light, the core's
    /// bloom, lobes and girdle bloom, the static star, and the share and
    /// fusion-sheet glows.
    var haloScale: CGFloat { self == .standard ? 1 : 0.70 }
    /// Softer lights that give a gem its body (the large gems' inner light,
    /// the colourless vessel's light): dimmed less than halos.
    var innerGlowScale: CGFloat { self == .standard ? 1 : 0.80 }

    // MARK: Landing

    /// One landing (§7.10): the gem's halo swells once, a few sparks leave
    /// the contact point, the pile light swells and the camera shakes.
    struct LandingBeat: Equatable, Sendable {
        let haloRise: TimeInterval
        let haloFall: TimeInterval
        /// How far the swell goes from the resting halo toward 0.95 (1 = all
        /// the way).
        let haloSwell: CGFloat
        /// The gem's first star flares once as it lands.
        let flaresStar: Bool
        /// Multiplies the spark and dust counts (at least one each).
        let particleShare: CGFloat
        /// Multiplies the spark and dust lifetimes.
        let particleLifetimeScale: CGFloat
        /// Multiplies how far the sparks travel.
        let particleReach: CGFloat
        /// Peak of the pile-light swell (× its resting alpha).
        let pileSwell: CGFloat
        let pileSwellRise: TimeInterval
        let pileSwellFall: TimeInterval
        /// Multiplies the camera shake's amplitude.
        let cameraShake: CGFloat
        let cameraShakeDuration: TimeInterval

        /// The landing light's spark count for a gem that would show
        /// `standardCount` sparks at 標準.
        func sparkCount(standard standardCount: Int) -> Int {
            max(1, Int((CGFloat(standardCount) * particleShare).rounded(.down)))
        }

        /// The last moment anything of the beat still moves (seconds).
        var duration: TimeInterval {
            max(
                haloRise + haloFall,
                0.52 * particleLifetimeScale,
                pileSwellRise + pileSwellFall,
                cameraShakeDuration
            )
        }
    }

    var landing: LandingBeat {
        switch self {
        case .standard:
            LandingBeat(
                haloRise: 0.08,
                haloFall: 0.36,
                haloSwell: 1,
                flaresStar: true,
                particleShare: 1,
                particleLifetimeScale: 1,
                particleReach: 1,
                pileSwell: 1.12,
                pileSwellRise: 0.12,
                pileSwellFall: 0.28,
                cameraShake: 1,
                cameraShakeDuration: Constants.Jar.dustLifetime
            )
        case .subtle:
            LandingBeat(
                haloRise: 0.06,
                haloFall: 0.20,
                haloSwell: 0.5,
                flaresStar: false,
                particleShare: 0.5,
                particleLifetimeScale: 0.6,
                particleReach: 0.7,
                pileSwell: 1.06,
                pileSwellRise: 0.08,
                pileSwellFall: 0.16,
                cameraShake: 0.5,
                cameraShakeDuration: 0.4
            )
        }
    }

    // MARK: Fusion

    /// Ten gems becoming one crystal in the jar (§7.10): the ten converge,
    /// then the finale of the crystal's grams tier (A0 only fades in).
    struct FusionBeat: Equatable, Sendable {
        /// The ten fade and converge on their centre.
        let formation: TimeInterval
        /// A0 (under 2.5 kg): the new gem fades in.
        let fadeIn: TimeInterval
        /// A1+: the white flash (2.2R) fades from this alpha.
        let flashAlpha: CGFloat
        let flashDuration: TimeInterval
        /// A1+: the shock ring grows from 1R to this many radii.
        let ringScale: CGFloat
        let ringDuration: TimeInterval
        /// A1+: the crystal springs from this share of its size.
        let birthStart: CGFloat
        /// Peak of the spring (1 = no overshoot).
        let birthOvershoot: CGFloat
        let birthGrow: TimeInterval
        let birthSettle: TimeInterval
        /// A2+: shards thrown out of the flash (0 = none).
        let shardCount: Int
        let shardLifetime: TimeInterval

        /// Formation plus the longest finale part (A2+ at 標準).
        var duration: TimeInterval {
            formation + max(
                flashDuration,
                ringDuration,
                birthGrow + birthSettle,
                shardCount > 0 ? shardLifetime : 0,
                fadeIn
            )
        }
    }

    var fusion: FusionBeat {
        switch self {
        case .standard:
            FusionBeat(
                formation: Constants.Jar.aggregateFormationDuration,
                fadeIn: 0.2,
                flashAlpha: 1,
                flashDuration: 0.16,
                ringScale: 3,
                ringDuration: 0.42,
                birthStart: 0.6,
                birthOvershoot: 1.08,
                birthGrow: 0.20,
                birthSettle: 0.18,
                shardCount: 12,
                shardLifetime: 0.6
            )
        case .subtle:
            FusionBeat(
                formation: 0.32,
                fadeIn: 0.12,
                flashAlpha: 0.55,
                flashDuration: 0.10,
                ringScale: 2.2,
                ringDuration: 0.26,
                birthStart: 0.85,
                birthOvershoot: 1,
                birthGrow: 0.22,
                birthSettle: 0,
                shardCount: 0,
                shardLifetime: 0
            )
        }
    }

    // MARK: Fusion sheet

    /// The fusion sheet's orbit (`FusionOrbitStage`): the newest source
    /// pops in, the ten pull toward the crystal (which swells) and let go.
    struct FusionSheetBeat: Equatable, Sendable {
        /// Delay before the ten pull in.
        let convergenceDelay: TimeInterval
        /// How long the pull holds before the ten let go.
        let convergenceHold: TimeInterval
        /// How long the release takes to settle before the rays fade.
        let releaseHold: TimeInterval
        /// The crystal's swell at the pull.
        let coreSwell: CGFloat
        /// Orbit radius at the pull (share of the stage).
        let convergedOrbit: CGFloat
        /// The four white rays behind the crystal.
        let showsRays: Bool
        /// Springs (標準) or short eases (控えめ).
        let usesSprings: Bool

        var duration: TimeInterval { convergenceDelay + convergenceHold + releaseHold }
    }

    var fusionSheet: FusionSheetBeat {
        switch self {
        case .standard:
            FusionSheetBeat(
                convergenceDelay: 0.22,
                convergenceHold: 0.43,
                releaseHold: 0.26,
                coreSwell: 1.16,
                convergedOrbit: 0.285,
                showsRays: true,
                usesSprings: true
            )
        case .subtle:
            FusionSheetBeat(
                convergenceDelay: 0.12,
                convergenceHold: 0.24,
                releaseHold: 0.16,
                coreSwell: 1.06,
                convergedOrbit: 0.345,
                showsRays: false,
                usesSprings: false
            )
        }
    }
}
