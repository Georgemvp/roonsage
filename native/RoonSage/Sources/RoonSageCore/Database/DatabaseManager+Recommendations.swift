import Foundation
import GRDB

// MARK: - Discovery engine persistence (server-of-record)
//
// Storage for the outward-facing recommendation pipeline: batches + scored items,
// the artist watchlist that feeds Release-Radar, and the persistent reject memory
// (block + cooldown). Follows the pool.read/write + Codable-JSON-column style of
// DatabaseManager+History.swift. Lives on the always-on server build; clients read
// the feed over /discovery/recommendations.

extension DatabaseManager {

    /// A fully-scored recommendation ready to persist (the pipeline's Store input).
    public struct StoredRecommendation: Sendable {
        public var kind: RecommendationKind
        public var artist: String
        public var artistMbid: String?
        public var album: String?
        public var releaseGroupMbid: String?
        public var year: Int?
        public var qobuzAlbumID: String?
        public var imageURL: String?
        public var score: Double
        public var components: ScoreComponents
        public var sources: [SourceRef]
        public var genres: [String]
        public var dedupKey: String
        public init(kind: RecommendationKind, artist: String, artistMbid: String? = nil,
                    album: String? = nil, releaseGroupMbid: String? = nil, year: Int? = nil,
                    qobuzAlbumID: String? = nil, imageURL: String? = nil, score: Double,
                    components: ScoreComponents, sources: [SourceRef], genres: [String], dedupKey: String) {
            self.kind = kind; self.artist = artist; self.artistMbid = artistMbid; self.album = album
            self.releaseGroupMbid = releaseGroupMbid; self.year = year; self.qobuzAlbumID = qobuzAlbumID
            self.imageURL = imageURL; self.score = score; self.components = components
            self.sources = sources; self.genres = genres; self.dedupKey = dedupKey
        }
    }

    /// A full recommendation row (all columns), used by accept/reject to run the
    /// side-effects and by the feed mapping.
    public struct RecommendationRow: Sendable {
        public var id: Int64
        public var kind: RecommendationKind
        public var artist: String
        public var artistMbid: String?
        public var album: String?
        public var releaseGroupMbid: String?
        public var year: Int?
        public var qobuzAlbumID: String?
        public var imageURL: String?
        public var score: Double
        public var components: ScoreComponents?
        public var sources: [SourceRef]
        public var genres: [String]
        public var explanation: String?
        public var explanationSig: String?
        public var status: String
        public var dedupKey: String
        public var createdAt: String

        public var dto: RecommendationItemDTO {
            RecommendationItemDTO(id: id, kind: kind, artist: artist, artistMbid: artistMbid,
                                  album: album, releaseGroupMbid: releaseGroupMbid, year: year,
                                  qobuzAlbumID: qobuzAlbumID, imageURL: imageURL, score: score,
                                  components: components, sources: sources, genres: genres,
                                  explanation: explanation, status: status, createdAt: createdAt)
        }
    }

    // MARK: - Batches

    /// Persist a run: one `recommendation_batches` row + its scored items. Returns
    /// the new batch id. Items are stored newest-batch-wins; the feed reads the
    /// latest complete batch.
    @discardableResult
    public func storeRecommendationBatch(_ items: [StoredRecommendation], trigger: String,
                                         tasteSig: String?) async throws -> Int64 {
        let iso = Self.isoFormatter.string(from: Date())
        let enc = JSONEncoder()
        return try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO recommendation_batches (created_at, status, trigger, item_count, taste_sig)
                VALUES (?, 'complete', ?, ?, ?)
            """, arguments: [iso, trigger, items.count, tasteSig])
            let batchID = db.lastInsertedRowID
            for it in items {
                let scoreJSON = (try? enc.encode(it.components)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let sourcesJSON = (try? enc.encode(it.sources)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let genresJSON = (try? enc.encode(it.genres)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(sql: """
                    INSERT INTO recommendation_items
                      (batch_id, kind, artist, artist_mbid, album, release_group_mbid, year,
                       qobuz_album_id, image_url, score, score_json, sources_json, genres_json,
                       status, dedup_key, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                """, arguments: [batchID, it.kind.rawValue, it.artist, it.artistMbid, it.album,
                                 it.releaseGroupMbid, it.year, it.qobuzAlbumID, it.imageURL, it.score,
                                 scoreJSON, sourcesJSON, genresJSON, it.dedupKey, iso])
            }
            return batchID
        }
    }

    private static func latestCompleteBatchID(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT id FROM recommendation_batches WHERE status = 'complete'
            ORDER BY id DESC LIMIT 1
        """)
    }

    /// Items of the newest complete batch, optionally filtered by kind, best score
    /// first. Rejected items are excluded; accepted ones are kept (so the UI can
    /// show a checkmark) unless `pendingOnly` is set.
    public func latestRecommendationItems(kind: RecommendationKind? = nil, limit: Int = 60,
                                          pendingOnly: Bool = false) async throws -> [RecommendationRow] {
        try await pool.read { db in
            guard let batchID = try Self.latestCompleteBatchID(db) else { return [] }
            var sql = "SELECT * FROM recommendation_items WHERE batch_id = ?"
            var args: [DatabaseValueConvertible] = [batchID]
            if let kind { sql += " AND kind = ?"; args.append(kind.rawValue) }
            sql += pendingOnly ? " AND status = 'pending'" : " AND status <> 'rejected'"
            sql += " ORDER BY score DESC LIMIT ?"; args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(Self.decodeRecommendationRow)
        }
    }

    public func recommendationRow(id: Int64) async throws -> RecommendationRow? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM recommendation_items WHERE id = ?", arguments: [id])
            else { return nil }
            return Self.decodeRecommendationRow(row)
        }
    }

    public func setRecommendationStatus(id: Int64, status: String, rejectedAt: String? = nil) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE recommendation_items SET status = ?, rejected_at = ? WHERE id = ?",
                           arguments: [status, rejectedAt, id])
        }
    }

    public func setRecommendationExplanation(id: Int64, explanation: String, sig: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE recommendation_items SET explanation = ?, explanation_sig = ? WHERE id = ?",
                           arguments: [explanation, sig, id])
        }
    }

    /// The most recent explanation stored for this exact recommendation identity
    /// under this exact signature (source producers + genres unchanged) — lets a
    /// recommendation that reappears across daily runs reuse its wording instead
    /// of paying an LLM call every time. Searches recent history, not just the
    /// current batch, since `dedup_key` is stable across batches but row ids aren't.
    public func cachedExplanation(dedupKey: String, sig: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT explanation FROM recommendation_items
                WHERE dedup_key = ? AND explanation_sig = ? AND explanation IS NOT NULL
                ORDER BY id DESC LIMIT 1
            """, arguments: [dedupKey, sig])
        }
    }

    /// Newest-batch status for /discovery/run-status.
    public func latestBatchStatus() async throws -> DiscoveryRunStatus {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT status, item_count, created_at FROM recommendation_batches ORDER BY id DESC LIMIT 1
            """) else { return DiscoveryRunStatus(status: "idle", itemCount: 0, createdAt: nil) }
            return DiscoveryRunStatus(status: row["status"] as String? ?? "idle",
                                      itemCount: row["item_count"] as Int? ?? 0,
                                      createdAt: row["created_at"] as String?)
        }
    }

    /// The newest batch's id + taste signature + timestamp — used by the
    /// scheduler's skip-if-unchanged guard (`DiscoveryPipeline.shouldSkipRun`) so
    /// it can compare against the currently-computed taste signature without
    /// re-running the pipeline.
    public func latestBatchInfo() async throws -> (id: Int64, tasteSig: String?, createdAt: Date)? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, taste_sig, created_at FROM recommendation_batches ORDER BY id DESC LIMIT 1
            """), let id = row["id"] as Int64?, let createdAtStr = row["created_at"] as String?,
            let createdAt = Self.isoFormatter.date(from: createdAtStr) else { return nil }
            return (id: id, tasteSig: row["taste_sig"] as String?, createdAt: createdAt)
        }
    }

    /// Keep only the newest `keeping` complete batches; delete the rest (items
    /// cascade). Called after each successful run so the table doesn't grow.
    public func pruneOldBatches(keeping: Int = 3) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM recommendation_batches WHERE id NOT IN (
                    SELECT id FROM recommendation_batches ORDER BY id DESC LIMIT ?
                )
            """, arguments: [keeping])
        }
    }

    /// Raw inputs for the "Ontdek-inzichten" dashboard (fed to
    /// `DiscoveryStatsBuilder.build`). Headline accept/reject counts come from the
    /// persistent watchlist + rejections tables (prune-proof); the per-item facts
    /// are every retained batch's items — all the item-level history that's kept.
    public func discoveryStatsInputs() async throws
        -> (accepted: Int, rejected: Int, facts: [DiscoveryStatsBuilder.ItemFacts], latestPending: Int) {
        try await pool.read { db in
            let accepted = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artist_watchlist WHERE source = 'accept'") ?? 0
            let rejected = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_rejections") ?? 0
            let dec = JSONDecoder()
            let rows = try Row.fetchAll(db, sql: "SELECT status, sources_json, genres_json FROM recommendation_items")
            let facts = rows.map { row -> DiscoveryStatsBuilder.ItemFacts in
                let producers = (row["sources_json"] as String?).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? dec.decode([SourceRef].self, from: $0) }?.map(\.producer) ?? []
                let genres = (row["genres_json"] as String?).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? dec.decode([String].self, from: $0) } ?? []
                return DiscoveryStatsBuilder.ItemFacts(
                    status: row["status"] as String? ?? "pending", producers: producers, genres: genres)
            }
            var latestPending = 0
            if let batchID = try Self.latestCompleteBatchID(db) {
                latestPending = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM recommendation_items WHERE batch_id = ? AND status = 'pending'",
                    arguments: [batchID]) ?? 0
            }
            return (accepted, rejected, facts, latestPending)
        }
    }

    /// Pending album-kind recommendations, Qobuz-resolved, across EVERY retained
    /// batch (not just the newest) — the material the weekly digest (F12b) picks
    /// its highlights from. `DigestSelection.top` handles dedup + ranking.
    public func recentPendingAlbumRecommendations(limit: Int = 300) async throws -> [DigestSelection.Candidate] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT dedup_key, artist, album, qobuz_album_id, score FROM recommendation_items
                WHERE kind = 'album' AND status = 'pending'
                  AND qobuz_album_id IS NOT NULL AND qobuz_album_id <> ''
                ORDER BY score DESC LIMIT ?
            """, arguments: [limit])
            return rows.compactMap { r -> DigestSelection.Candidate? in
                guard let dedup = r["dedup_key"] as String?, let artist = r["artist"] as String?,
                      let album = r["album"] as String? else { return nil }
                return DigestSelection.Candidate(dedupKey: dedup, artist: artist, album: album,
                                                 qobuzAlbumID: r["qobuz_album_id"] as String?,
                                                 score: r["score"] as Double? ?? 0)
            }
        }
    }

    // MARK: - Rejections (block + cooldown)

    public func recordRejection(dedupKey: String, kind: RecommendationKind, artist: String,
                                album: String?, permanent: Bool) async throws {
        let iso = Self.isoFormatter.string(from: Date())
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO discovery_rejections (dedup_key, kind, artist, album, rejected_at, permanent)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(dedup_key) DO UPDATE SET rejected_at = excluded.rejected_at,
                    permanent = MAX(discovery_rejections.permanent, excluded.permanent)
            """, arguments: [dedupKey, kind.rawValue, artist, album, iso, permanent ? 1 : 0])
        }
    }

    /// All remembered rejections as `dedupKey → RejectionInfo`, for the filter.
    public func activeRejections() async throws -> [String: RejectionInfo] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT dedup_key, rejected_at, permanent FROM discovery_rejections")
            var out: [String: RejectionInfo] = [:]
            for r in rows {
                guard let key = r["dedup_key"] as String? else { continue }
                let at = (r["rejected_at"] as String?).flatMap { Self.isoFormatter.date(from: $0) }
                out[key] = RejectionInfo(rejectedAt: at, permanent: (r["permanent"] as Int? ?? 0) != 0)
            }
            return out
        }
    }

    // MARK: - Watchlist (feeds Release-Radar)

    public func watchlistArtists() async throws -> [WatchlistArtist] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT artist, artist_mbid, display_name, last_seen_rg FROM artist_watchlist ORDER BY added_at DESC
            """)
            return rows.map {
                WatchlistArtist(artist: $0["artist"] as String? ?? "",
                                artistMbid: $0["artist_mbid"] as String?,
                                displayName: $0["display_name"] as String? ?? "",
                                lastSeenReleaseGroup: $0["last_seen_rg"] as String?)
            }
        }
    }

    public func addToWatchlist(artist: String, mbid: String?, displayName: String, source: String) async throws {
        let iso = Self.isoFormatter.string(from: Date())
        let key = artist.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO artist_watchlist (artist, artist_mbid, display_name, added_at, source)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(artist) DO UPDATE SET
                    artist_mbid = COALESCE(excluded.artist_mbid, artist_watchlist.artist_mbid),
                    display_name = excluded.display_name
            """, arguments: [key, mbid, displayName, iso, source])
        }
    }

    public func removeFromWatchlist(artist: String) async throws {
        let key = artist.lowercased().trimmingCharacters(in: .whitespaces)
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM artist_watchlist WHERE artist = ?", arguments: [key])
        }
    }

    public func updateWatchlistSeenRG(artist: String, releaseGroup: String) async throws {
        let key = artist.lowercased().trimmingCharacters(in: .whitespaces)
        try await pool.write { db in
            try db.execute(sql: "UPDATE artist_watchlist SET last_seen_rg = ? WHERE artist = ?",
                           arguments: [releaseGroup, key])
        }
    }

    // MARK: - Library sets (for scoring + filtering)

    /// Union of Roon (`track_genres`) + MusicBrainz (`track_mb_genres`) genres,
    /// lowercased — the reference set for the genreOverlap score component.
    public func libraryGenreSet() async throws -> Set<String> {
        try await pool.read { db in
            var out = Set<String>()
            for g in try String.fetchAll(db, sql: "SELECT DISTINCT genre FROM track_genres") { out.insert(g.lowercased()) }
            for g in try String.fetchAll(db, sql: "SELECT DISTINCT genre FROM track_mb_genres") { out.insert(g.lowercased()) }
            return out
        }
    }

    /// The full MusicBrainz genre vocabulary (lowercased) from `genre_taxonomy` —
    /// the reference set the pipeline filters candidate artist tags against, so only
    /// real genres (not "british"/"1980s"/"seen live") reach scoring + the insights
    /// genre trend. Empty until MB enrichment has synced the taxonomy (graceful).
    public func genreVocabularySet() async throws -> Set<String> {
        try await pool.read { db in
            var out = Set<String>()
            for g in try String.fetchAll(db, sql: "SELECT genre FROM genre_taxonomy") {
                out.insert(g.lowercased())
            }
            return out
        }
    }

    /// Distinct library artists, lowercased (for in-library filtering).
    public func libraryArtistSet() async throws -> Set<String> {
        try await pool.read { db in
            let names = try String.fetchAll(db, sql: "SELECT DISTINCT artist FROM tracks WHERE artist IS NOT NULL AND artist <> ''")
            return Set(names.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        }
    }

    /// Owned albums as lowercased "artist|album" keys (for album-kind in-library
    /// filtering — a gap-fill album by an owned artist must NOT be dropped).
    public func libraryAlbumKeySet() async throws -> Set<String> {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT artist, album FROM tracks WHERE artist IS NOT NULL AND album IS NOT NULL AND album <> ''
            """)
            var out = Set<String>()
            for r in rows {
                let a = (r["artist"] as String? ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                let al = (r["album"] as String? ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !al.isEmpty { out.insert("\(a)|\(al)") }
            }
            return out
        }
    }

    /// MusicBrainz genres for a set of content match keys (feeds per-genre feedback
    /// learning). Chunked to stay under SQLite's bound-parameter limit.
    public func mbGenresForMatchKeys(_ keys: [String]) async throws -> [String: [String]] {
        let unique = Array(Set(keys.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }
        return try await pool.read { db in
            var out: [String: [String]] = [:]
            var i = 0
            while i < unique.count {
                let chunk = Array(unique[i..<min(i + 400, unique.count)])
                i += 400
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db,
                    sql: "SELECT match_key, genre FROM track_mb_genres WHERE match_key IN (\(placeholders))",
                    arguments: StatementArguments(chunk))
                for r in rows {
                    guard let mk = r["match_key"] as String?, let g = r["genre"] as String? else { continue }
                    out[mk, default: []].append(g)
                }
            }
            return out
        }
    }

    /// Distinct artists in the listening history, lowercased.
    public func listenedArtistSet() async throws -> Set<String> {
        try await pool.read { db in
            let names = try String.fetchAll(db, sql: "SELECT DISTINCT artist FROM listening_history WHERE artist IS NOT NULL AND artist <> ''")
            return Set(names.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        }
    }

    // MARK: - Row decoding

    private static func decodeRecommendationRow(_ row: Row) -> RecommendationRow {
        let dec = JSONDecoder()
        let components = (row["score_json"] as String?).flatMap { $0.data(using: .utf8) }
            .flatMap { try? dec.decode(ScoreComponents.self, from: $0) }
        let sources = (row["sources_json"] as String?).flatMap { $0.data(using: .utf8) }
            .flatMap { try? dec.decode([SourceRef].self, from: $0) } ?? []
        let genres = (row["genres_json"] as String?).flatMap { $0.data(using: .utf8) }
            .flatMap { try? dec.decode([String].self, from: $0) } ?? []
        return RecommendationRow(
            id: row["id"] as Int64? ?? 0,
            kind: RecommendationKind(rawValue: row["kind"] as String? ?? "artist") ?? .artist,
            artist: row["artist"] as String? ?? "",
            artistMbid: row["artist_mbid"] as String?,
            album: row["album"] as String?,
            releaseGroupMbid: row["release_group_mbid"] as String?,
            year: row["year"] as Int?,
            qobuzAlbumID: row["qobuz_album_id"] as String?,
            imageURL: row["image_url"] as String?,
            score: row["score"] as Double? ?? 0,
            components: components,
            sources: sources,
            genres: genres,
            explanation: row["explanation"] as String?,
            explanationSig: row["explanation_sig"] as String?,
            status: row["status"] as String? ?? "pending",
            dedupKey: row["dedup_key"] as String? ?? "",
            createdAt: row["created_at"] as String? ?? "")
    }
}
