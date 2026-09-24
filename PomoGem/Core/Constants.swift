import CoreGraphics
import Foundation

/// Product-wide tuning values. Keep numerical tuning here so the feel of the
/// app can be adjusted without hunting for magic numbers in feature code.
enum Constants {
    enum App {
        static let maximumSubjects = 12
        static let subjectColorSaturation = 0.62
        static let subjectColorBrightness = 0.80
    }

    enum Timer {
        static let twentyFiveMinutes = 25
        static let fortyFiveMinutes = 45
        static let sixtyMinutes = 60
        static let ninetyMinutes = 90
        static let shortBreakMinutes = 5
        static let longBreakMinutes = 15
        static let focusSetsBeforeLongBreak = 4
        static let secondsPerMinute = 60
        static let gramsPerMinute = Mass.gramsPerMinute
        static let customMinimumMinutes = 1
        static let customMaximumMinutes = 360

#if DEBUG
        static let demoSeconds = 12
#endif
    }

    enum Mass {
        static let gramsPerMinute = 10
        static let measuredPebbleGrams = 250
        static let manualThirtyMinutes = 30
        static let manualSixtyMinutes = 60
        static let manualOneTwentyMinutes = 120
        static let manualMinutes = [
            manualThirtyMinutes,
            manualSixtyMinutes,
            manualOneTwentyMinutes
        ]
    }

    enum Fairness {
        static let dayBoundaryHour = 4
        static let manualEntriesPerDay = 3
        static let interruptionGrace: TimeInterval = 20
        static let clockTolerance: TimeInterval = 90
        static let bedrockMaximumHours = 9_999
    }

    enum Gacha {
        static let goldProbability = 0.08
        static let prismProbability = 0.008
        /// Random reward participation follows the same mass accounting as the
        /// jar: every accumulated 250g of measured focus earns one draw. The
        /// unfinished fraction carries across timer completions.
        static let creditGrams = Mass.measuredPebbleGrams
        static let creditRuleVersion = 1
        /// Reject the 12-second DEBUG demo and malformed recovery envelopes;
        /// the shortest product timer is one measured minute.
        static let minimumMeasuredSeconds = Timer.secondsPerMinute
        /// A persisted focus completion is bounded by the timer's public
        /// maximum. Keeping the draw batch bounded also makes malformed legacy
        /// recovery payloads safe to process without an unbounded RNG loop.
        static let maximumCreditableGramsPerCompletion =
            Timer.customMaximumMinutes * Mass.gramsPerMinute
        /// Retained only for reconciling history produced by versions where
        /// one 25-minute-or-longer completion meant one draw. New draws use
        /// `creditGrams`, not this duration gate.
        static let minimumEligibleSeconds = Timer.twentyFiveMinutes * Timer.secondsPerMinute
        /// A gold pebble is guaranteed after this many earned draw credits
        /// without gold. In other words, the following credit is pity.
        static let pityMissCount = 20
    }

    enum Jar {
        static let defaultSceneWidth: CGFloat = 390
        static let height: CGFloat = 420
        static let horizontalMargin: CGFloat = 16
        static let wallInset: CGFloat = 12
        static let floorInset: CGFloat = 10
        static let cornerRadius: CGFloat = 26
        static let glassFillOpacity = 0.055

        static let gravity: CGFloat = -7.2
        static let gravityVector = CGVector(dx: 0, dy: gravity)
        static let tiltGravityHorizontalScale: CGFloat = 7.2
        static let tiltGravityMinimumDownward: CGFloat = 2.2
        static let maximumExternalGravityMagnitude: CGFloat = 9.4
        static let gravitySmoothingFactor: CGFloat = 0.16
        static let restitution: CGFloat = 0.06
        static let friction: CGFloat = 0.5
        static let linearDamping: CGFloat = 0.30
        static let angularDamping: CGFloat = 0.50
        static let allowsRotation = true

        static let measuredRadius: CGFloat = 11.5
        static let manualThirtyRadius: CGFloat = 11
        static let manualSixtyRadius: CGFloat = 14
        static let manualOneTwentyRadius: CGFloat = 17

        /// Commemorative stones are deliberately larger than a normal focus
        /// pebble, but only a small rotating selection remains in the live jar.
        /// They do not contribute study mass and never become strata.
        static let achievementRadiusScale: CGFloat = 1.30
        static let maximumVisibleAchievementStones = 12

        /// Loose study pebbles and movable aggregate pebbles share this ceiling.
        /// Hierarchical roll-up keeps a multi-year jar comfortably below it.
        static let maxPhysicsBodies = 128
        static let aggregateCapacityUnits = 120.0
        static let postAggregateCapacityUnits = 72.0
        /// Decimal hierarchy: ten study pebbles become ×10, ten ×10 pebbles
        /// become ×100, and so on. The count remains instantly understandable.
        static let aggregateFanIn = 10
        static let minimumAggregateFanIn = aggregateFanIn
        static let aggregateBaseRadius: CGFloat = 18
        static let aggregateRadiusStep: CGFloat = 2.5
        static let aggregateMaximumRadius: CGFloat = 28
        static let maximumVisibleAggregateRoots = 48
        static let minimumRecentAggregateRoots = 12
        static let aggregateFormationDuration: TimeInterval = 0.52
        static let aggregateBirthImpulse: CGFloat = 2.4
        static let aggregateInteriorDotCount = 18
        static let aggregateInteriorDotScale: CGFloat = 0.13
        static let aggregateRingWidth: CGFloat = 1.25

        // Compatibility aliases for the former fixed-stratum implementation.
        // New code aggregates into a movable body instead of raising the floor.
        static let bakeThreshold = 120
        static let bakeCount = 48
        static let bakeCapacityUnits = aggregateCapacityUnits
        static let postBakeCapacityUnits = postAggregateCapacityUnits
        static let strataPackingFactor = 0.82
        static let bakeAnimationDuration: TimeInterval = 0.45
        static let bakePebbleFinalScale: CGFloat = 0.35
        static let targetFramesPerSecond = 60
        static let tiltUpdatesPerSecond = 30

        static let dropInterval: TimeInterval = 0.180
        static let dropHorizontalRangeFraction: CGFloat = 0.15
        static let dropHorizontalSpeed: CGFloat = 0.4
        static let dropVerticalSpeed: CGFloat = -1.8
        static let touchRadius: CGFloat = 48

        static let shakeHorizontalImpulse: CGFloat = 3.5
        static let shakeVerticalImpulseMin: CGFloat = 2
        static let shakeVerticalImpulseMax: CGFloat = 4.5
        /// Hard velocity ceilings keep a shake bounded even when a very small
        /// body already carries momentum. The impulse is still divided by
        /// radius-derived mass before these limits are applied, preserving the
        /// visibly heavier response of aggregate gems.
        static let shakeMaximumHorizontalVelocity: CGFloat = 120
        static let shakeMaximumVerticalVelocity: CGFloat = 140
        static let nudgeCooldown: TimeInterval = 0.45
        /// `CMDeviceMotion.userAcceleration` is expressed in g with gravity
        /// removed. A direction reversal above this peak separates an
        /// intentional jar shake from ordinary tilt or a single table bump.
        static let deviceShakeThreshold = 0.90
        static let deviceShakeReversalWindow: TimeInterval = 0.420
        static let deviceShakeReversalDotMaximum = -0.05
        static let deviceShakeRearmThreshold = 0.50
        static let deviceShakeRearmDuration: TimeInterval = 0.150
        static let deviceShakeCooldown: TimeInterval = 0.8
        static let deviceShakeHapticGuard: TimeInterval = 0.5
        static let systemShakeFallbackStrength: CGFloat = 0.78
        static let interactionCollisionMuteDuration: TimeInterval = 0.20
        static let interactionCollisionFollowUpDuration: TimeInterval = 0.80
        static let interactionCollisionMaximumSounds = 2
        static let interactionCollisionMaximumHaptics = 1

        /// A deliberate tap/shake opens a short-lived physical window. Gems
        /// can collide and find a new resting arrangement during the first
        /// three seconds, but sensor noise can never keep the jar awake
        /// indefinitely.
        static let idleWindow: TimeInterval = 3
        static let interactionHardStopDelay: TimeInterval = 5
        static let idleMovementThreshold: CGFloat = 0.5
        static let interactionSettlingDamping: CGFloat = 0.72
        static let restingDamping: CGFloat = 0.997

        static let completionDropDelay: TimeInterval = 0.350
        static let dropSpawnDelay = completionDropDelay
        static let screenShakeMaxAmplitude: CGFloat = 6
        static let screenShakeBaseAmplitude: CGFloat = 2
        static let screenShakeDecay: CGFloat = 0.85
        static let dustCount = 6
        static let dustLifetime: TimeInterval = 0.9
        static let dustRadiusScale: CGFloat = 0.13
        static let dustOpacity = 0.46
        static let dustDistanceBase: CGFloat = 1.4
        static let dustDistanceStep: CGFloat = 0.35
        static let dustVerticalScale: CGFloat = 0.4
        static let dustFinalScale: CGFloat = 0.15
        static let minimumLandingSpeed: CGFloat = 0.8

        static let goldSparkCount = 8
        static let goldPreDropDuration: TimeInterval = 0.4
        static let rareTwinkleInterval: TimeInterval = 2
        /// Faceted study gems: one deterministic star flare at most every
        /// interval while the scene is awake. The idle pause still freezes
        /// the jar after it settles, so a resting jar costs no extra frames.
        static let gemTwinkleInterval: TimeInterval = 0.45
        static let maximumConcurrentGemTwinkles = 6
        static let goldTwinkleProbability = 0.14
        static let prismTwinkleProbability = 0.20
        static let sparkFontScale: CGFloat = 0.72
        static let sparkDistanceScale: CGFloat = 0.72
        static let sparkFinalScale: CGFloat = 0.25
        static let moteRadiusScale: CGFloat = 0.12
        static let moteGlowScale: CGFloat = 0.25
        static let twinkleFontScale: CGFloat = 0.65
        static let twinkleFinalScale: CGFloat = 0.2

        static let bedrockBaseHeight: CGFloat = 14
        static let bedrockHoursDivisor: CGFloat = 40
        static let bedrockMinHeight: CGFloat = 18
        static let bedrockMaxHeight: CGFloat = 46

        // Archived effort is permanent data, but it must not permanently take over
        // the live physics chamber. Bedrock and every baked stratum share this one
        // bounded visual shelf; their full history remains available in SwiftData.
        static let archiveMaximumHeight: CGFloat = 72
        static let archiveMaximumFraction: CGFloat = 0.22
        static let bedrockMaximumRenderedHeight: CGFloat = 20

        // Visual texture values are initial art-direction tuning.
        static let outlineWidth: CGFloat = 2
        static let manualDashCount = 14
        static let manualSaturationReduction = 0.15
        static let speckleCount = 8
        static let tutorialOpacity = 0.42
        static let measuredStrokeOpacity = 0.95
        static let manualStrokeOpacity = 0.35
        static let goldGlowScale: CGFloat = 0.45
        static let prismStrokeOpacity = 0.9
        static let prismGlowScale: CGFloat = 0.35
        static let achievementStrokeWidth: CGFloat = 3
        static let achievementGlowScale: CGFloat = 0.22
    }

    enum Sound {
        static let sampleRate = 44_100.0
        static let maxVoices = 8
        static let secondaryCollisionCooldown: TimeInterval = 0.120

        static let thudBaseFrequencies = [82.0, 90.0, 98.0]
        static let thudEndFrequency = 45.0
        static let thudDuration: TimeInterval = 0.120
        static let thudDecay: TimeInterval = 0.045
        static let thudNoiseDuration: TimeInterval = 0.040
        static let thudNoiseLowPass = 900.0
        static let thudPitchVariation: Float = 0.04
        static let thudMinVolume: Float = 0.25
        static let thudVelocityDivisor: Float = 7.0
        static let brownNoiseMix = 0.35
        static let brownNoiseStep = 0.025

        static let tickFrequency = 240.0
        static let tickDuration: TimeInterval = 0.040
        static let tickVolume = 0.12
        static let tickDecayRate = 6.0

        // A struck-glass/gem timbre synthesized at runtime. Pitch shifting the
        // same bounded family keeps large stones low and small stones bright
        // without shipping third-party recordings or generated audio assets.
        static let gemClinkBaseFrequency = 1_100.0
        static let gemClinkDuration: TimeInterval = 0.140
        static let gemClinkVariantCount = 4
        static let gemClinkModalRatios = [1.0, 2.17, 3.81, 5.43]
        static let gemClinkModalAmplitudes = [1.0, 0.50, 0.23, 0.10]
        static let gemClinkStrikeNoiseDuration: TimeInterval = 0.0025
        static let gemMinimumCollisionSpeed: CGFloat = 0.32

        static let chimeE5 = 659.0
        static let chimeA5 = 880.0
        static let chimeFirstDuration: TimeInterval = 0.200
        static let chimeGap: TimeInterval = 0.130
        static let chimeSecondDuration: TimeInterval = 0.250
        static let attack: TimeInterval = 0.005
        static let decay: TimeInterval = 0.350
        static let chimeGain = 0.72

        static let goldCarrier = 1_568.0
        static let goldRatio = 3.01
        static let goldModulationIndex = 40.0
        static let goldModulationDuration: TimeInterval = 0.350
        static let goldVolume = 0.5

        static let prismFrequencies = [1_568.0, 1_975.0, 2_349.0]
        static let prismArpeggioInterval: TimeInterval = 0.060
    }

    enum Haptics {
        static let landingIntensityBase: Float = 0.35
        static let landingVelocityDivisor: Float = 8.0
        static let landingIntensityMin: Float = 0.4
        static let landingIntensityMax: Float = 1.0
        static let landingSharpness: Float = 0.25

        static let secondaryIntensity: Float = 0.2
        static let secondarySharpness: Float = 0.4

        static let goldTransientIntensity: Float = 0.6
        static let goldTransientSharpness: Float = 0.8
        static let goldContinuousDuration: TimeInterval = 0.080
        static let goldContinuousIntensity: Float = 0.3
        static let goldContinuousSharpness: Float = 0.1
        static let prismBeatInterval: TimeInterval = 0.055
        static let prismBeatIntensities: [Float] = [0.46, 0.62, 0.82]
        static let prismBeatSharpness: [Float] = [0.82, 0.62, 0.42]

        static let shakeDuration: TimeInterval = 0.300
        static let shakeIntensity: Float = 0.25
        static let shakeSharpness: Float = 0.15
    }

    enum Share {
        static let feedWidth = 1_080
        static let feedHeight = 1_350
        static let storyWidth = 1_080
        static let storyHeight = 1_920
        static let massFontSize: CGFloat = 58
        static let completionChipDelay: TimeInterval = 5
        static let automaticPromptDailyLimit = 1
        static let targetRenderDuration: TimeInterval = 1
    }

    enum Notification {
        static let defaultReminderHour = 20
        static let defaultReminderMinute = 0
        static let dailyMaximum = 1
    }

    enum Typography {
        static let massSize: CGFloat = 34
        static let timerSize: CGFloat = 76
        static let headingSize: CGFloat = 17
        static let bodySize: CGFloat = 14
        static let captionSize: CGFloat = 11
        static let heavyWeight = 800
        static let headingWeight = 700
        static let bodyWeight = 500
    }

    enum Shape {
        static let cardCornerRadius: CGFloat = 16
        static let buttonCornerRadius: CGFloat = 12
        static let chipCornerRadius: CGFloat = 999
        static let spacingUnit: CGFloat = 8
    }

    enum Store {
        /// Product price configured for the Japanese storefront. The App Store
        /// remains authoritative and the paywall always renders displayPrice.
        static let proLifetimeYen = 100
        static let maximumJars = 5
    }

    enum Color {
        static let inkNight = "#141927"
        static let inkCard = "#1B2136"
        static let inkRaised = "#232A40"
        static let glassEdge = "#AAC3F0"
        static let glassEdgeOpacity = 0.35
        static let amberLamp = "#E8B44A"
        static let textWarm = "#F2EFE7"
        static let textMute = "#8B93AC"
        static let english = "#E85D4A"
        static let mathematics = "#4D7CDE"
        static let japanese = "#C25FA3"
        static let science = "#3FA57C"
        static let socialStudies = "#8A6FD1"
        static let pebbleGold = "#F5C542"
        static let rockBed = "#2A2F42"
        /// Shared Aurora material tokens. SwiftUI and SpriteKit both derive
        /// their lighting from these values so the brand has one physical world.
        static let auroraWarm = "#FF8A70"
        static let auroraCool = "#8ACBFF"
        static let auroraViolet = "#8068F6"
        static let glassAbsorption = "#101B38"
        static let floorGlow = "#5BA8FF"
    }

    /// User-facing copy fixed by the product specification.
    enum UIStrings {
        static let start = "集中をはじめる"
        static let resume = "再開する"
        static let pause = "一時停止"
        static let giveUp = "今日はここまで"
        static let jarEmptyTitle = "まだ空っぽ。"
        static let jarEmptyBody = "25分の集中で、ここにひと粒落ちる。"
        static let goldToast = "✦ 金のつぶが出た！ +250g"
        static let prismToast = "❖ 虹のつぶ！！ +250g"
        static let manualCapToast = "自己申告はこの端末で1日3回まで"
        static let fairnessNote = "自己申告のつぶは破線つき。総質量には入るが、シェアの既定は実測のみ。"
        static let interruptionNote = "画面を離れたので、この回は自己申告あつかいになった"
        static let processTerminatedNote = "アプリが終了したため、この回は積まれませんでした"
        static let bedrockCTA = "過去の集中を記録する"
        static let bedrockNote = "以前取り込んだ時間は記録として保持されます。"
        static let shareTag = "#ポモジェム"
        static let eveningNotification = "瓶が待ってる。今日のひと粒、積んでいく？"
        static let wrappedNotification = "今月の積み重ねを見てみよう。"
        static let paywallTitle = "ポモジェムPro"
        static let customDurationRange = "\(Timer.customMinimumMinutes)〜\(Timer.customMaximumMinutes)分"
        static let onboardingOne = "集中した時間は、消えて見えない。"
        static let onboardingTwo = "ポモジェムは25分を「1粒」に変えて、瓶に積む。"
        static let onboardingThree = "減らない。消えない。責めない。"

        static func dropToast(subject: String) -> String {
            "\(subject) +250g 積んだ"
        }

        static func goldToast(grams: Int) -> String {
            grams == Constants.Mass.measuredPebbleGrams
                ? goldToast
                : "✦ 金のつぶが出た！ +\(grams)g"
        }

        static func prismToast(grams: Int) -> String {
            grams == Constants.Mass.measuredPebbleGrams
                ? prismToast
                : "❖ 虹のつぶ！！ +\(grams)g"
        }

        static func manualToast(subject: String, grams: Int) -> String {
            "自己申告 \(subject) +\(grams)g"
        }

        static func strataToast(pebbleCount: Int) -> String {
            "\(pebbleCount)粒が、ひとつのまとまり粒になった"
        }

        static func bedrockToast(hours: Int) -> String {
            "過去の\(hours)時間を記録した"
        }
    }
}
