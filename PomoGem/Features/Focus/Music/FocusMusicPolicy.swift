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

    /// PomoGem may read and control the Music app's player (pause, resume,
    /// next), whatever the subscription says. Those are the Music app's
    /// standard controls and never replace what it plays.
    var isAuthorized: Bool {
        switch self {
        case .needsAuthorization, .denied, .restricted:
            false
        case .checking, .checkFailed, .subscriptionOffer, .unavailable, .ready:
            true
        }
    }

    /// A row tap in the sheet can lead to playback: it plays, asks for
    /// permission first, waits for or retries the subscription check, or
    /// opens Apple's offer. Otherwise (D4.3: no subscription and no offer, or
    /// no permission) the rows only remember a choice and show no play mark.
    var allowsRowPlayback: Bool {
        switch self {
        case .denied, .restricted, .unavailable:
            false
        case .checking, .needsAuthorization, .checkFailed, .subscriptionOffer, .ready:
            true
        }
    }
}

/// How a subscription check updates the stored answer. The sheet re-checks
/// every time it opens, so a check must never make a known answer worse.
enum FocusMusicSubscriptionPolicy {
    /// While a check runs, a known answer stays in place: the sheet does not
    /// flash a spinner, and a row or timer tap during the check plays at once.
    static func stateWhileChecking(
        _ current: FocusMusicSubscriptionState
    ) -> FocusMusicSubscriptionState {
        if case .known = current { return current }
        return .checking
    }

    /// A failed re-check (offline, or MusicKit unable to reach Apple) keeps a
    /// known answer, including one that playback itself proved. A successful
    /// check always wins, so a lapsed subscription is still noticed.
    static func stateAfterCheck(
        _ current: FocusMusicSubscriptionState,
        result: FocusMusicSubscriptionState
    ) -> FocusMusicSubscriptionState {
        if result == .failed, case .known = current { return current }
        return result
    }
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
    /// Music app is opened once. Leaving PomoGem mid-focus pauses the timer
    /// while the leave pause is on (F1), and a break is never paused, so the
    /// copy suggests a break.
    case openMusicOnce
    case noSourceAvailable
    /// Signing in happens in the Music app, so, as with `openMusicOnce`, the
    /// copy suggests a break rather than leaving a running focus (F1).
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
                localized: "休憩のときなどに「ミュージック」アプリでApple Musicにサインインすると、再生できるようになります。",
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
        // Music that is playing can always be paused from the timer: while
        // the subscription answer is pending, missing or negative (a
        // person's own library music), and while a start is in flight.
        if availability.isAuthorized, nowPlaying.status == .playing {
            return .pause
        }
        if isBusy { return .ignore }
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

    /// After a header tap: open the sheet when the tap asked for it, or when
    /// a play or resume did not work, so the gentle hint, Apple's offer or
    /// the permission card is seen instead of nothing happening (D4.3).
    static func presentsSheet(
        after action: FocusMusicHeaderAction,
        availability: FocusMusicAvailability,
        hint: FocusMusicHint?,
        isPlaying: Bool
    ) -> Bool {
        switch action {
        case .presentSheet:
            true
        case .play, .resume:
            hint != nil || (availability != .ready && !isPlaying)
        case .pause, .ignore:
            false
        }
    }
}

/// The sheet's play/pause button and now-playing card.
enum FocusMusicTransportPolicy {
    enum Toggle: Equatable, Sendable {
        case pause
        case resume
        case play(FocusMusicSource)
        /// Nothing to pause or resume, and the chosen source cannot start.
        case unavailable
    }

    /// Pause and resume work whatever the subscription says; starting the
    /// chosen source needs `.ready`.
    static func toggle(
        availability: FocusMusicAvailability,
        chosen: FocusMusicSource?,
        nowPlaying: FocusMusicNowPlaying,
        queuedSourceID: String?
    ) -> Toggle {
        guard availability.isAuthorized else { return .unavailable }
        switch nowPlaying.status {
        case .playing:
            return .pause
        case .paused, .interrupted:
            // Ready with nothing queued by this process: the chosen source
            // replaces the paused queue, as on the timer.
            if availability == .ready, queuedSourceID == nil, let chosen {
                return .play(chosen)
            }
            return .resume
        case .stopped:
            if availability == .ready, let chosen { return .play(chosen) }
            return .unavailable
        }
    }

    /// Always when ready. Otherwise only while the Music app has something to
    /// pause or resume, so music started earlier can still be paused here.
    static func showsNowPlaying(
        availability: FocusMusicAvailability,
        nowPlaying: FocusMusicNowPlaying
    ) -> Bool {
        availability == .ready
            || (availability.isAuthorized && nowPlaying.status != .stopped)
    }
}

/// When the timer's music sheet must be closed (#32 completion alarm).
enum FocusMusicSheetPolicy {
    /// The sheet closes this long before the end, so it is gone before the
    /// completion alarm starts and VoiceOver focus moves to its Stop control.
    static let closesBeforeEndSeconds = 1

    /// True from the last second of a running phase on, including after its
    /// end while the timer screen stays up (a break's end). False while idle
    /// or paused. The sheet is modal: under it the pinned Stop button, the
    /// VoiceOver focus move and Magic Tap on the timer would be out of reach.
    static func keepsSheetClosed(isRunning: Bool, remainingSeconds: Int) -> Bool {
        isRunning && remainingSeconds <= closesBeforeEndSeconds
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
        /// The Music app's own state.
        var playback: FocusMusicPlaybackStatus
        /// Any other app playing audio (a podcast, another music app). The
        /// Music app's non-mixable playback would interrupt it.
        var isOtherAudioPlaying: Bool
    }

    /// Autoplay never asks for permission and never replaces music or other
    /// audio that is already playing; each focus session starts music at
    /// most once.
    static func shouldAutoplay(_ input: Input) -> Bool {
        guard input.isEnabled,
              input.chosen != nil,
              input.availability == .ready,
              input.isStartedOnThisIPhone,
              let sessionID = input.sessionID,
              sessionID != input.lastAutoplayedSessionID,
              let startedAt = input.startedAt,
              input.playback != .playing,
              !input.isOtherAudioPlaying
        else { return false }
        let age = input.now.timeIntervalSince(startedAt)
        return age <= freshStartWindow && age >= -futureStartTolerance
    }
}
