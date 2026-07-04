# muffon-audit — verbeterbacklog voor RoonSage

Bron: [staniel359/muffon](https://github.com/staniel359/muffon) — een multi-source music-streaming/discovery-client (Vue + Electron).
Deze audit vergelijkt muffon met de RoonSage native app en destilleert wat overneembaar is.

## Kader

muffon en RoonSage lossen verschillende problemen op. muffon = gratis multi-source *aggregator*
(Bandcamp/SoundCloud/YouTube Music…) met Last.fm-tags + Discogs/MB-metadata. RoonSage = **library-first**
curator op je eigen Roon-bibliotheek + Qobuz met een **CLAP-embedding + vectorindex** als sonische motor.

**Bewust NIET overgenomen** (strijdig met filosofie/scope):
- extra audiobronnen (YouTube/SoundCloud/Bandcamp/VK) — strijdig met library-first + hi-fi;
- video / YouTube-integratie;
- social-laag (volgen, feed, posts, DM's) — geen fit voor een persoonlijke curator;
- muffons Electron/Vue-stack — native Swift is architectonisch verder.

## Waar RoonSage al gelijk/vóór ligt

Radio (SonicRadio + AI-artiestenradio's > tag/top-radio) · Aanbevelingen (Discovery-engine met 9 producers) ·
Lyrics (LRCLIB synced in DB) · Scrobbling (LB + Last.fm gated) · Now Playing (ambient hero + visualizer) ·
Metadata (MB + Discogs + Deezer) · Favorieten + like/dislike-feedback die doorleert.

---

## Statusblok — verbeterprogramma (afvinkbaar)

Legenda: ⬜ open · 🔶 in uitvoering · ✅ geshipt · ⏸️ bewust uitgesteld

| # | Feature | Muffon-inspiratie | Impact | Status |
|---|---------|-------------------|--------|--------|
| A | **Navigeerbare graph** — elke track is een sprongpunt naar "sonisch vergelijkbaar"; elk resultaat wordt de volgende seed (recursief). Instap vanuit Now Playing, album-tracklist, track-Info, **Bibliotheek-rijen én Wachtrij** | muffons hyperlinked browsing (artist→albums/tracks/similar; tag→artists/albums) | ⭐ groot | ✅ v1.10.106 (+109 breder bereik) |
| B1 | **Multitag / multi-genre discovery** — stapel genres (AND/OR) + decennium, vind de kruising in je bibliotheek | multitag search (artists/albums) | midden | ✅ v1.10.106 |
| B2 | **Bookmarks / "Bewaar voor later"** — lichte listen-later-lijst over tracks/albums/artiesten, los van favorieten | bookmarks (multi-type) | midden | ✅ v1.10.105 |
| B3 | **Recent-hub** — browsable "recent gespeelde artiesten/albums/tracks" met her-ingang op bestaande `listening_history` | Listened (artists/albums/tracks) | klein | ✅ v1.10.105 |
| B4 | **Equalizer** voor lokaal afspelen | ingebouwde equalizer | midden | ⏸️ overslaan — lokaal = `AVPlayer` (geen `AVAudioEngine`), echte multiband-EQ vereist fragiele `MTAudioProcessingTap` op remote streams; Roon-zones hebben al top-DSP |
| B5 | **Discord Rich Presence** | Discord Rich Presence | klein/fun | ⏸️ overslaan — externe afhankelijkheid (eigen Discord-app/client_id), niet runtime-testbaar hier |
| C6 | **Achtergrond + transparantie personaliseren** — sfeer-intensiteitsslider (0–100%) + album-hoes-als-wallpaper toggle bovenop AmbientTheme | customizable background/transparency | klein | ✅ v1.10.106 |
| C7 | **Localisatie** — `String(localized:)` + string-catalogus | 13 talen | groot/laag nut | 🔶 v1.10.108 scaffolding + **v1.10.110 in-app taal-override** (Systeem/NL/EN, live via `\.locale` + `LS` leest override) — geconverteerd: nav + secties + iOS-tabs + Bewaard + Recent. Rest verhuist incrementeel via `LS()/LT()` |
| D8 | **In-de-charts-facet** — bron-filter op de Ontdek-feed (producer=charts) via toolbar-menu | top charts (artists/albums/tracks/tags per land) | midden | ✅ v1.10.107 |
| D9 | **Nieuwe-releases-facet** — bron-filter op de Ontdek-feed (producer=release-radar) via toolbar-menu | new/upcoming releases | midden | ✅ v1.10.107 |

## Aanbevolen volgorde

1. B2 + B3 + B1 — goedkope verticale slices op bestaande data/patronen (leren de stack, snelle winst).
2. C6 — kleine tevredenheids-feature op bestaand AmbientTheme.
3. A — de grote UX-sprong; zet de bestaande CLAP-motor overal aan.
4. D8 + D9 — surfaces bovenop bestaande Discovery-producers.
5. B4 + B5 — afgebakende extra's.
6. C7 — pas als bredere distributie speelt.
</content>
</invoke>
