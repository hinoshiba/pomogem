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
/// foreground, and no music plays through PomoGem's own audio session or a
/// background audio mode.
@MainActor
protocol FocusMusicPlaying: AnyObject {
    var nowPlaying: FocusMusicNowPlaying { get }
    /// A queue-entry identity, never a track title. Nil means that this
    /// adapter cannot establish continuity with a queue it started earlier.
    var currentEntryID: String? { get }
    /// Whether any other app (including the Music app) is playing audio right
    /// now. Reading it activates nothing.
    var isOtherAudioPlaying: Bool { get }
    /// Replaces the Music app's queue with `source` and starts it. Autoplay
    /// rechecks other audio after preparation, before changing the queue.
    func play(
        _ source: FocusMusicSource, shuffle: Bool, intent: FocusMusicPlaybackIntent
    ) async throws -> FocusMusicPlaybackStartOutcome
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
    func search(term: String) async throws -> [FocusMusicSource]
    /// Playlist metadata only. Paging never expands tracks or reads history.
    func libraryPlaylists(offset: Int, limit: Int) async throws -> [FocusMusicSource]
}

extension FocusMusicCatalogNaming {
    func search(term: String) async throws -> [FocusMusicSource] { [] }
    func libraryPlaylists(offset: Int, limit: Int) async throws -> [FocusMusicSource] { [] }
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
    /// The requested choice can differ from the actual curated fallback.
    private var queuedChoiceID: String?
    @ObservationIgnored private var queuedEntryID: String?
    @ObservationIgnored private var choiceGeneration = 0
    private struct PausedPlayback {
        let entryID: String
        let choiceID: String?
    }
    @ObservationIgnored private var pausedPlayback: PausedPlayback?
    private(set) var isBusy = false
    private(set) var hint: FocusMusicHint?
    private(set) var catalogTitles: [String: String] = [:]
    private(set) var preferenceRevision = 0

    @ObservationIgnored private let authorizer: any FocusMusicAuthorizing
    @ObservationIgnored private let subscriptions: any FocusMusicSubscriptionChecking
    @ObservationIgnored private let player: any FocusMusicPlaying
    @ObservationIgnored private let catalog: any FocusMusicCatalogNaming
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isObservingPlayer = false
    @ObservationIgnored private var didLoadCatalogTitles = false
    @ObservationIgnored private var subscriptionCheck: Task<Void, Never>?
    /// A pause tapped while a start was in flight: the start ends paused.
    @ObservationIgnored private var pausesPendingStart = false

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

    var chosenSource: FocusMusicSource? { chosenSource(for: nil) }

    func chosenSource(for subjectID: UUID? = nil) -> FocusMusicSource? {
        _ = preferenceRevision
        return FocusMusicPreferences.chosenSource(subjectID: subjectID, defaults: defaults)
    }

    func subjectSource(for subjectID: UUID) -> FocusMusicSource? {
        _ = preferenceRevision
        return FocusMusicPreferences.subjectSource(for: subjectID, defaults: defaults)
    }

    var savedSources: [FocusMusicSource] {
        _ = preferenceRevision
        return FocusMusicPreferences.savedSources(defaults: defaults)
    }

    func saveSource(_ source: FocusMusicSource) {
        FocusMusicPreferences.saveSource(source, defaults: defaults)
        preferenceRevision += 1
    }

    func removeSavedSource(_ source: FocusMusicSource) {
        FocusMusicPreferences.removeSavedSource(source, defaults: defaults)
        preferenceRevision += 1
    }

    func clearSubjectSource(_ subjectID: UUID) {
        FocusMusicPreferences.setChosenSource(nil, subjectID: subjectID, defaults: defaults)
        preferenceRevision += 1
    }

    func subjectSettings(for subjectID: UUID) -> FocusMusicSubjectSettings {
        FocusMusicSubjectSettings(
            source: subjectSource(for: subjectID),
            autoplay: subjectAutoplayOverride(for: subjectID)
        )
    }

    /// Commit the editor draft without changing the Music app's playback.
    func setSubjectSettings(_ settings: FocusMusicSubjectSettings, for subjectID: UUID) {
        FocusMusicPreferences.setChosenSource(settings.source, subjectID: subjectID, defaults: defaults)
        if let autoplay = settings.autoplay {
            FocusMusicPreferences.setAutoplayEnabled(autoplay, subjectID: subjectID, defaults: defaults)
        } else {
            FocusMusicPreferences.clearSubjectAutoplay(subjectID, defaults: defaults)
        }
        preferenceRevision += 1
    }

    func isAutoplayEnabled(for subjectID: UUID? = nil) -> Bool {
        _ = preferenceRevision
        return FocusMusicPreferences.isAutoplayEnabled(subjectID: subjectID, defaults: defaults)
    }

    func setAutoplayEnabled(_ enabled: Bool, for subjectID: UUID? = nil) {
        FocusMusicPreferences.setAutoplayEnabled(enabled, subjectID: subjectID, defaults: defaults)
        preferenceRevision += 1
    }

    func subjectAutoplayOverride(for subjectID: UUID) -> Bool? {
        _ = preferenceRevision
        return FocusMusicPreferences.subjectAutoplayOverride(for: subjectID, defaults: defaults)
    }

    func clearSubjectAutoplay(_ subjectID: UUID) {
        FocusMusicPreferences.clearSubjectAutoplay(subjectID, defaults: defaults)
        preferenceRevision += 1
    }

    /// Called only by the person's library-selection button. Loading the
    /// list never saves it; only a subsequent committed choice is stored.
    func libraryPlaylists() async throws -> [FocusMusicSource] {
        if authorizer.currentStatus == .notDetermined { await requestAuthorization() }
        guard refreshLocalState() else { throw FocusMusicPlaybackError.permissionDenied }
        var result: [FocusMusicSource] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await catalog.libraryPlaylists(offset: offset, limit: 100)
            try Task.checkCancellation()
            guard !page.isEmpty else { return result }
            let additions = page.filter { seen.insert($0.id).inserted }
            // A provider repeating the same page must not loop forever or
            // silently claim that a truncated list is the whole library.
            guard !additions.isEmpty else { throw FocusMusicPlaybackError.failed }
            result.append(contentsOf: additions)
            offset += page.count
        }
    }

    /// Search is called by an explicit button; appearing never prompts.
    func search(term: String) async throws -> [FocusMusicSource] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        if authorizer.currentStatus == .notDetermined { await requestAuthorization() }
        guard refreshLocalState() else { throw FocusMusicPlaybackError.permissionDenied }
        return try await catalog.search(term: term)
    }

    /// What a timer header tap would do with the state as it is now. The
    /// button's icon and VoiceOver label follow it, so they never promise a
    /// pause that the tap would not perform.
    var headerAction: FocusMusicHeaderAction { headerAction(for: nil) }

    func headerAction(for subjectID: UUID?) -> FocusMusicHeaderAction {
        FocusMusicHeaderPolicy.action(
            availability: availability,
            chosen: chosenSource(for: subjectID),
            nowPlaying: nowPlaying,
            queuedSourceID: resumableQueueID(for: subjectID),
            isBusy: isBusy
        )
    }

    /// What the sheet's play/pause button would do now.
    var transportToggle: FocusMusicTransportPolicy.Toggle { transportToggle(for: nil) }

    func transportToggle(for subjectID: UUID?) -> FocusMusicTransportPolicy.Toggle {
        FocusMusicTransportPolicy.toggle(
            availability: availability,
            chosen: chosenSource(for: subjectID),
            nowPlaying: nowPlaying,
            queuedSourceID: resumableQueueID(for: subjectID)
        )
    }

    private func resumableQueueID(for subjectID: UUID?) -> String? {
        if let pausedPlayback,
           pausedPlayback.choiceID == chosenSource(for: subjectID)?.id,
           pausedPlayback.entryID == player.currentEntryID,
           nowPlaying.status == .paused || nowPlaying.status == .interrupted {
            return pausedPlayback.entryID
        }
        guard let chosen = chosenSource(for: subjectID) else { return queuedSourceID }
        return queuedChoiceID == chosen.id ? queuedSourceID : nil
    }

    var showsNowPlaying: Bool {
        FocusMusicTransportPolicy.showsNowPlaying(
            availability: availability,
            nowPlaying: nowPlaying
        )
    }

    /// The catalog's (localized) title when known, else our Japanese label.
    func title(for source: FocusMusicSource) -> String {
        source.customTitle ?? catalogTitles[source.id] ?? source.fallbackTitle
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
        let titles = await catalog.titles(for: FocusMusicCatalog.sources + savedSources)
        catalogTitles = titles.filter { !$0.value.isEmpty }
    }

    /// Concurrent callers (the sheet appearing while the timer button is
    /// tapped) share one request instead of racing two answers. The shared
    /// task stores the answer itself before it finishes, so every caller,
    /// whichever resumes first, reads the new answer when its await returns.
    private func checkSubscription() async {
        if let inFlight = subscriptionCheck {
            await inFlight.value
            return
        }
        subscription = FocusMusicSubscriptionPolicy.stateWhileChecking(subscription)
        let subscriptions = self.subscriptions
        // Created and stored before this function suspends, and the main
        // actor runs the task only after that, so it clears its own slot.
        let check = Task { @MainActor [weak self] in
            let result: FocusMusicSubscriptionState
            do {
                result = .known(try await subscriptions.current())
            } catch {
                result = .failed
            }
            guard let self else { return }
            subscriptionCheck = nil
            subscription = FocusMusicSubscriptionPolicy.stateAfterCheck(
                subscription,
                result: result
            )
        }
        subscriptionCheck = check
        await check.value
    }

    // MARK: - Actions

    /// The timer header tap (D4.4a). Returns what it did so the button can
    /// open the sheet when playback is not possible from the timer alone.
    @discardableResult
    func handleHeaderTap(subjectID: UUID? = nil) async -> FocusMusicHeaderAction {
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
            chosen: chosenSource(for: subjectID),
            nowPlaying: nowPlaying,
            queuedSourceID: resumableQueueID(for: subjectID),
            isBusy: isBusy
        )
        switch action {
        case .play(let source):
            await startPlayback(from: source)
        case .pause:
            pause(subjectID: subjectID)
        case .resume:
            await resume()
        case .presentSheet, .ignore:
            break
        }
        return action
    }

    /// Whether the timer button should open the sheet after a tap that
    /// performed `action`: also when a play or resume did not work.
    func presentsSheet(after action: FocusMusicHeaderAction) -> Bool {
        FocusMusicHeaderPolicy.presentsSheet(
            after: action,
            availability: availability,
            hint: hint,
            isPlaying: isPlaying
        )
    }

    /// A row tap in the sheet: remember the choice, then play it when
    /// possible. A first tap may ask for permission (the person's own tap).
    @discardableResult
    func choose(_ source: FocusMusicSource, subjectID: UUID? = nil) async -> FocusMusicChoiceOutcome {
        guard !isBusy else { return .handled }
        choiceGeneration &+= 1
        let generation = choiceGeneration
        FocusMusicPreferences.setChosenSource(source, subjectID: subjectID, defaults: defaults)
        preferenceRevision += 1
        refreshLocalState()
        if availability == .needsAuthorization {
            await requestAuthorization()
        } else if availability == .checking || availability == .checkFailed {
            await refresh()
        }
        // Rows stay selectable while the initial subscription answer is
        // pending. Only the latest explicit choice may start when it arrives.
        guard !Task.isCancelled, generation == choiceGeneration else { return .handled }
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
    func togglePlayback(subjectID: UUID? = nil) async {
        switch transportToggle(for: subjectID) {
        case .pause:
            pause(subjectID: subjectID)
        case .resume:
            await resume()
        case .play(let chosen):
            await startPlayback(from: chosen)
        case .unavailable:
            break
        }
    }

    /// Always allowed once authorized, even while a start is in flight: the
    /// person's pause wins, and that start then ends paused.
    func pause(subjectID: UUID? = nil) {
        guard authorization == .authorized else { return }
        choiceGeneration &+= 1
        if isBusy { pausesPendingStart = true }
        player.pause()
        syncNowPlaying()
        // A queue may have naturally advanced beyond the entry we started.
        // Our own pause still identifies precisely what this control should
        // resume, provided neither the selected source nor entry changes.
        pausedPlayback = player.currentEntryID.map {
            PausedPlayback(entryID: $0, choiceID: chosenSource(for: subjectID)?.id)
        }
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
    private func startPlayback(
        from chosen: FocusMusicSource, intent: FocusMusicPlaybackIntent = .manual
    ) async {
        guard !Task.isCancelled, authorization == .authorized, !isBusy else { return }
        syncNowPlaying()
        // Re-selecting the same station or playlist continues its queue.
        // Replacing it on every tap restarts many radio programs from zero.
        if queuedChoiceID == chosen.id {
            switch nowPlaying.status {
            case .playing:
                hint = nil
                return
            case .paused, .interrupted:
                await resume()
                return
            case .stopped:
                break
            }
        }
        isBusy = true
        pausesPendingStart = false
        defer {
            isBusy = false
            pausesPendingStart = false
            syncNowPlaying()
        }
        hint = nil
        for source in FocusMusicCatalog.fallbackOrder(startingWith: chosen) {
            // Paused while an earlier source was being tried: start nothing.
            if pausesPendingStart { return }
            do {
                // A failed start may already have replaced the Music app's
                // queue. Never treat it as our previous successful choice.
                queuedSourceID = nil
                queuedChoiceID = nil
                queuedEntryID = nil
                pausedPlayback = nil
                let outcome = try await player.play(
                    source,
                    shuffle: source.supportsShuffle && FocusMusicPreferences.isShuffleEnabled(defaults: defaults),
                    intent: intent
                )
                // Audio started elsewhere while the source was loading.
                // Leave it alone, without a hint, fallback, or queue claim.
                guard outcome == .started else { return }
                queuedSourceID = source.id
                queuedChoiceID = chosen.id
                queuedEntryID = player.currentEntryID
                if case .known = subscription {} else {
                    // Catalog music just started, so this person can play
                    // it. A later failed re-check keeps this answer.
                    subscription = .known(FocusMusicSubscription(
                        canPlayCatalogContent: true,
                        canBecomeSubscriber: false
                    ))
                }
                if pausesPendingStart { player.pause() }
                return
            } catch is CancellationError {
                return
            } catch let error as FocusMusicPlaybackError where error.triesNextSource {
                guard !Task.isCancelled else { return }
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
    /// replaces music or other audio (another app's podcast or music) that is
    /// already playing, and never stops music later.
    func autoplayIfNeeded(
        sessionID: UUID?,
        startedAt: Date?,
        isStartedOnThisIPhone: Bool,
        subjectID: UUID? = nil
    ) async {
        guard let sessionID,
              isStartedOnThisIPhone,
              FocusMusicPreferences.isAutoplayEnabled(subjectID: subjectID, defaults: defaults),
              chosenSource(for: subjectID) != nil,
              FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults) != sessionID
        else { return }
        await refresh()
        // SwiftUI cancels the start task when the timer pauses, ends, or
        // disappears. The shared subscription task can still finish normally.
        guard !Task.isCancelled else { return }
        syncNowPlaying()
        let input = FocusMusicAutoplayPolicy.Input(
            isEnabled: FocusMusicPreferences.isAutoplayEnabled(subjectID: subjectID, defaults: defaults),
            chosen: chosenSource(for: subjectID),
            availability: availability,
            sessionID: sessionID,
            startedAt: startedAt,
            isStartedOnThisIPhone: isStartedOnThisIPhone,
            now: now(),
            lastAutoplayedSessionID: FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults),
            playback: nowPlaying.status,
            isOtherAudioPlaying: player.isOtherAudioPlaying
        )
        guard FocusMusicAutoplayPolicy.shouldAutoplay(input),
              let chosen = input.chosen,
              !isBusy
        else { return }
        FocusMusicPreferences.recordAutoplay(sessionID: sessionID, defaults: defaults)
        await startPlayback(from: chosen, intent: .autoplay)
    }

    // MARK: - Lifecycle

    /// Complete data deletion: the defaults cleaner removes the stored keys;
    /// this forgets what this process queued and any hint. The Music app
    /// itself is the person's and keeps playing.
    func resetForCompleteDataDeletion() {
        queuedSourceID = nil
        queuedChoiceID = nil
        queuedEntryID = nil
        pausedPlayback = nil
        hint = nil
        catalogTitles = [:]
        didLoadCatalogTitles = false
        preferenceRevision += 1
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
        if let pausedPlayback,
           pausedPlayback.entryID != player.currentEntryID
            || (current.status != .paused && current.status != .interrupted) {
            self.pausedPlayback = nil
        }
        if queuedChoiceID != nil,
           queuedEntryID == nil || queuedEntryID != player.currentEntryID {
            // SystemMusicPlayer does not expose its full queue. A different
            // entry (including natural advance), or an adapter without entry
            // identity, cannot prove that it still contains our chosen source.
            queuedSourceID = nil
            queuedChoiceID = nil
            queuedEntryID = nil
        }
        if current != nowPlaying { nowPlaying = current }
    }
}
