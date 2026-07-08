#!/usr/bin/env bash
# Distil the MusicMoveArr dumps (torrent: MusicBrainz Tidal Spotify Deezer) into a
# COMPACT SQLite sidecar the analyzer + discovery engine consume:
#
#   metadata.db
#     ds_tracks(source, artist, title, album, isrc, recording_mbid,
#               duration, bpm, gain, rank, album_upc, label, release_date, explicit,
#               match_key)                              -- identity for OWNED tracks
#     ds_candidates(artist, album, year, genres, fans, source) -- adjacent, NOT owned
#
# ds_tracks is filtered to the user's own library artists (the importer only
# matches analyzed tracks), and ds_candidates to albums by non-owned artists in
# the library's top genres — so a 121 GB dump collapses to a few hundred MB.
#
# The heavy lifting is DuckDB over the raw flat CSVs (no Postgres import). All
# steps are resumable: re-running skips work whose output already exists.
#
# Usage: native/scripts/distill-datasets.sh [WORKDIR] [LIBRARY_DB]
#   WORKDIR     dir holding CSV.7z / the extracted CSVs / metadata.db
#               (default: /Volumes/Elements/roonsage-datasets)
#   LIBRARY_DB  RoonSage library.db to read owned artists from
#               (default: ~/Library/Application Support/RoonSage/library.db)
#
# Requires: 7zz (sevenzip), duckdb, sqlite3 — `brew install sevenzip duckdb`.
set -euo pipefail

WORKDIR="${1:-/Volumes/Elements/roonsage-datasets}"
LIBRARY_DB="${2:-$HOME/Library/Application Support/RoonSage/library.db}"
DATASET_DIR="$WORKDIR/MusicBrainz Tidal Spotify Deezer Dataset 22 Feb 2026"
ARCHIVE="$DATASET_DIR/CSV.7z"
DEEZER_CSV="$DATASET_DIR/CSV/deezer_flat.csv"
SIDECAR="$WORKDIR/metadata.db"
TMP="$WORKDIR/duckdb-tmp"

for bin in 7zz duckdb sqlite3; do
  command -v "$bin" >/dev/null || { echo "ERROR: '$bin' not found (brew install sevenzip duckdb)"; exit 1; }
done
[ -f "$LIBRARY_DB" ] || { echo "ERROR: library.db not found at $LIBRARY_DB"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "ERROR: CSV.7z not found at $ARCHIVE (download the torrent first)"; exit 1; }
mkdir -p "$TMP"

# 1. Owned artists (lowercased, distinct) → a CSV DuckDB can join against.
LIB_ARTISTS="$WORKDIR/lib_artists.csv"
echo "[1/3] Exporting owned artists from $LIBRARY_DB …"
sqlite3 -noheader -csv "$LIBRARY_DB" \
  "SELECT DISTINCT lower(trim(artist)) FROM tracks WHERE artist IS NOT NULL AND trim(artist) != '';" \
  > "$LIB_ARTISTS"
echo "      $(wc -l < "$LIB_ARTISTS") artists."

# 2. Extract deezer_flat.csv (the richest table: ISRC + BPM + gain + rank + fans
#    + genre). ~121 GB uncompressed; skip if already extracted.
if [ ! -f "$DEEZER_CSV" ]; then
  echo "[2/3] Extracting deezer_flat.csv (~121 GB) …"
  7zz e -y -o"$DATASET_DIR/CSV" "$ARCHIVE" "CSV/deezer_flat.csv" >/dev/null
else
  echo "[2/3] deezer_flat.csv already extracted — skipping."
fi

# 3. Distil into the SQLite sidecar via DuckDB. Bounded memory + on-drive spill
#    so a 121 GB scan never blows up RAM.
echo "[3/3] Distilling → $SIDECAR (DuckDB) …"
rm -f "$SIDECAR"
duckdb <<SQL
PRAGMA memory_limit='6GB';
PRAGMA temp_directory='$TMP';
PRAGMA threads=6;
INSTALL sqlite; LOAD sqlite;

CREATE TEMP TABLE lib_artists AS
  SELECT column0 AS artist FROM read_csv('$LIB_ARTISTS', header=false, columns={'column0':'VARCHAR'});

-- Raw Deezer view (typed projection of the columns we use).
CREATE TEMP VIEW deezer AS
  SELECT ArtistName, ArtistNbFan, AlbumName, AlbumGenreName, AlbumReleaseDate,
         TrackTitle, TrackTitleVersion, TrackISRC, TrackDuration, TrackBPM, TrackGain, TrackRank,
         AlbumUPC, Label, TrackReleaseDate, TrackExplicitLyrics, AlbumExplicitLyrics
  FROM read_csv('$DEEZER_CSV', header=true, sample_size=-1, ignore_errors=true,
                all_varchar=true);

-- Library's top genres (by owned-track count) — the candidate seed.
CREATE TEMP TABLE lib_genres AS
  SELECT AlbumGenreName AS genre, COUNT(*) AS n
  FROM deezer
  WHERE lower(ArtistName) IN (SELECT artist FROM lib_artists)
    AND AlbumGenreName IS NOT NULL AND AlbumGenreName <> ''
  GROUP BY 1 ORDER BY n DESC LIMIT 25;

ATTACH '$SIDECAR' AS side (TYPE SQLITE);

-- ds_tracks: identity for OWNED artists' tracks with an ISRC. Title keeps the
-- version suffix (the importer's TrackIdentity strips it) so remaster/edition
-- rows still key to the base track. match_key stays NULL — pass A fills it in
-- the analyzer, using the real normaliser.
CREATE TABLE side.ds_tracks AS
  SELECT 'deezer' AS source, ArtistName AS artist,
         COALESCE(NULLIF(TrackTitle,''), TrackTitleVersion) AS title, AlbumName AS album,
         TrackISRC AS isrc, CAST(NULL AS VARCHAR) AS recording_mbid,
         TRY_CAST(TrackDuration AS DOUBLE) AS duration,
         TRY_CAST(TrackBPM AS DOUBLE) AS bpm,
         TRY_CAST(TrackGain AS DOUBLE) AS gain,
         TRY_CAST(TrackRank AS BIGINT) AS rank,
         NULLIF(AlbumUPC, '') AS album_upc,
         NULLIF(Label, '') AS label,
         COALESCE(NULLIF(TrackReleaseDate,''), NULLIF(AlbumReleaseDate,'')) AS release_date,
         -- Deezer's dump encodes these as the strings "True"/"False" (Python-style),
         -- NOT "1"/"0" — verified against a raw CSV sample after a first pass came
         -- back all-NULL.
         CASE WHEN lower(TrackExplicitLyrics) = 'true' OR lower(AlbumExplicitLyrics) = 'true' THEN 1
              WHEN lower(TrackExplicitLyrics) = 'false' OR lower(AlbumExplicitLyrics) = 'false' THEN 0
              ELSE NULL END AS explicit,
         CAST(NULL AS VARCHAR) AS match_key
  FROM deezer
  WHERE lower(ArtistName) IN (SELECT artist FROM lib_artists)
    AND TrackISRC IS NOT NULL AND TrackISRC <> ''
    AND TrackTitle IS NOT NULL AND TrackTitle <> '';

-- ds_candidates: albums by NON-owned artists in the library's top genres, ranked
-- by artist fan count (the dataset's adjacency proxy). Capped so the sidecar
-- stays small; DatasetProducer shuffles + filters owned/disliked at query time.
CREATE TABLE side.ds_candidates AS
  SELECT artist, album, year, genres, fans, 'deezer' AS source FROM (
    SELECT ArtistName AS artist, AlbumName AS album,
           TRY_CAST(substr(AlbumReleaseDate,1,4) AS INTEGER) AS year,
           to_json([AlbumGenreName]) AS genres,
           MAX(TRY_CAST(ArtistNbFan AS BIGINT)) AS fans
    FROM deezer
    WHERE AlbumGenreName IN (SELECT genre FROM lib_genres)
      AND lower(ArtistName) NOT IN (SELECT artist FROM lib_artists)
      AND AlbumName IS NOT NULL AND AlbumName <> ''
    GROUP BY ArtistName, AlbumName, year, AlbumGenreName
  ) ORDER BY fans DESC LIMIT 50000;

DETACH side;
SQL

# Indexes the importer + producer rely on.
sqlite3 "$SIDECAR" \
  "CREATE INDEX IF NOT EXISTS idx_ds_candidates_fans ON ds_candidates(fans DESC);
   ANALYZE;"

echo "Done. Sidecar: $SIDECAR"
sqlite3 "$SIDECAR" \
  "SELECT 'ds_tracks     ' || COUNT(*) || ' rows, ' || COUNT(isrc) || ' with ISRC' FROM ds_tracks;
   SELECT 'ds_candidates ' || COUNT(*) || ' rows' FROM ds_candidates;"
ls -lh "$SIDECAR"
echo
echo "Next:"
echo "  roonsage-analyzer import-dataset --sidecar '$SIDECAR'   # fase 1: ISRC/MBID onto track_features"
echo "  set discovery 'dataset_sidecar_path' = '$SIDECAR' in the analyzer app # fase 2: DatasetProducer"
