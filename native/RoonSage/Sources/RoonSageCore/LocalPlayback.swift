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
        /// K-weighted LUFS of this track / mean of its album (analyzer, F3) —
        /// drive the loudness-normalization gain; nil when not measured.
        public let lufs: Double?
        public let albumLufs: Double?
        public init(id: String, title: String, artist: String, album: String,
                    imageKey: String?, durationSec: Double?, streamURLOverride: URL? = nil,
                    lufs: Double? = nil, albumLufs: Double? = nil) {
            self.id = id; self.title = title; self.artist = artist
            self.album = album; self.imageKey = imageKey; self.durationSec = durationSec
            self.streamURLOverride = streamURLOverride
            self.lufs = lufs; self.albumLufs = albumLufs
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

    // MARK: Shuffle / repeat / volume — parity with the Roon zone hero, so the
    // merged Now Playing screen offers the same controls whether you're on a
    // zone or this device.

    /// Shuffle upcoming tracks (keeps the current one playing). Restoring the
    /// original order needs the untouched list, so `baseQueue` is kept alongside.
    public private(set) var shuffle: Bool = false
    /// "disabled" | "loop" (whole queue) | "loop_one" (repeat current) — the same
    /// vocabulary as Roon's loop mode, cycled via `NowPlayingHeroOptions.nextLoop`.
    public private(set) var loopMode: String = "disabled"
    /// User volume level 0…1, applied as a multiplier ON TOP of the loudness
    /// normalization gain (so the two never fight — see `reapplyVolume`).
    public private(set) var volume: Double = 1.0
    public private(set) var isMuted: Bool = false
    /// The queue in its ORIGINAL order, so turning shuffle off restores it.
    @ObservationIgnored private var baseQueue: [Track] = []
    /// Loudness-normalization gain for the current item; `player.volume` is this
    /// times the user volume (see `reapplyVolume`).
    @ObservationIgnored private var loudnessGain: Float = 1.0

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
    /// Watches the current item's `status` so a server-side failure surfaces as a
    /// visible error instead of a silent "engaged but no sound".
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
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
        baseQueue = tracks
        queue = tracks
        isEngaged = true
        lastError = nil
        activateSession()
        let start = min(max(0, startAt), tracks.count - 1)
        if shuffle {
            applyShuffleOrder(startingAt: start)
            load(index: 0, autoPlay: true)
        } else {
            load(index: start, autoPlay: true)
        }
    }

    // MARK: - Shuffle / repeat / volume

    /// Toggle shuffle without interrupting the current track: rebuild the queue
    /// array around the playing item (shuffled upcoming, or the original order).
    public func setShuffle(_ on: Bool) {
        guard shuffle != on else { return }
        shuffle = on
        guard isEngaged else { onStateChange?(); return }
        let cur = current
        if on {
            let curIdx = cur.flatMap { c in baseQueue.firstIndex(where: { $0.id == c.id }) } ?? index
            applyShuffleOrder(startingAt: curIdx)
        } else {
            queue = baseQueue
            index = cur.flatMap { c in baseQueue.firstIndex(where: { $0.id == c.id }) } ?? 0
        }
        onStateChange?()
    }

    /// Set the repeat mode ("disabled" | "loop" | "loop_one").
    public func setLoop(_ mode: String) {
        loopMode = mode
        onStateChange?()
    }

    /// Set the user volume (0…1). A non-zero level clears mute.
    public func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        if volume > 0 { isMuted = false }
        reapplyVolume()
        onStateChange?()
    }

    public func toggleMute() {
        isMuted.toggle()
        reapplyVolume()
        onStateChange?()
    }

    /// Rebuild `queue` with the chosen base-queue track first and the rest
    /// shuffled after it; leaves `index` at 0 (the current item), so no reload.
    private func applyShuffleOrder(startingAt i: Int) {
        guard !baseQueue.isEmpty else { return }
        var rest = baseQueue
        let first = baseQueue.indices.contains(i) ? rest.remove(at: i) : rest.removeFirst()
        queue = [first] + rest.shuffled()
        index = 0
    }

    private func reapplyVolume() {
        #if canImport(AVFoundation)
        player.volume = loudnessGain * Float(isMuted ? 0 : volume)
        #endif
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
        advance(auto: false)
    }

    /// Advance the queue, honouring the repeat mode. `auto` is true when a track
    /// finished on its own (so "loop_one" replays it); a user-pressed Next always
    /// steps forward. "loop" wraps at the end; otherwise the session stops.
    private func advance(auto: Bool) {
        if auto, loopMode == "loop_one" {
            seek(toSeconds: 0)
            #if canImport(AVFoundation)
            player.play(); isPlaying = true
            #endif
            onStateChange?()
            return
        }
        if index + 1 < queue.count { load(index: index + 1, autoPlay: true) }
        else if loopMode == "loop" { load(index: 0, autoPlay: true) }
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
        statusObserver?.invalidate()
        statusObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        #endif
        isPlaying = false
        isEngaged = false
        queue = []
        baseQueue = []
        index = 0
        positionSec = 0
        deactivateSession()
        onStateChange?()
    }

    // MARK: - Internals

    private func load(index i: Int, autoPlay: Bool) {
        index = i
        positionSec = 0
        lastError = nil
        #if canImport(AVFoundation)
        guard let item = makeItem(for: queue[i]) else {
            lastError = "Kon dit nummer niet laden."
            isPlaying = false
            onStateChange?()
            return
        }
        observeFailures(of: item)
        player.replaceCurrentItem(with: item)
        applyLoudness(for: queue[i])
        if autoPlay { player.play(); isPlaying = true } else { player.pause(); isPlaying = false }
        #endif
        onStateChange?()
    }

    #if canImport(AVFoundation)
    /// Surface an asynchronous load failure. Without this a `/audio` error
    /// (bad/absent token → 401, missing on-disk file → 404, unsupported type →
    /// 415) fails silently: the engine stays engaged on a dead item, so the user
    /// hears nothing and sees no reason why. Here we stop, clear `isPlaying`, and
    /// publish a `lastError` the UI can show.
    private func observeFailures(of item: AVPlayerItem) {
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed, let self else { return }
            // Read the (non-Sendable) item synchronously here, then hop to the
            // main actor with only Sendable values (the item's identity + code).
            // Capture `self` strongly (the engine is @MainActor, hence Sendable)
            // so the Task never references the mutable `weak var self`.
            let observedID = ObjectIdentifier(observed)
            let code = (observed.error as NSError?)?.code
            Task { @MainActor [self] in
                guard let current = self.player.currentItem,
                      ObjectIdentifier(current) == observedID else { return }
                self.reportLoadFailure(code: code)
            }
        }
    }

    private func reportLoadFailure(code: Int?) {
        isPlaying = false
        lastError = code.map { "Kon dit nummer niet afspelen op dit apparaat (\($0))." }
            ?? "Kon dit nummer niet afspelen op dit apparaat."
        onStateChange?()
    }
    #endif

    /// Re-apply the loudness gain to the current item — call after the user
    /// changes the normalization settings so the change is audible immediately.
    public func reapplyLoudness() {
        #if canImport(AVFoundation)
        guard isEngaged, let track = current else { return }
        applyLoudness(for: track)
        #endif
    }

    #if canImport(AVFoundation)
    private func applyLoudness(for track: Track) {
        loudnessGain = LocalLoudness.volume(
            trackLufs: track.lufs, albumLufs: track.albumLufs,
            mode: LocalLoudness.mode, preampDB: LocalLoudness.preampDB)
        // Fold in the user volume so the slider and loudness normalization stack
        // instead of overwriting each other.
        reapplyVolume()
    }
    #endif

    #if canImport(AVFoundation)
    private func makeItem(for track: Track) -> AVPlayerItem? {
        // Qobuz (or any direct CDN URL): play it straight, no /audio server.
        if let override = track.streamURLOverride { return AVPlayerItem(url: override) }
        var comps = URLComponents(string: "\(streamBase)/audio")
        // AVPlayer can't attach a custom auth header without private API, so the
        // token rides in the query (the /audio endpoint accepts both).
        var items = [URLQueryItem(name: "match_key", value: track.id)]
        if let token, !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        // Onderweg: ask the server for AAC instead of the original (policy-gated).
        items.append(contentsOf: LocalTranscode.queryItems())
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        return AVPlayerItem(url: url)
    }

    private func handleItemEnded(_ finished: AVPlayerItem?) {
        // Ignore stale notifications from a replaced item.
        guard isEngaged, finished === player.currentItem else { return }
        advance(auto: true)
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
