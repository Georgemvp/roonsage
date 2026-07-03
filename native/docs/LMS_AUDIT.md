# LMS-audit — wat RoonSage kan lenen van epoupon/lms

> **Status 2026-07-03: sprint 1–3 volledig geïmplementeerd** (v1.10.95–97 /
> ios-v1.7.66–68 / analyzer-v1.1.79–81). Eén bewuste afwijking: §3.1
> (releasegroepen) is geleverd via LMS's *eigen no-MBID-fallbackheuristiek*
> (`AlbumGrouping` op de bestaande editie-normalisatie) in plaats van
> MB-enrichment — "Andere versies" + type-secties werken; een echte
> release-group-MBID-verrijking door de analyzer blijft open als verdieping
> (kan de `AlbumGrouping.classify`-heuristiek vervangen zonder UI-wijziging).
> LB-love-sync (§4.5) is eenrichtings-import (loves → likes); terugsyncen kan
> niet zonder per-track recording-MBIDs. Backlogitems (§3.2 artiestrollen,
> §2.4 Song-Path-interpolatie, §3.3 disc-secties, §3.4 scan-versioning,
> §5.2 per-apparaat-tokens, §5.4 OpenSubsonic) staan nog open.

> Gegenereerd: 2026-07-03. Methode: shallow clone van https://github.com/epoupon/lms,
> 4 parallelle code-verkenningen (scanner/metadata · aanbevelingsengine · web-UI/UX ·
> API/infra), bevindingen daarna afgezet tegen de eigen codebase (o.a. geverifieerd:
> `LocalPlayback.swift` past **geen** gain toe; `LibraryView` heeft **geen** sorteermodi;
> nergens artiestbiografie, disc/medium-model of album/artiest-favorieten).
>
> LMS = Lightweight Music Server: C++/Wt self-hosted streamer, ~15 jaar gerijpt,
> Subsonic/OpenSubsonic-compatibel, met een eigen embedding-gedreven
> aanbevelingsengine (MusicNN). Architectuur lijkt opvallend op de onze:
> één server-van-record + thin clients, embeddings server-side, SQLite/WAL.

---

## TL;DR — prioriteitenmatrix

| # | Idee | Domein | Impact | Moeite | Verdict |
|---|------|--------|--------|--------|---------|
| 1 | **Loudness-normalisatie bij lokaal afspelen** (LUFS ligt al in de DB!) | Playback | Hoog | Laag | **Quick win** |
| 2 | **Near-duplicate-embeddingfilter** (cos-afstand < 0.05) in radio/similar | Engine | Hoog | Laag | **Quick win** |
| 3 | **Sorteermodi in bibliotheek** (recent toegevoegd / meest / recent gespeeld / willekeurig) | UX | Hoog | Laag | **Quick win** |
| 4 | **Uniforme afspeelacties**: Speel · Volgende · Achteraan · Geschud, op élke entiteit | UX | Middel | Laag | **Quick win** |
| 5 | **Adaptieve afstandsdrempel** (μ+2σ van NN-afstanden) i.p.v. magic numbers | Engine | Middel | Laag | **Quick win** |
| 6 | **Favorieten (ster) voor albums/artiesten** + LB-love-sync | UX/Data | Hoog | Middel | **Doen** |
| 7 | **Artiestpagina 2.0**: bio, secties per releasetype, "verschijnt op", vergelijkbare artiesten | UX | Hoog | Middel | **Doen** |
| 8 | **Releasegroepen & -types in de bibliotheek** ("Andere versies", EP/Live/Compilatie) | Data | Middel | Middel | **Doen** |
| 9 | **Wachtrij opslaan als playlist** + radio-toggle in de wachtrij | UX | Middel | Laag | **Doen** |
| 10 | **Transcoding op het `/audio`-endpoint** (AAC-bitrate voor onderweg/cellular) | Infra | Hoog | Middel | **Doen** |
| 11 | **Login-throttling + timing-safe tokencheck** op 5766/5767 | Security | Middel | Laag | **Doen** |
| 12 | **Artiestrollen** (componist/dirigent/producer/remixer) uit file-tags | Data | Middel | Hoog | Overwegen |
| 13 | **Song Path via interpolatie** in embedding-ruimte (i.p.v. greedy walk) | Engine | Middel | Middel | Overwegen |
| 14 | **Chamfer/medoid-afstand** voor "vergelijkbare artiesten/albums in je bibliotheek" | Engine | Middel | Middel | Overwegen |
| 15 | **OpenSubsonic-API op de analyzer-server** → gratis client-ecosysteem | Strategisch | Zeer hoog | Zeer hoog | Strategische optie |
| 16 | Multi-user, podcasts, PAM/SSO, web-UI | — | — | — | **Skip** (past niet bij single-user native) |

---

## 1. Playback & audiokwaliteit

### 1.1 Loudness-normalisatie — de laagst hangende vrucht ⭐

LMS past ReplayGain **client-side** toe met een Web-Audio-GainNode:

```
gain = 10 ^ ((preAmp + replayGain) / 20)
```

met 4 modi (`None / Auto / Track / Release`), een pre-amp-slider (−15…+15 dB)
én een fallback-gain voor tracks zónder RG-info (belangrijk: anders knalt
ongenormaliseerd materiaal er tussenuit).

**RoonSage-situatie:** F3 heeft LUFS-meting geschipt (schema v28 + `LoudnessBackfill`),
maar `LocalPlayback.swift` doet er **niets** mee — geverifieerd, geen gain/volume-logica.
De data ligt klaar; alleen de toepassing ontbreekt.

**Voorstel:** in `LocalPlaybackController` per track `gain = 10^((doel − LUFS)/20)`
(doel ≈ −14 LUFS, instelbaar), toegepast via `AVPlayer.volume` of een
`MTAudioProcessingTap`/`AVAudioMix`. Neem LMS' fallback-gain over voor
niet-geanalyseerde tracks (bijv. −6 dB conservatief). Instellingen: modus
(uit/track/album) + pre-amp in Instellingen → Audio.

### 1.2 Transcoding voor `/audio`

LMS transcodeert on-the-fly (ffmpeg-childprocess): bitrate-onderhandeling per
client, **slimme no-op-detectie** (bron voldoet al → niet transcoderen; nooit
lossy→lossless "upgraden"), seek via `-ss`-offset i.p.v. HTTP-Range, en een
`estimateContentLength`-truc zodat clients kunnen seeken in een stream waarvan
de lengte nog niet bekend is.

**RoonSage-situatie:** D9 streamt het originele bestand (FLAC!) van de analyzer
naar de client. Op het LAN prima; over ZeroTier op cellular is dat zwaar en
duur.

**Voorstel:** `/audio?bitrate=256&format=aac` op de analyzer-server, via
`AVAssetReader` + `AVAssetWriter`/`AudioConverter` (geen ffmpeg nodig op macOS).
Client-kant: instelling "Transcodeer onderweg" (nooit/altijd/alleen-cellular —
iOS weet via `NWPathMonitor` of je op wifi zit). Neem de no-op-logica over.
Seek-offset-parameter meenemen (`?offset=<sec>`), net als LMS.

### 1.3 Wat we al beter doen
MediaSession-integratie (lock screen/CarPlay via `NowPlayingCenter`), gapless
op Roon-zones (Roon zelf), visualizer, karaoke-lyrics — LMS heeft hier niets
vergelijkbaars. Geen actie.

---

## 2. Aanbevelingsengine — verfijningen op een al sterk fundament

Onze CLAP-512-dim-stack is moderner dan LMS' MusicNN-200-dim, maar LMS heeft
tien jaar productie-slijpwerk in de **selectielaag** bovenop de embeddings, en
daar valt echt wat te halen.

### 2.1 Constraint-architectuur (hard/zacht) ⭐

LMS selecteert kandidaten greedy met een expliciet constraint-raamwerk:

- **Hard (verwerpen):** duplicaat-track; zelfde recording-MBID; afstand tot
  álle seeds > drempel; **near-duplicate-embedding: cos-afstand < 0.05 tot een
  al geselecteerde track** — vangt dezelfde opname op compilaties/remasters
  zónder metadata-match.
- **Zacht (straffen, gewogen):** interpolatie-fit 0.8 · vloeiende overgang 0.2 ·
  zelfde album 0.5 · zelfde artiest 0.5. Kandidaten worden 5× overbemonsterd,
  dan greedy de laagste strafscore.

**RoonSage-situatie:** wij hebben een per-artiest-cap in `sonicRerank` en een
disliked-filter ná de kNN, maar geen near-duplicate-filter en geen
zelfde-album-straf. Met 76.5k tracks (incl. compilaties + remasters) levert
Similar/Radio vrijwel zeker af en toe dezelfde opname twee keer.

**Voorstel:** voeg aan `VectorIndex.nearest`-consumers (RadioEngine, Similar,
Fingerprint-aanvulling) een near-duplicate-check toe (cos < ~0.05 tussen
geselecteerden onderling) + een zachte zelfde-album/artiest-straf i.p.v. alleen
een harde cap. Klein, puur, perfect testbaar.

### 2.2 Adaptieve drempels i.p.v. magic numbers

LMS kalibreert per bibliotheek: sample ~500 tracks, meet per sample de afstand
tot z'n dichtstbijzijnde buur, en zet de "similar genoeg"-drempel op
**μ + 2σ**. Geen handmatig getunde constante die op de ene bibliotheek te
streng en op de andere te los is.

**Voorstel:** één keer per feature-sync berekenen in `SonicLibraryCache`
(we hebben de vectors al in het geheugen), cachen naast de `VectorIndex`.
Gebruiken als kwaliteitsvloer in Radio ("niets aanbieden dat verder weg ligt
dan μ+2σ") en als "avontuurlijkheid"-schaal: de dial van Smart Radios kan
letterlijk in σ's uitgedrukt worden.

### 2.3 Medoid + Chamfer voor artiest/album-similariteit

LMS representeert een album/artiest niet als gemiddelde (centroid) maar als
**medoid** (bestaande track die de som van afstanden minimaliseert — geen
out-of-distribution-kunstvector), en vergelijkt sets van tracks met
**symmetrische Chamfer-afstand** (twee-staps: medoid-prefilter → Chamfer-rerank).

**Voorstel:** dit is de nette basis voor een "Vergelijkbare artiesten in je
bibliotheek"-sectie op de artiestpagina (zie §4.2) en "Vergelijkbare albums"
op de albumpagina — features die we nu niet hebben en die de bibliotheek veel
verkenbaarder maken. Alles wat ervoor nodig is (per-track-vectors, gegroepeerd
per artiest) zit al in `SonicLibraryCache`.

### 2.4 Song Path: interpolatie i.p.v. greedy walk

LMS bouwt een brug van A naar B door **lineair te interpoleren in de
embedding-ruimte** (t = 1/(n+1) … n/(n+1), elk punt L2-genormaliseerd), per
interpolatiepunt 32 buren te zoeken en dan greedy te kiezen met
smoothness-constraints. Onze Song Path is een cosine-walk richting het doel —
die kan blijven "hangen" in dichte clusters en het einde te abrupt naderen.

**Voorstel:** A/B'tje waard: interpolatie-variant naast de walk leggen (pure
functie op `VectorIndex`, goed testbaar), kijken welke mooiere bruggen geeft.

### 2.5 PCA-whitening (lage prioriteit)
LMS reduceert 200→60 dims mét whitening (schaal 1/√eigenwaarde) vóór cosine.
Whitening kan retrieval-kwaliteit verbeteren doordat dominante assen niet
alles overstemmen. Wij draaien brute-force op 512 dims met vDSP — snel genoeg
voor 54k vectors, dus alleen interessant als kwaliteitsexperiment, niet als
performancefix. (We hebben al een `PCAProjector` voor de Music Map — de
infrastructuur bestaat.)

---

## 3. Datamodel & metadata-verdieping

### 3.1 Releasegroepen & releasetypes

LMS slaat per release zowel `MBID` (deze uitgave) als `groupMBID`
(release group) op → "Andere versies" (remasters/heruitgaves) netjes
gegroepeerd, en artiestpagina's opgedeeld in **Albums / EPs / Singles /
Compilaties / Live** (MB primary+secondary types). Zonder MBID valt het terug
op een conservatieve heuristiek (zelfde naam + discs + compilatievlag + label
+ barcode; buurmappen alleen bij multi-disc).

**RoonSage-situatie:** release groups worden alleen in de Discovery-pipeline
(uitwaarts) gebruikt; de bibliotheek zelf kent het concept niet. De
MB-enrichment-machinerie (incl. responscache) bestaat al — de Ontdek-audit
loste precies dit soort dingen op met MB-lookups.

**Voorstel:** enrichment-uitbreiding: per album `release_group_mbid` +
`primary_type`/`secondary_types` ophalen (zit in dezelfde MB-release-group-
response die we al opvragen voor genres). Twee UI-winsten: (a) albumdetail
krijgt "Andere versies in je bibliotheek", (b) artiestdetail krijgt
type-secties i.p.v. één platte albumlijst. Vooral bij een 76.5k-bibliotheek
met veel heruitgaves maakt dit browsen aanzienlijk professioneler.

### 3.2 Artiestrollen (klassiek!)

LMS modelleert `TrackArtistLink` met **rol** (artist/componist/dirigent/
tekstdichter/mixer/producer/remixer/performer) + subtype, en bewaart naast de
artiest-referentie óók de rauwe tagwaarde + een `MBID-matched`-vlag (weet je
of de koppeling via MBID of naam kwam — goud voor reconciliatie, exact ons
matchKey-probleem).

**RoonSage-situatie:** Roon Browse geeft één artieststring; onze analyzer leest
file-tags maar extraheert geen rollen. Het klassieke-metadata-probleem
(E1/matchKey-divergentie) komt deels doordat we componist/uitvoerende niet
scheiden.

**Voorstel (groter, overwegen):** analyzer laat `TAG:composer`, `conductor`,
`albumartist` e.d. meelezen (AVFoundation metadata levert deze al aan) en
exporteert ze via `/features`. Winst: componist-browsing voor klassiek,
"verschijnt op als producer/remixer"-secties, en een betere matchKey voor
klassiek (match op componist+werk i.p.v. artiest+titel).

### 3.3 Disc/medium als entiteit
LMS maakt de disc een volwaardige entiteit (positie, subtitle, per-disc
artwork, zelfs per-disc ReplayGain). Voor boxsets/klassiek geeft dat veel
nettere albumpagina's ("CD 1 — Die Walküre, Akte 1"). Wij hebben geen
`disc_number` in het schema (geverifieerd). Kleine schema-uitbreiding +
sectie-headers in albumdetail; alleen zinvol als de tags/Roon het aanleveren —
eerst steekproef doen.

### 3.4 Scanner-patronen voor de analyzer
- **Scan-versioning:** elk record krijgt het versienummer van de laatste scan;
  na afloop is alles met een oud nummer per definitie verwijderd → orphan-
  detectie gratis, geen aparte diff-boekhouding. Elegant en direct toepasbaar
  op de analyzer-walk (detecteren wij verwijderde bestanden nu eigenlijk?).
- **`.lmsignore`** (gitignore-syntax per bibliotheekroot) — handig om
  bijv. een `Unsorted/`-map buiten de analyse te houden op de 4tbdrive.
- **Duplicaat-detectiestap** — rapporteer identieke tracks (zelfde audio,
  andere map) als onderhoudslijst in de analyzer-app.

---

## 4. UX-patronen

### 4.1 Sorteermodi overal ⭐

LMS biedt op elke browse-lijst dezelfde dropdown: **Alles · Willekeurig ·
Favorieten · Recent gespeeld · Meest gespeeld · Recent toegevoegd · Recent
gewijzigd** — en dat maakt een bibliotheek van tienduizenden items ineens
doorwaadbaar ("willekeurige metal-albums", "recent toegevoegde elektronica").

**RoonSage-situatie:** `LibraryView` heeft géén sorteermodi (geverifieerd).
Alle data is er nochtans: `date_added`, `listening_history` (incl. Last.fm-
backfill) → meest/recent gespeeld is een query, geen feature.

**Voorstel:** één `SortModeSelector`-component (menu in de toolbar) op
Bibliotheek-albums/artiesten/tracks. Willekeurig-met-vaste-seed per sessie
zodat scrollen stabiel blijft.

### 4.2 Artiestpagina 2.0

LMS' artiestpagina: rond portret · **biografie** (2 regels geklemd, tik om uit
te klappen) · secties per releasetype · **"Verschijnt op"** met rolfilter ·
**"Vergelijkbare artiesten"**-grid. Onze artiestweergave (`LibraryDetailViews`)
is een albumlijst; geen bio (geverifieerd: nergens biografie-code).

**Voorstel — samengesteld uit dingen die er al bijna zijn:**
- Bio: Last.fm `artist.getInfo` (client bestaat) of MB/Wikidata; cache in DB.
- Vergelijkbare artiesten: §2.3 (embeddings, in-bibliotheek) — géén extra
  netwerkbron nodig, dit onderscheidt ons juist van LMS' Last.fm-afhankelijkheid.
- Type-secties: §3.1.
- Meest gespeelde tracks van deze artiest: `listening_history`-query.

Dit is de pagina waar "mooier en professioneler" het meest zichtbaar wordt.

### 4.3 Uniforme afspeelacties
LMS geeft élke entiteit (track/album/artiest/playlist) hetzelfde
command-vocabulaire: **Play · Play Next · Play Last · Play Shuffled** (+ Star ·
Download · Info) via een split-button. Bij ons verschilt het aanbod per view
(soms alleen "Speel af", soms ook "In wachtrij"). Eén gedeeld
`PlayActionsMenu`-component (met dezelfde 4 werkwoorden, zowel voor Roon-zones
als lokaal afspelen) maakt de app voorspelbaarder — en is vooral refactorwerk,
geen nieuwe logica.

### 4.4 Wachtrij-UX
Uit LMS' playqueue het overnemen waard: **wachtrij opslaan als playlist**
(wij hebben playlists server-of-record — dit is een kleine POST), **radio-modus
als toggle ín de wachtrij** (onze Smart Radios bestaan al; de toggle "vul
automatisch bij met vergelijkbaars" hoort bij de wachtrij i.p.v. een apart
scherm), shuffle-in-place, en een totaalduur-regel ("23 tracks · 1u42m").

### 4.5 Favorieten voor albums & artiesten
LMS heeft ster-markering op artist/release/track, als sorteermodus én
browse-filter, met **bidirectionele ListenBrainz-love-sync**. Wij hebben alleen
track-duimpjes (`track_feedback`). Uitbreiden naar albums/artiesten
(server-of-record, zelfde patroon) + "Favorieten"-sorteermodus in §4.1 + LB-sync
(token is al geconfigureerd) — en de sterren meewegen in Discovery/Radio's
feedback-as (de 0.10-feedbackgewichtscomponent bestaat al in `DiscoveryScoring`).

### 4.6 Kleinere polish-ideeën
- **Info-modal per track/album**: codec, bitrate, sample rate, playcount,
  copyright — de analyzer wéét dit al; nergens getoond.
- **Volledig-scherm artwork** (tik op hoes in Now Playing → modal). Hebben we
  op macOS niet.
- **Regel-clamping** op kaarttitels (`lineLimit(2)` + `reservesSpace: true`)
  tegen layout-springen in grids.
- **Spatiebalk = play/pauze** op macOS (we hebben ⌘K, maar geen
  transport-shortcuts buiten menu's; LMS heeft Space/Ctrl+pijlen/seek-combo's).

---

## 5. Server & security

### 5.1 Login-throttling + timing-safe vergelijking
LMS: per client-IP na 5 foute pogingen 3 s straf (IPv6 per /64-blok), en het
hasht óók bij onbekende gebruikers (timing-attack-mitigatie). Onze
token-checks op 5766/5767 (ZeroTier, maar toch): voeg een simpele
per-IP-throttle toe aan `LibraryShareServer` en vergelijk tokens
constant-time. Paar regels, professioneel randje — en het device-approval-
verhaal van 2026-07-02 laat zien dat er al organisch verkeer met foute
credentials langskomt.

### 5.2 Per-apparaat-tokens met intrekking
LMS geeft per gebruiker een API-key die je kunt regenereren. Wij hebben één
gedeeld `ROONSAGE_SHARE_TOKEN` + device-approval. Volgende stap: per
goedgekeurd apparaat een eigen token (kolom bestaat bijna al in
`approved_devices`), intrekbaar per apparaat in de analyzer-UI. Lost meteen de
"stale token = #1 won't-connect-oorzaak" deels op: één apparaat resetten
i.p.v. alle.

### 5.3 DB-integriteitscheck bij start
LMS draait configureerbaar `PRAGMA integrity_check` bij opstarten. De legacy-
Python-stack had `repair_corrupt_indexes()`; native (GRDB) heeft zo'n vangnet
niet. Eén `PRAGMA quick_check` bij het openen van de pool + log-warning is
goedkoop; we hebben al eens een corruptie-recovery meegemaakt (2026-05-28).

### 5.4 Strategische optie: OpenSubsonic-API op de analyzer
De grootste (en duurste) gedachte uit deze audit: LMS ontleent enorm veel
waarde aan Subsonic-compatibiliteit — elke client (Symfonium, Tempo, Amperfy,
play:Sub, DSub…) werkt er direct mee. Onze analyzer-server heeft alles wat
daarvoor nodig is (bibliotheek, art, `/audio`-streaming, straks transcoding).
Een minimale OpenSubsonic-laag (ping, getArtists/getAlbum/getSong, search3,
stream, getCoverArt, scrobble, star) zou RoonSage-data ontsluiten voor een
heel ecosysteem aan volwassen apps — CarPlay, Android, offline-sync — zonder
dat wij die clients hoeven te bouwen. Zeer hoge moeite (50+ endpoints voor
volledige dekking, al is een bruikbare subset ~10), dus alleen als richting
noteren, niet plannen.

---

## 6. Bewust NIET overnemen

- **Multi-user/rollen/quota** — RoonSage is single-user by design.
- **Podcasts** — buiten scope; Roon zelf en dedicated apps doen dit beter.
- **Web-UI/Wt-patronen** (infinite-scroll-sentinel, Bootstrap-grids) — SwiftUI
  `List`/`LazyVGrid` doet dit native al; niets te halen.
- **PAM/SSO-backends** — geen reverse-proxy-scenario.
- **MusicNN i.p.v. CLAP** — onze embeddings zijn moderner én ondersteunen
  text-to-audio; LMS kan dat niet. De winst zit in hun *selectielaag* (§2),
  niet hun model.
- **Tag-based engine als tweede modus** — wij hebben al een rule-based
  fallback wanneer embeddings ontbreken; geen aparte engine nodig.

---

## Voorgestelde volgorde

**Sprint 1 — quick wins (elk ≤ 1 dag, direct voelbaar):**
1. Loudness-normalisatie in `LocalPlayback` (§1.1)
2. Near-duplicate-filter + zachte album/artiest-straf in de selectielaag (§2.1)
3. Sorteermodi in Bibliotheek (§4.1)
4. Wachtrij: opslaan-als-playlist + totaalduur (§4.4)
5. Throttle + constant-time tokencheck + `quick_check` (§5.1, §5.3)

**Sprint 2 — de zichtbare sprong ("mooier & professioneler"):**
6. Artiestpagina 2.0: bio + vergelijkbare artiesten (medoid/Chamfer) + meest gespeeld (§4.2, §2.3)
7. Favorieten voor albums/artiesten + LB-love-sync (§4.5)
8. Uniform `PlayActionsMenu` (§4.3)
9. Info-modal + volledig-scherm artwork (§4.6)

**Sprint 3 — data & onderweg:**
10. Releasegroepen/-types via MB-enrichment → "Andere versies" + type-secties (§3.1)
11. Transcoding op `/audio` voor cellular (§1.2)
12. Adaptieve drempels + avontuurlijkheid-in-σ's (§2.2)

**Backlog / onderzoek:** artiestrollen voor klassiek (§3.2), Song-Path-
interpolatie-A/B (§2.4), disc-secties (§3.3), scan-versioning in de analyzer
(§3.4), per-apparaat-tokens (§5.2), OpenSubsonic (§5.4).
