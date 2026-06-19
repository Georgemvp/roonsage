# Smart Radios — RoonSage

Goal: **Plexamp-class smart radios** that flow like a designed set, learn what you
love, and let you steer how adventurous they are — every track from your own Roon
library or Qobuz, never hallucinated.

This document records the architecture, what's shipped, and the staged roadmap.

---

## How a station is built (after this work)

All five radio surfaces — in-app **Sonic Radio** (endless stations), **AI artist
radios → Qobuz**, the **genre/mood/activity/decade** category stations, the
**now-playing "more like this"** radio, and the **Sonic Fingerprint**
recommendations — funnel through one ranking core when CLAP embeddings exist
(`useSonicEmbeddings`, default on). The rule-based BPM/Camelot/tag engine
(`SonicSimilarity`) remains the documented fallback for un-analyzed tracks / the
A/B-off path, and is unchanged.

```
seeds ─► RadioEngine.rank ─► RadioSequencer.order ─► station
            │
            ├─ multi-anchor relevance   (centroid ⊕ nearest-seed-anchor)
            ├─ adventurousness dial      (novelty bias + MMR diversity λ)
            ├─ taste steering            (+likes, +taste vector, −dislikes in vector space)
            ├─ MMR diversification       (kills near-duplicate clusters)
            └─ a Reason per pick         ("klinkt als…", "ontdekking", "omdat je … mooi vond")
```

### The pieces (`Sources/RoonSageCore/Sonic/`)

- **`RadioEngine.swift`** — the heart. Given seeds + the `VectorIndex`:
  - **Multi-anchor relevance.** A seed set spanning ballads *and* bangers has a
    centroid stuck in the muddy middle. We score each candidate on a blend of
    closeness to the centroid **and** to its *nearest* seed anchor, so both poles
    stay represented (no centroid collapse).
  - **The adventurousness dial (0…1).** One knob biases toward novelty (unheard
    artists / farther-out sonics) **and** loosens the MMR diversity λ. Familiar
    deep-cut hour ↔ voyage.
  - **Taste steering in vector space.** The query is nudged toward liked tracks
    and the personal taste vector, and pushed *away* from disliked ones (the
    Song-Alchemy ADD/SUBTRACT idea applied to personalization). Dislikes can be
    hard-banned or soft-down-sampled.
  - **MMR diversification** + a **reason** per pick (explainability).
- **`RadioSequencer.swift`** — orders the chosen set into a *flowing* journey:
  greedy walk minimising track-to-track jumps in CLAP cosine + tempo
  (half/double-time aware) + Camelot harmony (reuses the DJ wheel) + a gentle
  energy arc. This is what makes a station feel designed rather than shuffled.
- **`TasteVector.swift`** — your "musical centre of gravity": a recency-weighted
  centroid of played + liked tracks (`log(1+plays) · exp(−ageDays/120d)`, plus a
  flat like bonus), L2-normalized into a query nudge. Available on the always-on
  server build (history lives there); thin clients lean on seeds + artist-level
  signals instead.

### Where it's wired
- `RoonClient+Radio.swift` · `buildRadioCandidates` (endless Sonic Radio)
- `RoonClient+ArtistRadio.swift` · `buildPlaylistCandidates` + the capped Qobuz
  playlist is flow-sequenced into a gentle arc
- `RoonClient+Features.swift` · `similarTracks` (now-playing) + `sonicFingerprint`
- UI: an **Avontuurlijkheid** slider + a **hard-ban disliked** toggle on the Radio
  screen (`SonicRadioView`, shared by macOS + iOS).
- Settings: `radioAdventurousness`, `radioHardBanDisliked` (UserDefaults).

### Data per track today
512-dim CLAP embedding (the primary driver), 6 CLAP mood cosines, optional Ollama
tags, Roon genres, play history, explicit like/dislike, BPM/Camelot/energy(RMS)/
duration, PCA-2D map coords.

---

## Roadmap (staged)

Shipped first because it works on **existing** embeddings (no re-analysis needed):

| Stage | Item | Status |
|------|------|--------|
| A | RadioEngine (multi-anchor, dial, MMR, dislike steering, reasons) | ✅ shipped |
| A | RadioSequencer flow ordering | ✅ shipped |
| A | Adventurousness dial + hard-ban UI | ✅ shipped |
| A | Recency-weighted personal taste vector | ✅ shipped |
| B | Per-track **reason** surfaced in the UI (Fingerprint recs) | ✅ shipped |
| B | **Sonic neighborhoods** — k-means over CLAP → `.sonic` discovered stations | ✅ shipped |
| B | **Sonic Adventure** — A→far journey via `SongPaths`, "Reis" on Now Playing | ✅ shipped |
| B | **Live re-steering** — a thumb mid-station rebuilds the upcoming pool | ✅ shipped |
| B | **Analyzer tuning UI** — dial + hard-ban in the server's radio settings | ✅ shipped |

Notes on the "online taste model": the recency-weighted **taste vector** (likes +
plays, minus dislikes via the query push) IS the learned taste representation. A
separate logistic classifier over the (sparse) like/dislike labels was considered
and skipped — it would overfit and largely duplicate the taste vector. Revisit if
feedback volume grows.

Next (also on existing data):

- **ListenBrainz read-back** into `listening_history` (currently write-only).
- **Offline eval harness** — hold out liked tracks, measure recall@k; extend the
  `useSonicEmbeddings` A/B flag to score radio quality.
- **Endless Sonic Adventure** — today it's a one-shot ~40-track voyage; make it
  re-path to a new far region as it drains.

Richer analysis (pays off after the next analyzer pass — the library lives on a
slow external drive, so this is gated on a scan the user controls):

- **CLAP zero-shot attribute axes** — valence / danceability / acousticness /
  instrumentalness from the same probe-cosine mechanism as moods. "Meer meta" for
  sharper mood/activity stations + sequencing, for free from the existing model.
- **Perceptual loudness (EBU R128 / LUFS)** to replace the raw-RMS "energy".
- **Propagate `bpm_confidence`** to the client and down-weight low-confidence BPM
  in the sequencer.
- **Coverage fix + surfacing** — better `match_key` (album/duration), better
  primary-artist extraction, and show "X% van je bibliotheek geanalyseerd".

Discovery frontier:
- Hybrid library-kNN + Qobuz expansion so stations introduce genuinely *new*
  music, not only reshuffle the library.
