import Foundation
import Observation

// Real-device-only behaviour (MusicKit authorization, the subscription check,
// the Music app's player and the catalog) sits behind these protocols so the
// state machine below is unit tested with fakes (G7).

@MainActor
protocol FocusMusicAuthorizing {
    /// Reading the status never prompts.
    var currentStatus: FocusMusicAuthorization { get }
    /// Shows the system prompt. Call only from the person's tap.
    func request() async -> FocusMusicAuthorization
}

@MainActor
protocol FocusMusicSubscriptionChecking {
    func current() async throws -> FocusMusicSubscription
}

/// Drives the Music app (`SystemMusicPlayer`): PomoGem stays in the
/// foreground and has no audio session or background mode of its own.
@MainActor
protocol FocusMusicPlaying: AnyObject {
    var nowPlaying: FocusMusicNowPlaying { get }
    /// Replaces the Music app's queue with `source` and starts it. Throws
    /// `FocusMusicPlaybackError`.
    func play(_ source: FocusMusicSource) async throws
    func pause()
    func resume() async throws
    func skipToNext() async throws
    /// Registers one change handler; called only after authorization.
    func observe(_ onChange: @escaping @MainActor () -> Void)
}

@MainActor
protocol FocusMusicCatalogNaming {
    /// Catalog titles by source ID. Missing entries keep the fallback title.
    func titles(for sources: [FocusMusicSource]) async -> [String: String]
}

enum FocusMusicChoiceOutcome: Equatable, Sendable {
    case handled
    /// The sheet should show Apple's subscription offer.
    case presentOffer
}

/// Process-wide state for focus background music (Docs/FocusMusic.md). The
/// timer header button and `FocusMusicSheet` share it. Nothing here is
/// synced; the only stored values are the device-local keys in
/// `FocusMusicPreferences`.
@MainActor
@Observable
final class FocusMusicController {
    static let shared = FocusMusicController(
        authorizer: SystemFocusMusicAuthorizer(),
        subscriptions: SystemFocusMusicSubscriptions(),
        player: SystemFocusMusicPlayer(),
        catalog: SystemFocusMusicCatalog()
    )

    private(set) var authorization: FocusMusicAuthorization
    private(set) var subscription: FocusMusicSubscriptionState = .unknown
    private(set) var nowPlaying = FocusMusicNowPlaying()
    /// The source this process last queued in the Music app, if any.
    private(set) var queuedSourceID: String?
    private(set) var isBusy = false
    private(set) var hint: FocusMusicHint?
    private(set) var catalogTitles: [String: String] = [:]

    @ObservationIgnored private let authorizer: any FocusMusicAuthorizing
    @ObservationIgnored private let subscriptions: any FocusMusicSubscriptionChecking
    @ObservationIgnored private let player: any FocusMusicPlaying
    @ObservationIgnored private let catalog: any FocusMusicCatalogNaming
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isObservingPlayer = false
    @ObservationIgnored private var didLoadCatalogTitles = false
    @ObservationIgnored private var subscriptionCheck: Task<FocusMusicSubscriptionState, Never>?

    init(
        authorizer: any FocusMusicAuthorizing,
        subscriptions: any FocusMusicSubscriptionChecking,
        player: any FocusMusicPlaying,
        catalog: any FocusMusicCatalogNaming,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.authorizer = authorizer
        self.subscriptions = subscriptions
        self.player = player
        self.catalog = catalog
        self.defaults = defaults
        self.now = now
        authorization = authorizer.currentStatus
    }

    var availability: FocusMusicAvailability {
        FocusMusicAvailabilityPolicy.availability(
            authorization: authorization,
            subscription: subscription
        )
    }

    var isPlaying: Bool { nowPlaying.status == .playing }

    var chosenSource: FocusMusicSource? {
        FocusMusicPreferences.chosenSource(defaults: defaults)
    }

    /// The catalog's (localized) title when known, else our Japanese label.
    func title(for source: FocusMusicSource) -> String {
        catalogTitles[source.id] ?? source.fallbackTitle
    }

    // MARK: - Status

    /// Re-reads the authorization and, once authorized, the subscription.
    /// Never shows a prompt, so views may call it on appear.
    func refresh(forceSubscriptionCheck: Bool = false) async {
        guard refreshLocalState() else { return }
        switch subscription {
        case .unknown, .checking, .failed:
            await checkSubscription()
        case .known:
            if forceSubscriptionCheck { await checkSubscription() }
        }
    }

    /// Authorization and the Music app's state only: no network, no prompt.
    @discardableResult
    private func refreshLocalState() -> Bool {
        authorization = authorizer.currentStatus
        guard authorization == .authorized else {
            nowPlaying = FocusMusicNowPlaying()
            return false
        }
        startObservingPlayerIfNeeded()
        syncNowPlaying()
        return true
    }

    /// D4.3: the MusicKit prompt appears only from the person's tap.
    func requestAuthorization() async {
        authorization = authorizer.currentStatus
        if authorization == .notDetermined {
            authorization = await authorizer.request()
        }
        await refresh(forceSubscriptionCheck: true)
    }

    func loadCatalogTitlesIfNeeded() async {
        guard authorization == .authorized, !didLoadCatalogTitles else { return }
        didLoadCatalogTitles = true
        let titles = await catalog.titles(for: FocusMusicCatalog.sources)
        catalogTitles = titles.filter { !$0.value.isEmpty }
    }

    /// Concurrent callers (the sheet appearing while the timer button is
    /// tapped) share one request instead of racing two answers.
    private func checkSubscription() async {
        if let inFlight = subscriptionCheck {
            _ = await inFlight.value
            return
        }
        subscription = .checking
        let subscriptions = self.subscriptions
        let check = Task { @MainActor () -> FocusMusicSubscriptionState in
            do {
                return .known(try await subscriptions.current())
            } catch {
                return .failed
            }
        }
        subscriptionCheck = check
        let result = await check.value
        subscriptionCheck = nil
        subscription = result
    }

    // MARK: - Actions

    /// The timer header tap (D4.4a). Returns what it did so the button can
    /// open the sheet when playback is not possible from the timer alone.
    @discardableResult
    func handleHeaderTap() async -> FocusMusicHeaderAction {
        // Wait only for a first answer. After a failed check the tap opens
        // the sheet at once, and the sheet retries.
        switch subscription {
        case .unknown, .checking:
            await refresh()
        case .known, .failed:
            refreshLocalState()
        }
        let action = FocusMusicHeaderPolicy.action(
            availability: availability,
            chosen: chosenSource,
            nowPlaying: nowPlaying,
            queuedSourceID: queuedSourceID,
            isBusy: isBusy
        )
        switch action {
        case .play(let source):
            await startPlayback(from: source)
        case .pause:
            pause()
        case .resume:
            await resume()
        case .presentSheet, .ignore:
            break
        }
        return action
    }

    /// A row tap in the sheet: remember the choice, then play it when
    /// possible. A first tap may ask for permission (the person's own tap).
    @discardableResult
    func choose(_ source: FocusMusicSource) async -> FocusMusicChoiceOutcome {
        guard !isBusy else { return .handled }
        FocusMusicPreferences.setChosenSource(source, defaults: defaults)
        if availability == .needsAuthorization {
            await requestAuthorization()
        } else if availability == .checking || availability == .checkFailed {
            await refresh()
        }
        switch availability {
        case .ready:
            await startPlayback(from: source)
            return .handled
        case .checkFailed:
            // The subscription answer is missing (offline, or MusicKit could
            // not reach Apple). Playing is the real test, and it was the
            // person's own tap; a failure shows the usual gentle hint.
            await startPlayback(from: source)
            return .handled
        case .subscriptionOffer:
            return .presentOffer
        case .checking, .needsAuthorization, .denied, .restricted, .unavailable:
            return .handled
        }
    }

    /// The sheet's play/pause control.
    func togglePlayback() async {
        guard availability == .ready || isPlaying else { return }
        if isPlaying {
            pause()
            return
        }
        guard let chosen = chosenSource else { return }
        if queuedSourceID != nil,
           nowPlaying.status == .paused || nowPlaying.status == .interrupted {
            await resume()
        } else {
            await startPlayback(from: chosen)
        }
    }

    func pause() {
        guard authorization == .authorized else { return }
        player.pause()
        syncNowPlaying()
    }

    func skipToNext() async {
        guard authorization == .authorized, !isBusy else { return }
        do {
            try await player.skipToNext()
            hint = nil
        } catch {
            hint = .openMusicOnce
        }
        syncNowPlaying()
    }

    private func resume() async {
        guard authorization == .authorized else { return }
        do {
            try await player.resume()
            hint = nil
        } catch {
            hint = .openMusicOnce
        }
        syncNowPlaying()
    }

    /// Tries the chosen source, then the others in catalog order, moving on
    /// only when a source is missing from the storefront or needs the
    /// catalog. Any other failure stops with one gentle hint.
    private func startPlayback(from chosen: FocusMusicSource) async {
        guard authorization == .authorized, !isBusy else { return }
        isBusy = true
        defer {
            isBusy = false
            syncNowPlaying()
        }
        hint = nil
        for source in FocusMusicCatalog.fallbackOrder(startingWith: chosen) {
            do {
                try await player.play(source)
                queuedSourceID = source.id
                if case .failed = subscription {
                    // Catalog music just started, so this person can play it.
                    subscription = .known(FocusMusicSubscription(
                        canPlayCatalogContent: true,
                        canBecomeSubscriber: false
                    ))
                }
                return
            } catch let error as FocusMusicPlaybackError where error.triesNextSource {
                continue
            } catch let error as FocusMusicPlaybackError {
                await handle(error)
                return
            } catch {
                hint = .openMusicOnce
                return
            }
        }
        hint = .noSourceAvailable
    }

    private func handle(_ error: FocusMusicPlaybackError) async {
        switch error {
        case .permissionDenied:
            authorization = authorizer.currentStatus
            if authorization == .authorized { hint = .openMusicOnce }
        case .notSignedIn:
            hint = .signIn
        case .subscriptionRequired:
            await checkSubscription()
            if availability == .ready { hint = .openMusicOnce }
        case .failed, .notInStorefront, .needsCatalogAccess:
            hint = .openMusicOnce
        }
    }

    // MARK: - Autoplay

    /// D4.5: with 「集中を始めたら再生する」 on, a focus that has just started
    /// on this iPhone starts the chosen source once. It never prompts, never
    /// replaces music that is already playing, and never stops music later.
    func autoplayIfNeeded(
        sessionID: UUID?,
        startedAt: Date?,
        isStartedOnThisIPhone: Bool
    ) async {
        guard let sessionID,
              isStartedOnThisIPhone,
              FocusMusicPreferences.isAutoplayEnabled(defaults: defaults),
              chosenSource != nil,
              FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults) != sessionID
        else { return }
        await refresh()
        syncNowPlaying()
        let input = FocusMusicAutoplayPolicy.Input(
            isEnabled: FocusMusicPreferences.isAutoplayEnabled(defaults: defaults),
            chosen: chosenSource,
            availability: availability,
            sessionID: sessionID,
            startedAt: startedAt,
            isStartedOnThisIPhone: isStartedOnThisIPhone,
            now: now(),
            lastAutoplayedSessionID: FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults),
            playback: nowPlaying.status
        )
        guard FocusMusicAutoplayPolicy.shouldAutoplay(input),
              let chosen = input.chosen,
              !isBusy
        else { return }
        FocusMusicPreferences.recordAutoplay(sessionID: sessionID, defaults: defaults)
        await startPlayback(from: chosen)
    }

    // MARK: - Lifecycle

    /// Complete data deletion: the defaults cleaner removes the stored keys;
    /// this forgets what this process queued and any hint. The Music app
    /// itself is the person's and keeps playing.
    func resetForCompleteDataDeletion() {
        queuedSourceID = nil
        hint = nil
    }

    private func startObservingPlayerIfNeeded() {
        guard !isObservingPlayer, authorization == .authorized else { return }
        isObservingPlayer = true
        player.observe { [weak self] in
            self?.syncNowPlaying()
        }
    }

    private func syncNowPlaying() {
        guard authorization == .authorized else {
            nowPlaying = FocusMusicNowPlaying()
            return
        }
        let current = player.nowPlaying
        if current != nowPlaying { nowPlaying = current }
    }
}
