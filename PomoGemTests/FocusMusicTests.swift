import MediaPlayer
import MusicKit
import XCTest
@testable import PomoGem

/// Focus background music (Docs/FocusMusic.md): the curated catalog, the pure
/// policies, device-local storage and the controller's state machine driven
/// by fakes. MusicKit, the Music app and the subscription are real-device only.
@MainActor
final class FocusMusicTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    private var authorizer: FakeMusicAuthorizer!
    private var subscriptions: FakeMusicSubscriptions!
    private var player: FakeMusicPlayer!
    private var catalog: FakeMusicCatalog!
    private var clock: Date!

    override func setUp() async throws {
        try await super.setUp()
        domain = "FocusMusicTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        authorizer = FakeMusicAuthorizer(status: .authorized)
        subscriptions = FakeMusicSubscriptions()
        player = FakeMusicPlayer()
        catalog = FakeMusicCatalog()
        clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        authorizer = nil
        subscriptions = nil
        player = nil
        catalog = nil
        try await super.tearDown()
    }

    private func makeController() -> FocusMusicController {
        FocusMusicController(
            authorizer: authorizer,
            subscriptions: subscriptions,
            player: player,
            catalog: catalog,
            defaults: defaults,
            now: { [unowned self] in self.clock }
        )
    }

    private var sources: [FocusMusicSource] { FocusMusicCatalog.sources }
    private var classical: FocusMusicSource { sources[0] }
    private var station: FocusMusicSource { sources[1] }
    private var pianoChill: FocusMusicSource { sources[2] }

    // MARK: - Catalog

    func testCatalogListsTheVerifiedSourcesInFallbackOrder() {
        XCTAssertEqual(sources.map(\.id), [
            "pl.cf8514b686374fadbe6807a6339dfd89",
            "ra.985486574",
            "pl.cb4d1c09a2df4230a78d0395fe1f8fde",
            "pl.f6ab843650ff4d6aafbd96de3a0b8a13",
            "pl.9b8a976ba78741d9925e6e9a050703de",
        ])
        XCTAssertEqual(sources.map(\.kind), [.playlist, .station, .playlist, .playlist, .playlist])
        XCTAssertEqual(sources.map(\.fallbackTitle), [
            "作業用BGM：クラシック", "クラシックステーション", "ピアノ・チル", "集中", "穏やかに集中するとき",
        ])
    }

    func testFallbackOrderStartsWithTheChoiceThenKeepsCatalogOrder() {
        for chosen in sources {
            let order = FocusMusicCatalog.fallbackOrder(startingWith: chosen)
            XCTAssertEqual(order.first, chosen)
            XCTAssertEqual(order.count, sources.count)
            XCTAssertEqual(Set(order.map(\.id)), Set(sources.map(\.id)))
            XCTAssertEqual(Array(order.dropFirst()), sources.filter { $0 != chosen })
        }
    }

    func testUnknownOrEmptyIDReadsAsNoChoice() {
        XCTAssertNil(FocusMusicCatalog.source(id: nil))
        XCTAssertNil(FocusMusicCatalog.source(id: ""))
        XCTAssertNil(FocusMusicCatalog.source(id: "pl.retired"))
        defaults.set("pl.retired", forKey: FocusMusicPreferences.sourceKey)
        XCTAssertNil(FocusMusicPreferences.chosenSource(defaults: defaults))
    }

    // MARK: - Device-local storage

    func testPreferencesStoreOnlyTheSourceIDDeviceLocally() {
        XCTAssertTrue(FocusMusicPreferences.allKeys.allSatisfy { $0.hasPrefix("music.") })
        XCTAssertNil(FocusMusicPreferences.chosenSource(defaults: defaults))
        XCTAssertFalse(FocusMusicPreferences.isAutoplayEnabled(defaults: defaults), "autoplay is opt-in")

        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: FocusMusicPreferences.sourceKey) as? String, pianoChill.id)
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: defaults), pianoChill)

        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        XCTAssertTrue(FocusMusicPreferences.isAutoplayEnabled(defaults: defaults))

        let session = UUID()
        FocusMusicPreferences.recordAutoplay(sessionID: session, defaults: defaults)
        XCTAssertEqual(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults), session)

        FocusMusicPreferences.setChosenSource(nil, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: FocusMusicPreferences.sourceKey))
    }

    func testCompleteDataDeletionRemovesEveryMusicKey() throws {
        FocusMusicPreferences.setChosenSource(station, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        FocusMusicPreferences.recordAutoplay(sessionID: UUID(), defaults: defaults)

        try CompleteDataDeletionDefaultsCleaner.clear(defaults: defaults, persistentDomainName: domain)

        for key in FocusMusicPreferences.allKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertNil(FocusMusicPreferences.chosenSource(defaults: defaults))
        XCTAssertFalse(FocusMusicPreferences.isAutoplayEnabled(defaults: defaults))
        XCTAssertNil(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults))
    }

    func testCompleteDataDeletionResetForgetsWhatThisProcessQueued() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        let controller = makeController()
        await controller.handleHeaderTap()
        XCTAssertEqual(controller.queuedSourceID, classical.id)

        controller.resetForCompleteDataDeletion()

        XCTAssertNil(controller.queuedSourceID)
        XCTAssertNil(controller.hint)
        // A paused queue is no longer this process's: the next tap starts the
        // choice again instead of resuming.
        controller.pause()
        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))
    }

    func testTheAppDeclaresTheAppleMusicPurposeString() {
        // MusicAuthorization.request() terminates an app without this key.
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String,
            "タイマー画面から『ミュージック』アプリで集中用の音楽を再生するために使います。"
        )
    }

    // MARK: - Pure policies

    func testAvailabilityFollowsAuthorizationThenSubscription() {
        typealias Policy = FocusMusicAvailabilityPolicy
        let subscriber = FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false)
        let offer = FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true)
        let none = FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: false)
        for subscription in [FocusMusicSubscriptionState.unknown, .checking, .failed, .known(subscriber)] {
            XCTAssertEqual(Policy.availability(authorization: .notDetermined, subscription: subscription), .needsAuthorization)
            XCTAssertEqual(Policy.availability(authorization: .denied, subscription: subscription), .denied)
            XCTAssertEqual(Policy.availability(authorization: .restricted, subscription: subscription), .restricted)
        }
        XCTAssertEqual(Policy.availability(authorization: .authorized, subscription: .unknown), .checking)
        XCTAssertEqual(Policy.availability(authorization: .authorized, subscription: .checking), .checking)
        XCTAssertEqual(Policy.availability(authorization: .authorized, subscription: .failed), .checkFailed)
        XCTAssertEqual(Policy.availability(authorization: .authorized, subscription: .known(subscriber)), .ready)
        XCTAssertEqual(Policy.availability(authorization: .authorized, subscription: .known(offer)), .subscriptionOffer)
        XCTAssertEqual(Policy.availability(authorization: .authorized, subscription: .known(none)), .unavailable)
    }

    func testWithoutTheDeveloperTokenOnlyPlaylistsFallBackToTheStoreIDQueue() {
        typealias Policy = FocusMusicCatalogRoutePolicy
        XCTAssertEqual(Policy.route(for: classical, after: .developerTokenUnavailable), .mediaPlayerQueue)
        XCTAssertEqual(Policy.route(for: station, after: .developerTokenUnavailable), .fail(.needsCatalogAccess))
        for source in [classical, station] {
            XCTAssertEqual(Policy.route(for: source, after: .notFound), .fail(.notInStorefront))
            XCTAssertEqual(Policy.route(for: source, after: .permissionDenied), .fail(.permissionDenied))
            XCTAssertEqual(Policy.route(for: source, after: .notSignedIn), .fail(.notSignedIn))
            XCTAssertEqual(Policy.route(for: source, after: .other), .fail(.failed))
        }
        XCTAssertTrue(FocusMusicPlaybackError.notInStorefront.triesNextSource)
        XCTAssertTrue(FocusMusicPlaybackError.needsCatalogAccess.triesNextSource)
        for error in [FocusMusicPlaybackError.permissionDenied, .notSignedIn, .subscriptionRequired, .failed] {
            XCTAssertFalse(error.triesNextSource, "\(error)")
        }
    }

    func testSystemErrorsMapToTheRoutingTaxonomy() {
        typealias Adapter = SystemFocusMusicPlayer
        XCTAssertEqual(Adapter.catalogFailure(MusicTokenRequestError.developerTokenRequestFailed), .developerTokenUnavailable)
        XCTAssertEqual(Adapter.catalogFailure(MusicTokenRequestError.permissionDenied), .permissionDenied)
        XCTAssertEqual(Adapter.catalogFailure(MusicTokenRequestError.privacyAcknowledgementRequired), .permissionDenied)
        XCTAssertEqual(Adapter.catalogFailure(MusicTokenRequestError.userNotSignedIn), .notSignedIn)
        XCTAssertEqual(Adapter.catalogFailure(MusicTokenRequestError.userTokenRevoked), .notSignedIn)
        XCTAssertEqual(Adapter.catalogFailure(MusicTokenRequestError.unknown), .other)
        XCTAssertEqual(Adapter.catalogFailure(URLError(.notConnectedToInternet)), .other)
        XCTAssertEqual(Adapter.catalogFailure(httpStatus: 401), .developerTokenUnavailable)
        XCTAssertEqual(Adapter.catalogFailure(httpStatus: 403), .developerTokenUnavailable)
        XCTAssertEqual(Adapter.catalogFailure(httpStatus: 404), .notFound)
        XCTAssertEqual(Adapter.catalogFailure(httpStatus: 500), .other)

        XCTAssertEqual(Adapter.playbackError(forMediaPlayerCode: .notFound), .notInStorefront)
        XCTAssertEqual(Adapter.playbackError(forMediaPlayerCode: .permissionDenied), .permissionDenied)
        XCTAssertEqual(Adapter.playbackError(forMediaPlayerCode: .cloudServiceCapabilityMissing), .subscriptionRequired)
        XCTAssertEqual(Adapter.playbackError(forMediaPlayerCode: .networkConnectionFailed), .failed)
        XCTAssertEqual(Adapter.playbackError(forMediaPlayerCode: nil), .failed)

        XCTAssertEqual(Adapter.map(MusicKit.MusicPlayer.PlaybackStatus.seekingForward), .playing)
        XCTAssertEqual(Adapter.map(MusicKit.MusicPlayer.PlaybackStatus.interrupted), .interrupted)
        XCTAssertEqual(Adapter.map(MPMusicPlaybackState.seekingBackward), .playing)
        XCTAssertEqual(Adapter.map(MPMusicPlaybackState.stopped), .stopped)
    }

    func testHeaderTapPolicy() {
        typealias Policy = FocusMusicHeaderPolicy
        let stopped = FocusMusicNowPlaying(status: .stopped)
        let playing = FocusMusicNowPlaying(status: .playing, title: "x")
        let paused = FocusMusicNowPlaying(status: .paused, title: "x")

        for availability in [FocusMusicAvailability.needsAuthorization, .denied, .restricted, .checkFailed, .subscriptionOffer, .unavailable, .checking] {
            XCTAssertEqual(
                Policy.action(availability: availability, chosen: classical, nowPlaying: stopped, queuedSourceID: nil, isBusy: false),
                .presentSheet,
                "\(availability)"
            )
        }
        XCTAssertEqual(Policy.action(availability: .ready, chosen: nil, nowPlaying: stopped, queuedSourceID: nil, isBusy: false), .presentSheet)
        XCTAssertEqual(Policy.action(availability: .ready, chosen: classical, nowPlaying: stopped, queuedSourceID: nil, isBusy: false), .play(classical))
        XCTAssertEqual(Policy.action(availability: .ready, chosen: classical, nowPlaying: playing, queuedSourceID: nil, isBusy: false), .pause)
        XCTAssertEqual(Policy.action(availability: .checking, chosen: nil, nowPlaying: playing, queuedSourceID: nil, isBusy: false), .pause)
        XCTAssertEqual(Policy.action(availability: .ready, chosen: classical, nowPlaying: paused, queuedSourceID: station.id, isBusy: false), .resume)
        XCTAssertEqual(Policy.action(availability: .ready, chosen: classical, nowPlaying: paused, queuedSourceID: nil, isBusy: false), .play(classical))
        XCTAssertEqual(Policy.action(availability: .ready, chosen: classical, nowPlaying: stopped, queuedSourceID: nil, isBusy: true), .ignore)
    }

    func testAutoplayPolicyStartsOnlyAFreshFocusOnce() {
        let session = UUID()
        let base = FocusMusicAutoplayPolicy.Input(
            isEnabled: true,
            chosen: classical,
            availability: .ready,
            sessionID: session,
            startedAt: clock.addingTimeInterval(-3),
            isStartedOnThisIPhone: true,
            now: clock,
            lastAutoplayedSessionID: nil,
            playback: .stopped
        )
        XCTAssertTrue(FocusMusicAutoplayPolicy.shouldAutoplay(base))

        func refused(_ change: (inout FocusMusicAutoplayPolicy.Input) -> Void, _ message: String) {
            var input = base
            change(&input)
            XCTAssertFalse(FocusMusicAutoplayPolicy.shouldAutoplay(input), message)
        }
        refused({ $0.isEnabled = false }, "opt-in is off")
        refused({ $0.chosen = nil }, "nothing chosen")
        for availability in [FocusMusicAvailability.needsAuthorization, .denied, .restricted, .checking, .checkFailed, .subscriptionOffer, .unavailable] {
            refused({ $0.availability = availability }, "never prompts or offers: \(availability)")
        }
        refused({ $0.sessionID = nil }, "not a running focus")
        refused({ $0.lastAutoplayedSessionID = session }, "same session again")
        refused({ $0.startedAt = nil }, "no start")
        refused({ $0.startedAt = self.clock.addingTimeInterval(-(FocusMusicAutoplayPolicy.freshStartWindow + 1)) }, "recovered, handed off or resumed focus")
        refused({ $0.startedAt = self.clock.addingTimeInterval(FocusMusicAutoplayPolicy.futureStartTolerance + 1) }, "start in the future")
        refused({ $0.playback = .playing }, "never replaces playing music")
        refused({ $0.isStartedOnThisIPhone = false }, "continued from another iPhone through iCloud")

        var edge = base
        edge.startedAt = clock.addingTimeInterval(-FocusMusicAutoplayPolicy.freshStartWindow)
        XCTAssertTrue(FocusMusicAutoplayPolicy.shouldAutoplay(edge))
        edge.playback = .paused
        XCTAssertTrue(FocusMusicAutoplayPolicy.shouldAutoplay(edge), "a paused queue may be replaced by the chosen source")
    }

    func testHintsAreNonEmptyAndCalm() {
        for hint in [FocusMusicHint.openMusicOnce, .noSourceAvailable, .signIn] {
            XCTAssertFalse(hint.message.isEmpty)
            XCTAssertFalse(hint.message.contains("！"), "no urgency: \(hint)")
        }
    }

    // MARK: - Controller: permission and subscription

    func testRefreshAndHeaderTapNeverPromptForPermission() async {
        authorizer.status = .notDetermined
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        let controller = makeController()

        await controller.refresh(forceSubscriptionCheck: true)
        let action = await controller.handleHeaderTap()

        XCTAssertEqual(controller.availability, .needsAuthorization)
        XCTAssertEqual(action, .presentSheet)
        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(subscriptions.callCount, 0)
        XCTAssertEqual(player.observeCount, 0, "the Music app's player is untouched before authorization")
        XCTAssertEqual(player.attempts, [])
    }

    func testTheTapInTheSheetAsksOnceThenChecksTheSubscription() async {
        authorizer.status = .notDetermined
        authorizer.requestResult = .authorized
        let controller = makeController()

        await controller.requestAuthorization()

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(subscriptions.callCount, 1)
        XCTAssertEqual(controller.availability, .ready)
        XCTAssertEqual(player.observeCount, 1)

        await controller.requestAuthorization()
        XCTAssertEqual(authorizer.requestCount, 1, "an answered prompt is never shown again")
    }

    func testDeniedAndRestrictedNeverReadTheSubscription() async {
        for status in [FocusMusicAuthorization.denied, .restricted] {
            authorizer.status = status
            authorizer.requestResult = status
            let controller = makeController()
            await controller.refresh(forceSubscriptionCheck: true)
            await controller.requestAuthorization()
            XCTAssertEqual(controller.availability, status == .denied ? .denied : .restricted)
            XCTAssertEqual(authorizer.requestCount, 0, "only notDetermined is ever asked")
        }
        XCTAssertEqual(subscriptions.callCount, 0)
    }

    func testWithoutASubscriptionTheSheetOffersAppleMusicOrHidesPlay() async {
        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true))
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(controller.availability, .subscriptionOffer)

        let outcome = await controller.choose(pianoChill)
        XCTAssertEqual(outcome, .presentOffer)
        XCTAssertEqual(player.attempts, [])
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: defaults), pianoChill, "the choice is kept for later")
        let tap = await controller.handleHeaderTap()
        XCTAssertEqual(tap, .presentSheet)

        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: false))
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertEqual(controller.availability, .unavailable)
        let unavailableOutcome = await controller.choose(pianoChill)
        XCTAssertEqual(unavailableOutcome, .handled)
        XCTAssertEqual(player.attempts, [])

        // After the offer sheet closes the sheet re-checks; a new subscriber plays.
        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false))
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertEqual(controller.availability, .ready)
    }

    func testAFailedSubscriptionCheckIsRetried() async {
        subscriptions.result = .failure(URLError(.notConnectedToInternet))
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(controller.availability, .checkFailed)

        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false))
        await controller.refresh()
        XCTAssertEqual(controller.availability, .ready)
        XCTAssertEqual(subscriptions.callCount, 2)

        await controller.refresh()
        XCTAssertEqual(subscriptions.callCount, 2, "a known answer is reused until the sheet asks again")
    }

    func testAfterAFailedCheckTheTimerTapOpensTheSheetAtOnce() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        subscriptions.result = .failure(URLError(.notConnectedToInternet))
        let controller = makeController()
        await controller.refresh()

        let action = await controller.handleHeaderTap()

        XCTAssertEqual(action, .presentSheet)
        XCTAssertEqual(subscriptions.callCount, 1, "the tap does not wait on the network again; the sheet retries")
    }

    func testConcurrentChecksShareOneSubscriptionRequest() async {
        subscriptions.suspends = true
        let controller = makeController()
        let first = Task { await controller.refresh(forceSubscriptionCheck: true) }
        await subscriptions.waitUntilCalled()
        // A second request, if one were made, would answer at once.
        subscriptions.suspends = false
        let second = Task { await controller.refresh(forceSubscriptionCheck: true) }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(controller.availability, .checking)

        subscriptions.resume()
        await first.value
        await second.value

        XCTAssertEqual(subscriptions.callCount, 1)
        XCTAssertEqual(controller.availability, .ready)
    }

    // MARK: - Controller: playback

    func testChoosingPlaysTheChoiceAndStoresOnlyItsID() async {
        let controller = makeController()
        await controller.refresh()

        let outcome = await controller.choose(pianoChill)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(player.attempts, [pianoChill.id])
        XCTAssertEqual(controller.queuedSourceID, pianoChill.id)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.nowPlaying.title, "T-\(pianoChill.id)")
        XCTAssertEqual(defaults.string(forKey: FocusMusicPreferences.sourceKey), pianoChill.id)
        XCTAssertFalse(controller.isBusy)
    }

    func testPlaybackFallsThroughMissingSourcesInCatalogOrder() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        player.failures = [classical.id: .notInStorefront, station.id: .needsCatalogAccess]
        let controller = makeController()

        let action = await controller.handleHeaderTap()

        XCTAssertEqual(action, .play(classical))
        XCTAssertEqual(player.attempts, [classical.id, station.id, pianoChill.id])
        XCTAssertEqual(controller.queuedSourceID, pianoChill.id)
        XCTAssertNil(controller.hint)
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: defaults), classical, "the person's choice is not rewritten")
    }

    func testWhenNoSourceIsInTheStorefrontTheSheetSaysSo() async {
        FocusMusicPreferences.setChosenSource(station, defaults: defaults)
        for source in sources { player.failures[source.id] = .notInStorefront }
        let controller = makeController()

        await controller.handleHeaderTap()

        XCTAssertEqual(player.attempts, FocusMusicCatalog.fallbackOrder(startingWith: station).map(\.id))
        XCTAssertEqual(controller.hint, .noSourceAvailable)
        XCTAssertNil(controller.queuedSourceID)
        XCTAssertFalse(controller.isBusy)
    }

    func testAPlaybackFailureStopsWithAGentleHint() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        player.failures[classical.id] = .failed
        let controller = makeController()

        await controller.handleHeaderTap()

        XCTAssertEqual(player.attempts, [classical.id], "only storefront gaps move on to the next source")
        XCTAssertEqual(controller.hint, .openMusicOnce)

        player.failures[classical.id] = nil
        await controller.handleHeaderTap()
        XCTAssertNil(controller.hint, "a successful start clears the hint")
        XCTAssertTrue(controller.isPlaying)
    }

    func testSignInPermissionAndSubscriptionFailuresUpdateTheState() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        let controller = makeController()

        player.failures[classical.id] = .notSignedIn
        await controller.handleHeaderTap()
        XCTAssertEqual(controller.hint, .signIn)

        player.failures[classical.id] = .subscriptionRequired
        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true))
        await controller.handleHeaderTap()
        XCTAssertEqual(controller.availability, .subscriptionOffer, "a lapsed subscription is re-read")

        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false))
        await controller.refresh(forceSubscriptionCheck: true)
        player.failures[classical.id] = .permissionDenied
        let authorizer = self.authorizer!
        player.beforeFailure = { authorizer.status = .denied }
        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))
        XCTAssertEqual(controller.availability, .denied, "a revoked permission is re-read")
    }

    func testHeaderTapPlaysPausesAndResumesTheChoice() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        let controller = makeController()

        var action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))
        XCTAssertTrue(controller.isPlaying)
        action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .pause)
        XCTAssertEqual(player.pauseCount, 1)
        XCTAssertFalse(controller.isPlaying)
        action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .resume)
        XCTAssertEqual(player.resumeCount, 1)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(player.attempts, [classical.id], "resume does not restart the playlist")
    }

    func testHeaderTapWithoutAChoiceOpensTheSheet() async {
        let controller = makeController()
        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .presentSheet)
        XCTAssertEqual(player.attempts, [])
    }

    func testTheSheetControlsPauseResumeAndSkip() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        let controller = makeController()
        await controller.refresh()

        await controller.togglePlayback()
        XCTAssertEqual(player.attempts, [classical.id])
        await controller.togglePlayback()
        XCTAssertEqual(player.pauseCount, 1)
        await controller.togglePlayback()
        XCTAssertEqual(player.resumeCount, 1)
        await controller.skipToNext()
        XCTAssertEqual(player.skipCount, 1)

        player.resumeError = FocusMusicPlaybackError.failed
        await controller.togglePlayback()
        await controller.togglePlayback()
        XCTAssertEqual(controller.hint, .openMusicOnce)
    }

    func testPlayerChangesReachTheTimerButton() async {
        let controller = makeController()
        await controller.refresh()
        await controller.refresh()
        XCTAssertEqual(player.observeCount, 1)

        player.nowPlaying = FocusMusicNowPlaying(status: .playing, title: "Nocturne")
        player.onChange?()

        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.nowPlaying.title, "Nocturne")
    }

    func testCatalogTitlesReplaceFallbackTitlesWhenKnown() async {
        catalog.names = [classical.id: "Classical Concentration", station.id: ""]
        let controller = makeController()
        XCTAssertEqual(controller.title(for: classical), classical.fallbackTitle)

        await controller.loadCatalogTitlesIfNeeded()
        XCTAssertEqual(catalog.callCount, 1)
        XCTAssertEqual(controller.title(for: classical), "Classical Concentration")
        XCTAssertEqual(controller.title(for: station), station.fallbackTitle, "an empty catalog title keeps our label")
        XCTAssertEqual(controller.title(for: pianoChill), pianoChill.fallbackTitle)

        await controller.loadCatalogTitlesIfNeeded()
        XCTAssertEqual(catalog.callCount, 1)
    }

    func testCatalogTitlesWaitForAuthorization() async {
        authorizer.status = .notDetermined
        let controller = makeController()
        await controller.loadCatalogTitlesIfNeeded()
        XCTAssertEqual(catalog.callCount, 0)
    }

    // MARK: - Controller: autoplay

    func testAutoplayStartsTheChoiceOnceForAFreshFocus() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        let controller = makeController()
        let session = UUID()

        await controller.autoplayIfNeeded(
            sessionID: session,
            startedAt: clock.addingTimeInterval(-2),
            isStartedOnThisIPhone: true
        )
        XCTAssertEqual(player.attempts, [pianoChill.id])
        XCTAssertEqual(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults), session)

        // Pause, then the view remounts (resume, recovery, account revalidation).
        controller.pause()
        await controller.autoplayIfNeeded(
            sessionID: session,
            startedAt: clock.addingTimeInterval(-2),
            isStartedOnThisIPhone: true
        )
        let relaunched = makeController()
        await relaunched.autoplayIfNeeded(
            sessionID: session,
            startedAt: clock.addingTimeInterval(-2),
            isStartedOnThisIPhone: true
        )
        XCTAssertEqual(player.attempts, [pianoChill.id])
    }

    func testAutoplayIsOffByDefault() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        let controller = makeController()
        await controller.autoplayIfNeeded(
            sessionID: UUID(),
            startedAt: clock,
            isStartedOnThisIPhone: true
        )
        XCTAssertEqual(player.attempts, [])
        XCTAssertEqual(subscriptions.callCount, 0)
    }

    func testAutoplayNeverPromptsOffersOrReplacesPlayingMusic() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)

        authorizer.status = .notDetermined
        await makeController().autoplayIfNeeded(
            sessionID: UUID(),
            startedAt: clock,
            isStartedOnThisIPhone: true
        )
        XCTAssertEqual(authorizer.requestCount, 0)

        authorizer.status = .authorized
        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true))
        await makeController().autoplayIfNeeded(
            sessionID: UUID(),
            startedAt: clock,
            isStartedOnThisIPhone: true
        )

        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false))
        player.nowPlaying = FocusMusicNowPlaying(status: .playing, title: "The person's own music")
        await makeController().autoplayIfNeeded(
            sessionID: UUID(),
            startedAt: clock,
            isStartedOnThisIPhone: true
        )

        XCTAssertEqual(player.attempts, [])
        XCTAssertNil(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults))
    }

    func testAutoplayIgnoresARecoveredOrAdoptedFocus() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        let controller = makeController()

        await controller.autoplayIfNeeded(
            sessionID: UUID(),
            startedAt: clock.addingTimeInterval(-120),
            isStartedOnThisIPhone: true
        )
        await controller.autoplayIfNeeded(
            sessionID: nil,
            startedAt: clock,
            isStartedOnThisIPhone: true
        )
        // Continued from another iPhone seconds after it started there.
        let checksBeforeAdoption = subscriptions.callCount
        await makeController().autoplayIfNeeded(
            sessionID: UUID(),
            startedAt: clock.addingTimeInterval(-2),
            isStartedOnThisIPhone: false
        )

        XCTAssertEqual(player.attempts, [])
        XCTAssertNil(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults))
        XCTAssertEqual(
            subscriptions.callCount,
            checksBeforeAdoption,
            "an adopted focus does not even read the subscription"
        )
    }

    // MARK: - Controller: unknown subscription

    func testWhenTheSubscriptionCannotBeReadARowTapStillTriesToPlay() async {
        // MusicSubscription can fail offline, or before the MusicKit App
        // Service is on; the person's tap on a row is then the real test.
        subscriptions.result = .failure(URLError(.notConnectedToInternet))
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(controller.availability, .checkFailed)

        let outcome = await controller.choose(classical)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(subscriptions.callCount, 2, "the row tap re-checks once before trying")
        XCTAssertEqual(player.attempts, [classical.id])
        XCTAssertEqual(controller.availability, .ready, "music that started proves catalog playback")
        XCTAssertTrue(controller.isPlaying)

        // The timer button now pauses it directly.
        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .pause)
    }

    func testAFailedTryWithAnUnknownSubscriptionKeepsTheRetryState() async {
        subscriptions.result = .failure(URLError(.notConnectedToInternet))
        player.failures[classical.id] = .failed
        let controller = makeController()

        let outcome = await controller.choose(classical)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(player.attempts, [classical.id])
        XCTAssertEqual(controller.availability, .checkFailed)
        XCTAssertEqual(controller.hint, .openMusicOnce)
        XCTAssertFalse(controller.isBusy)
    }

    func testAutoplayNeverGuessesAnUnknownSubscription() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        subscriptions.result = .failure(URLError(.notConnectedToInternet))

        await makeController().autoplayIfNeeded(
            sessionID: UUID(),
            startedAt: clock,
            isStartedOnThisIPhone: true
        )

        XCTAssertEqual(player.attempts, [])
    }
}

// MARK: - Fakes

@MainActor
private final class FakeMusicAuthorizer: FocusMusicAuthorizing {
    var status: FocusMusicAuthorization
    var requestResult: FocusMusicAuthorization = .authorized
    private(set) var requestCount = 0

    init(status: FocusMusicAuthorization) {
        self.status = status
    }

    var currentStatus: FocusMusicAuthorization { status }

    func request() async -> FocusMusicAuthorization {
        requestCount += 1
        status = requestResult
        return requestResult
    }
}

@MainActor
private final class FakeMusicSubscriptions: FocusMusicSubscriptionChecking {
    var result: Result<FocusMusicSubscription, Error> = .success(
        FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false)
    )
    var suspends = false
    private(set) var callCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var calledWaiters: [CheckedContinuation<Void, Never>] = []

    func current() async throws -> FocusMusicSubscription {
        callCount += 1
        calledWaiters.forEach { $0.resume() }
        calledWaiters.removeAll()
        if suspends {
            await withCheckedContinuation { gate = $0 }
        }
        return try result.get()
    }

    func waitUntilCalled() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { calledWaiters.append($0) }
    }

    func resume() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class FakeMusicPlayer: FocusMusicPlaying {
    var nowPlaying = FocusMusicNowPlaying()
    var failures: [String: FocusMusicPlaybackError] = [:]
    var resumeError: Error?
    var beforeFailure: (() -> Void)?
    private(set) var attempts: [String] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var skipCount = 0
    private(set) var observeCount = 0
    private(set) var onChange: (@MainActor () -> Void)?

    func play(_ source: FocusMusicSource) async throws {
        attempts.append(source.id)
        if let failure = failures[source.id] {
            beforeFailure?()
            throw failure
        }
        nowPlaying = FocusMusicNowPlaying(status: .playing, title: "T-\(source.id)")
    }

    func pause() {
        pauseCount += 1
        nowPlaying.status = .paused
    }

    func resume() async throws {
        resumeCount += 1
        if let resumeError { throw resumeError }
        nowPlaying.status = .playing
    }

    func skipToNext() async throws {
        skipCount += 1
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        observeCount += 1
        self.onChange = onChange
    }
}

@MainActor
private final class FakeMusicCatalog: FocusMusicCatalogNaming {
    var names: [String: String] = [:]
    private(set) var callCount = 0

    func titles(for sources: [FocusMusicSource]) async -> [String: String] {
        callCount += 1
        return names
    }
}
