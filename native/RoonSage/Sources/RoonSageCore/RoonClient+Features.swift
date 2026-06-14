import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
    // MARK: - Audio features (synced from the native analyzer)

    public var analyzerURL: String {
        get { UserDefaults.standard.string(forKey: "analyzer_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "analyzer_url") }
    }

    public func audioFeaturesStats() async -> (total: Int, matched: Int) {
        guard let db = database else { return (0, 0) }
        return await Task.detached { (try? db.audioFeaturesStats()) ?? (0, 0) }.value
    }

    /// Pull all features from the analyzer's HTTP endpoint, upsert them, and
    /// reconcile them against the library (exact match_key + fuzzy fallback).
    /// Returns the match diagnostic, or nil on failure.
    public func syncAudioFeatures(from baseURL: String) async -> DatabaseManager.AudioFeatureDiagnostic? {
        guard let payload = await fetchFeaturePayload(from: baseURL) else { return nil }
        let db = database
        let diag = await Task.detached { () -> DatabaseManager.AudioFeatureDiagnostic? in
            try? db?.upsertAudioFeatures(payload.features)
            // Fuzzy fallback rewrites tracks.match_key for confident matches so the
            // DJ/Sonic joins pick them up; apply on a real sync.
            return try? db?.reconcileFeatureMatches(payload.identities, apply: true)
        }.value
        // Pull the 512-dim embeddings (binary bundle) after match_keys are
        // reconciled, so they attach to the right rows.
        await pullEmbeddings(from: baseURL)
        await sonicCache.invalidate()
        return diag
    }

    /// Fetch the analyzer's binary `/embeddings` bundle and attach the vectors
    /// to the feature rows by match_key. Best-effort: older analyzers without
    /// the endpoint simply yield no embeddings.
    private func pullEmbeddings(from baseURL: String) async {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/embeddings"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let db = database
        _ = await Task.detached { try? db?.applyEmbeddingsBlob(data) }.value
    }

    /// Read-only: fetch features and report the match breakdown WITHOUT mutating
    /// the library (no fuzzy rewrites). For the Settings "Diagnose" action.
    public func diagnoseAudioFeatures(from baseURL: String) async -> DatabaseManager.AudioFeatureDiagnostic? {
        guard let payload = await fetchFeaturePayload(from: baseURL) else { return nil }
        let db = database
        return await Task.detached { () -> DatabaseManager.AudioFeatureDiagnostic? in
            try? db?.reconcileFeatureMatches(payload.identities, apply: false)
        }.value
    }

    private struct FeaturePayload: Sendable {
        var features: [DatabaseManager.AudioFeatureRow]
        var identities: [DatabaseManager.FeatureIdentity]
    }

    /// Fetch + parse the analyzer `/features` JSON off the main actor.
    private func fetchFeaturePayload(from baseURL: String) async -> FeaturePayload? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/features"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return await Task.detached { () -> FeaturePayload? in
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            var features: [DatabaseManager.AudioFeatureRow] = []
            var identities: [DatabaseManager.FeatureIdentity] = []
            features.reserveCapacity(arr.count); identities.reserveCapacity(arr.count)
            for o in arr {
                guard let mk = o["match_key"] as? String, !mk.isEmpty else { continue }
                features.append(DatabaseManager.AudioFeatureRow(
                    matchKey: mk,
                    bpm: o["bpm"] as? Double, camelot: o["camelot"] as? String,
                    keyRoot: o["key_root"] as? String, keyMode: o["key_mode"] as? String,
                    energy: o["energy"] as? Double, duration: o["duration"] as? Double,
                    tags: o["tags"] as? String, moods: o["moods"] as? String
                ))
                identities.append(DatabaseManager.FeatureIdentity(
                    matchKey: mk, artist: o["artist"] as? String, title: o["title"] as? String))
            }
            return FeaturePayload(features: features, identities: identities)
        }.value
    }

    // MARK: - DJ sets

    public func buildDJSet(
        count: Int, startBPM: Double, endBPM: Double,
        curve: DJSetBuilder.Curve, tags: [String], excludeLive: Bool = true
    ) async -> [DatabaseManager.DJCandidate] {
        guard let db = database else { return [] }
        return await Task.detached {
            let cands = (try? db.djCandidates(
                minBPM: min(startBPM, endBPM), maxBPM: max(startBPM, endBPM),
                tags: tags, excludeLive: excludeLive
            )) ?? []
            return DJSetBuilder.build(candidates: cands, count: count, startBPM: startBPM, endBPM: endBPM, curve: curve)
        }.value
    }

    /// Audio features for a now-playing track (by content match key), if synced.
    public func featuresFor(title: String, artist: String?, album: String?) -> (bpm: Double, camelot: String, tags: [String])? {
        database?.featuresForMatchKey(TrackIdentity.matchKey(artist: artist, album: album, title: title))
    }

    /// Build an endless-style mix seeded from a track: harmonically-compatible
    /// tracks within ±12 BPM of the seed, ordered by the DJ-set builder.
    public func buildRadio(title: String, artist: String?, album: String?, count: Int = 25) async -> [DatabaseManager.DJCandidate] {
        guard let db = database,
              let seed = featuresFor(title: title, artist: artist, album: album), seed.bpm > 0 else { return [] }
        return await Task.detached {
            let cands = (try? db.djCandidates(minBPM: seed.bpm - 12, maxBPM: seed.bpm + 12, tags: [], excludeLive: true)) ?? []
            guard !cands.isEmpty else { return [] }
            return DJSetBuilder.build(candidates: cands, count: count, startBPM: seed.bpm, endBPM: seed.bpm, curve: .flat)
        }.value
    }

    // MARK: - Live DJ (next-track suggestions)

    public enum HarmonicRelation: Sendable {
        case harmonic   // adjacent on the Camelot wheel — smoothest mix
        case sameKey    // identical key
        case tempo      // tempo-compatible only
    }

    /// How a candidate's Camelot key mixes with the current key (for UI badges).
    public nonisolated static func harmonicRelation(current: String, candidate: String) -> HarmonicRelation {
        guard !current.isEmpty, !candidate.isEmpty else { return .tempo }
        if current == candidate { return .sameKey }
        if Camelot.compatible(current).contains(candidate) { return .harmonic }
        return .tempo
    }

    /// Live-DJ suggestions: tracks that mix well RIGHT NOW after the given key/BPM —
    /// within a tight BPM window, ranked by Camelot-harmonic compatibility, BPM
    /// proximity and energy. Runs off the main actor (blocking pool.read).
    public func harmonicNextTracks(bpm: Double, camelot: String, excludeID: String? = nil,
                                   limit: Int = 25) async -> [DatabaseManager.DJCandidate] {
        guard let db = database, bpm > 0 else { return [] }
        let lo = bpm - 8, hi = bpm + 8
        let compatible = Camelot.compatible(camelot)
        return await Task.detached {
            let cands = (try? db.djCandidates(minBPM: lo, maxBPM: hi, tags: [], excludeLive: true)) ?? []
            func rank(_ c: DatabaseManager.DJCandidate) -> Double {
                let bpmPen = abs(c.bpm - bpm) / 4.0
                let harm: Double
                if !camelot.isEmpty, c.camelot == camelot { harm = 0.2 }
                else if compatible.contains(c.camelot) { harm = 0.0 }
                else { harm = 1.0 }
                return bpmPen + harm - c.energy * 0.1
            }
            return cands.filter { $0.id != excludeID }
                .sorted { rank($0) < rank($1) }
                .prefix(limit)
                .map { $0 }
        }.value
    }

    public func playDJSet(_ set: [DatabaseManager.DJCandidate], zoneID: String) async {
        let tracks = set.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        await curateTracks(tracks, zoneID: zoneID)
    }

    public func saveDJSet(name: String, set: [DatabaseManager.DJCandidate]) {
        let tracks = set.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        _ = savePlaylist(name: name, tracks: tracks)
    }

    // MARK: - Discovery sections

    public func undiscoveredAlbums(limit: Int = 16) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.undiscoveredAlbums(limit: limit)) ?? [] }.value
    }

    public func forgottenFavorites(days: Int = 60, limit: Int = 20) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.forgottenFavorites(days: days, limit: limit)) ?? [] }.value
    }

    public func topTracks(limit: Int = 25) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.topTracks(limit: limit)) ?? [] }.value
    }

    /// Filter by `options`, shuffle, and play a random `count`-track mix.
    public func playShuffledMix(options: DatabaseManager.FilterOptions, count: Int, zoneID: String) async {
        var opts = options
        opts.limit = max(opts.limit, 500)
        var pool = await filterTracks(options: opts)
        pool.shuffle()
        let pick = Array(pool.prefix(count))
        guard !pick.isEmpty else { return }
        await curateTracks(pick, zoneID: zoneID)
    }

    /// Play every track of an album by its album_key (first plays, rest queue).
    public func playAlbum(albumKey: String, zoneID: String) async {
        var opts = DatabaseManager.FilterOptions()
        opts.albumKey = albumKey
        opts.excludeLive = false
        opts.limit = 200
        let tracks = await filterTracks(options: opts)
        guard !tracks.isEmpty else { return }
        await curateTracks(tracks, zoneID: zoneID)
    }

    /// Play an artist's library tracks to a zone (first plays, rest queue).
    public func playArtist(name: String, zoneID: String) async {
        var opts = DatabaseManager.FilterOptions()
        opts.artists = [name]
        opts.limit = 200
        let tracks = await filterTracks(options: opts)
        guard !tracks.isEmpty else { return }
        await curateTracks(tracks, zoneID: zoneID)
    }

    // MARK: - Sonic similarity (Radio / Fingerprint)

    /// Library tracks sonically similar to a seed (tempo, key, energy, tags).
    /// Heavy scan runs off the main actor.
    public func similarTracks(toMatchKey matchKey: String, limit: Int = 30) async -> [SonicEngine.Scored] {
        guard let db = database, !matchKey.isEmpty else { return [] }
        let lib = await sonicCache.tracks(from: db)
        return await Task.detached {
            guard let seed = lib.first(where: { $0.matchKey == matchKey }) else { return [] }
            return SonicEngine.similar(to: seed, in: lib, limit: limit)
        }.value
    }

    public func similarTracks(title: String, artist: String?, album: String?, limit: Int = 30) async -> [SonicEngine.Scored] {
        await similarTracks(toMatchKey: TrackIdentity.matchKey(artist: artist, album: album, title: title), limit: limit)
    }

    /// Seed a station from a now-playing track and play the similar set.
    public func playSonicRadio(title: String, artist: String?, album: String?, count: Int = 30, zoneID: String) async {
        let scored = await similarTracks(title: title, artist: artist, album: album, limit: count)
        let tracks = scored.map { TrackRecord(id: $0.track.id, title: $0.track.title, artist: $0.track.artist, album: $0.track.album) }
        guard !tracks.isEmpty else { return }
        await curateTracks(tracks, zoneID: zoneID)
    }

    public struct Fingerprint: Sendable {
        public var profile: SonicEngine.Profile
        public var recommendations: [SonicEngine.Scored]
        public var seedCount: Int
    }

    /// Your "musical DNA": a profile of your most-played analyzed tracks plus
    /// library recommendations closest to that taste. Computed off-main.
    public func sonicFingerprint(seedLimit: Int = 40, recommendCount: Int = 60) async -> Fingerprint? {
        guard let db = database else { return nil }
        let lib = await sonicCache.tracks(from: db)
        return await Task.detached {
            guard !lib.isEmpty else { return nil }
            let top = (try? db.topTracks(limit: seedLimit)) ?? []
            let byKey = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })
            let seeds = top.compactMap { $0.matchKey.flatMap { byKey[$0] } }
            // Fall back to the loudest/most-typical slice if there's no play history yet.
            let effectiveSeeds = seeds.isEmpty ? Array(lib.prefix(min(40, lib.count))) : seeds
            let profile = SonicEngine.profile(of: effectiveSeeds)
            let recs = SonicEngine.nearest(toSeeds: effectiveSeeds, in: lib, limit: recommendCount)
            return Fingerprint(profile: profile, recommendations: recs, seedCount: effectiveSeeds.count)
        }.value
    }

    /// All analyzed tracks (for the Music Map). Cached; loads off-main.
    public func sonicLibrary() async -> [DatabaseManager.SonicTrack] {
        guard let db = database else { return [] }
        return await sonicCache.tracks(from: db)
    }

    /// Case-insensitive search over the cached sonic library (title + artist).
    /// Returns up to 20 matches. Used by Song Paths and Song Alchemy pickers.
    public func sonicSearch(_ query: String) async -> [DatabaseManager.SonicTrack] {
        guard let db = database else { return [] }
        return await sonicCache.search(query, from: db)
    }

    /// Drop the cached sonic library so the next read hits SQLite. For the
    /// explicit "Reload" actions in Music Map / Sonic DNA.
    public func invalidateSonicCache() async {
        await sonicCache.invalidate()
    }

}
