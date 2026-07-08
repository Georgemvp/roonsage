import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - MusicBrainz genres (synced from the analyzer)
    //
    // MB genres are keyed by content `match_key` (like track_audio_features), in
    // their own table, so the Roon genre pass — which clears `track_genres` — never
    // wipes them. The hierarchy lives in `genre_taxonomy` (parent ← subgenre).

    /// Replace the MB genres for the synced tracks. Each element carries a track's
    /// full genre set; the existing rows for those match_keys are dropped first so
    /// a re-sync reflects removals too.
    public func upsertMBGenres(_ rows: [(matchKey: String, genres: [String])]) async throws {
        guard !rows.isEmpty else { return }
        let keys = rows.map { $0.matchKey }
        var pairs: [(String, String)] = []
        for r in rows where !r.matchKey.isEmpty {
            for g in r.genres {
                let gl = g.lowercased().trimmingCharacters(in: .whitespaces)
                if !gl.isEmpty { pairs.append((r.matchKey, gl)) }
            }
        }
        let outKeys = keys, outPairs = pairs
        try await pool.write { db in
            let kChunk = Self.rowsPerChunk(columns: 1)
            var s = 0
            while s < outKeys.count {
                let slice = outKeys[s..<min(s + kChunk, outKeys.count)]
                let ph = slice.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM track_mb_genres WHERE match_key IN (\(ph))",
                               arguments: StatementArguments(Array(slice) as [DatabaseValueConvertible]))
                s += slice.count
            }
            let pChunk = Self.rowsPerChunk(columns: 2)
            var p = 0
            while p < outPairs.count {
                let slice = outPairs[p..<min(p + pChunk, outPairs.count)]
                let ph = slice.map { _ in "(?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = []
                for pr in slice { args.append(pr.0); args.append(pr.1) }
                try db.execute(sql: "INSERT OR IGNORE INTO track_mb_genres (match_key, genre) VALUES \(ph)",
                               arguments: StatementArguments(args))
                p += slice.count
            }
        }
    }

    /// Replace the Deezer genres for the synced tracks — mirrors `upsertMBGenres`
    /// exactly, but for the second (Deezer) genre signal in its own table.
    public func upsertDeezerGenres(_ rows: [(matchKey: String, genres: [String])]) async throws {
        guard !rows.isEmpty else { return }
        let keys = rows.map { $0.matchKey }
        var pairs: [(String, String)] = []
        for r in rows where !r.matchKey.isEmpty {
            for g in r.genres {
                let gl = g.lowercased().trimmingCharacters(in: .whitespaces)
                if !gl.isEmpty { pairs.append((r.matchKey, gl)) }
            }
        }
        let outKeys = keys, outPairs = pairs
        try await pool.write { db in
            let kChunk = Self.rowsPerChunk(columns: 1)
            var s = 0
            while s < outKeys.count {
                let slice = outKeys[s..<min(s + kChunk, outKeys.count)]
                let ph = slice.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM track_deezer_genres WHERE match_key IN (\(ph))",
                               arguments: StatementArguments(Array(slice) as [DatabaseValueConvertible]))
                s += slice.count
            }
            let pChunk = Self.rowsPerChunk(columns: 2)
            var p = 0
            while p < outPairs.count {
                let slice = outPairs[p..<min(p + pChunk, outPairs.count)]
                let ph = slice.map { _ in "(?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = []
                for pr in slice { args.append(pr.0); args.append(pr.1) }
                try db.execute(sql: "INSERT OR IGNORE INTO track_deezer_genres (match_key, genre) VALUES \(ph)",
                               arguments: StatementArguments(args))
                p += slice.count
            }
        }
    }

    /// Upsert the genre hierarchy nodes pulled from the analyzer's `/genres`.
    /// Empty parents are normalised to NULL (root genre).
    public func upsertGenreTaxonomy(_ nodes: [(genre: String, parent: String?, mbid: String?)]) async throws {
        guard !nodes.isEmpty else { return }
        let out = nodes
        try await pool.write { db in
            for n in out {
                let genre = n.genre.lowercased()
                guard !genre.isEmpty else { continue }
                let parent = (n.parent?.isEmpty == false) ? n.parent!.lowercased() : nil
                try db.execute(sql: """
                    INSERT INTO genre_taxonomy (genre, parent, mbid) VALUES (?, ?, ?)
                    ON CONFLICT(genre) DO UPDATE SET parent = excluded.parent, mbid = excluded.mbid
                """, arguments: [genre, parent, n.mbid])
            }
        }
    }

    /// Expand a list of requested genres to include every descendant subgenre via
    /// `genre_taxonomy` (a filter on "Rock" then also matches "Blues Rock", etc.).
    /// Returns lowercased names. With an empty/unsynced taxonomy this is just the
    /// (lowercased) input, so behaviour degrades gracefully to a flat match.
    static func expandGenres(_ db: Database, _ requested: [String]) throws -> [String] {
        let lowered = requested.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !lowered.isEmpty else { return [] }
        let seed = lowered.map { _ in "SELECT ? AS g" }.joined(separator: " UNION ")
        let sql = """
            WITH RECURSIVE wanted(g) AS (
                \(seed)
                UNION
                SELECT gt.genre FROM genre_taxonomy gt JOIN wanted w ON LOWER(gt.parent) = w.g
            )
            SELECT DISTINCT g FROM wanted
        """
        return try String.fetchAll(db, sql: sql, arguments: StatementArguments(lowered as [DatabaseValueConvertible]))
    }

    // MARK: - Genre families & purity (generation)

    /// Coarse genre family for a raw tag (Roon or MusicBrainz), used by the
    /// genre-purity gate. The `genre_taxonomy` is flat in practice (subgenres
    /// carry no parent), so we group by keyword instead: "smooth jazz" and
    /// "contemporary jazz" both fold into `jazz`, "house"/"electro"/"french
    /// house" into `electronic`, etc. Order matters — the first family whose
    /// keyword the tag contains wins (jazz before "smooth", blues/folk before
    /// "rock"). An unrecognised tag becomes its own singleton family, so it can
    /// never out-vote a real one.
    static func genreFamily(_ raw: String) -> String {
        let t = raw.lowercased()
        // (family, keywords) — scanned in order; specific genres before broad ones.
        let table: [(String, [String])] = [
            ("jazz",       ["jazz"]),
            ("classical",  ["classical", "baroque", "opera", "symphon", "orchestr", "chamber", "choral"]),
            ("metal",      ["metal", "metalcore", "grindcore", "djent"]),
            ("hiphop",     ["hip hop", "hip-hop", "rap", "trap", "grime", "drill"]),
            ("rnb",        ["r&b", "rnb", "soul", "funk", "motown", "disco"]),
            ("electronic", ["electronic", "electro", "house", "techno", "trance", "edm", "dance",
                            "dubstep", "drum and bass", "dnb", "idm", "downtempo", "breakbeat",
                            "big beat", "garage", "ambient"]),
            ("reggae",     ["reggae", "ska", "dub", "dancehall"]),
            ("latin",      ["latin", "salsa", "bossa", "samba", "tango", "flamenco"]),
            ("country",    ["country", "bluegrass", "americana", "honky"]),
            ("blues",      ["blues"]),
            ("folk",       ["folk", "singer-songwriter", "singer/songwriter"]),
            ("rock",       ["rock", "punk", "grunge", "indie", "shoegaze", "emo"]),
            ("pop",        ["pop"]),
            ("easy",       ["easy listening", "lounge", "smooth", "adult contemporary", "new age"]),
            ("world",      ["world", "international", "afro", "celtic", "traditional"]),
        ]
        for (family, keywords) in table where keywords.contains(where: { t.contains($0) }) {
            return family
        }
        return t   // unrecognised → its own singleton family
    }

    /// Genre-purity test for the generation pool. A track legitimately belongs to
    /// a requested genre when that genre's *family* is the plurality of its tags
    /// (Roon ∪ MusicBrainz), OR the literal requested genre is confirmed by BOTH
    /// sources. This blocks a single spurious crowd-tag — a lone "jazz" on an
    /// electronic track — from promoting off-genre material into a genre-scoped
    /// pool, while a genuinely on-genre track (even one only one source tagged)
    /// survives. With no genre data at all it stays lenient (returns true).
    static func passesGenrePurity(roon: [String], mb: [String], requested: [String]) -> Bool {
        let reqFamilies = Set(requested.map(genreFamily))
        guard !reqFamilies.isEmpty else { return true }
        // Cross-source confirmation: the literal requested genre in both sources.
        let reqLower = Set(requested.map { $0.lowercased() })
        let roonSet = Set(roon.map { $0.lowercased() })
        let mbSet = Set(mb.map { $0.lowercased() })
        if !reqLower.isDisjoint(with: roonSet), !reqLower.isDisjoint(with: mbSet) { return true }
        // Plurality: the requested family occurs at least as often as any other.
        let allTags = roon + mb
        guard !allTags.isEmpty else { return true }
        var histogram: [String: Int] = [:]
        for tag in allTags { histogram[genreFamily(tag), default: 0] += 1 }
        let reqCount = reqFamilies.reduce(0) { $0 + (histogram[$1] ?? 0) }
        let maxOther = histogram.filter { !reqFamilies.contains($0.key) }.values.max() ?? 0
        return reqCount > 0 && reqCount >= maxOther
    }

    public struct GenreTreeNode: Sendable, Codable {
        public let genre: String
        public let subgenres: [String]
    }

    /// A two-level tree of the genres actually present in the library, grouped
    /// under their parent genre. Roots are genres with no in-library parent.
    /// Drives the MCP `get_genre_tree` tool and a hierarchical genre picker.
    public func genreTree() async throws -> [GenreTreeNode] {
        try await pool.read { db in
            let used = try String.fetchAll(db, sql: "SELECT DISTINCT genre FROM track_mb_genres")
            guard !used.isEmpty else { return [] }
            var parentOf: [String: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT genre, parent FROM genre_taxonomy WHERE parent IS NOT NULL AND parent != ''") {
                if let g = r["genre"] as String?, let p = r["parent"] as String? { parentOf[g] = p }
            }
            let usedSet = Set(used)
            var children: [String: [String]] = [:]
            var roots = Set<String>()
            for g in used {
                if let p = parentOf[g], usedSet.contains(p) { children[p, default: []].append(g) }
                else { roots.insert(g) }
            }
            return roots.sorted().map { GenreTreeNode(genre: $0, subgenres: (children[$0] ?? []).sorted()) }
        }
    }

    /// Count of distinct genres present across Roon + MusicBrainz sources — the
    /// "how many more genres now" number for diagnostics/UI.
    public func genreCounts() async throws -> (roon: Int, musicbrainz: Int) {
        try await pool.read { db in
            let roon = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT genre) FROM track_genres") ?? 0
            let mb = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT genre) FROM track_mb_genres") ?? 0
            return (roon, mb)
        }
    }
}
