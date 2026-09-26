import Foundation

// Pure model and policy for focus background music (Docs/FocusMusic.md).
// Nothing here touches MusicKit or MediaPlayer, so every decision is unit
// tested with fakes; the system adapters live in FocusMusicSystemAdapters.

/// One Apple-curated source. Only `id` is ever stored (device-local
/// `music.focus.source`). MusicKit `Playlist` and `Station` values are
/// resolved at playback time and never persisted.
struct FocusMusicSource: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case playlist
        case station
    }

    /// Apple Music catalog ID: `pl.` for a playlist, `ra.` for a station.
    /// Apple's editorial IDs are global across storefronts.
    let id: String
    /// Shown whenever the catalog title cannot be read (no MusicKit developer
    /// token yet, offline). It is Apple's Japanese storefront title.
    let fallbackTitle: String

    var kind: Kind { id.hasPrefix("ra.") ? .station : .playlist }
}

enum FocusMusicCatalog {
    /// Verified in the JP and US storefronts on 2026-09-26, in fallback order.
    /// Apple can rename or retire editorial items without notice, so each ID
    /// is resolved at runtime and a missing one falls through to the next.
    static let sources: [FocusMusicSource] = [
        FocusMusicSource(
            id: "pl.cf8514b686374fadbe6807a6339dfd89",
            fallbackTitle: String(
                localized: "作業用BGM：クラシック",
                table: "Focus",
                comment: "Apple Music Classical playlist title (US storefront: Classical Concentration)"
            )
        ),
        FocusMusicSource(
            id: "ra.985486574",
            fallbackTitle: String(
                localized: "クラシックステーション",
                table: "Focus",
                comment: "Apple Music station title (US storefront: Classical Station)"
            )
        ),
        FocusMusicSource(
            id: "pl.cb4d1c09a2df4230a78d0395fe1f8fde",
            fallbackTitle: String(
                localized: "ピアノ・チル",
                table: "Focus",
                comment: "Apple Music Classical playlist title (US storefront: Piano Chill)"
            )
        ),
        FocusMusicSource(
            id: "pl.f6ab843650ff4d6aafbd96de3a0b8a13",
            // A meaningful key (Docs/Localization.md): 「集中」 alone is the
            // focus phase ("Focus") in the app; here it is a playlist name.
            fallbackTitle: String(
                localized: "focus-music.source.concentration",
                defaultValue: "集中",
                table: "Focus",
                comment: "Apple Music Focus playlist title (US storefront: Concentration)"
            )
        ),
        FocusMusicSource(
            id: "pl.9b8a976ba78741d9925e6e9a050703de",
            fallbackTitle: String(
                localized: "穏やかに集中するとき",
                table: "Focus",
                comment: "Apple Music Focus playlist title (US storefront: Peaceful Focus)"
            )
        ),
    ]

    static func source(id: String?) -> FocusMusicSource? {
        guard let id, !id.isEmpty else { return nil }
        return sources.first { $0.id == id }
    }

    /// The chosen source first, then every other source in catalog order.
    static func fallbackOrder(startingWith chosen: FocusMusicSource) -> [FocusMusicSource] {
        [chosen] + sources.filter { $0.id != chosen.id }
    }
}

/// Device-local choices (G3: never synced, never exported). Complete data
/// deletion clears the whole standard defaults domain, which includes these.
enum FocusMusicPreferences {
    static let sourceKey = "music.focus.source"
    static let autoplayKey = "music.focus.autoplay"
    /// The focus session autoplay last started music for, so a relaunch,
    /// recovery or resume of the same session never starts it again.
    static let autoplayedSessionKey = "music.focus.autoplay.last-session"
    static let allKeys = [sourceKey, autoplayKey, autoplayedSessionKey]

    /// 「集中を始めたら再生する」 is opt-in (App Review 4.5.2: playback is
    /// user-initiated; starting a focus with the toggle on counts).
    static let defaultAutoplay = false

    /// An ID this build does not list (a retired source) reads as no choice.
    static func chosenSource(defaults: UserDefaults = .standard) -> FocusMusicSource? {
        FocusMusicCatalog.source(id: defaults.string(forKey: sourceKey))
    }

    static func setChosenSource(_ source: FocusMusicSource?, defaults: UserDefaults = .standard) {
        if let source {
            defaults.set(source.id, forKey: sourceKey)
        } else {
            defaults.removeObject(forKey: sourceKey)
        }
    }

    static func isAutoplayEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoplayKey) as? Bool ?? defaultAutoplay
    }

    static func setAutoplayEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: autoplayKey)
    }

    static func lastAutoplayedSessionID(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: autoplayedSessionKey).flatMap(UUID.init(uuidString:))
    }

    static func recordAutoplay(sessionID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(sessionID.uuidString, forKey: autoplayedSessionKey)
    }
}

enum FocusMusicAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

struct FocusMusicSubscription: Equatable, Sendable {
    var canPlayCatalogContent: Bool
    var canBecomeSubscriber: Bool
}

enum FocusMusicSubscriptionState: Equatable, Sendable {
    case unknown
    case checking
    case known(FocusMusicSubscription)
    case failed
}

/// What the music sheet and the timer button can offer right now.
enum FocusMusicAvailability: Equatable, Sendable {
    /// Authorized; the subscription answer is still on its way.
    case checking
    /// Ask only when the person taps (never from autoplay or on appear).
    case needsAuthorization
    case denied
    case restricted
    /// The subscription could not be read (offline, signed out).
    case checkFailed
    /// No catalog playback, but Apple's subscription offer sheet can help.
    case subscriptionOffer
    /// No catalog playback and no offer: play controls are hidden.
    case unavailable
    case ready
}

enum FocusMusicAvailabilityPolicy {
    static func availability(
        authorization: FocusMusicAuthorization,
        subscription: FocusMusicSubscriptionState
    ) -> FocusMusicAvailability {
        switch authorization {
        case .notDetermined:
            return .needsAuthorization
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorized:
            switch subscription {
            case .unknown, .checking:
                return .checking
            case .failed:
                return .checkFailed
            case .known(let subscription):
                if subscription.canPlayCatalogContent { return .ready }
                return subscription.canBecomeSubscriber ? .subscriptionOffer : .unavailable
            }
        }
    }
}

enum FocusMusicPlaybackStatus: Equatable, Sendable {
    case stopped
    case playing
    case paused
    case interrupted
}

struct FocusMusicNowPlaying: Equatable, Sendable {
    var status: FocusMusicPlaybackStatus = .stopped
    /// The Music app's current entry, when it reports one.
    var title: String?
}

/// Playback failures the adapters report. Only the first two let the
/// controller move on to the next source.
enum FocusMusicPlaybackError: Error, Equatable, Sendable {
    /// The catalog has no such item in this storefront (or it was retired).
    case notInStorefront
    /// A station needs a MusicKit catalog lookup, which needs the developer
    /// token (MusicKit App Service on the App ID). Playlists fall back to the
    /// MediaPlayer store-ID queue instead.
    case needsCatalogAccess
    case permissionDenied
    case notSignedIn
    case subscriptionRequired
    case failed

    var triesNextSource: Bool {
        self == .notInStorefront || self == .needsCatalogAccess
    }
}

/// How a MusicKit catalog lookup or play request failed, before routing.
enum FocusMusicCatalogFailure: Equatable, Sendable {
    /// `MusicTokenRequestError.developerTokenRequestFailed`, or the Apple
    /// Music API refusing the token (HTTP 401/403): the App Service is off.
    case developerTokenUnavailable
    case notFound
    case permissionDenied
    case notSignedIn
    case other
}

enum FocusMusicCatalogRoute: Equatable, Sendable {
    /// `MPMusicPlayerController.systemMusicPlayer.setQueue(with: [id])`.
    case mediaPlayerQueue
    case fail(FocusMusicPlaybackError)
}

enum FocusMusicCatalogRoutePolicy {
    /// D4.1: without the developer token only playlists can still play, by
    /// store ID through MediaPlayer. Stations need their catalog playParams.
    static func route(
        for source: FocusMusicSource,
        after failure: FocusMusicCatalogFailure
    ) -> FocusMusicCatalogRoute {
        switch failure {
        case .developerTokenUnavailable:
            return source.kind == .playlist ? .mediaPlayerQueue : .fail(.needsCatalogAccess)
        case .notFound:
            return .fail(.notInStorefront)
        case .permissionDenied:
            return .fail(.permissionDenied)
        case .notSignedIn:
            return .fail(.notSignedIn)
        case .other:
            return .fail(.failed)
        }
    }
}

/// A gentle, factual line under the controls. Never urgent, never blaming.
enum FocusMusicHint: Equatable, Sendable {
    /// iOS 26.4-era Music updates can block third-party playback until the
    /// Music app is opened once. Leaving PomoGem mid-focus may pause the
    /// timer, so the copy suggests a break.
    case openMusicOnce
    case noSourceAvailable
    case signIn

    var message: String {
        switch self {
        case .openMusicOnce:
            String(
                localized: "再生を始められませんでした。休憩のときなどに「ミュージック」アプリを一度開いてから、もう一度お試しください。",
                table: "Focus"
            )
        case .noSourceAvailable:
            String(
                localized: "この地域のApple Musicでは、用意した音楽を再生できませんでした。",
                table: "Focus"
            )
        case .signIn:
            String(
                localized: "「ミュージック」アプリでApple Musicにサインインすると再生できます。",
                table: "Focus"
            )
        }
    }
}

/// What a tap on the timer header's music button does.
enum FocusMusicHeaderAction: Equatable, Sendable {
    case presentSheet
    case play(FocusMusicSource)
    case pause
    case resume
    /// A start is already in flight; ignore the tap.
    case ignore
}

enum FocusMusicHeaderPolicy {
    /// D4.4(a): play/pause the chosen source when ready; otherwise open the
    /// sheet, which owns permission, subscription and choice.
    static func action(
        availability: FocusMusicAvailability,
        chosen: FocusMusicSource?,
        nowPlaying: FocusMusicNowPlaying,
        queuedSourceID: String?,
        isBusy: Bool
    ) -> FocusMusicHeaderAction {
        if isBusy { return .ignore }
        // Music that is playing can always be paused from the timer, even if
        // the subscription answer is still pending.
        if availability == .ready || availability == .checking,
           nowPlaying.status == .playing {
            return .pause
        }
        guard availability == .ready, let chosen else { return .presentSheet }
        switch nowPlaying.status {
        case .playing:
            return .pause
        case .paused, .interrupted:
            // Continue what this process queued; anything else is replaced
            // by the chosen source.
            return queuedSourceID == nil ? .play(chosen) : .resume
        case .stopped:
            return .play(chosen)
        }
    }
}

enum FocusMusicAutoplayPolicy {
    /// A focus whose start is older than this is a recovery, handoff or
    /// resume, not a start (D4.5 counts only a start).
    static let freshStartWindow: TimeInterval = 15
    /// Tolerates a start stamped slightly after the view's clock read.
    static let futureStartTolerance: TimeInterval = 2

    struct Input: Equatable, Sendable {
        var isEnabled: Bool
        var chosen: FocusMusicSource?
        var availability: FocusMusicAvailability
        var sessionID: UUID?
        var startedAt: Date?
        /// False for a focus continued from iCloud (another iPhone started
        /// it, even if only seconds ago).
        var isStartedOnThisIPhone: Bool
        var now: Date
        var lastAutoplayedSessionID: UUID?
        var playback: FocusMusicPlaybackStatus
    }

    /// Autoplay never asks for permission and never replaces music that is
    /// already playing; each focus session starts music at most once.
    static func shouldAutoplay(_ input: Input) -> Bool {
        guard input.isEnabled,
              input.chosen != nil,
              input.availability == .ready,
              input.isStartedOnThisIPhone,
              let sessionID = input.sessionID,
              sessionID != input.lastAutoplayedSessionID,
              let startedAt = input.startedAt,
              input.playback != .playing
        else { return false }
        let age = input.now.timeIntervalSince(startedAt)
        return age <= freshStartWindow && age >= -futureStartTolerance
    }
}
