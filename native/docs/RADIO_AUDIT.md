# Radio-audit — waarom "RoonSage · Acoustic" niet klopte, en wat er nu slim(mer) is

> **Status 2026-07-05: alle bevindingen geïmplementeerd** (v1.10.113 /
> ios-v1.7.85 / analyzer-v1.1.84). Zie het maatregelenblok onderaan voor de
> mapping bevinding → fix → bestand. Openstaand: kalibratie van de
> CLAP-attribuutassen tegen handmatig geverifieerde referentietracks (de
> percentiel-kalibratie is de pragmatische tussenstap), en een echt
> co-listen-signaal uit ListenBrainz (nu: Deezer fan-graph).

> Gegenereerd: 2026-07-05. Methode: 3 parallelle code-verkenningen
> (titel-generatie · trackselectie-engine · Qobuz-sync/LLM) + directe reads van
> `RadioEngine`, `RadioSequencer`, `SonicClusters`, `QobuzClient`,
> `RoonClient+ArtistRadio`. Aanleiding: Qobuz-playlists met namen als
> "RoonSage · Acoustic" op muziek die niet akoestisch is.

---

## TL;DR

De **selectie-engine was al Plexamp-klasse** (CLAP-kNN, multi-anchor, MMR,
adaptieve σ-drempel, smaakvector, flow-sequencing, live re-steer). Het probleem
zat volledig in de **naamgeving**, met drie root causes:

| # | Root cause | Gevolg |
|---|-----------|--------|
| 1 | Titel werd één keer gegenereerd en **voor eeuwig bevroren** (Qobuz-naam = vind-sleutel) | Naam beschrijft een lang verdwenen eerste selectie |
| 2 | LLM-fallback voor `.sonic`-buurten = **kale Engelse analyzer-tag** via één argmax ("acoustic" → "Acoustic") | "RoonSage · Acoustic" op niet-akoestische muziek |
| 3 | Titel-prompt kreeg **geen gemeten audio-kenmerken** (attributen stonden default uit) + temp ~0.8 + geen JSON-mode | Het model *gokte* stijlwoorden op artiestnamen |

## Bevindingen → maatregelen

| Bevinding | Fix | Waar |
|-----------|-----|------|
| Titel bevroren; Qobuz-naam als vind-sleutel | Titel hergenereert wanneer de **profiel-signatuur** (gebande sonische karakteristiek, ongevoelig voor de dagrotatie) verschuift; hernoemen **in-place** via de bewaarde `qobuzPlaylistID`; orphan-reconciliatie beschermt ook op ID | `TitleGrounding.profileSignature`, `aiTitleAndDescription`, `QobuzClient.deleteRadioOrphans(keepIDs:)` |
| Kale Engelse tag-namen | Tag benoemt een buurt alleen nog **gecorroboreerd** (≥40% dekking), **vertaald** (vaste NL-woordenlijst) en **niet tegengesproken** door de gemeten attributen; anders mood of "Sonische buurt N" | `SonicClusters.label` + `tagName` |
| Titel niet gegrond in audio | Attributen (valence/danceability/acousticness/instrumentalness) voeden de prompt **default aan**, **bibliotheek-gekalibreerd** (percentielen); gegenereerde titels worden **gevalideerd** tegen de metingen (claim-lexicon NL/EN) met één corrigerende retry — "akoestisch" op elektronische muziek is nu onmogelijk i.p.v. onwaarschijnlijk | `TitleGrounding` (Calibration/SelectionStats/violations), `generateAIMeta` |
| LLM-call fragiel | `jsonMode: true` + `temperature 0.35`; Ollama-default → `qwen3:8b` (mini draait `qwen3.5:9b-mlx`) | `LLMClient`, `generateAIMeta` |
| Bucket-radio's konden wegdriften van hun naam | **Feature-fusie**: activity/mood/genre/decennium-radio's gaten hun k-NN-pool op het definiërende gemeten kenmerk (met relaxatie) — de naam klopt per constructie | `bucketGate`, `gatedWithRelaxation` |
| Geen song-radio | `startTrackRadio` (seed = één track) via de volledige RadioEngine; `playSonicRadio` (Now Playing/⌘K) delegeert; "Radio op dit nummer" in contextmenu's | `RoonClient+Radio`, `PlayActionsMenu` |
| Geen collaboratief signaal | Deezer **fan-graph** ("fans also like") gecachet in `related_artists` (schema v34, TTL 30d); begrensde `relatedAffinityBonus` (0.06) in de ranking | `RelatedArtists`, `RadioEngine.rank` |
| ~22k Qobuz-tracks onanalyseerbaar → nooit radio-kandidaat | **Preview-embeddings**: strikt gematchte Deezer 30s-previews → CLAP-analyse → `preview://deezer/<id>`-rows; uitgesloten van lokale playback, wél in /features, /embeddings, radio's | `PreviewEmbeddingBackfill`, `FeatureStore.previewPathPrefix`, `DatabaseManager.tracksWithoutFeatures` |

## Wat al goed was (bewust ongemoeid)

- `RadioEngine.rank`: multi-anchor (50/50 centroid↔dichtstbijzijnde seed), MMR
  met harde near-dup-ban (cos > 0.95) + album/artiest-caps, adaptieve
  σ-similarity-floor, recency-gewogen persoonlijke smaakvector, popularity-tilt.
- `RadioSequencer`: flow-ordening op embedding + BPM (half/double-time-aware) +
  Camelot + energieboog — dit doet Spotify-radio niet eens.
- Live her-sturen op duimpjes; dislikes drievoudig verwerkt (query-repulsie,
  down-sampling, optionele hard-ban).

## Ronde 2 (2026-07-05, v1.10.114 / analyzer-v1.1.85) — na live loggen

Het loggen van ronde 1 op de mini onthulde de échte kwaliteitsplafonds:

| Vondst (uit de logs/DB) | Fix |
|---|---|
| **Energy-as stuk**: lineaire RMS, alles geplet in [0,0.6], p99=0.37, 0 tracks ≥0.7, én verkeerde ordening (Knopfler 0.48 > Kobosil 0.37). Vergiftigde de activity-gates (Workout matchte NUL), de energiebanden én mijn eigen claim-validator (verwierp élke 'energiek'-titel). | **Perceptuele `arousal`-CLAP-as** (uit de embedding, geen her-analyse; forced refresh voor bestaande rijen) + energie **percentiel-gekalibreerd** overal: validator/banden/activity-gates bibliotheek-relatief; sequencer-energieboog op arousal. |
| **Titel-monotonie**: 6+ playlists "Elektronische …" — elk station los benoemd. | **Batch-titelgeneratie**: hele set in één LLM-call met distinctie-eis; per-station validatie + corrigerende retry. |
| **Geen skip-signaal** (alleen expliciete duimen). | **Skip-leren**: track <25s → impliciete dislike (schema v35 `track_skips`); ≥3× → radio-down-sampling (met like-override), niet zichtbaar als thumbs-down. |
| **Platte fan-graph-bonus** (+0.06). | **Rang-gewogen** (1.0→0.4) + begrensde **transitieve** hop (cache-only). |
| **Sprong op de top-up-naad** van de eindeloze radio. | **Cross-batch sequencing**: nieuwe pool opent op de track sonisch dichtst bij de net-gespeelde. |
| **3/21 geselecteerde radio's nooit gebouwd** (niet-seed artiesten). | Geselecteerde artist-ids ge-union'd bij de auto-seeds. |
| **Spook-'Jaren 4010'** (corrupte jaartag). | `isPlausibleYear` (1900..volgend jaar). |

## Nog open (verdieping)

1. **CLAP-assen ijken tegen referentietracks.** De zero-shot-tekstprobes (incl.
   de nieuwe arousal-as) blijven heuristisch; percentiel-kalibratie maakt ze
   bibliotheek-relatief, maar een handvol handmatig gelabelde tracks per as zou
   de absolute drempels valideren.
2. **Mood-argmax-ruis**: de mood-buckets (bv. "Stevig") gebruiken CLAP-mood-
   argmax en kunnen sonisch gemengd zijn; arousal lost de energie-verwarring op
   maar niet de mood-toewijzing zelf.
3. **ListenBrainz similar-artists** als tweede co-listen-bron naast Deezer.
4. **Gemini voor titels**: de batch gebruikt de geconfigureerde provider
   (nu qwen3.5:9b-mlx lokaal); Gemini 2.5 Flash zou het Nederlands verder tillen —
   één instelling in Settings → LLM, geen code nodig.
