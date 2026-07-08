import AudioAnalysis
import Foundation
import GRDB

public struct DatasetImportProgress: Sendable {
    public var keyed: Int      // sidecar rows that received a match_key (pass A)
    public var matched: Int    // analyzer rows that got any identity data
    public var checked: Int    // analyzer rows checked against the sidecar (incl. no match)
    public var total: Int      // analyzer rows total
}

/// Matches analyzed tracks against a distilled MusicMoveArr dataset sidecar
/// (`metadata.db`, built offline by `native/scripts/distill-datasets.sh`) and
/// copies hard identity (ISRC, MusicBrainz recording id) plus Deezer dump
/// metrics onto `track_features`. Mirrors `GenreEnricher`/`PopularityEnricher`.
///
/// Expected sidecar table (raw strings on purpose):
///     ds_tracks(source TEXT,          -- 'deezer' | 'tidal' | 'spotify' | 'musicbrainz'
///               artist TEXT, title TEXT, album TEXT,
///               isrc TEXT, recording_mbid TEXT,
///               duration REAL, bpm REAL, gain REAL, rank INTEGER,
///               match_key TEXT)       -- NULL until pass A fills it
///     + index on match_key
///
/// The sidecar stores RAW artist/title; the real `TrackIdentity.matchKey` is
/// computed HERE (pass A), never re-implemented in SQL — the analyzer↔app
/// normaliser divergence was a hard-won lesson. Both passes are resumable:
/// pass A only touches sidecar rows with `match_key IS NULL`, pass B only
/// analyzer rows with `dataset_checked_at IS NULL`.
public final class DatasetImporter {
    private let store: FeatureStore
    private let sidecar: DatabaseQueue
    private let batch: Int
    private var cancelled = false

    public enum ImportError: Error, CustomStringConvertible {
        case sidecarMissing(String)
        case sidecarMalformed(String)

        public var description: String {
            switch self {
            case .sidecarMissing(let p): return "sidecar not found at \(p)"
            case .sidecarMalformed(let m): return "sidecar malformed: \(m)"
            }
        }
    }

    public init(store: FeatureStore, sidecarPath: String, batch: Int = 2_000) throws {
        // DatabaseQueue(path:) would silently CREATE an empty db — guard first.
        guard FileManager.default.fileExists(atPath: sidecarPath) else {
            throw ImportError.sidecarMissing(sidecarPath)
        }
        self.store = store
        self.sidecar = try DatabaseQueue(path: sidecarPath)
        self.batch = max(1, batch)
        let hasTable = try sidecar.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='ds_tracks'") ?? false
        }
        guard hasTable else { throw ImportError.sidecarMalformed("no ds_tracks table") }
        try sidecar.write { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_ds_tracks_match ON ds_tracks(match_key)")
        }
    }

    public func cancel() { cancelled = true }

    public func run(onProgress: @escaping @Sendable (DatasetImportProgress) -> Void) async throws {
        let keyed = try keySidecarRows(onProgress: onProgress)
        try matchAnalyzerRows(keyed: keyed, onProgress: onProgress)
    }

    /// Pass A — stamp every sidecar row with the current TrackIdentity matchKey.
    private func keySidecarRows(onProgress: (DatasetImportProgress) -> Void) throws -> Int {
        var keyed = 0
        while !cancelled {
            let rows = try sidecar.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT rowid, artist, album, title FROM ds_tracks
                    WHERE match_key IS NULL LIMIT ?
                """, arguments: [batch])
            }
            if rows.isEmpty { break }
            let keys: [(Int64, String)] = rows.compactMap { r in
                guard let rowid = r["rowid"] as Int64? else { return nil }
                let key = TrackIdentity.matchKey(artist: r["artist"], album: r["album"], title: r["title"])
                // Rows with empty artist/title still get their (degenerate) key
                // so they're never re-selected — resumability needs non-NULL.
                return (rowid, key)
            }
            try sidecar.write { db in
                for (rowid, key) in keys {
                    try db.execute(sql: "UPDATE ds_tracks SET match_key = ? WHERE rowid = ?",
                                   arguments: [key, rowid])
                }
            }
            keyed += keys.count
            onProgress(DatasetImportProgress(keyed: keyed, matched: 0, checked: 0, total: store.count()))
        }
        return keyed
    }

    /// Pass B — for every unchecked analyzer row, look up its sidecar rows and
    /// merge identity: any non-empty ISRC (highest-ranked Deezer row wins),
    /// recording MBID from the MusicBrainz rows, BPM/gain/rank from Deezer.
    private func matchAnalyzerRows(keyed: Int, onProgress: (DatasetImportProgress) -> Void) throws {
        let total = store.count()
        var matched = 0
        var checked = store.datasetCheckedCount()
        while !cancelled {
            let tracks = store.tracksNeedingDatasetCheck(limit: batch)
            if tracks.isEmpty { break }
            for t in tracks {
                if cancelled { break }
                // Look up by a FRESH key (same trick as exportJSON): the stored
                // PK may predate a normaliser change; the sidecar keys are always
                // current-scheme (pass A runs in this same binary). The UPDATE
                // still targets the stored PK.
                let lookupKey = TrackIdentity.matchKey(artist: t.artist, album: t.album, title: t.title)
                let rows = try sidecar.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT source, isrc, recording_mbid, bpm, gain, rank
                        FROM ds_tracks WHERE match_key = ?
                    """, arguments: [lookupKey])
                }
                let merged = Self.merge(rows)
                if merged.isrc != nil || merged.mbid != nil || merged.bpm != nil { matched += 1 }
                try store.setDatasetIdentity(matchKey: t.matchKey, isrc: merged.isrc,
                                             recordingMbid: merged.mbid, deezerBpm: merged.bpm,
                                             deezerGain: merged.gain, popularity: merged.rank,
                                             checkedAt: Self.now())
                checked += 1
            }
            onProgress(DatasetImportProgress(keyed: keyed, matched: matched, checked: checked, total: total))
        }
    }

    static func merge(_ rows: [Row]) -> (isrc: String?, mbid: String?, bpm: Double?, gain: Double?, rank: Int?) {
        var isrc: String?, mbid: String?, bpm: Double?, gain: Double?, rank: Int?
        var bestDeezerRank = Int.min   // rank-less Deezer rows still contribute BPM/gain
        for r in rows {
            let source = (r["source"] as String?) ?? ""
            if mbid == nil, let m = r["recording_mbid"] as String?, !m.isEmpty { mbid = m }
            let rowRank = (r["rank"] as Int?) ?? -1
            if source == "deezer" {
                // Multiple Deezer rows per key = releases/versions; the highest
                // rank is the canonical one for metrics AND for its ISRC.
                if rowRank > bestDeezerRank {
                    bestDeezerRank = rowRank
                    if let b = r["bpm"] as Double?, b > 0 { bpm = b }
                    if let g = r["gain"] as Double? { gain = g }
                    if rowRank >= 0 { rank = rowRank }
                    if let i = r["isrc"] as String?, !i.isEmpty { isrc = i }
                }
            } else if isrc == nil, let i = r["isrc"] as String?, !i.isEmpty {
                isrc = i
            }
        }
        return (isrc, mbid, bpm, gain, rank)
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
