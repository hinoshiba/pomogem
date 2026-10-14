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

    func testDiscoveryPermissionRecoveryClearsOnlyThePermissionFailure() async {
        authorizer.status = .denied
        let controller = makeController()
        var permissionFailure: FocusMusicDiscoveryFailure?
        do {
            _ = try await controller.search(term: "piano")
            XCTFail("Searching while denied must fail before querying the catalog")
        } catch {
            permissionFailure = FocusMusicDiscoveryFailure(error: error, authorization: controller.authorization)
        }
        XCTAssertEqual(permissionFailure, .permissionRequired)
        XCTAssertTrue(catalog.searchedTerms.isEmpty)

        let requestFailure = FocusMusicDiscoveryFailure(
            error: FocusMusicPlaybackError.failed, authorization: .authorized
        )
        XCTAssertEqual(requestFailure, .requestFailed)
        authorizer.status = .authorized
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertNil(permissionFailure?.remaining(after: controller.authorization))
        XCTAssertEqual(requestFailure.remaining(after: controller.authorization), .requestFailed,
                       "Permission recovery does not prove that a network request succeeded")
        XCTAssertEqual(permissionFailure?.remaining(after: .denied), .permissionRequired)
        XCTAssertEqual(permissionFailure?.remaining(after: .restricted), .permissionRequired)
        XCTAssertEqual(requestFailure.remaining(after: .denied), .requestFailed)
        XCTAssertNil(FocusMusicDiscoveryFailure(
            error: FocusMusicPlaybackError.permissionDenied, authorization: .authorized
        ).remaining(after: .authorized),
        "A permission failure delivered just after authorization recovers must not revive the prompt")
    }

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
        player.pause()
        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))
    }

    func testTheAppDeclaresTheAppleMusicPurposeString() {
        // MusicAuthorization.request() terminates an app without this key.
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String,
            "集中用の音楽を再生し、自分のライブラリからプレイリストを選ぶために使います。"
        )
    }

    // MARK: - Personal choices and subject defaults

    func testSubjectMusicDraftIsSavedWithoutPlayingAndSurvivesRelaunch() {
        let subject = UUID()
        let otherSubject = UUID()
        let controller = makeController()
        controller.setAutoplayEnabled(true)
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        var draft = controller.subjectSettings(for: subject)
        draft.source = .libraryPlaylist(id: "p.private", title: "My study playlist")
        draft.autoplay = false
        XCTAssertEqual(controller.subjectSettings(for: subject), FocusMusicSubjectSettings())
        XCTAssertTrue(controller.savedSources.isEmpty, "Editing or cancelling a draft must not save a favorite")

        controller.setSubjectSettings(draft, for: subject)
        let relaunched = makeController()
        XCTAssertEqual(relaunched.subjectSettings(for: subject), draft)
        XCTAssertEqual(relaunched.chosenSource(for: subject), draft.source)
        XCTAssertFalse(relaunched.isAutoplayEnabled(for: subject))
        XCTAssertTrue(relaunched.isAutoplayEnabled(for: otherSubject))
        XCTAssertEqual(relaunched.chosenSource(for: otherSubject), classical)
        XCTAssertEqual(player.attempts, [])
        XCTAssertEqual(authorizer.requestCount, 0)

        relaunched.setSubjectSettings(FocusMusicSubjectSettings(), for: subject)
        XCTAssertTrue(relaunched.isAutoplayEnabled(for: subject))
        XCTAssertEqual(relaunched.chosenSource(for: subject), classical)
    }

    func testLibraryPlaylistSourceDecodesAlongsideLegacySavedFavorites() throws {
        let old = Data(#"{"id":"pl.saved","fallbackTitle":"Saved","kind":"playlist"}"#.utf8)
        let legacy = try JSONDecoder().decode(FocusMusicSource.self, from: old)
        XCTAssertNil(legacy.libraryID)
        let library = FocusMusicSource.libraryPlaylist(id: "pl.saved", title: "Personal")
        XCTAssertNotEqual(library.id, legacy.id, "A library ID must never collide with a catalog choice")
        XCTAssertEqual(try JSONDecoder().decode(FocusMusicSource.self, from: JSONEncoder().encode(library)), library)
        XCTAssertEqual(FocusMusicCatalog.fallbackOrder(startingWith: library), [library])
        XCTAssertEqual(FocusMusicCatalogRoutePolicy.route(for: library, after: .developerTokenUnavailable),
                       .fail(.needsCatalogAccess), "Never send a library ID to the catalog store-ID fallback")
    }

    func testSubjectAutoplayCanOverrideCommonOffOrOnIndependently() async {
        let enabledSubject = UUID()
        let disabledSubject = UUID()
        let controller = makeController()
        let library = FocusMusicSource.libraryPlaylist(id: "p.study", title: "Study")
        controller.setSubjectSettings(.init(source: library, autoplay: true), for: enabledSubject)
        controller.setSubjectSettings(.init(source: classical, autoplay: false), for: disabledSubject)
        XCTAssertFalse(controller.isAutoplayEnabled())
        await controller.autoplayIfNeeded(sessionID: UUID(), startedAt: clock,
                                         isStartedOnThisIPhone: true, subjectID: enabledSubject)
        XCTAssertEqual(player.attempts, [library.id])
        player.nowPlaying.status = .stopped
        controller.setAutoplayEnabled(true)
        await controller.autoplayIfNeeded(sessionID: UUID(), startedAt: clock,
                                         isStartedOnThisIPhone: true, subjectID: disabledSubject)
        XCTAssertEqual(player.attempts, [library.id], "A subject's explicit Off wins over common On")
        controller.clearSubjectAutoplay(disabledSubject)
        await controller.autoplayIfNeeded(sessionID: UUID(), startedAt: clock,
                                         isStartedOnThisIPhone: true, subjectID: disabledSubject)
        XCTAssertEqual(player.attempts, [library.id, classical.id])
    }

    func testLibraryPickerLoadsEveryPageOnlyAfterExplicitPermissionAndSavesNothing() async throws {
        authorizer.status = .notDetermined
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertEqual(catalog.libraryOffsets, [])
        catalog.libraryPages = [
            0: [.libraryPlaylist(id: "p.one", title: "One"), .libraryPlaylist(id: "p.two", title: "Two")],
            2: [.libraryPlaylist(id: "p.three", title: "Three")]
        ]
        let result = try await controller.libraryPlaylists()
        XCTAssertEqual(result.map(\.libraryID), ["p.one", "p.two", "p.three"])
        XCTAssertEqual(catalog.libraryOffsets, [0, 2, 3], "A short provider page must not hide later playlists")
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(player.attempts, [])
        XCTAssertNil(controller.chosenSource)
        XCTAssertEqual(controller.savedSources, [])
        XCTAssertNil(defaults.object(forKey: FocusMusicPreferences.savedSourcesKey))
    }

    func testDeniedLibraryPickerDoesNotReadPlaylists() async {
        authorizer.status = .denied
        do {
            _ = try await makeController().libraryPlaylists()
            XCTFail("A denied library request must not load personal playlists")
        } catch {
            XCTAssertEqual(error as? FocusMusicPlaybackError, .permissionDenied)
        }
        XCTAssertEqual(catalog.libraryOffsets, [])
        XCTAssertEqual(authorizer.requestCount, 0)
    }

    func testRepeatedLibraryPageFailsInsteadOfLoopingOrShowingATruncatedSuccess() async {
        let source = FocusMusicSource.libraryPlaylist(id: "p.one", title: "One")
        catalog.libraryPages = [0: [source], 1: [source]]
        do {
            _ = try await makeController().libraryPlaylists()
            XCTFail("Repeated pages are not a completed library listing")
        } catch {
            XCTAssertEqual(error as? FocusMusicPlaybackError, .failed)
        }
        XCTAssertEqual(catalog.libraryOffsets, [0, 1])
    }

    func testPersonalSourcesSurviveRelaunchAndSubjectOverridesDoNotChangeTheCommonChoice() {
        let subject = UUID()
        let otherSubject = UUID()
        let song = FocusMusicSource(id: "123456", fallbackTitle: "My song", kind: .song)
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        FocusMusicPreferences.setChosenSource(song, subjectID: subject, defaults: defaults)

        let relaunched = UserDefaults(suiteName: domain)!
        XCTAssertEqual(FocusMusicPreferences.chosenSource(subjectID: subject, defaults: relaunched), song)
        XCTAssertEqual(FocusMusicPreferences.chosenSource(subjectID: otherSubject, defaults: relaunched), classical)
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: relaunched), classical)
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: relaunched), [song])

        FocusMusicPreferences.setChosenSource(nil, subjectID: subject, defaults: defaults)
        XCTAssertEqual(FocusMusicPreferences.chosenSource(subjectID: subject, defaults: defaults), classical)
    }

    func testAnOptionalFavoriteNameSurvivesSelectionAndCatalogTitleRefresh() async {
        let named = FocusMusicSource(id: station.id, fallbackTitle: "Radio", kind: .station, customTitle: "Radio")
        let controller = makeController()
        controller.saveSource(named)
        await controller.choose(named)
        catalog.names = [station.id: "Catalog station title"]
        await controller.loadCatalogTitlesIfNeeded()
        XCTAssertEqual(controller.chosenSource, named)
        XCTAssertEqual(controller.title(for: named), "Radio")
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: UserDefaults(suiteName: domain)!), named)
    }

    func testRemovingFavoriteKeepsCommonAndSubjectChoicesAcrossRelaunch() {
        let subject = UUID()
        let otherSubject = UUID()
        let album = FocusMusicSource(id: "67890", fallbackTitle: "My album", kind: .album)
        FocusMusicPreferences.setChosenSource(album, defaults: defaults)
        FocusMusicPreferences.setChosenSource(album, subjectID: subject, defaults: defaults)
        FocusMusicPreferences.setChosenSource(album, subjectID: otherSubject, defaults: defaults)
        FocusMusicPreferences.saveSource(album, defaults: defaults)
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: defaults).count, 1)

        FocusMusicPreferences.removeSavedSource(album, defaults: defaults)
        let relaunched = UserDefaults(suiteName: domain)!
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: relaunched), album)
        for id in [subject, otherSubject] {
            XCTAssertEqual(FocusMusicPreferences.subjectSource(for: id, defaults: relaunched), album)
        }
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: relaunched), [])
        FocusMusicPreferences.setChosenSource(album, subjectID: subject, defaults: relaunched)
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: relaunched), [],
                       "Selecting an unfavorited source must not silently restore its heart")
        FocusMusicPreferences.saveSource(album, defaults: relaunched)
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: relaunched), [album])
    }

    func testLegacyFavoriteJSONStillResolvesChoicesWithoutNewMembershipData() throws {
        let legacy = Data(#"[{"id":"123456","fallbackTitle":"Old song","kind":"song"}]"#.utf8)
        defaults.set(legacy, forKey: FocusMusicPreferences.savedSourcesKey)
        defaults.set("123456", forKey: FocusMusicPreferences.sourceKey)
        let source = try XCTUnwrap(FocusMusicPreferences.chosenSource(defaults: defaults))
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: defaults), [source])
        FocusMusicPreferences.removeSavedSource(source, defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: FocusMusicPreferences.savedSourcesKey), legacy,
                       "Favorite membership must not rewrite the existing metadata JSON")
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: defaults), source)
    }

    func testBrokenPersonalMetadataKeepsLegacyCommonMusicUsable() {
        defaults.set(Data("broken".utf8), forKey: FocusMusicPreferences.savedSourcesKey)
        defaults.set(Data("broken".utf8), forKey: FocusMusicPreferences.subjectSourcesKey)
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        XCTAssertEqual(FocusMusicPreferences.chosenSource(subjectID: UUID(), defaults: defaults), pianoChill)
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: defaults), [])
    }

    func testAppleMusicLinksIdentifySongAlbumPlaylistAndStationWithoutOpeningURLs() {
        let cases: [(String, String, FocusMusicSource.Kind)] = [
            ("https://music.apple.com/jp/album/album-name/123?i=456", "456", .song),
            ("https://music.apple.com/us/song/song-name/456", "456", .song),
            ("https://music.apple.com/jp/album/album-name/123", "123", .album),
            ("https://music.apple.com/jp/playlist/focus/pl.abc123", "pl.abc123", .playlist),
            ("https://music.apple.com/us/station/classical/ra.985486574", "ra.985486574", .station),
            (" https://music.apple.com/playlist/pl.abc123 ", "pl.abc123", .playlist),
            ("https://music.apple.com/jp/station/my-station/ra.u-abc123", "ra.u-abc123", .station),
        ]
        for (url, id, kind) in cases {
            XCTAssertEqual(FocusMusicSourceLink.parse(url)?.id, id, url)
            XCTAssertEqual(FocusMusicSourceLink.parse(url)?.kind, kind, url)
        }
        for invalid in [
            "https://music.apple.com.evil.example/jp/song/name/456",
            "http://music.apple.com/jp/song/name/456",
            "https://user@music.apple.com/jp/song/name/456",
            "https://music.apple.com:123/jp/song/name/456",
            "https://music.apple.com/jp/artist/name/456",
            "https://music.apple.com/jp/song/name/not-an-id",
            "https://music.apple.com/jp/album/name/123?i=bad",
            "https://music.apple.com/jp/station/name/ra.",
            "https://music.apple.com/jp/playlist/name/pl.",
            "https://example.com/playlist/pl.abc123",
        ] {
            XCTAssertNil(FocusMusicSourceLink.parse(invalid), invalid)
        }
    }

    func testReselectingAStationContinuesWithoutReplacingItsQueue() async {
        let controller = makeController()
        await controller.choose(station)
        await controller.choose(station)
        XCTAssertEqual(player.attempts, [station.id])
        controller.pause()
        await controller.choose(station)
        XCTAssertEqual(player.attempts, [station.id])
        XCTAssertEqual(player.resumeCount, 1)
        XCTAssertTrue(controller.isPlaying)
    }

    func testShuffleIsEnabledForCollectionsOnlyAndHonorsThePreference() async {
        let controller = makeController()
        await controller.choose(classical)
        await controller.choose(station)
        let song = FocusMusicSource(id: "123456", fallbackTitle: "Song", kind: .song)
        await controller.choose(song)
        defaults.set(false, forKey: FocusMusicPreferences.shuffleKey)
        await controller.choose(pianoChill)
        XCTAssertEqual(player.shuffleChoices, [true, false, false, false])
    }

    func testUnavailablePersonalChoiceDoesNotSilentlyPlayUnrelatedCuratedMusic() async {
        let song = FocusMusicSource(id: "123456", fallbackTitle: "Song", kind: .song)
        player.failures[song.id] = .notInStorefront
        let controller = makeController()
        await controller.choose(song)
        XCTAssertEqual(player.attempts, [song.id])
        XCTAssertEqual(controller.chosenSource, song)
        XCTAssertEqual(controller.hint, .noSourceAvailable)
    }

    func testSubjectChoiceDrivesFreshFocusAutoplayAndHeaderPlayback() async {
        let subject = UUID()
        let controller = makeController()
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        FocusMusicPreferences.setChosenSource(pianoChill, subjectID: subject, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        await controller.autoplayIfNeeded(sessionID: UUID(), startedAt: clock, isStartedOnThisIPhone: true, subjectID: subject)
        XCTAssertEqual(player.attempts, [pianoChill.id])
        XCTAssertEqual(controller.chosenSource, classical)
        XCTAssertEqual(controller.chosenSource(for: subject), pianoChill)

        player.nowPlaying.status = .stopped
        await controller.handleHeaderTap(subjectID: subject)
        XCTAssertEqual(player.attempts, [pianoChill.id, pianoChill.id])
    }

    func testSwitchingSubjectsWhilePausedStartsTheNewSubjectsMusic() async {
        let subject = UUID()
        let controller = makeController()
        FocusMusicPreferences.setChosenSource(pianoChill, subjectID: subject, defaults: defaults)
        await controller.choose(classical)
        controller.pause()
        XCTAssertEqual(controller.headerAction(for: subject), .play(pianoChill))
        XCTAssertEqual(controller.transportToggle(for: subject), .play(pianoChill))
        await controller.handleHeaderTap(subjectID: subject)
        XCTAssertEqual(player.attempts, [classical.id, pianoChill.id])
        XCTAssertEqual(player.resumeCount, 0)
        controller.pause(subjectID: subject)
        await controller.togglePlayback()
        XCTAssertEqual(player.attempts, [classical.id, pianoChill.id, classical.id])
    }

    func testReselectingACuratedFallbackContinuesItsQueue() async {
        let controller = makeController()
        player.failures[classical.id] = .notInStorefront
        await controller.choose(classical)
        XCTAssertEqual(controller.queuedSourceID, station.id)
        controller.pause()
        XCTAssertEqual(controller.headerAction, .resume)
        await controller.choose(classical)
        XCTAssertEqual(player.attempts, [classical.id, station.id])
        XCTAssertEqual(player.resumeCount, 1)
    }

    func testFailedQueueReplacementDoesNotResumeItAsThePreviousChoice() async {
        let controller = makeController()
        await controller.choose(classical)
        player.failures[pianoChill.id] = .failed
        player.beforeFailure = {
            self.player.nowPlaying = FocusMusicNowPlaying(status: .paused, title: "Failed replacement")
        }
        await controller.choose(pianoChill)
        XCTAssertNil(controller.queuedSourceID)
        await controller.choose(classical)
        XCTAssertEqual(player.attempts, [classical.id, pianoChill.id, classical.id])
        XCTAssertEqual(player.resumeCount, 0)
    }

    func testExternalQueueReplacementMakesExplicitReselectionStartTheChosenSource() async {
        let controller = makeController()
        for status in [FocusMusicPlaybackStatus.playing, .paused] {
            await controller.choose(classical)
            let previousAttempts = player.attempts.count
            player.currentEntryID = "external-\(UUID())"
            player.nowPlaying = FocusMusicNowPlaying(status: status, title: "External music")
            player.onChange?()
            XCTAssertNil(controller.queuedSourceID)
            await controller.choose(classical)
            XCTAssertEqual(player.attempts.count, previousAttempts + 1)
            XCTAssertEqual(player.attempts.last, classical.id)
            XCTAssertEqual(player.resumeCount, 0, "Explicitly selecting A must not resume external B")
        }
    }

    func testNaturalNextTrackStillAllowsOurPauseAndResumeWithoutReplacingQueue() async {
        let subject = UUID()
        let controller = makeController()
        await controller.choose(classical, subjectID: subject)
        player.currentEntryID = "natural-next-entry"
        player.nowPlaying = FocusMusicNowPlaying(status: .playing, title: "Next track")
        player.onChange?()
        XCTAssertNil(controller.queuedSourceID, "A new entry alone cannot prove source ownership")
        XCTAssertTrue(controller.showsNowPlaying)
        XCTAssertEqual(controller.headerAction(for: subject), .pause)
        await controller.handleHeaderTap(subjectID: subject)
        XCTAssertEqual(controller.headerAction(for: subject), .resume)
        await controller.handleHeaderTap(subjectID: subject)
        XCTAssertEqual(player.attempts, [classical.id])
        XCTAssertEqual(player.resumeCount, 1)
        await controller.togglePlayback(subjectID: subject)
        await controller.togglePlayback(subjectID: subject)
        XCTAssertEqual(player.attempts, [classical.id])
        XCTAssertEqual(player.resumeCount, 2)
    }

    func testOurPausedEntryCannotResumeAfterExternalMusicOrSelectedSubjectChanges() async {
        let subject = UUID()
        let otherSubject = UUID()
        let controller = makeController()
        await controller.choose(classical, subjectID: subject)
        controller.setSubjectSettings(.init(source: pianoChill), for: otherSubject)
        player.currentEntryID = "next-track"
        player.onChange?()
        controller.pause(subjectID: subject)
        XCTAssertEqual(controller.headerAction(for: otherSubject), .play(pianoChill))
        player.currentEntryID = "external-paused-track"
        player.nowPlaying = FocusMusicNowPlaying(status: .paused, title: "External")
        player.onChange?()
        XCTAssertEqual(controller.headerAction(for: subject), .play(classical))
    }

    func testUnknownQueueIdentityDoesNotTreatExternalMusicAsTheSelectedSource() async {
        let controller = makeController()
        await controller.choose(classical)
        player.currentEntryID = nil
        player.onChange?()
        XCTAssertNil(controller.queuedSourceID)
        await controller.choose(classical)
        XCTAssertEqual(player.attempts, [classical.id, classical.id])
    }

    func testCompleteDeletionAlsoClearsPersonalSourcesSubjectsAndShuffle() throws {
        let song = FocusMusicSource(id: "123456", fallbackTitle: "Song", kind: .song)
        FocusMusicPreferences.setChosenSource(song, subjectID: UUID(), defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, subjectID: UUID(), defaults: defaults)
        defaults.set(false, forKey: FocusMusicPreferences.shuffleKey)
        try CompleteDataDeletionDefaultsCleaner.clear(defaults: defaults, persistentDomainName: domain)
        for key in FocusMusicPreferences.allKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(FocusMusicPreferences.savedSources(defaults: defaults), [])
        XCTAssertTrue(FocusMusicPreferences.isShuffleEnabled(defaults: defaults))
    }

    func testSearchRequiresAnExplicitPermissionGrantAndNeverStartsPlayback() async throws {
        authorizer.status = .notDetermined
        authorizer.requestResult = .authorized
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(authorizer.requestCount, 0)
        let song = FocusMusicSource(id: "123456", fallbackTitle: "Song", kind: .song)
        catalog.results = [song]
        let results = try await controller.search(term: " piano ")
        XCTAssertEqual(results, [song])
        XCTAssertEqual(catalog.searchedTerms, ["piano"])
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(player.attempts, [])
        XCTAssertNil(controller.chosenSource)
    }

    func testDeniedSearchNeverQueriesTheCatalog() async {
        authorizer.status = .denied
        let controller = makeController()
        do {
            _ = try await controller.search(term: "piano")
            XCTFail("Denied search must not reach Apple Music")
        } catch {
            XCTAssertEqual(error as? FocusMusicPlaybackError, .permissionDenied)
        }
        XCTAssertEqual(catalog.searchedTerms, [])
        XCTAssertEqual(authorizer.requestCount, 0)
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

        // SystemMusicPlayer.play() failing with MediaPlayer's own errors keeps
        // their meaning instead of reading as a generic failure.
        func mediaPlayerError(_ code: MPError.Code) -> NSError {
            NSError(domain: MPErrorDomain, code: code.rawValue)
        }
        XCTAssertEqual(Adapter.route(after: mediaPlayerError(.cloudServiceCapabilityMissing), for: classical), .fail(.subscriptionRequired))
        XCTAssertEqual(Adapter.route(after: mediaPlayerError(.notFound), for: station), .fail(.notInStorefront))
        XCTAssertEqual(Adapter.route(after: mediaPlayerError(.permissionDenied), for: classical), .fail(.permissionDenied))
        XCTAssertEqual(Adapter.route(after: mediaPlayerError(.networkConnectionFailed), for: classical), .fail(.failed))
        XCTAssertEqual(
            Adapter.route(after: NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6), for: classical),
            .fail(.failed)
        )
        XCTAssertEqual(Adapter.route(after: MusicTokenRequestError.developerTokenRequestFailed, for: classical), .mediaPlayerQueue)
        XCTAssertEqual(Adapter.route(after: MusicTokenRequestError.developerTokenRequestFailed, for: station), .fail(.needsCatalogAccess))
        XCTAssertEqual(Adapter.route(after: MusicTokenRequestError.userNotSignedIn, for: classical), .fail(.notSignedIn))

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

        // Music that is playing is paused from the timer in every authorized
        // state, and even while a start is in flight.
        for availability in [FocusMusicAvailability.ready, .checking, .checkFailed, .subscriptionOffer, .unavailable] {
            for chosen in [classical, nil] {
                for isBusy in [false, true] {
                    XCTAssertEqual(
                        Policy.action(availability: availability, chosen: chosen, nowPlaying: playing, queuedSourceID: nil, isBusy: isBusy),
                        .pause,
                        "\(availability) chosen: \(String(describing: chosen?.id)) busy: \(isBusy)"
                    )
                }
            }
            XCTAssertTrue(availability.isAuthorized)
        }
        // Paused music outside `.ready` is resumed from the sheet, not the timer.
        for availability in [FocusMusicAvailability.checkFailed, .subscriptionOffer, .unavailable] {
            XCTAssertEqual(
                Policy.action(availability: availability, chosen: classical, nowPlaying: paused, queuedSourceID: classical.id, isBusy: false),
                .presentSheet
            )
        }
        for availability in [FocusMusicAvailability.needsAuthorization, .denied, .restricted] {
            XCTAssertFalse(availability.isAuthorized)
            XCTAssertEqual(
                Policy.action(availability: availability, chosen: classical, nowPlaying: playing, queuedSourceID: nil, isBusy: false),
                .presentSheet,
                "PomoGem cannot control the player without permission: \(availability)"
            )
        }
    }

    func testAHeaderTapThatCouldNotPlayOpensTheSheet() {
        typealias Policy = FocusMusicHeaderPolicy
        XCTAssertTrue(Policy.presentsSheet(after: .presentSheet, availability: .ready, hint: nil, isPlaying: false))
        for action in [FocusMusicHeaderAction.play(classical), .resume] {
            XCTAssertFalse(Policy.presentsSheet(after: action, availability: .ready, hint: nil, isPlaying: true), "it played")
            XCTAssertFalse(
                Policy.presentsSheet(after: action, availability: .ready, hint: nil, isPlaying: false),
                "started, and the Music app has not reported it yet"
            )
            XCTAssertTrue(Policy.presentsSheet(after: action, availability: .ready, hint: .openMusicOnce, isPlaying: false))
            XCTAssertTrue(Policy.presentsSheet(after: action, availability: .ready, hint: .signIn, isPlaying: false))
            XCTAssertTrue(Policy.presentsSheet(after: action, availability: .ready, hint: .noSourceAvailable, isPlaying: false))
            for availability in [FocusMusicAvailability.subscriptionOffer, .denied, .unavailable, .checkFailed] {
                XCTAssertTrue(
                    Policy.presentsSheet(after: action, availability: availability, hint: nil, isPlaying: false),
                    "the play revealed \(availability)"
                )
            }
        }
        XCTAssertFalse(Policy.presentsSheet(after: .pause, availability: .ready, hint: .openMusicOnce, isPlaying: false))
        XCTAssertFalse(Policy.presentsSheet(after: .ignore, availability: .checkFailed, hint: nil, isPlaying: false))
    }

    func testTheSheetTransportPausesAndResumesInEveryAuthorizedState() {
        typealias Policy = FocusMusicTransportPolicy
        let stopped = FocusMusicNowPlaying(status: .stopped)
        let playing = FocusMusicNowPlaying(status: .playing, title: "x")
        let paused = FocusMusicNowPlaying(status: .paused, title: "x")
        let interrupted = FocusMusicNowPlaying(status: .interrupted)

        XCTAssertEqual(Policy.toggle(availability: .ready, chosen: classical, nowPlaying: stopped, queuedSourceID: nil), .play(classical))
        XCTAssertEqual(Policy.toggle(availability: .ready, chosen: nil, nowPlaying: stopped, queuedSourceID: nil), .unavailable)
        XCTAssertEqual(Policy.toggle(availability: .ready, chosen: classical, nowPlaying: paused, queuedSourceID: nil), .play(classical), "replaces a queue this process did not start")
        XCTAssertEqual(Policy.toggle(availability: .ready, chosen: classical, nowPlaying: paused, queuedSourceID: station.id), .resume)
        XCTAssertEqual(Policy.toggle(availability: .ready, chosen: nil, nowPlaying: paused, queuedSourceID: nil), .resume)
        XCTAssertTrue(Policy.showsNowPlaying(availability: .ready, nowPlaying: stopped))

        for availability in [FocusMusicAvailability.checking, .checkFailed, .subscriptionOffer, .unavailable] {
            XCTAssertEqual(Policy.toggle(availability: availability, chosen: classical, nowPlaying: playing, queuedSourceID: nil), .pause, "\(availability)")
            XCTAssertEqual(Policy.toggle(availability: availability, chosen: classical, nowPlaying: paused, queuedSourceID: nil), .resume, "\(availability)")
            XCTAssertEqual(Policy.toggle(availability: availability, chosen: classical, nowPlaying: interrupted, queuedSourceID: nil), .resume, "\(availability)")
            XCTAssertEqual(Policy.toggle(availability: availability, chosen: classical, nowPlaying: stopped, queuedSourceID: nil), .unavailable, "never starts catalog music: \(availability)")
            XCTAssertTrue(Policy.showsNowPlaying(availability: availability, nowPlaying: playing), "\(availability)")
            XCTAssertTrue(Policy.showsNowPlaying(availability: availability, nowPlaying: paused), "\(availability)")
            XCTAssertFalse(Policy.showsNowPlaying(availability: availability, nowPlaying: stopped), "\(availability)")
        }
        for availability in [FocusMusicAvailability.needsAuthorization, .denied, .restricted] {
            XCTAssertEqual(Policy.toggle(availability: availability, chosen: classical, nowPlaying: playing, queuedSourceID: nil), .unavailable)
            XCTAssertFalse(Policy.showsNowPlaying(availability: availability, nowPlaying: playing))
        }
    }

    func testRowsOfferPlaybackOnlyWhenATapCanLeadToIt() {
        // D4.3: with no permission, or no subscription and no offer, the rows
        // only remember a choice.
        let expected: [FocusMusicAvailability: Bool] = [
            .ready: true,
            .checking: true,
            .checkFailed: true,
            .needsAuthorization: true,
            .subscriptionOffer: true,
            .denied: false,
            .restricted: false,
            .unavailable: false,
        ]
        for (availability, allows) in expected {
            XCTAssertEqual(availability.allowsRowPlayback, allows, "\(availability)")
        }
    }

    func testTheSheetClosesBeforeTheTimerEndsAndStaysClosed() {
        typealias Policy = FocusMusicSheetPolicy
        XCTAssertEqual(Policy.closesBeforeEndSeconds, 1)
        XCTAssertFalse(Policy.keepsSheetClosed(isRunning: true, remainingSeconds: 25 * 60))
        XCTAssertFalse(Policy.keepsSheetClosed(isRunning: true, remainingSeconds: 2))
        XCTAssertTrue(Policy.keepsSheetClosed(isRunning: true, remainingSeconds: 1), "the last second, before the alarm")
        XCTAssertTrue(Policy.keepsSheetClosed(isRunning: true, remainingSeconds: 0), "a break's end stays on screen with its alarm")
        XCTAssertFalse(Policy.keepsSheetClosed(isRunning: false, remainingSeconds: 1), "a paused focus does not end")
        XCTAssertFalse(Policy.keepsSheetClosed(isRunning: false, remainingSeconds: 0), "idle before the focus starts")
    }

    func testFocusViewFeedsAutoplayOnlyALocalRunningFocus() {
        let session = UUID()
        let start = clock.addingTimeInterval(-3)
        typealias FocusStart = FocusMusicButton.FocusStart

        let running = FocusStart.make(phase: .focusing, currentSessionID: session, phaseStartedAt: start, origin: .local)
        XCTAssertEqual(running, FocusStart(sessionID: session, startedAt: start, isStartedOnThisIPhone: true))

        let handedOff = FocusStart.make(phase: .focusing, currentSessionID: session, phaseStartedAt: start, origin: .iCloud)
        XCTAssertEqual(handedOff.sessionID, session)
        XCTAssertFalse(handedOff.isStartedOnThisIPhone, "a focus continued from iCloud never autoplays")

        for phase in [PomodoroPhase.paused, .idle, .shortBreak, .longBreak, .focusCompleted, .breakCompleted] {
            XCTAssertNil(
                FocusStart.make(phase: phase, currentSessionID: session, phaseStartedAt: start, origin: .local).sessionID,
                "\(phase)"
            )
        }
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
            playback: .stopped,
            isOtherAudioPlaying: false
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
        refused({ $0.isOtherAudioPlaying = true }, "never interrupts another app's audio")
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

    /// The hint can show in a sheet opened from a running focus, where going
    /// to the Music app pauses the focus while the leave pause is on (F1).
    /// Every hint that sends the person to the Music app suggests a break.
    func testHintsThatSendThePersonToTheMusicAppSuggestABreak() {
        for hint in [FocusMusicHint.openMusicOnce, .signIn] {
            XCTAssertTrue(hint.message.contains("「ミュージック」アプリ"), "\(hint)")
            XCTAssertTrue(hint.message.contains("休憩のときなどに"), "\(hint) must not ask to leave a running focus")
        }
        XCTAssertFalse(FocusMusicHint.noSourceAvailable.message.contains("「ミュージック」アプリ"))
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

    func testForegroundRefreshReadsChangedPermissionWithoutPromptingOrPlaying() async {
        authorizer.status = .denied
        let controller = makeController()
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertEqual(controller.availability, .denied)
        authorizer.status = .authorized
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertEqual(controller.availability, .ready)
        authorizer.status = .denied
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertEqual(controller.availability, .denied)
        XCTAssertEqual(authorizer.requestCount, 0)
        XCTAssertTrue(player.attempts.isEmpty)
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
        let second = Task { () -> FocusMusicAvailability in
            await controller.refresh(forceSubscriptionCheck: true)
            return controller.availability
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(controller.availability, .checking)

        subscriptions.resume()
        let secondSaw = await second.value
        await first.value

        XCTAssertEqual(subscriptions.callCount, 1)
        XCTAssertEqual(secondSaw, .ready, "the joining caller reads the answer as soon as its own await returns")
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

    // MARK: - Controller: callers joining a running subscription check

    /// Waits until the fake player has been asked to play `count` times.
    private func waitForPlayAttempts(_ count: Int) async {
        for _ in 0..<100 where player.attempts.count < count {
            await Task.yield()
        }
    }

    func testAHeaderTapThatJoinsTheFirstCheckPlaysOnceItAnswers() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        subscriptions.suspends = true
        let controller = makeController()
        // The button's `.task` owns the first check after launch.
        let buttonAppeared = Task { await controller.refresh() }
        await subscriptions.waitUntilCalled()
        let tap = Task { () -> (FocusMusicHeaderAction, [String]) in
            let action = await controller.handleHeaderTap()
            return (action, self.player.attempts)
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(player.attempts, [])

        subscriptions.resume()
        let (action, attemptsWhenTapReturned) = await tap.value
        await buttonAppeared.value

        XCTAssertEqual(action, .play(classical), "not the sheet: the answer was ready when the tap resumed")
        XCTAssertEqual(attemptsWhenTapReturned, [classical.id])
        XCTAssertFalse(controller.presentsSheet(after: action))
        XCTAssertEqual(subscriptions.callCount, 1)
    }

    func testARowTapThatJoinsTheFirstCheckPlaysOnceItAnswers() async {
        subscriptions.suspends = true
        let controller = makeController()
        // The sheet's `.task` owns the check.
        let sheetAppeared = Task { await controller.refresh(forceSubscriptionCheck: true) }
        await subscriptions.waitUntilCalled()
        let row = Task { () -> (FocusMusicChoiceOutcome, [String]) in
            let outcome = await controller.choose(classical)
            return (outcome, self.player.attempts)
        }
        for _ in 0..<5 { await Task.yield() }

        subscriptions.resume()
        let (outcome, attemptsWhenChooseReturned) = await row.value
        await sheetAppeared.value

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(attemptsWhenChooseReturned, [classical.id])
        XCTAssertEqual(subscriptions.callCount, 1)
    }

    func testAutoplayThatJoinsTheFirstCheckAfterLaunchStillStarts() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        subscriptions.suspends = true
        let controller = makeController()
        let buttonAppeared = Task { await controller.refresh() }
        await subscriptions.waitUntilCalled()
        let session = UUID()
        let autoplay = Task { () -> [String] in
            await controller.autoplayIfNeeded(
                sessionID: session,
                startedAt: self.clock,
                isStartedOnThisIPhone: true
            )
            return self.player.attempts
        }
        for _ in 0..<5 { await Task.yield() }

        subscriptions.resume()
        let attemptsWhenAutoplayReturned = await autoplay.value
        await buttonAppeared.value

        XCTAssertEqual(attemptsWhenAutoplayReturned, [pianoChill.id], "the first focus after launch is not skipped")
        XCTAssertEqual(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults), session)
        XCTAssertEqual(subscriptions.callCount, 1)
    }

    func testCancelledAutoplayDoesNotStartAfterTheSharedSubscriptionCheckFinishes() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        subscriptions.suspends = true
        let controller = makeController()
        let autoplay = Task {
            await controller.autoplayIfNeeded(sessionID: UUID(), startedAt: self.clock,
                                             isStartedOnThisIPhone: true)
        }
        await subscriptions.waitUntilCalled()
        autoplay.cancel()
        subscriptions.resume()
        await autoplay.value
        XCTAssertEqual(controller.availability, .ready, "Other callers can still use the shared answer")
        XCTAssertTrue(player.attempts.isEmpty)
        XCTAssertNil(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults))
    }

    func testLatestRowChoiceWinsWhileTheInitialSubscriptionCheckIsPending() async {
        subscriptions.suspends = true
        player.suspendsPlay = true
        let controller = makeController()
        let first = Task { await controller.choose(self.classical) }
        await subscriptions.waitUntilCalled()
        let second = Task { await controller.choose(self.pianoChill) }
        for _ in 0..<100 where controller.chosenSource != pianoChill { await Task.yield() }
        XCTAssertEqual(controller.chosenSource, pianoChill)
        subscriptions.resume()
        await waitForPlayAttempts(1)
        XCTAssertEqual(player.attempts, [pianoChill.id])
        player.releasePlay()
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(controller.nowPlaying.title, "T-\(pianoChill.id)")
        XCTAssertEqual(controller.chosenSource, pianoChill)
    }

    func testTheSheetsRecheckKeepsTheKnownAnswerSoARowTapPlaysAtOnce() async {
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(controller.availability, .ready)

        subscriptions.suspends = true
        let sheetAppeared = Task { await controller.refresh(forceSubscriptionCheck: true) }
        await subscriptions.waitUntilCalled(times: 2)
        XCTAssertEqual(controller.availability, .ready, "no spinner over a known answer")

        let outcome = await controller.choose(classical)
        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(player.attempts, [classical.id], "played without waiting for the re-check")

        subscriptions.resume()
        await sheetAppeared.value
        XCTAssertEqual(controller.availability, .ready)
    }

    func testSubscriptionChecksNeverMakeAKnownAnswerWorse() {
        typealias Policy = FocusMusicSubscriptionPolicy
        let subscriber = FocusMusicSubscriptionState.known(
            FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false)
        )
        let lapsed = FocusMusicSubscriptionState.known(
            FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true)
        )
        XCTAssertEqual(Policy.stateWhileChecking(.unknown), .checking)
        XCTAssertEqual(Policy.stateWhileChecking(.failed), .checking)
        XCTAssertEqual(Policy.stateWhileChecking(subscriber), subscriber)

        XCTAssertEqual(Policy.stateAfterCheck(.checking, result: .failed), .failed)
        XCTAssertEqual(Policy.stateAfterCheck(.checking, result: subscriber), subscriber)
        XCTAssertEqual(Policy.stateAfterCheck(subscriber, result: .failed), subscriber, "a failed re-check keeps the answer")
        XCTAssertEqual(Policy.stateAfterCheck(subscriber, result: lapsed), lapsed, "a real new answer wins")
        XCTAssertEqual(Policy.stateAfterCheck(lapsed, result: subscriber), subscriber)
    }

    func testAFailedRecheckKeepsAKnownAnswer() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(controller.availability, .ready)

        subscriptions.result = .failure(URLError(.notConnectedToInternet))
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertEqual(controller.availability, .ready)
        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))

        // A successful answer still replaces it: a lapsed subscription shows.
        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true))
        await controller.refresh(forceSubscriptionCheck: true)
        XCTAssertEqual(controller.availability, .subscriptionOffer)
    }

    func testAFailedRecheckKeepsTheAnswerPlaybackProved() async {
        // Offline, or MusicSubscription failing before the App Service is on.
        subscriptions.result = .failure(URLError(.notConnectedToInternet))
        let controller = makeController()
        await controller.refresh()
        _ = await controller.choose(classical)
        XCTAssertEqual(controller.availability, .ready)

        // The sheet opens again and its re-check still fails.
        await controller.refresh(forceSubscriptionCheck: true)

        XCTAssertEqual(controller.availability, .ready)
        XCTAssertTrue(controller.showsNowPlaying)
        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .pause)
    }

    // MARK: - Controller: pausing whatever the subscription says

    func testANonSubscribersOwnMusicCanBePausedAndResumed() async {
        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true))
        player.nowPlaying = FocusMusicNowPlaying(status: .playing, title: "Purchased album")
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(controller.availability, .subscriptionOffer)
        XCTAssertEqual(controller.headerAction, .pause, "the label promises what the tap does")
        XCTAssertTrue(controller.showsNowPlaying)

        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .pause)
        XCTAssertEqual(player.pauseCount, 1)
        XCTAssertFalse(controller.presentsSheet(after: action))

        // Paused, the sheet still shows the card and resumes the same music.
        XCTAssertTrue(controller.showsNowPlaying)
        XCTAssertEqual(controller.transportToggle, .resume)
        await controller.togglePlayback()
        XCTAssertEqual(player.resumeCount, 1)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(player.attempts, [], "nothing from the catalog is started")
    }

    func testMusicStartedWhileUnavailableOrUncheckedCanBePaused() async {
        for result: Result<FocusMusicSubscription, Error> in [
            .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: false)),
            .failure(URLError(.notConnectedToInternet)),
        ] {
            subscriptions.result = result
            player.nowPlaying = FocusMusicNowPlaying(status: .playing, title: "x")
            let controller = makeController()
            await controller.refresh()
            XCTAssertNotEqual(controller.availability, .ready)
            let action = await controller.handleHeaderTap()
            XCTAssertEqual(action, .pause, "\(controller.availability)")
            XCTAssertFalse(controller.isPlaying)
        }
    }

    func testAPauseDuringAStartWinsAndTheStartEndsPaused() async {
        player.nowPlaying = FocusMusicNowPlaying(status: .playing, title: "The person's own music")
        let controller = makeController()
        await controller.refresh()
        player.suspendsPlay = true
        let row = Task { await controller.choose(pianoChill) }
        await waitForPlayAttempts(1)
        XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(controller.headerAction, .pause, "a start in flight never blocks a pause")

        let action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .pause)
        player.releasePlay()
        _ = await row.value

        XCTAssertEqual(player.attempts, [pianoChill.id])
        XCTAssertFalse(controller.isPlaying, "the start that was in flight ends paused")
        XCTAssertEqual(player.pauseCount, 2)
        XCTAssertFalse(controller.isBusy)
    }

    // MARK: - Controller: a header play that does not start

    func testAHeaderPlayThatFailsOpensTheSheetWithItsHint() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        let controller = makeController()

        player.failures[classical.id] = .failed
        var action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))
        XCTAssertEqual(controller.hint, .openMusicOnce)
        XCTAssertTrue(controller.presentsSheet(after: action), "the hint is seen, not lost")

        // A lapsed subscription turns into Apple's offer in the sheet.
        player.failures[classical.id] = .subscriptionRequired
        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: false, canBecomeSubscriber: true))
        action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))
        XCTAssertEqual(controller.availability, .subscriptionOffer)
        XCTAssertTrue(controller.presentsSheet(after: action))

        subscriptions.result = .success(FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false))
        await controller.refresh(forceSubscriptionCheck: true)
        player.failures[classical.id] = nil
        action = await controller.handleHeaderTap()
        XCTAssertEqual(action, .play(classical))
        XCTAssertFalse(controller.presentsSheet(after: action), "a play that started stays on the timer")
    }

    // MARK: - Controller: D4.3 branches

    func testARowTapAsksForPermissionOnceThenPlays() async {
        authorizer.status = .notDetermined
        authorizer.requestResult = .authorized
        let controller = makeController()

        let outcome = await controller.choose(pianoChill)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(subscriptions.callCount, 1)
        XCTAssertEqual(player.attempts, [pianoChill.id])
        XCTAssertEqual(FocusMusicPreferences.chosenSource(defaults: defaults), pianoChill)
    }

    func testARowTapAnsweredWithDenyPlaysNothing() async {
        authorizer.status = .notDetermined
        authorizer.requestResult = .denied
        let controller = makeController()

        let outcome = await controller.choose(pianoChill)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(player.attempts, [])
        XCTAssertEqual(controller.availability, .denied)
        XCTAssertFalse(controller.availability.allowsRowPlayback)
        XCTAssertEqual(subscriptions.callCount, 0)
    }

    func testASkipThatFailsShowsTheGentleHint() async {
        let controller = makeController()
        await controller.refresh()
        player.skipError = FocusMusicPlaybackError.failed

        await controller.skipToNext()

        XCTAssertEqual(player.skipCount, 1)
        XCTAssertEqual(controller.hint, .openMusicOnce)
    }

    func testAPermissionErrorWhileStillAuthorizedShowsTheGentleHint() async {
        // MusicKit's privacyAcknowledgementRequired: the status stays
        // authorized, and opening the Music app once clears it.
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        player.failures[classical.id] = .permissionDenied
        let controller = makeController()

        await controller.handleHeaderTap()

        XCTAssertEqual(controller.availability, .ready)
        XCTAssertEqual(controller.hint, .openMusicOnce)
    }

    func testASubscriptionErrorWhileStillSubscribedShowsTheGentleHint() async {
        FocusMusicPreferences.setChosenSource(classical, defaults: defaults)
        player.failures[classical.id] = .subscriptionRequired
        let controller = makeController()

        await controller.handleHeaderTap()

        XCTAssertEqual(subscriptions.callCount, 2, "the error re-reads the subscription")
        XCTAssertEqual(controller.availability, .ready)
        XCTAssertEqual(controller.hint, .openMusicOnce)
    }

    // MARK: - Controller: other apps' audio

    func testAutoplayLeavesAnotherAppsAudioAlone() async {
        FocusMusicPreferences.setChosenSource(pianoChill, defaults: defaults)
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        // A podcast or another music app: the Music app itself reports stopped.
        player.nowPlaying = FocusMusicNowPlaying(status: .stopped)
        player.isOtherAudioPlaying = true
        let controller = makeController()

        await controller.autoplayIfNeeded(sessionID: UUID(), startedAt: clock, isStartedOnThisIPhone: true)

        XCTAssertEqual(player.attempts, [])
        XCTAssertNil(FocusMusicPreferences.lastAutoplayedSessionID(defaults: defaults))

        player.isOtherAudioPlaying = false
        let session = UUID()
        await controller.autoplayIfNeeded(sessionID: session, startedAt: clock, isStartedOnThisIPhone: true)
        XCTAssertEqual(player.attempts, [pianoChill.id])
    }

    func testAutoplayLeavesAudioStartedWhileTheSourceLoadsAlone() async {
        FocusMusicPreferences.setAutoplayEnabled(true, defaults: defaults)
        for source in [pianoChill, .libraryPlaylist(id: "p.study", title: "Study")] {
            for musicAppIsPlaying in [false, true] {
                FocusMusicPreferences.setChosenSource(source, defaults: defaults)
                player.nowPlaying = FocusMusicNowPlaying()
                player.isOtherAudioPlaying = false
                player.suspendsPlay = true
                let controller = makeController()
                let session = UUID()
                let expectedAttempts = player.attempts.count + 1
                let start = Task {
                    await controller.autoplayIfNeeded(
                        sessionID: session, startedAt: clock, isStartedOnThisIPhone: true
                    )
                }
                await waitForPlayAttempts(expectedAttempts)
                XCTAssertTrue(controller.isBusy)

                // Either Music or an unrelated audio app starts while the
                // selected catalog/library source is still being prepared.
                let externalState = FocusMusicNowPlaying(
                    status: musicAppIsPlaying ? .playing : .stopped,
                    title: musicAppIsPlaying ? "My Music queue" : nil
                )
                player.nowPlaying = externalState
                player.currentEntryID = "external-queue"
                player.isOtherAudioPlaying = !musicAppIsPlaying
                player.releasePlay()
                await start.value

                XCTAssertEqual(player.nowPlaying, externalState)
                XCTAssertEqual(player.currentEntryID, "external-queue")
                XCTAssertEqual(player.attempts.count, expectedAttempts, "skipping must not try another source")
                XCTAssertNil(controller.queuedSourceID, "the external queue must not become our choice")
                XCTAssertNil(controller.hint, "yielding to another app is not a playback failure")
                XCTAssertFalse(controller.isBusy)

                // This focus consumed its one automatic attempt. It must not
                // start later merely because the external audio stopped.
                player.nowPlaying = FocusMusicNowPlaying()
                player.isOtherAudioPlaying = false
                await controller.autoplayIfNeeded(
                    sessionID: session, startedAt: clock, isStartedOnThisIPhone: true
                )
                XCTAssertEqual(player.attempts.count, expectedAttempts)
            }
        }
    }

    func testManualSelectionMayReplaceAudioStartedWhileTheSourceLoads() async {
        for musicAppIsPlaying in [false, true] {
            player.nowPlaying = FocusMusicNowPlaying()
            player.isOtherAudioPlaying = false
            player.suspendsPlay = true
            let controller = makeController()
            let expectedAttempts = player.attempts.count + 1
            let start = Task { await controller.choose(pianoChill) }
            await waitForPlayAttempts(expectedAttempts)

            player.nowPlaying = FocusMusicNowPlaying(status: musicAppIsPlaying ? .playing : .stopped)
            player.currentEntryID = "external-queue"
            player.isOtherAudioPlaying = !musicAppIsPlaying
            player.releasePlay()
            _ = await start.value

            XCTAssertEqual(player.attempts.count, expectedAttempts)
            XCTAssertEqual(player.nowPlaying, FocusMusicNowPlaying(status: .playing, title: "T-\(pianoChill.id)"))
            XCTAssertNotEqual(player.currentEntryID, "external-queue")
            XCTAssertEqual(controller.queuedSourceID, pianoChill.id)
            XCTAssertNil(controller.hint)
            XCTAssertFalse(controller.isBusy)
        }
    }

    // MARK: - MediaPlayer's prepareToPlay deadline

    func testACallbackThatNeverComesTimesOut() async {
        do {
            try await FocusMusicCallbackDeadline.wait(
                timeout: .milliseconds(50),
                timeoutError: FocusMusicPlaybackError.failed
            ) { _ in }
            XCTFail("a missing callback must not wait forever")
        } catch {
            XCTAssertEqual(error as? FocusMusicPlaybackError, .failed)
        }
    }

    func testACallbackBeforeTheDeadlineDecidesTheResult() async throws {
        try await FocusMusicCallbackDeadline.wait(
            timeout: .seconds(30),
            timeoutError: FocusMusicPlaybackError.failed
        ) { completion in
            DispatchQueue.global().async { completion(nil) }
        }

        do {
            try await FocusMusicCallbackDeadline.wait(
                timeout: .seconds(30),
                timeoutError: FocusMusicPlaybackError.failed
            ) { completion in
                completion(URLError(.timedOut))
                completion(nil)
            }
            XCTFail("the callback's error is thrown")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut, "only the first answer counts")
        }
    }

    func testACallbackAfterTheDeadlineIsIgnored() async {
        let late = LateCallback()
        do {
            try await FocusMusicCallbackDeadline.wait(
                timeout: .milliseconds(20),
                timeoutError: FocusMusicPlaybackError.failed
            ) { completion in
                late.completion = completion
            }
            XCTFail("timed out first")
        } catch {
            XCTAssertEqual(error as? FocusMusicPlaybackError, .failed)
        }
        // Resuming the continuation a second time would trap.
        late.completion?(nil)
        late.completion?(URLError(.cancelled))
    }
}

private final class LateCallback: @unchecked Sendable {
    var completion: (@Sendable (Error?) -> Void)?
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
    /// Read when a call answers, so a suspended call answers with the
    /// result set before `resume()`.
    var result: Result<FocusMusicSubscription, Error> = .success(
        FocusMusicSubscription(canPlayCatalogContent: true, canBecomeSubscriber: false)
    )
    var suspends = false
    private(set) var callCount = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var calledWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func current() async throws -> FocusMusicSubscription {
        callCount += 1
        let reached = calledWaiters.filter { $0.count <= callCount }
        calledWaiters.removeAll { $0.count <= callCount }
        reached.forEach { $0.continuation.resume() }
        if suspends {
            await withCheckedContinuation { gates.append($0) }
        }
        return try result.get()
    }

    /// Returns once `current()` has been called `times` times in total.
    func waitUntilCalled(times: Int = 1) async {
        guard callCount < times else { return }
        await withCheckedContinuation { calledWaiters.append((times, $0)) }
    }

    func resume() {
        let waiting = gates
        gates.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class FakeMusicPlayer: FocusMusicPlaying {
    var nowPlaying = FocusMusicNowPlaying()
    var currentEntryID: String? = "initial-entry"
    var isOtherAudioPlaying = false
    var failures: [String: FocusMusicPlaybackError] = [:]
    var resumeError: Error?
    var skipError: Error?
    var beforeFailure: (() -> Void)?
    /// Holds each `play` until `releasePlay()`, like a slow catalog lookup.
    var suspendsPlay = false
    private(set) var attempts: [String] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var skipCount = 0
    private(set) var observeCount = 0
    private(set) var onChange: (@MainActor () -> Void)?
    private var playGate: CheckedContinuation<Void, Never>?

    private(set) var shuffleChoices: [Bool] = []

    func play(
        _ source: FocusMusicSource, shuffle: Bool, intent: FocusMusicPlaybackIntent
    ) async throws -> FocusMusicPlaybackStartOutcome {
        attempts.append(source.id)
        shuffleChoices.append(shuffle)
        if suspendsPlay {
            await withCheckedContinuation { playGate = $0 }
        }
        if let failure = failures[source.id] {
            beforeFailure?()
            throw failure
        }
        try Task.checkCancellation()
        guard intent.allowsStarting(
            playback: nowPlaying.status, isOtherAudioPlaying: isOtherAudioPlaying
        ) else { return .skippedForOtherAudio }
        currentEntryID = UUID().uuidString
        nowPlaying = FocusMusicNowPlaying(status: .playing, title: "T-\(source.id)")
        return .started
    }

    func releasePlay() {
        playGate?.resume()
        playGate = nil
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
        if let skipError { throw skipError }
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        observeCount += 1
        self.onChange = onChange
    }
}

@MainActor
private final class FakeMusicCatalog: FocusMusicCatalogNaming {
    var names: [String: String] = [:]
    var results: [FocusMusicSource] = []
    private(set) var searchedTerms: [String] = []
    private(set) var callCount = 0
    var libraryPages: [Int: [FocusMusicSource]] = [:]
    private(set) var libraryOffsets: [Int] = []

    func libraryPlaylists(offset: Int, limit: Int) async throws -> [FocusMusicSource] {
        libraryOffsets.append(offset)
        return libraryPages[offset] ?? []
    }

    func search(term: String) async throws -> [FocusMusicSource] {
        searchedTerms.append(term)
        return results
    }

    func titles(for sources: [FocusMusicSource]) async -> [String: String] {
        callCount += 1
        return names
    }
}
