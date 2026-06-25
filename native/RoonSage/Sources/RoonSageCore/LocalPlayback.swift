import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Plays library audio **on this device** — the iPhone (or Mac) as a listening
/// endpoint, independent of Roon's zones. Roon's own output (RAAT) is a licensed
/// closed SDK a third party can't join, so instead of registering a Roon zone we
/// stream the track's on-disk file from the analyser server's `/audio` endpoint
/// and decode it locally with AVFoundation.
///
/// This is a self-contained engine: it owns an `AVPlayer`, a small queue, the
/// audio session (iOS), and publishes observable state the UI binds to. It does
/// NOT touch `MPNowPlayingInfoCenter` — the iOS app's `NowPlayingCenter` reads
/// this engine and owns the system now-playing surface, so there's a single
/// writer. `onStateChange` lets that layer refresh on every transition.
@MainActor
@Observable
public final class LocalPlaybackController {
    public static let shared = LocalPlaybackController()

    /// A queued track. `id` is the library match key — the `/audio` lookup key.
    /// `streamURLOverride`, when set, is played directly (used for Qobuz: a
    /// signed CDN URL the phone fetches itself, bypassing the `/audio` server).
    public struct Track: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let artist: String
        public let album: String
        public let imageKey: String?
        public let durationSec: Double?
        public let streamURLOverride: URL?
        public init(id: String, title: String, artist: String, album: String,
                    imageKey: String?, durationSec: Double?, streamURLOverride: URL? = nil) {
            self.id = id; self.title = title; self.artist = artist
            self.album = album; self.imageKey = imageKey; self.durationSec = durationSec
            self.streamURLOverride = streamURLOverride
        }
    }

    public private(set) var queue: [Track] = []
    public private(set) var index: Int = 0
    public private(set) var isPlaying: Bool = false
    /// True while a local session is loaded — the UI uses this to know that
    /// "Deze iPhone" owns now-playing/transport (vs. a Roon zone).
    public private(set) var isEngaged: Bool = false
    public private(set) var positionSec: Double = 0
    /// User-facing error from the last action (e.g. a track that wouldn't load).
    public var lastError: String?

    public var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    /// Duration of the current track — the player's value once known, else the
    /// metadata hint.
    public var durationSec: Double {
        #if canImport(AVFoundation)
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { return d }
        }
        #endif
        return current?.durationSec ?? 0
    }

    /// Set by the iOS app so it can refresh `MPNowPlayingInfoCenter` and the
    /// home-screen widget whenever the engine's state changes. Kept as a closure
    /// so this core type never imports MediaPlayer. `@MainActor` so the handler
    /// can touch main-actor UI/system state directly.
    public var onStateChange: (@MainActor () -> Void)?

    #if canImport(AVFoundation)
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    #endif
    @ObservationIgnored private var streamBase: String = ""
    @ObservationIgnored private var token: String?

    private init() {
        #if canImport(AVFoundation)
        // Advance when the current item finishes (single AVPlayer + manual queue,
        // so end-of-track is a notification, not AVQueuePlayer item management).
        // Both callbacks are delivered on the main queue (the main actor's
        // executor), so assume isolation rather than hop through a Task — that
        // keeps it synchronous and avoids sending the non-Sendable AVPlayerItem
        // across an actor boundary.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let finished = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.handleItemEnded(finished) }
        }
        // ~2 Hz position updates drive the scrubber + lock-screen elapsed time.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.positionSec = time.seconds.isFinite ? max(0, time.seconds) : 0
                self.onStateChange?()
            }
        }
        #endif
    }

    // MARK: - Public transport

    /// Load a queue and start playing on this device. `streamBase` is the
    /// analyser server base (e.g. `http://host:5766`); `token` is the shared
    /// secret (sent as `X-RoonSage-Token`), nil if unpaired.
    public func play(_ tracks: [Track], streamBase: String, token: String?, startAt: Int = 0) {
        guard !tracks.isEmpty else { return }
        var base = streamBase.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }
        self.streamBase = base
        self.token = token
        queue = tracks
        isEngaged = true
        lastError = nil
        activateSession()
        load(index: min(max(0, startAt), tracks.count - 1), autoPlay: true)
    }

    public func togglePlayPause() {
        #if canImport(AVFoundation)
        guard isEngaged else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
        onStateChange?()
        #endif
    }

    public func next() {
        guard isEngaged else { return }
        if index + 1 < queue.count { load(index: index + 1, autoPlay: true) }
        else { stop() }
    }

    public func previous() {
        guard isEngaged else { return }
        // Standard behaviour: restart the track if we're past the intro,
        // otherwise step back.
        if positionSec > 3 || index == 0 { seek(toSeconds: 0) }
        else { load(index: index - 1, autoPlay: true) }
    }

    public func seek(toSeconds seconds: Double) {
        #if canImport(AVFoundation)
        guard isEngaged else { return }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t)
        positionSec = max(0, seconds)
        onStateChange?()
        #endif
    }

    public func seek(toFraction fraction: Double) {
        let d = durationSec
        guard d > 0 else { return }
        seek(toSeconds: max(0, min(1, fraction)) * d)
    }

    /// Tear down the session and clear state — local playback fully stops.
    public func stop() {
        #if canImport(AVFoundation)
        player.pause()
        player.replaceCurrentItem(with: nil)
        #endif
        isPlaying = false
        isEngaged = false
        queue = []
        index = 0
        positionSec = 0
        deactivateSession()
        onStateChange?()
    }

    // MARK: - Internals

    private func load(index i: Int, autoPlay: Bool) {
        index = i
        positionSec = 0
        #if canImport(AVFoundation)
        guard let item = makeItem(for: queue[i]) else {
            lastError = "Kon dit nummer niet laden."
            onStateChange?()
            return
        }
        player.replaceCurrentItem(with: item)
        if autoPlay { player.play(); isPlaying = true } else { player.pause(); isPlaying = false }
        #endif
        onStateChange?()
    }

    #if canImport(AVFoundation)
    private func makeItem(for track: Track) -> AVPlayerItem? {
        // Qobuz (or any direct CDN URL): play it straight, no /audio server.
        if let override = track.streamURLOverride { return AVPlayerItem(url: override) }
        var comps = URLComponents(string: "\(streamBase)/audio")
        // AVPlayer can't attach a custom auth header without private API, so the
        // token rides in the query (the /audio endpoint accepts both).
        var items = [URLQueryItem(name: "match_key", value: track.id)]
        if let token, !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        return AVPlayerItem(url: url)
    }

    private func handleItemEnded(_ finished: AVPlayerItem?) {
        // Ignore stale notifications from a replaced item.
        guard isEngaged, finished === player.currentItem else { return }
        next()
    }
    #endif

    // MARK: - Audio session (iOS only; macOS plays without a session)

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
