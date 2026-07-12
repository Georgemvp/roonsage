import AudioAnalysis
import Foundation

// MARK: - Sonic Radio
//
// Daily "for you" stations seeded from the artists you listen to most. Each
// radio centres on one frequently-played artist: we take that artist's analyzed
// tracks, compute the sonic centroid of their CLAP embeddings (or fall back to
// the rule-based BPM/Camelot/tag engine), and grow an endless station of
// sonically-close library tracks around it.
//
// "Daily": the candidate ordering is seeded on the calendar date, so each radio
// is stable for the day but rotates to a fresh selection tomorrow. The endless
// top-up refills the queue (a different date+generation salt each refill) as it
// drains, so the station never runs out.

extension RoonClient {

    // MARK: Tuning constants (nonisolated: also read from the off-main builder)
    /// Tracks queued per batch (first batch starts playback; later batches refill).
    nonisolated static let radioBatchSize = 18
    /// Refill when the live queue drops to this many tracks or fewer.
    nonisolated static let radioLowWater = 5
    /// How many of an artist's analyzed tracks must exist to make a station.
    nonisolated static let radioMinTracks = 2
    /// Upper bound on seed tracks per artist (centroid is averaged; bounds work).
    nonisolated static let radioMaxSeeds = 60
    /// Candidate-pool size pulled per generation.
    nonisolated static let radioPoolSize = 250

    // MARK: Models

    /// One daily station, presented as a card on the Radio's screen.
    public struct SonicRadio: Sendable, Identifiable {
        public let id: String          // "artist:<lowercased name>"
        public let artist: String      // display name
        public let imageKey: String?   // artwork from a representative track
        public let trackCount: Int     // analyzed tracks backing the station
        let seedIds: [String]          // analyzed track ids (centroid seeds)
    }

    /// Public, observable summary of the running radio (drives the banner).
    public struct RadioStatus: Sendable, Equatable {
        public let artist: String
        public let zoneID: String
    }

    /// Internal run state: the ordered candidate pool + how far we've queued.
    struct RadioRunState {
        let artist: String
        let artistKey: String      // stable id ("artist:<lower>")
        let zoneID: String
        let seedIds: [String]
        var pool: [TrackRecord]
        var cursor: Int
        var queuedKeys: Set<String>
        var generation: Int
        /// Content keys skipped during THIS station — feed the re-steer as a soft
        /// negative so the upcoming pool drifts away from what you keep skipping.
        var skippedKeys: Set<String> = []
        /// The active DJ persona, if the station was started as one — kept so the
        /// endless top-up regenerations preserve its dial/arc/gate.
        var djMode: DJMode? = nil
    }

    // MARK: Daily radios

    /// Build today's stations for `category`. Artist radios use the play-history
    /// scoring below; the other categories are bucketed by `radioBuckets(_:)`
    /// (genre/mood/activity/decade) and ordered as that builder returns them.
    public func dailyRadios(category: RadioCategory) async -> [SonicRadio] {
        guard category == .artist else {
            return await radioBuckets(category).map {
                SonicRadio(id: $0.id, artist: $0.label, imageKey: $0.imageKey,
                           trackCount: $0.trackCount, seedIds: $0.seedIds)
            }
        }
        return await dailyRadios()
    }

    /// Build today's stations from the most-played artists (Roon + imported
    /// Last.fm history, since `listening_history` holds both). Only artists with
    /// enough analyzed tracks qualify; order rotates daily.
    public func dailyRadios() async -> [SonicRadio] {
        guard let db = database else { return [] }
        let lib = await radioLibrary()
        guard !lib.isEmpty else { return [] }
        // Top artists drive the seeds. The thin client's local `listening_history`
        // is empty (history lives on the server), so pull it from /history in
        // remote mode — otherwise radios never appear on the client apps.
        let top: [(artist: String, count: Int)]
        if isRemote {
            let snap = await tasteProfile(topLimit: 100, recentLimit: 1)
            top = (snap?.topArtists ?? []).map { (artist: $0.artist, count: $0.count) }
        } else {
            top = (try? await db.topArtistsListened(limit: 100)) ?? []
        }

        // Group analyzed tracks by lowercased artist for O(1) lookup.
        var byArtist: [String: [DatabaseManager.SonicTrack]] = [:]
        for t in lib {
            guard let a = t.artist, !a.isEmpty else { continue }
            byArtist[a.lowercased(), default: []].append(t)
        }

        let tallies = feedbackArtistTallies(lib: lib)
        let disliked = radioDislikedMatchKeys
        var playCount: [String: Int] = [:]
        for e in top { playCount[e.artist.lowercased()] = e.count }

        // Candidate artists = those we've played + those we've thumbed up (a like
        // gives an unplayed artist a *chance* at a station, not a guaranteed one).
        var candidateKeys = Set(top.map { $0.artist.lowercased() })
        candidateKeys.formUnion(tallies.liked.keys)

        // Affinity score: play history dominates; a like nudges an artist up, a
        // dislike nudges it down — neither flips the ranking on its own.
        let stamp = Self.dayStamp()
        var scored: [(radio: SonicRadio, score: Double)] = []
        for key in candidateKeys {
            guard let tracks = byArtist[key] else { continue }
            // Disliked tracks shouldn't define a station's sound: drop them from
            // the seed set (they remain available as down-sampled candidates).
            let seedPool = tracks.filter { !disliked.contains($0.matchKey) }
            guard seedPool.count >= Self.radioMinTracks else { continue }
            let seeds = Array(seedPool.prefix(Self.radioMaxSeeds))
            let display = tracks.first(where: { ($0.artist?.isEmpty == false) })?.artist ?? key
            let img = tracks.first(where: { $0.imageKey?.isEmpty == false })?.imageKey
            let radio = SonicRadio(
                id: "artist:\(key)", artist: display, imageKey: img,
                trackCount: seedPool.count, seedIds: seeds.map(\.id))
            let base = Double(playCount[key] ?? 0)
            let bonus = 3.0 * Double(tallies.liked[key] ?? 0)
            let penalty = 2.0 * Double(tallies.disliked[key] ?? 0)
            // Daily jitter (≈0…4) keeps the order fresh each morning without
            // overriding genuine play/like signal.
            let jitter = Double(Self.seed64("\(stamp)\u{1f}\(key)") % 1000) / 250.0
            scored.append((radio, base + bonus - penalty + jitter))
        }
        return scored.sorted { $0.score > $1.score }.map(\.radio)
    }

    // MARK: Playback control

    /// Start an endless station for `radio` in `zoneID`: play the first batch,
    /// subscribe to the queue, and let the monitor refill it as it drains.
    public func startRadio(_ radio: SonicRadio, zoneID: String, djMode: DJMode? = nil) async {
        guard let db = database else {
            reportError("Radio mislukt — geen bibliotheek beschikbaar.")
            return
        }
        let lib = await radioLibrary()
        let index = await activeIndex(db)
        let seedIds = radio.seedIds
        let key = radio.id
        let stamp = Self.dayStamp()
        let disliked = radioDislikedMatchKeys
        let liked = likedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        // A DJ persona overrides the dial + arc and adds its seed-derived gate;
        // without one the station keeps the user's global adventurousness / smooth
        // flow, exactly as before.
        let adv = djMode?.adventurousness ?? radioAdventurousness
        let arc = djMode?.arc ?? .smooth
        let hardBan = radioHardBanDisliked
        let taste = await personalTasteVector(lib: lib, index: index)
        let stats = await sonicCache.nnStats(from: db)
        let baseGate = await candidateGate(for: key)
        let modeGate = await djModeGate(djMode, seedIds: seedIds, lib: lib, db: db)
        let gate = Self.composeGates(baseGate, modeGate)
        let related = await relatedSeedArtists(radioID: key, artist: radio.artist)
        let pool = await Task.detached {
            Self.buildRadioCandidates(seedIds: seedIds, lib: lib, index: index,
                                      seed: "\(stamp)-\(key)-0", disliked: disliked,
                                      likedKeys: liked, knownArtists: known,
                                      adventurousness: adv, hardBan: hardBan, tasteVector: taste,
                                      nnStats: stats, relatedArtists: related, gate: gate, arc: arc)
        }.value
        guard !pool.isEmpty else {
            reportError("Radio kon geen vergelijkbare tracks vinden — analyseer eerst meer muziek.")
            return
        }

        let first = Array(pool.prefix(Self.radioBatchSize))
        radioState = RadioRunState(
            artist: radio.artist, artistKey: key, zoneID: zoneID, seedIds: seedIds,
            pool: pool, cursor: first.count, queuedKeys: Set(first.map { $0.id }), generation: 0,
            djMode: djMode)
        activeRadio = RadioStatus(artist: radio.artist, zoneID: zoneID)

        await curateTracks(first, zoneID: zoneID)   // first plays now, rest queue
        startQueue(zoneID: zoneID)                   // observe depth for top-ups
        startRadioMonitor()
        Log.info("Sonic Radio gestart: \(radio.artist) → zone \(zoneID) (\(pool.count) kandidaten)", category: .roon)
    }

    /// Start an endless station seeded on ONE track — song radio, the Spotify/
    /// Plexamp "start radio from this song" verb. The station grows around that
    /// single track's embedding (plus the usual taste steering + dial). The
    /// `track:` id keeps it outside the bucket gates and the persisted Qobuz
    /// radio machinery: a song radio is a playback session, not a mirrored
    /// playlist.
    public func startTrackRadio(title: String, artist: String?, album: String? = nil,
                                zoneID: String, djMode: DJMode? = nil) async {
        let lib = await radioLibrary()
        guard !lib.isEmpty else {
            reportError("Radio mislukt — nog geen geanalyseerde bibliotheek beschikbaar.")
            return
        }
        let mk = TrackIdentity.matchKey(artist: artist, album: album, title: title)
        let seed = lib.first { !$0.matchKey.isEmpty && $0.matchKey == mk }
            ?? lib.first {
                $0.title.lowercased() == title.lowercased()
                    && ($0.artist ?? "").lowercased() == (artist ?? "").lowercased()
            }
        guard let seed else {
            reportError("Deze track is nog niet geanalyseerd — radio op dit nummer kan nog niet.")
            return
        }
        let radio = SonicRadio(
            id: "track:\(seed.matchKey.isEmpty ? seed.id : seed.matchKey)",
            artist: seed.title,   // the banner reads "Radio: <track title>"
            imageKey: seed.imageKey, trackCount: 1, seedIds: [seed.id])
        await startRadio(radio, zoneID: zoneID, djMode: djMode)
    }

    // MARK: DJ personas (Guest DJ)

    /// The seed-derived candidate gate for a persona, or nil. Fetches the year map
    /// only for The Timekeeper (the one persona that needs it).
    private func djModeGate(
        _ djMode: DJMode?, seedIds: [String],
        lib: [DatabaseManager.SonicTrack], db: DatabaseManager
    ) async -> (@Sendable (DatabaseManager.SonicTrack) -> Bool)? {
        guard let djMode, let seedId = seedIds.first,
              let seed = lib.first(where: { $0.id == seedId }) else { return nil }
        let years = (djMode == .timekeeper) ? ((try? await db.yearByMatchKey()) ?? [:]) : [:]
        return djMode.gate(seed: seed, years: years)
    }

    /// AND two optional candidate gates. A candidate must satisfy both to pass;
    /// when either is nil the other stands alone (nil ∧ nil = no gate).
    nonisolated static func composeGates(
        _ a: (@Sendable (DatabaseManager.SonicTrack) -> Bool)?,
        _ b: (@Sendable (DatabaseManager.SonicTrack) -> Bool)?
    ) -> (@Sendable (DatabaseManager.SonicTrack) -> Bool)? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (x?, nil): return x
        case let (nil, y?): return y
        case let (x?, y?): return { x($0) && y($0) }
        }
    }

    /// Guest-DJ autoplay: when enabled and no RoonSage station is running, a zone
    /// whose queue is nearly empty is topped up by seeding a persona station on
    /// its now-playing track. Idempotent per track (see `lastAutoplayTitle`) so a
    /// track that can't seed a station isn't retried on every zone frame.
    func maybeAutoplayGuestDJ(for zone: Zone) {
        guard djAutoplayEnabled, radioState == nil, !autoplayInFlight,
              zone.state == .playing, let np = zone.nowPlaying,
              let remaining = zone.queueItemsRemaining, remaining <= Self.radioLowWater,
              lastAutoplayTitle != np.title else { return }
        lastAutoplayTitle = np.title
        autoplayInFlight = true
        let mode = djAutoplayAutoPersona
            ? DJMode.forTimeOfDay(hour: Calendar.current.component(.hour, from: Date()))
            : selectedDJMode
        Task { [weak self] in
            guard let self else { return }
            await self.startTrackRadio(title: np.title, artist: np.artist, album: np.album,
                                       zoneID: zone.id, djMode: mode)
            self.autoplayInFlight = false
        }
    }

    /// Stop the running station. Playback already queued in Roon keeps playing;
    /// we just stop refilling it.
    public func stopRadio() {
        radioMonitorTask?.cancel()
        radioMonitorTask = nil
        radioState = nil
        activeRadio = nil
    }

    // MARK: Endless top-up

    private func startRadioMonitor() {
        radioMonitorTask?.cancel()
        radioMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.topUpRadioIfNeeded()
            }
        }
    }

    func topUpRadioIfNeeded() async {
        guard let state = radioState, queueZoneID == state.zoneID else { return }
        guard queueItems.count <= Self.radioLowWater else { return }
        await appendNextRadioBatch()
    }

    private func appendNextRadioBatch() async {
        guard var state = radioState else { return }
        if state.cursor >= state.pool.count {
            // Single-flight: don't regenerate if a re-steer (or another top-up) is
            // already rebuilding the pool — its result will land in radioState.
            guard !radioRegenerating else { return }
            radioRegenerating = true
            await regenerateRadioPool(&state)
            radioRegenerating = false
            guard !state.pool.isEmpty else { radioState = state; return }
        }
        let end = min(state.cursor + Self.radioBatchSize, state.pool.count)
        var batch: [TrackRecord] = []
        for i in state.cursor..<end {
            let t = state.pool[i]
            if state.queuedKeys.contains(t.id) { continue }
            state.queuedKeys.insert(t.id)
            batch.append(t)
        }
        state.cursor = end
        radioState = state
        guard !batch.isEmpty else { return }
        await queueTracks(batch, zoneID: state.zoneID)
    }

    /// Rebuild a fresh candidate pool with a new generation salt so the endless
    /// station keeps finding new (yet on-theme) tracks instead of looping.
    /// `preserveQueuedKeys` keeps the session's already-queued set (live re-steer):
    /// without it the next top-up would re-queue tracks still sitting in the Roon
    /// queue. The exhaustion path leaves it false — by then the old tracks have
    /// drained, so a clean reset is correct.
    private func regenerateRadioPool(_ state: inout RadioRunState, preserveQueuedKeys: Bool = false) async {
        guard let db = database else { return }
        let lib = await radioLibrary()
        let index = await activeIndex(db)
        let seedIds = state.seedIds
        let key = state.artistKey
        let nextGen = state.generation + 1
        let stamp = Self.dayStamp()
        let disliked = radioDislikedMatchKeys
        let liked = likedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        let djMode = state.djMode
        let adv = djMode?.adventurousness ?? radioAdventurousness
        let arc = djMode?.arc ?? .smooth
        let hardBan = radioHardBanDisliked
        let taste = await personalTasteVector(lib: lib, index: index)
        let stats = await sonicCache.nnStats(from: db)
        let baseGate = await candidateGate(for: key)
        let modeGate = await djModeGate(djMode, seedIds: seedIds, lib: lib, db: db)
        let gate = Self.composeGates(baseGate, modeGate)
        let related = await relatedSeedArtists(radioID: key, artist: state.artist)
        // Continuation anchor: the final track of the generation that just drained,
        // so the new pool opens on a sonically-adjacent track (seamless seam). Only
        // on the exhaustion path — a live re-steer keeps its queued tracks and
        // shouldn't reorder around a track that hasn't played yet.
        let continueFrom = preserveQueuedKeys ? nil : state.pool.last?.id
        let skipped = state.skippedKeys
        let pool = await Task.detached {
            Self.buildRadioCandidates(seedIds: seedIds, lib: lib, index: index,
                                      seed: "\(stamp)-\(key)-\(nextGen)", disliked: disliked,
                                      skippedKeys: skipped,
                                      likedKeys: liked, knownArtists: known,
                                      adventurousness: adv, hardBan: hardBan, tasteVector: taste,
                                      nnStats: stats, relatedArtists: related, gate: gate,
                                      continueFromId: continueFrom, arc: arc)
        }.value
        state.pool = pool
        state.cursor = 0
        state.generation = nextGen
        if !preserveQueuedKeys { state.queuedKeys = [] }
    }

    /// Live re-steer: after a thumb during a running station, rebuild the upcoming
    /// pool with the latest like/dislike (and refreshed taste vector) so the next
    /// top-ups adapt within a few tracks. The current track keeps playing — a thumb
    /// never interrupts playback (see RoonClient+Feedback) — only what comes next
    /// shifts toward "more like this" / away from "less like this".
    func resteerActiveRadio() async {
        // Single-flight: skip if a regeneration is already running (the in-flight
        // build reads the now-current feedback anyway).
        guard !radioRegenerating, var state = radioState else { return }
        radioRegenerating = true
        // Keep the already-queued set so we don't re-queue tracks still in the Roon
        // queue; only the not-yet-played tail adapts to the new thumb.
        await regenerateRadioPool(&state, preserveQueuedKeys: true)
        radioRegenerating = false
        guard !state.pool.isEmpty else { return }
        radioState = state
        Log.info("Radio live bijgestuurd op nieuwe feedback: \(state.artist)", category: .roon)
    }

    /// Natural-language steer: nudge the adventurousness dial from a phrase
    /// ("avontuurlijker", "veiliger", "verras me minder") and live re-steer the
    /// running station. Returns false when the phrase carries no recognised steer,
    /// so a caller (voice / chat / a text field) can fall back. The dial change
    /// persists (radioAdventurousness), so new stations inherit it too.
    @discardableResult
    public func steerActiveRadio(phrase: String) async -> Bool {
        guard let steer = RadioSteerParser.parse(phrase) else { return false }
        radioAdventurousness = min(1, max(0, radioAdventurousness + steer.adventurousnessDelta))
        if radioState != nil { await resteerActiveRadio() }
        Log.info("Radio NL-steer '\(phrase)' → avontuurlijkheid \(String(format: "%.2f", radioAdventurousness))", category: .roon)
        return true
    }

    /// Record a skip during the active station and re-steer: the skipped track
    /// becomes a soft negative (softer than a thumbs-down) so the upcoming pool
    /// drifts away from it. No-op off-station or on a duplicate skip. Session-only —
    /// the set resets when the station restarts.
    func recordRadioSkip(matchKey: String) {
        guard !matchKey.isEmpty, var state = radioState else { return }
        guard state.skippedKeys.insert(matchKey).inserted else { return }
        radioState = state
        Log.debug("Radio: skip geregistreerd (\(matchKey)) → bijsturen", category: .roon)
        Task { await resteerActiveRadio() }
    }

    // MARK: Candidate building (pure, off-main)

    /// The ordered station pool: the artist's own tracks plus their sonic
    /// neighbours, deduped and date-shuffled for daily variety. Leads on one of
    /// the artist's own tracks so the station opens on-brand.
    nonisolated static func buildRadioCandidates(
        seedIds: [String], lib: [DatabaseManager.SonicTrack],
        index: VectorIndex?, seed: String, disliked: Set<String> = [],
        skippedKeys: Set<String> = [],
        likedKeys: Set<String> = [], knownArtists: Set<String> = [],
        adventurousness: Double = defaultAdventurousness, hardBan: Bool = false,
        tasteVector: [Float]? = nil, nnStats: VectorIndex.NNStats? = nil,
        relatedArtists: [String: Double] = [:],
        gate: (@Sendable (DatabaseManager.SonicTrack) -> Bool)? = nil,
        continueFromId: String? = nil,
        arc: RadioSequencer.Arc = .smooth
    ) -> [TrackRecord] {
        let seedSet = Set(seedIds)
        // Don't seed the station on a disliked track.
        let own = lib.filter { seedSet.contains($0.id) && !disliked.contains($0.matchKey) }
        guard !own.isEmpty else { return [] }

        // Smart path (embeddings present): RadioEngine adds multi-anchor relevance,
        // the adventurousness dial (novelty + MMR diversity), like/dislike vector
        // steering, and a flow-ordered sequence. Rule-based path is the documented
        // fallback (and what the unit tests exercise via index: nil).
        let useEmb = index != nil && own.contains { index!.embedding(forId: $0.id) != nil }
        let neighbours: [DatabaseManager.SonicTrack]
        if useEmb, let index {
            // sequence:false here — we flow-order the FULL combined pool below,
            // opening on the continuation anchor (seamless top-up) when given.
            let opts = RadioEngine.Options(
                adventurousness: adventurousness, poolLimit: radioPoolSize,
                hardBanDisliked: hardBan, sequence: false, arc: .smooth,
                similarityFloor: nnStats.map { RadioEngine.Options.floor(stats: $0, adventurousness: adventurousness) })
            let ranked = RadioEngine.rank(
                seeds: own, library: lib, index: index, options: opts,
                disliked: disliked, skippedKeys: skippedKeys, likedKeys: likedKeys, knownArtists: knownArtists,
                tasteVector: tasteVector, relatedArtists: relatedArtists, salt: seed)
            neighbours = applyFeedbackWeighting(
                ranked.map(\.track), disliked: disliked, salt: seed, matchKey: { $0.matchKey })
        } else {
            // Disliked tracks aren't banned — just heard much less often.
            neighbours = applyFeedbackWeighting(
                SonicEngine.nearest(toSeeds: own, in: lib, limit: radioPoolSize, index: index).map(\.track),
                disliked: disliked, salt: seed, matchKey: { $0.matchKey })
        }

        // Feature fusion: keep the endless pool true to the bucket's defining
        // measured constraint (activity/mood/genre/decade); relaxes when the
        // matching pool alone can't feed the queue.
        var gatedNeighbours = neighbours
        if let gate {
            gatedNeighbours = gatedWithRelaxation(neighbours, gate: gate, minKeep: radioBatchSize * 3)
        }

        // Dedup by CONTENT, not Roon id: the same song often has several library
        // rows (soundtrack + compilation, duplicate albums) with different ids
        // but one match_key — id-dedup would queue it twice.
        var seen = Set<String>()
        var combined: [DatabaseManager.SonicTrack] = []
        combined.reserveCapacity(own.count + gatedNeighbours.count)
        for t in own + gatedNeighbours {
            let key = t.matchKey.isEmpty ? t.id : t.matchKey
            if seen.insert(key).inserted { combined.append(t) }
        }

        if useEmb {
            // Flow-order the FULL combined pool into one smooth journey. The opener:
            //  • a CONTINUATION anchor (the track that was just playing) on a top-up
            //    regeneration, so generation N+1 glides out of generation N instead
            //    of jumping — the seamless-seam fix; else
            //  • a seed-artist track, so a fresh station opens on-brand.
            let startIds: Set<String>
            if let anchor = continueFromId,
               let nearest = nearestPoolTrack(to: anchor, in: combined, lib: lib, index: index) {
                startIds = [nearest]
            } else {
                startIds = seedSet
            }
            let ordered = RadioSequencer.order(combined, preferredStartIds: startIds, arc: arc)
            return ordered.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        }

        var shuffled = dailyShuffled(combined, seed: seed)
        if let leadIdx = shuffled.firstIndex(where: { seedSet.contains($0.id) }), leadIdx != 0 {
            shuffled.swapAt(0, leadIdx)
        }
        return shuffled.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
    }

    /// The pool member sonically closest to `anchorId` (cosine over CLAP
    /// embeddings) — the continuation opener for a seamless top-up. nil when the
    /// anchor or the pool has no usable embedding.
    nonisolated static func nearestPoolTrack(
        to anchorId: String, in pool: [DatabaseManager.SonicTrack],
        lib: [DatabaseManager.SonicTrack], index: VectorIndex?
    ) -> String? {
        guard let index, let anchor = index.embedding(forId: anchorId) else { return nil }
        let a = VectorIndex.normalized(anchor)
        var best: String?
        var bestSim = -Double.infinity
        for t in pool where t.id != anchorId {
            guard let e = index.embedding(forId: t.id) else { continue }
            let en = VectorIndex.normalized(e)
            var s: Float = 0
            let n = min(a.count, en.count)
            var i = 0
            while i < n { s += a[i] * en[i]; i += 1 }
            if Double(s) > bestSim { bestSim = Double(s); best = t.id }
        }
        return best
    }

    // MARK: Deterministic daily shuffle

    /// Today's date as `yyyy-MM-dd` in the user's calendar — the daily seed.
    nonisolated static func dayStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// FNV-1a 64-bit — a stable string hash (unlike `String.hashValue`, which is
    /// salted per process and would reshuffle on every launch).
    nonisolated static func seed64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    nonisolated static func dailyShuffled<T>(_ array: [T], seed: String) -> [T] {
        var rng = SeededRNG(seed: seed64(seed))
        return array.shuffled(using: &rng)
    }
}

/// SplitMix64 — a tiny deterministic RNG so a given date always shuffles the
/// same way (cache-friendly, reproducible across launches and devices).
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
