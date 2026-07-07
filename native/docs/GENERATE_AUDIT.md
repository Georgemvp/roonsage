# GENERATE_AUDIT — AI-playlistgeneratie erft de sonische radio-engine

Audit 2026-07-07. Kernbevinding: de Genereer-pijplijn (`RoonClient+Generate.swift`)
was de **enige** playlist-producent die de sonische engine niet gebruikte. De
LLM-curator zag alleen `titel — artiest (jaar)` en kon de muziek niet "horen";
de enige audio-input was één CLAP-tekstcosine-rerank (`sonicRerank`). Vlak
ernaast lag de Plexamp-klasse machinerie die AI-radio's, custom radio's en
Ontdek Wekelijks al voedt — het patroon `RadioEngine.rank → RadioSequencer.order`
(zie `Sonic/DiscoverWeekly.swift` als sjabloon).

## Kloof vóór deze audit (radio ✅ / generator ❌)

| Signaal / techniek | Radio | Generator (voor) |
|---|---|---|
| Multi-anchor relevantie (centroid + dichtstbijzijnde anker) | ✅ | ❌ |
| MMR-diversificatie + near-duplicate hard-drop (0.95) | ✅ | ❌ |
| Album/artiest soft-penalty | ✅ | alleen harde cap 2 |
| TasteVector-steering (recency-gewogen CLAP-centrum) | ✅ | ❌ (alleen artiestnamen in prompt) |
| Like/dislike/skip vector-push | ✅ | ❌ |
| Avontuurlijkheids-dial (novelty + MMR-λ + popularity-tilt) | ✅ | ❌ |
| Deezer fan-graph affiniteit | ✅ | ❌ |
| Popularity-steer (hits ↔ deep cuts) | ✅ | ❌ |
| Flow-sequencing (CLAP/BPM/Camelot/energie-arc) | ✅ | ❌ (LLM-pickvolgorde) |
| Mood/activity-gate met verzachting | ✅ | ❌ (alleen genre/tag-filter) |
| Gegronde titels (TitleGrounding claim-validatie) | ✅ | ❌ (vrije LLM-titel) |
| "Waarom deze track" (RadioEngine.Reason) | ✅ | ❌ |

## Maatregelen

- **QW1 Flow-sequencing** — eindresultaat door `RadioSequencer.order` met
  kiesbare arc (Gelijkmatig/Oplopend/Piek; default Piek zoals custom radio's).
- **QW2 Near-dup + spreiding** — engine-MMR levert album/artiest-penalties mee;
  de near-dup hard-drop (zelfde opname via remaster/compilatie) draait
  bovendien EXPLICIET via `SonicSelection.dropNearDuplicates`, omdat MMR wordt
  overgeslagen zodra de pool ≤ poolLimit is (de gangbare situatie bij een
  gerichte aanvraag) — anders zou een dubbel er dan doorheen glippen.
- **QW3 Taste in vectorruimte** — request-embedding als `queryAnchor` in
  `RadioEngine.rank`; TasteVector + like/dislike-push sturen de query zoals bij
  elke radio ("near de request, zoals jij het lekker vindt").
- **QW4 Sonische hints voor de curator** — de genummerde LLM-lijst krijgt per
  track dominante mood + bpm, zodat het model op klank cureert i.p.v. op
  naamherkenning.
- **QW5 Gegronde titel** — `describePlaylist` krijgt het gemeten sonische
  profiel (`sonicProfileSummary`) in de prompt en valideert de titel met
  `TitleGrounding.violations` + één corrigerende retry (patroon van
  `generateCustomAIMeta`); anders heuristische fallback zonder claims.
- **M1 Engine-selectie** — `buildCandidatePool` rangschikt de gefilterde pool
  via `RadioEngine.rank` over een sub-`VectorIndex` van de pool (i.p.v. kale
  cosine), met dial, taste, fan-graph-loze defaults en coverage-guard voor
  ongeanalyseerde tracks.
- **M2 Mood/activity-gates** — `analyzeForFilters` haalt naast genres ook
  moods (`knownMoodKeys`) en activiteiten (workout/onderweg/chillen/lounge/
  energiek/focus) uit het verzoek; toegepast als gemeten gate met verzachting
  (`gatedWithRelaxation`), library-gekalibreerd via `TitleGrounding.Calibration`.
- **U1 Sturing in de UI** — avontuurlijkheids-slider + arc-keuze in
  GenerateView (zelfde idioom als CustomRadioEditorView).
- **U4 Redenen** — `GenerationResult.reasonByTrackID` toont per track waarom
  hij erin zit (RadioEngine.Reason, NL).

- **U2 seed-tracks/artiesten** — GenerateView-facetpicker (hergebruikt
  `FacetMultiSelectView` uit CustomRadioEditor). Seeds → echte embedding-ankers
  in `RadioEngine.rank(seeds:)` (in de sub-index opgenomen), naast het
  tekst-anker. Ontsluit meteen **fan-graph** (`relatedArtistWeights` gemerged
  over de seed-artiesten) én de **σ-vloer** (`nnStats` → `Options.floor`), die
  beide echte track-ankers vereisen — daarom niet los te leveren.
- **U3 duur-doel** — `targetMinutes` cureert een ruime overschatting, ordent,
  en `trimToDuration` knipt op de gemeten `durationByMatchKey` tot de
  minuut-budget. UI-toggle Aantal/Duur (30/60/90/120).
- **M3 (veilige slice)** — `suggestedArc(for:)` leidt de energie-arc af uit de
  gemeten activity/mood-facetten (workout→piek, focus/chill→vloeiend,
  onderweg→oplopend); arc="Auto" in de UI. Deterministisch, geen extra LLM-call.

## Bewust niet gedaan
- **Volledig M3** (LLM ontwerpt structuur, engine kiest álles, LLM-picks weg):
  de LLM-picks vangen semantiek die embeddings missen ("liedjes over regen");
  engine-ranking → LLM-picks → deterministische assemblage → flow-sequencing
  ís de hybride. De veilige structurele slice (auto-arc) is wél gedaan.

## Status
- 2026-07-07: QW1–QW5, M1, M2, U1, U4 (batch 1: commits a5e1244 + c956ceb).
- 2026-07-07: U2 (+fan-graph +σ-vloer), U3, M3-auto-arc (batch 2).
- 2026-07-07: **Diagnostiek** — `GenerationTrace` legt elke fase vast (verzoek,
  seeds, geanalyseerde filters, poolgroottes per verbreding, gate/relax,
  klank-frase, σ-vloer, engine-in/uit + near-dup-drops, LLM-picks/retry,
  duur-trim, titel-grounding, eindlijst). Naar de log (`.llm`, deelbaar via
  Instellingen → Logboek) én in-app via een "Diagnostiek"-sectie onder het
  resultaat. Puur additief — verandert de output niet.
- 2026-07-07: U2-picker-UX — de seed-pickers pinnen nu een "Favorieten"-sectie
  (liked + vaak-gespeeld) bovenaan i.p.v. één alfabetische lijst van de hele
  bibliotheek; `.searchable` doorzoekt het geheel. `RadioFacetOptions` kreeg
  `featuredArtists`/`featuredTracks`; `FacetMultiSelectView` een `featured`-param.
- Open: alleen nog "volledig M3" (bewust; regressierisico).
