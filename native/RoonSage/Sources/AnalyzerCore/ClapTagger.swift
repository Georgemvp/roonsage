import Accelerate
import AudioAnalysis
import Foundation

public struct ClapTagProgress: Sendable {
    public var tagged: Int      // rows stamped with the current vocabulary version
    public var total: Int       // rows with an embedding (the taggable universe)
}

/// The controlled zero-shot tag vocabulary: every term the tagger may emit,
/// with the CLAP text prompts that define it. Replaces the Ollama `Tagger`,
/// which guessed tags from METADATA it never heard — the guesses anchored on
/// the prompt's example words ("driving" landed on 62% of the library, "deep
/// house" on indie rock) and produced 7.5k+ uncontrolled tag spellings.
/// Here every tag is (a) scored against the actual audio embedding and
/// (b) drawn from this fixed list, so downstream naming (SonicClusters'
/// Dutch `tagName` map, radio profiles) can rely on the vocabulary.
public enum ClapTagVocabulary {
    /// Stamped into `tags_model` per row; bump to force a library-wide retag.
    public static let version = "clap-zs-v1"

    /// tag → caption-style prompts (mean-of-phrases, like `CLAPModel.attributeAxes`).
    public static let terms: [(tag: String, prompts: [String])] = [
        // Genres the audio tower can actually hear.
        ("rock", ["rock music with electric guitars, bass and drums", "a classic rock song"]),
        ("indie rock", ["indie rock with jangly guitars", "alternative rock music"]),
        ("hard rock", ["hard rock with heavy distorted electric guitars", "loud aggressive rock music"]),
        ("metal", ["heavy metal with aggressive distorted guitars and double bass drums", "a metal band playing loud and fast"]),
        ("punk", ["punk rock, fast and raw", "a punk band playing fast power chords"]),
        ("pop", ["a catchy mainstream pop song with vocals", "polished radio pop music"]),
        ("synth-pop", ["synth-pop with bright synthesizers and vocals", "1980s synthesizer pop music"]),
        ("house", ["house music with a four-on-the-floor kick drum", "an electronic house track for the club"]),
        ("deep house", ["deep house with a warm mellow groove", "smooth deep house music"]),
        ("techno", ["techno with a relentless driving electronic beat", "dark industrial techno music"]),
        ("trance", ["trance music with euphoric arpeggiated synthesizers", "uplifting trance with long builds"]),
        ("drum and bass", ["drum and bass with fast breakbeats and deep bass", "jungle drum and bass music"]),
        ("ambient", ["ambient music with slowly evolving atmospheric textures and no beat", "a calm ambient soundscape"]),
        ("downtempo", ["downtempo electronica with a slow relaxed beat", "a chilled trip-hop instrumental"]),
        ("classical", ["classical music performed by a symphony orchestra", "a classical orchestral piece with strings"]),
        ("opera", ["opera singing with orchestral accompaniment", "an operatic aria sung by a classical voice"]),
        ("solo piano", ["solo piano music, a single piano playing", "an intimate piano piece without other instruments"]),
        ("orchestral", ["a full orchestra playing with strings and brass", "a grand orchestral arrangement"]),
        ("cinematic", ["epic cinematic film score music", "a dramatic movie soundtrack with orchestra"]),
        ("jazz", ["a jazz ensemble with swing and improvisation", "jazz music with saxophone and double bass"]),
        ("blues", ["blues music with expressive guitar bends", "a slow blues song with guitar and vocals"]),
        ("soul", ["soul music with warm expressive vocals", "classic soul with horns and a rhythm section"]),
        ("funk", ["funk music with a tight syncopated groove", "funky bass and rhythm guitar"]),
        ("disco", ["disco music with strings and a danceable beat", "1970s disco with a four-on-the-floor groove"]),
        ("r&b", ["smooth contemporary r&b with sung vocals", "an r&b track with slick production"]),
        ("hip-hop", ["hip-hop music with rapping over a beat", "a rap track with strong drums"]),
        ("folk", ["folk music with acoustic guitar and storytelling vocals", "a traditional folk song"]),
        ("singer-songwriter", ["an intimate singer-songwriter song with acoustic guitar or piano", "a solo artist singing a personal song"]),
        ("country", ["country music with twangy guitars", "an american country song"]),
        ("reggae", ["reggae music with offbeat guitar skanks", "a laid-back reggae groove"]),
        ("latin", ["latin music with percussion and spanish rhythms", "a latin dance track"]),
        // Texture / mood (aligned with SonicClusters' Dutch tagName allowlist).
        ("acoustic", ["acoustic music played on organic instruments", "an unplugged acoustic performance"]),
        ("electronic", ["electronic music made with synthesizers and drum machines", "a produced electronic track"]),
        ("instrumental", ["instrumental music without any vocals", "a track with no singing"]),
        ("energetic", ["high-energy intense driving music", "a powerful energetic track"]),
        ("calm", ["calm gentle quiet music", "soft peaceful relaxing music"]),
        ("melancholic", ["sad melancholic emotional music", "a sorrowful wistful song"]),
        ("uplifting", ["uplifting euphoric feel-good music", "a joyful triumphant song"]),
        ("dark", ["dark ominous brooding music", "a menacing tense track"]),
        ("dreamy", ["dreamy ethereal floating music", "hazy shimmering dream-pop textures"]),
        ("atmospheric", ["atmospheric spacious music with lots of reverb", "a wide ambient atmosphere in a song"]),
        ("groovy", ["a groovy track with an infectious rhythm", "music with a strong funky groove"]),
        ("hypnotic", ["hypnotic repetitive trance-inducing music", "a looping mesmerizing rhythm"]),
        ("romantic", ["a romantic tender love song", "warm intimate romantic music"]),
        ("psychedelic", ["psychedelic music with swirling trippy effects", "a trippy psychedelic rock jam"]),
        ("epic", ["epic grandiose monumental music", "a heroic anthemic track"]),
        ("live", ["a live concert recording with audience noise and applause", "a live performance in front of a crowd"]),
    ]
}

/// Zero-shot audio tagging: scores every embedded track against the fixed
/// vocabulary and stores the tags whose LIBRARY-RELATIVE z-score clears the
/// floor. Z-scores (per term, over a library sample) cancel CLAP's per-prompt
/// text prior — the same reason `MoodCalibration` exists client-side: raw
/// cosines would hand every track the same few structurally-high terms.
/// Resumable via `tags_model`; bump `ClapTagVocabulary.version` to retag.
public final class ClapTagger {
    private let store: FeatureStore
    private let clap: CLAPModel
    private let batchSize: Int
    private let zFloor: Float
    private let zRelaxed: Float
    private let maxTags: Int
    private let sampleLimit: Int
    private var cancelled = false

    public init(store: FeatureStore, clap: CLAPModel, batchSize: Int = 512,
                zFloor: Float = 2.0, zRelaxed: Float = 1.0, maxTags: Int = 5,
                sampleLimit: Int = 4000) {
        self.store = store
        self.clap = clap
        self.batchSize = max(1, batchSize)
        self.zFloor = zFloor
        self.zRelaxed = zRelaxed
        self.maxTags = max(1, maxTags)
        self.sampleLimit = max(100, sampleLimit)
    }

    public func cancel() { cancelled = true }

    /// One term's unit text embedding + its cosine distribution over the library.
    struct TermStats {
        let tag: String
        let embed: [Float]
        var mean: Float
        var std: Float
    }

    public func run(onProgress: @escaping @Sendable (ClapTagProgress) -> Void) async {
        guard clap.canEmbedText else {
            NSLog("[clap-tag] text tower unavailable (tokenizer missing) — cannot tag")
            return
        }
        let total = store.embeddedCount()
        guard total > 0 else { return }
        guard var terms = embedTerms() else {
            NSLog("[clap-tag] could not embed vocabulary — aborting")
            return
        }

        // Calibrate: per-term cosine mean/std over an evenly-spread library
        // sample, so "clears the floor" means unusual FOR THIS LIBRARY.
        let sample = store.embeddingSample(limit: sampleLimit)
        guard sample.count >= 50 else {
            NSLog("[clap-tag] only \(sample.count) embedded rows — not enough to calibrate")
            return
        }
        calibrate(&terms, sample: sample)

        while !cancelled {
            let rows = store.rowsNeedingClapTags(version: ClapTagVocabulary.version, limit: batchSize)
            if rows.isEmpty { break }
            var updates: [(matchKey: String, tags: String)] = []
            updates.reserveCapacity(rows.count)
            for row in rows {
                if cancelled { break }
                let tags = Self.tags(for: row.embedding, terms: terms,
                                     zFloor: zFloor, zRelaxed: zRelaxed, maxTags: maxTags)
                guard let json = try? JSONSerialization.data(withJSONObject: tags),
                      let s = String(data: json, encoding: .utf8) else { continue }
                updates.append((row.matchKey, s))
            }
            guard !updates.isEmpty else { break }
            try? store.setClapTags(updates, model: ClapTagVocabulary.version)
            onProgress(ClapTagProgress(
                tagged: store.clapTaggedCount(version: ClapTagVocabulary.version), total: total))
        }
    }

    /// Mean-of-phrases unit embedding per vocabulary term (like `prepareProbes`).
    private func embedTerms() -> [TermStats]? {
        var out: [TermStats] = []
        for (tag, prompts) in ClapTagVocabulary.terms {
            var acc = [Float](repeating: 0, count: 512)
            var n = 0
            for p in prompts {
                guard let e = try? clap.textEmbedding(p), e.count == acc.count else { continue }
                vDSP_vadd(acc, 1, e, 1, &acc, 1, vDSP_Length(acc.count)); n += 1
            }
            guard n > 0 else { continue }
            var norm: Float = 0
            vDSP_svesq(acc, 1, &norm, vDSP_Length(acc.count))
            norm = sqrt(norm)
            guard norm > 0 else { continue }
            vDSP_vsdiv(acc, 1, &norm, &acc, 1, vDSP_Length(acc.count))
            out.append(TermStats(tag: tag, embed: acc, mean: 0, std: 1))
        }
        return out.isEmpty ? nil : out
    }

    /// Per-term cosine mean/std over the sample (embeddings are unit vectors,
    /// so cosine == dot product).
    private func calibrate(_ terms: inout [TermStats], sample: [[Float]]) {
        for i in terms.indices {
            var sum: Float = 0
            var sumSq: Float = 0
            for e in sample {
                var d: Float = 0
                vDSP_dotpr(e, 1, terms[i].embed, 1, &d, vDSP_Length(min(e.count, terms[i].embed.count)))
                sum += d; sumSq += d * d
            }
            let n = Float(sample.count)
            let mean = sum / n
            let variance = max(0, sumSq / n - mean * mean)
            terms[i].mean = mean
            terms[i].std = max(1e-4, sqrt(variance))
        }
    }

    /// The tags for one track: every term whose z clears `zFloor` (best first,
    /// capped), topped up to 2 from the `zRelaxed` band when the strict floor
    /// yields fewer — a track that is unusual on nothing stays sparsely tagged
    /// (honest) rather than getting filler.
    static func tags(for embedding: [Float], terms: [TermStats],
                     zFloor: Float, zRelaxed: Float, maxTags: Int) -> [String] {
        var scored: [(tag: String, z: Float)] = []
        scored.reserveCapacity(terms.count)
        for t in terms {
            var d: Float = 0
            vDSP_dotpr(embedding, 1, t.embed, 1, &d, vDSP_Length(min(embedding.count, t.embed.count)))
            scored.append((t.tag, (d - t.mean) / t.std))
        }
        scored.sort { $0.z != $1.z ? $0.z > $1.z : $0.tag < $1.tag }
        var out = scored.prefix(while: { $0.z >= zFloor }).prefix(maxTags).map(\.tag)
        if out.count < 2 {
            for s in scored where s.z >= zRelaxed && !out.contains(s.tag) {
                out.append(s.tag)
                if out.count >= 2 { break }
            }
        }
        return Array(out)
    }
}
