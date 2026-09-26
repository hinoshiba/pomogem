import Combine
import Foundation
import MediaPlayer
import MusicKit

// Real-device adapters for focus background music. They need a signed build,
// the Music app, an Apple Music subscription and, for catalog lookups, the
// MusicKit App Service on App ID com.hinoshiba.pomogem (Docs/FocusMusic.md).
// None of this runs in unit tests; FocusMusicController is tested with fakes.

@MainActor
struct SystemFocusMusicAuthorizer: FocusMusicAuthorizing {
    var currentStatus: FocusMusicAuthorization {
        Self.map(MusicAuthorization.currentStatus)
    }

    func request() async -> FocusMusicAuthorization {
        Self.map(await MusicAuthorization.request())
    }

    static func map(_ status: MusicAuthorization.Status) -> FocusMusicAuthorization {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }
}

@MainActor
struct SystemFocusMusicSubscriptions: FocusMusicSubscriptionChecking {
    func current() async throws -> FocusMusicSubscription {
        let subscription = try await MusicSubscription.current
        return FocusMusicSubscription(
            canPlayCatalogContent: subscription.canPlayCatalogContent,
            canBecomeSubscriber: subscription.canBecomeSubscriber
        )
    }
}

/// `SystemMusicPlayer` first (D4.1). When the developer token is unavailable
/// the playlist is queued by store ID through
/// `MPMusicPlayerController.systemMusicPlayer` instead, and later controls go
/// through the same framework. Both drive the Music app; PomoGem never
/// becomes the Now Playing app and adds no audio background mode.
@MainActor
final class SystemFocusMusicPlayer: FocusMusicPlaying {
    private enum Route {
        case musicKit
        case mediaPlayer
    }

    private var route: Route = .musicKit
    private var onChange: (@MainActor () -> Void)?
    private var stateObserver: AnyCancellable?
    private var queueObserver: AnyCancellable?
    private var mediaPlayerObservers: [NSObjectProtocol] = []

    var nowPlaying: FocusMusicNowPlaying {
        switch route {
        case .musicKit:
            let player = SystemMusicPlayer.shared
            return FocusMusicNowPlaying(
                status: Self.map(player.state.playbackStatus),
                title: player.queue.currentEntry?.title
            )
        case .mediaPlayer:
            let player = MPMusicPlayerController.systemMusicPlayer
            return FocusMusicNowPlaying(
                status: Self.map(player.playbackState),
                title: player.nowPlayingItem?.title
            )
        }
    }

    func play(_ source: FocusMusicSource) async throws {
        do {
            let player = SystemMusicPlayer.shared
            switch source.kind {
            case .playlist:
                let playlist = try await Self.catalogPlaylist(source)
                player.queue = [playlist]
            case .station:
                let station = try await Self.catalogStation(source)
                player.queue = [station]
            }
            try await player.play()
            route = .musicKit
            observeMusicKitQueue()
        } catch let error as FocusMusicPlaybackError {
            throw error
        } catch {
            switch FocusMusicCatalogRoutePolicy.route(for: source, after: Self.catalogFailure(error)) {
            case .mediaPlayerQueue:
                try await playByStoreID(source)
            case .fail(let failure):
                throw failure
            }
        }
    }

    func pause() {
        switch route {
        case .musicKit: SystemMusicPlayer.shared.pause()
        case .mediaPlayer: MPMusicPlayerController.systemMusicPlayer.pause()
        }
    }

    func resume() async throws {
        switch route {
        case .musicKit:
            try await SystemMusicPlayer.shared.play()
        case .mediaPlayer:
            MPMusicPlayerController.systemMusicPlayer.play()
        }
    }

    func skipToNext() async throws {
        switch route {
        case .musicKit:
            try await SystemMusicPlayer.shared.skipToNextEntry()
        case .mediaPlayer:
            MPMusicPlayerController.systemMusicPlayer.skipToNextItem()
        }
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        // `objectWillChange` fires before the value changes; the main-queue
        // hop delivers it after the change, on the main actor.
        stateObserver = SystemMusicPlayer.shared.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            }
        observeMusicKitQueue()
        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [
            Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange,
            Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
        ] {
            mediaPlayerObservers.append(center.addObserver(
                forName: name,
                object: player,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            })
        }
    }

    private func observeMusicKitQueue() {
        guard onChange != nil else { return }
        queueObserver = SystemMusicPlayer.shared.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.notifyChange() }
            }
    }

    private func notifyChange() {
        onChange?()
    }

    /// The stopgap while the MusicKit App Service is off: playlists only.
    private func playByStoreID(_ source: FocusMusicSource) async throws {
        let player = MPMusicPlayerController.systemMusicPlayer
        player.setQueue(with: [source.id])
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                player.prepareToPlay { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            let nsError = error as NSError
            guard nsError.domain == MPErrorDomain else { throw FocusMusicPlaybackError.failed }
            throw Self.playbackError(forMediaPlayerCode: MPError.Code(rawValue: nsError.code))
        }
        player.play()
        route = .mediaPlayer
    }

    private static func catalogPlaylist(_ source: FocusMusicSource) async throws -> Playlist {
        var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(source.id))
        if #available(iOS 26.4, *) { request.options = [.findEquivalents] }
        guard let playlist = try await request.response().items.first else {
            throw FocusMusicPlaybackError.notInStorefront
        }
        return playlist
    }

    private static func catalogStation(_ source: FocusMusicSource) async throws -> Station {
        var request = MusicCatalogResourceRequest<Station>(matching: \.id, equalTo: MusicItemID(source.id))
        if #available(iOS 26.4, *) { request.options = [.findEquivalents] }
        guard let station = try await request.response().items.first else {
            throw FocusMusicPlaybackError.notInStorefront
        }
        return station
    }

    static func catalogFailure(_ error: Error) -> FocusMusicCatalogFailure {
        if let tokenError = error as? MusicTokenRequestError {
            switch tokenError {
            case .developerTokenRequestFailed:
                return .developerTokenUnavailable
            case .permissionDenied, .privacyAcknowledgementRequired:
                return .permissionDenied
            case .userNotSignedIn, .userTokenRevoked, .userTokenRequestFailed:
                return .notSignedIn
            case .unknown:
                return .other
            @unknown default:
                return .other
            }
        }
        if let dataError = error as? MusicDataRequest.Error {
            return catalogFailure(httpStatus: dataError.status)
        }
        return .other
    }

    static func catalogFailure(httpStatus: Int) -> FocusMusicCatalogFailure {
        switch httpStatus {
        case 401, 403: .developerTokenUnavailable
        case 404: .notFound
        default: .other
        }
    }

    static func playbackError(forMediaPlayerCode code: MPError.Code?) -> FocusMusicPlaybackError {
        switch code {
        case .permissionDenied: .permissionDenied
        case .cloudServiceCapabilityMissing: .subscriptionRequired
        case .notFound: .notInStorefront
        default: .failed
        }
    }

    static func map(_ status: MusicKit.MusicPlayer.PlaybackStatus) -> FocusMusicPlaybackStatus {
        switch status {
        case .playing, .seekingForward, .seekingBackward: .playing
        case .paused: .paused
        case .interrupted: .interrupted
        case .stopped: .stopped
        @unknown default: .stopped
        }
    }

    static func map(_ state: MPMusicPlaybackState) -> FocusMusicPlaybackStatus {
        switch state {
        case .playing, .seekingForward, .seekingBackward: .playing
        case .paused: .paused
        case .interrupted: .interrupted
        case .stopped: .stopped
        @unknown default: .stopped
        }
    }
}

@MainActor
struct SystemFocusMusicCatalog: FocusMusicCatalogNaming {
    /// Needs the developer token; without it every title stays our label.
    func titles(for sources: [FocusMusicSource]) async -> [String: String] {
        var titles: [String: String] = [:]
        let playlistIDs = sources.filter { $0.kind == .playlist }.map { MusicItemID($0.id) }
        let stationIDs = sources.filter { $0.kind == .station }.map { MusicItemID($0.id) }
        if !playlistIDs.isEmpty,
           let response = try? await MusicCatalogResourceRequest<Playlist>(
               matching: \.id,
               memberOf: playlistIDs
           ).response() {
            for playlist in response.items { titles[playlist.id.rawValue] = playlist.name }
        }
        if !stationIDs.isEmpty,
           let response = try? await MusicCatalogResourceRequest<Station>(
               matching: \.id,
               memberOf: stationIDs
           ).response() {
            for station in response.items { titles[station.id.rawValue] = station.name }
        }
        return titles
    }
}
