# Koel Player-audit — wat de RoonSage-mobiele-app ervan kan leren

> Gegenereerd: 2026-07-08. Bron: [koel/player](https://github.com/koel/player) (Flutter
> iOS/Android-client voor de Koel-muziekserver) — volledige `lib/`-boom doorgelicht —
> vergeleken met de native RoonSage-app (shell `native/iosapp` + gedeelde views in
> `native/RoonSage/Sources/RoonSageUI`).
>
> Architectuur-noot: Koel Player is exact dezelfde vorm als RoonSage-mobiel — een
> thin client die streamt van een eigen server. De vergelijking is dus 1-op-1 geldig.
> Kanttekening: laatste Koel Player-release is v1.1.0 (sept 2021); het is een
> gepolijste maar simpele app.

---

## 1. Oordeel in één alinea

RoonSage is functioneel véél rijker dan Koel Player (sonic engine, AI-generatie,
discovery-pipeline, karaoke-lyrics, Live Activity/widgets/Handoff, theming,
loudness/transcoding — Koel heeft dat allemaal niet). Maar Koel Player wint op
**vier mobiele fundamenten** die RoonSage mist: **offline downloads**,
**swipe-to-queue**, **globale zoek** en **frictieloze pairing (QR)**. Dat zijn
precies de dingen die een telefoon-app een telefoon-app maken: hij moet werken in
de trein, met één duim, zonder setup-gedoe.

## 2. Wat RoonSage al heeft en Koel niet (niet aan sleutelen)

Sonische radio's/adventure, AI-playlistgeneratie + templates, Ontdek-pipeline
(weekly/feed/insights), smaakprofiel + feedback-leren, karaoke-lyrics in DB,
BeatVisualizer, sleeptimer, opdrachtenpalet (⌘K), thema-presets + ambient-tint,
Live Activity/Dynamic Island, home-widget, Siri/Shortcuts, Handoff, Qobuz-sync,
loudness-normalisatie, onderweg-AAC-transcoding. Koel's "smart playlists" zijn een
zwakkere variant van onze RadioConfig-radio's; Koel's web-EQ/visualizer zitten
niet eens in hun mobiele app.

## 3. Gap-analyse — wat Koel Player wél heeft

Severity: 🔴 kernwaarde mobiel · 🟠 merkbaar beter · ⚪ polish. Effort: S (<1u) · M (uren) · L (dag+)

### K1 🔴 L — Offline downloads + offline-modus
**Koel:** per track/album/artiest een download-knop (`playable_cache_icon.dart`),
eigen "Downloaded"-scherm met sortering (`downloaded.dart`), bestanden op schijf
(`download_provider.dart`), en een `download_sync_provider.dart` die elke 5 min
(bij connectiviteit) de metadata van gedownloade tracks her-synct met de server.
Bij geen verbinding: `no_connection.dart` routeert naar de gedownloade bibliotheek.
**RoonSage:** niets. Lokaal afspelen streamt on-demand van `/audio`
(`LocalPlayback.swift:362`); onderweg vereist dat ZeroTier-aan + bereik. Cache is
alleen artwork (`ImageCache.swift`/`DiskImageCache.swift`).
**Voorstel:** hergebruik de bestaande `/audio`-endpoint + AAC-transcode-pad
(`LocalTranscode.swift`) om tracks naar Application Support te downloaden;
`LocalPlaybackController.makeItem` checkt eerst het lokale bestand; "Gedownload"-
sectie in Bibliotheek-Overzicht; download-verb in `PlayActionsMenu`; offline-gate
in `WelcomeGate` ("Geen server — speel je downloads"). Loudness-metadata mee-cachen.
Dit is de grootste losse hefboom voor de iPhone-app.

### K2 🔴 S/M — Swipe-to-queue + lokaal "speel hierna"
**Koel:** swipe-rechts op elke track/album/artiest-rij → achteraan in de wachtrij,
met groene achtergrond + "Queued"-overlay; de rij blijft staan
(`swipe_to_queue_dismissible.dart`, `confirmDismiss` → `false`).
**RoonSage:** queue-verbs alleen via contextMenu (`PlayActionsMenu.swift:29-33`),
en die zijn **Roon-zone-only** — de lokale engine heeft géén insert-next
(commentaar `PlayActionsMenu.swift:22-24`). `swipeActions` bestaan alleen in
Bookmarks/DiscoverFeed/CustomRadio.
**Voorstel:** (a) `.swipeActions` op track-rijen in LibraryView, FilteredTracksView,
album/artiest-detail en playlist-detail: leading = "Hierna" / "In wachtrij";
(b) `LocalPlaybackController.insertNext(_:)` zodat de verbs ook bij "dit apparaat"
werken. Grootste dagelijkse-UX-winst per uur werk.

### K3 🟠 M — Globale zoek (één zoekingang over alles)
**Koel:** één zoekscherm over songs + artiesten + albums (+ podcasts)
(`search.dart`, `search_provider.dart`).
**RoonSage:** zoeken is per-scherm (`.searchable` in `LibraryView.swift:142`;
sonisch zoeken en AskView apart). Op iPhone is er geen ⌘K-equivalent.
**Voorstel:** één zoekscherm (of pull-down op Bibliotheek-Overzicht) met
gesecteerde resultaten: tracks / albums / artiesten / playlists / radio's, plus
een "Sonisch zoeken →"-doorsteek. Het opdrachtenpalet levert de patronen al.

### K4 🟠 M — QR-pairing
**Koel:** QR-login (`qr_login_button.dart`) — scannen i.p.v. host+wachtwoord typen.
**RoonSage:** handmatig host + token; bekend supportleed: stale token = #1
"connect niet"-oorzaak, plus device-approval-wachtrij.
**Voorstel:** analyzer-app (Instellingen → Server) toont QR met
`{hosts:[LAN,ZT], token}`; iOS scant → vult in, health-checkt, dient
device-approval-verzoek in. Eén-scan-onboarding voor nieuwe apparaten.

### K5 🟠 M — Alfabet-snelscroll in lange lijsten
**Koel:** letter-index aan de rechterrand (`alphabet_scrollbar.dart`).
**RoonSage:** 76,5k tracks / duizenden artiesten, maar alleen endless scroll
(`LibraryView.swift:595+`). SwiftUI heeft geen native sectionIndex — custom
overlay (verticale letterkolom + drag) op Artiesten/Albums/Tracks bij sortering
op titel/artiest.

### K6 🟠 S/M — Playlist-mappen
**Koel:** playlist-folders + aanmaak-sheet (`playlist_folder.dart`,
`create_playlist_folder_sheet.dart`).
**RoonSage:** vlakke lijst met bron-badges (`PlaylistsView.swift:117`). Met
LB-mirrors, Last.fm, AI-radio's en bewaarde playlists wordt dat druk.
**Voorstel:** `folder`-veld op de server-of-record `/playlists` (schema-bump) of
lichter: client-side groepering op bron uitbreiden tot inklapbare secties.

### K7 ⚪ S — Marquee voor lange titels
**Koel:** `marquee_text.dart` scrollt lange titels in Now Playing.
**RoonSage:** truncatie. Kleine polish, direct zichtbaar in de hero + mini-bar.

### K8 ⚪ S — Sorteervoorkeur onthouden per scherm
**Koel:** bewaart sort-config per scherm (`AppState.set('downloaded.sort', …)`).
**RoonSage:** `SortField` in LibraryView reset per sessie → `@AppStorage`.

### K9 ⚪ S — Pull-to-refresh + skeletons overal
**Koel:** elk scherm heeft een placeholder-skeleton + pull-to-refresh
(`ui/placeholders/*`, `pull_to_refresh.dart`).
**RoonSage:** `SkeletonRows` bestaat maar wordt niet uniform gebruikt — dit is al
UX_AUDIT-bevinding-categorie "lege/laad/fout-states" (11 stuks); Koel bevestigt de
prioriteit.

### K10 ⚪ M — Gapless lokaal afspelen
Geen Koel-feature per se (hun audio_handler queuet wel vooruit), maar de
vergelijking legde het bloot: onze lokale engine is één `AVPlayer` die pas bij
`didPlayToEndTime` de volgende track laadt (`LocalPlayback.swift:99,112`) → hoorbaar
gat. `AVQueuePlayer` met pre-enqueue van het volgende item dicht dat gat.

### Bewust NIET overnemen
- **Podcasts** (`podcasts.dart` e.v.) — buiten de product-constitutie
  (library-first: Roon-bibliotheek + Qobuz).
- **Broadcast/internet-radio** (`radio_stations.dart`) — onze radio's zijn
  algoritmisch over de eigen bibliotheek; dat is het product.
- **Metadata-editing op mobiel** (`edit_album_sheet.dart` e.v.) — Roon is de
  metadata-bron; muteren vanaf de telefoon is een voetgeweer.
- **Frosted context-menu's** — native `contextMenu` is op iOS de juiste keuze.

## 4. Aanbevolen batches

| Batch | Inhoud | Effort | Waarom eerst |
|---|---|---|---|
| 1 | K2 swipe-to-queue + `insertNext` lokaal; K7 marquee; K8 sort-persist | S/M | dagelijkse-UX-winst, klein |
| 2 | K3 globale zoek + K5 alfabet-index | M | vindbaarheid bij 76,5k tracks |
| 3 | K4 QR-pairing | M | lost #1-supportklacht structureel op |
| 4 | K1 offline downloads + offline-modus | L | grootste feature-gat; bouwt op transcode-pad |
| Backlog | K6 playlist-mappen; K9 states-uniformering (→ UX_AUDIT); K10 gapless | S–M | |

## 5. Status

- [ ] Batch 1 — K2/K7/K8
- [ ] Batch 2 — K3/K5
- [ ] Batch 3 — K4
- [ ] Batch 4 — K1
- [ ] Backlog — K6/K9/K10
