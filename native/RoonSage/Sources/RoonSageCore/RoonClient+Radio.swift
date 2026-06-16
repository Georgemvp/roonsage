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
    }

    // MARK: Daily radios

    /// Build today's stations from the most-played artists (Roon + imported
    /// Last.fm history, since `listening_history` holds both). Only artists with
    /// enough analyzed tracks qualify; order rotates daily.
    public func dailyRadios() async -> [SonicRadio] {
        guard let db = database else { return [] }
        let lib = await sonicCache.tracks(from: db)
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
        guard !top.isEmpty else { return [] }

        // Group analyzed tracks by lowercased artist for O(1) lookup.
        var byArtist: [String: [DatabaseManager.SonicTrack]] = [:]
        for t in lib {
            guard let a = t.artist, !a.isEmpty else { continue }
            byArtist[a.lowercased(), default: []].append(t)
        }

        var radios: [SonicRadio] = []
        for entry in top {
            let key = entry.artist.lowercased()
            guard let tracks = byArtist[key], tracks.count >= Self.radioMinTracks else { continue }
            let seeds = Array(tracks.prefix(Self.radioMaxSeeds))
            let img = tracks.first(where: { $0.imageKey?.isEmpty == false })?.imageKey
            radios.append(SonicRadio(
                id: "artist:\(key)", artist: entry.artist, imageKey: img,
                trackCount: tracks.count, seedIds: seeds.map(\.id)))
        }
        // Rotate the card order daily so the screen feels fresh each morning.
        return Self.dailyShuffled(radios, seed: Self.dayStamp())
    }

    // MARK: Playback control

    /// Start an endless station for `radio` in `zoneID`: play the first batch,
    /// subscribe to the queue, and let the monitor refill it as it drains.
    public func startRadio(_ radio: SonicRadio, zoneID: String) async {
        guard let db = database else {
            reportError("Radio mislukt — geen bibliotheek beschikbaar.")
            return
        }
        let lib = await sonicCache.tracks(from: db)
        let index = await activeIndex(db)
        let seedIds = radio.seedIds
        let key = radio.id
        let stamp = Self.dayStamp()
        let pool = await Task.detached {
            Self.buildRadioCandidates(seedIds: seedIds, lib: lib, index: index,
                                      seed: "\(stamp)-\(key)-0")
        }.value
        guard !pool.isEmpty else {
            reportError("Radio kon geen vergelijkbare tracks vinden — analyseer eerst meer muziek.")
            return
        }

        let first = Array(pool.prefix(Self.radioBatchSize))
        radioState = RadioRunState(
            artist: radio.artist, artistKey: key, zoneID: zoneID, seedIds: seedIds,
            pool: pool, cursor: first.count, queuedKeys: Set(first.map { $0.id }), generation: 0)
        activeRadio = RadioStatus(artist: radio.artist, zoneID: zoneID)

        await curateTracks(first, zoneID: zoneID)   // first plays now, rest queue
        startQueue(zoneID: zoneID)                   // observe depth for top-ups
        startRadioMonitor()
        Log.info("Sonic Radio gestart: \(radio.artist) → zone \(zoneID) (\(pool.count) kandidaten)", category: .roon)
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
            await regenerateRadioPool(&state)
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
    private func regenerateRadioPool(_ state: inout RadioRunState) async {
        guard let db = database else { return }
        let lib = await sonicCache.tracks(from: db)
        let index = await activeIndex(db)
        let seedIds = state.seedIds
        let key = state.artistKey
        let nextGen = state.generation + 1
        let stamp = Self.dayStamp()
        let pool = await Task.detached {
            Self.buildRadioCandidates(seedIds: seedIds, lib: lib, index: index,
                                      seed: "\(stamp)-\(key)-\(nextGen)")
        }.value
        state.pool = pool
        state.cursor = 0
        state.generation = nextGen
        state.queuedKeys = []
    }

    // MARK: Candidate building (pure, off-main)

    /// The ordered station pool: the artist's own tracks plus their sonic
    /// neighbours, deduped and date-shuffled for daily variety. Leads on one of
    /// the artist's own tracks so the station opens on-brand.
    nonisolated static func buildRadioCandidates(
        seedIds: [String], lib: [DatabaseManager.SonicTrack],
        index: VectorIndex?, seed: String
    ) -> [TrackRecord] {
        let seedSet = Set(seedIds)
        let own = lib.filter { seedSet.contains($0.id) }
        guard !own.isEmpty else { return [] }

        let neighbours = SonicEngine.nearest(
            toSeeds: own, in: lib, limit: radioPoolSize, index: index).map(\.track)

        var seenIds = Set<String>()
        var combined: [DatabaseManager.SonicTrack] = []
        combined.reserveCapacity(own.count + neighbours.count)
        for t in own + neighbours where seenIds.insert(t.id).inserted {
            combined.append(t)
        }

        var shuffled = dailyShuffled(combined, seed: seed)
        if let leadIdx = shuffled.firstIndex(where: { seedSet.contains($0.id) }), leadIdx != 0 {
            shuffled.swapAt(0, leadIdx)
        }
        return shuffled.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
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
