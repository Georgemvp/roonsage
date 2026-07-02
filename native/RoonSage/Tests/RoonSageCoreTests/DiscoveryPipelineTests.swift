@testable import RoonSageCore
import XCTest

/// The pure pipeline merge/dedup: cross-producer grouping (which becomes the
/// consensus signal) and post-resolve re-dedup by canonical identity.
final class DiscoveryPipelineTests: XCTestCase {

    func testMergeGroupsByNormalizedIdentityAndCountsSources() {
        let candidates = [
            Candidate(kind: .artist, artist: "Boards of Canada", similarity: 0.9, producer: "similar-artist-web"),
            Candidate(kind: .artist, artist: "boards of canada", similarity: 0.7, producer: "charts"),   // same after normalise
            Candidate(kind: .artist, artist: "Aphex Twin", similarity: 0.8, producer: "similar-artist-web"),
        ]
        let merged = DiscoveryPipeline.merge(candidates)
        XCTAssertEqual(merged.count, 2)

        let boc = merged.first { $0.artist.lowercased() == "boards of canada" }
        XCTAssertNotNil(boc)
        XCTAssertEqual(boc?.distinctSources, 2)   // found by two producers → consensus
        XCTAssertEqual(boc?.sources.count, 2)

        let aphex = merged.first { $0.artist.lowercased() == "aphex twin" }
        XCTAssertEqual(aphex?.distinctSources, 1)
    }

    func testMergeDoesNotDoubleCountSameProducer() {
        let candidates = [
            Candidate(kind: .artist, artist: "Autechre", similarity: 0.6, producer: "similar-artist-web"),
            Candidate(kind: .artist, artist: "Autechre", similarity: 0.9, producer: "similar-artist-web"),
        ]
        let merged = DiscoveryPipeline.merge(candidates)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.distinctSources, 1)   // same producer twice ≠ consensus
    }

    func testRededupeCollapsesByResolvedMBID() {
        // Two items that normalized differently pre-resolve but share an MBID
        // (canonicalised) collapse into one, unioning their sources.
        var a = WorkItem(kind: .artist, artist: "The Beatles", album: nil, year: nil, genres: [],
                         sources: [SourceRef(producer: "similar-artist-web")], artistMbid: "mbid-1",
                         releaseGroupMbid: nil, qobuzAlbumID: nil, imageURL: nil, releaseDate: nil, gapPriority: nil)
        var b = a
        b.artist = "Beatles"
        b.sources = [SourceRef(producer: "charts")]
        let deduped = DiscoveryPipeline.rededupe([a, b])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.distinctSources, 2)
        _ = (a, b)
    }

    func testMergeThreadsGapPriorityFromCandidate() {
        // Gap-fill sets gapPriority; a later, gapPriority-less duplicate from
        // another producer must not blank it out (first non-nil wins).
        let candidates = [
            Candidate(kind: .album, artist: "Boards of Canada", album: "Geogaddi",
                     similarity: 0.6, producer: "gap-fill", gapPriority: 1.0),
            Candidate(kind: .album, artist: "Boards of Canada", album: "Geogaddi",
                     similarity: 0.5, producer: "similar-artist-web"),
        ]
        let merged = DiscoveryPipeline.merge(candidates)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.gapPriority, 1.0)
        XCTAssertEqual(merged.first?.distinctSources, 2)
    }

    func testPreKeyNormalizesArtist() {
        XCTAssertEqual(
            DiscoveryPipeline.preKey(kind: .artist, artist: "Sigur Rós", album: nil),
            DiscoveryPipeline.preKey(kind: .artist, artist: "sigur ros", album: nil))
    }

    // MARK: - Genre-from-tags distillation (fixes the "0 genres" empty inputs)

    func testGenresFromTagsFiltersNoiseAgainstVocabulary() {
        let tags = ["rock", "british", "blues rock", "1980s", "classic rock", "seen live"]
        let vocab: Set<String> = ["rock", "blues rock", "classic rock", "country rock"]
        // Keeps only real genres, in the original vote-ranked order.
        XCTAssertEqual(DiscoveryPipeline.genresFromTags(tags, vocabulary: vocab),
                       ["rock", "blues rock", "classic rock"])
    }

    func testGenresFromTagsFallsBackToRawTagsWhenVocabularyEmpty() {
        // Taxonomy not synced yet → don't stay blank; use the raw tags (capped at 6).
        let tags = ["a", "b", "c", "d", "e", "f", "g"]
        XCTAssertEqual(DiscoveryPipeline.genresFromTags(tags, vocabulary: []),
                       ["a", "b", "c", "d", "e", "f"])
    }

    func testGenresFromTagsCapsAtSix() {
        let tags = ["rock", "pop", "jazz", "blues", "folk", "soul", "funk", "disco"]
        let vocab = Set(tags)
        XCTAssertEqual(DiscoveryPipeline.genresFromTags(tags, vocabulary: vocab).count, 6)
    }
}
