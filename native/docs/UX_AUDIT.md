# RoonSage Native — UX-audit & verbeterplan

> Gegenereerd: 2026-06-22. Methode: multi-agent audit (17 units — 13 schermen +
> 4 cross-cutting sweeps), **elke bevinding adversarieel hertoetst tegen de echte
> code**. 78 bevindingen bevestigd (10 high · 43 medium · 25 low).
>
> **Dekkingsnoot:** door een sessielimiet werd de verificatiefase van 6 units
> afgekapt: **DJ Set / Live DJ**, de **macOS-shell** (menubar, update, logconsole)
> en de 4 losse cross-cutting sweeps (deze laatste vielen grotendeels samen met de
> per-scherm-bevindingen). Daar zitten dus vrijwel zeker nóg bevindingen die hier
> nog niet staan. Aanrader: die 6 units los nadraaien (de 11 voltooide units komen
> uit cache).

---

## 1. Samenvatting — het oordeel

De app is **functioneel rijk maar nog niet consequent professioneel afgewerkt**.
De fundering is goed: er ís een volwassen design-system (`Theme.swift` — spacing-,
radius-, typografie- en motion-tokens, `Card`, `Badge`, `Haptics`, semantische
kleuren) en een doordachte adaptieve navigatie. Het probleem zit niet in *ontwerp*
maar in **inconsistente toepassing** ervan en in een paar systematische gaten:

- **Toegankelijkheid is de grootste, meest zichtbare zwakte (17 bevindingen).**
  De scrubber, queue-rijen, bibliotheek-rijen, grid-cellen, widgets en de Music Map
  zijn voor VoiceOver-gebruikers deels of geheel onbruikbaar; meerdere tikdoelen zijn
  kleiner dan de Apple-minimum van 44pt. Dit is het soort detail dat een app
  meteen "onaf" laat voelen bij een App-Store-review.
- **Stille acties ondermijnen vertrouwen (13 feedback-bevindingen).** Een playlist
  afspelen, een track in de queue tikken, naar Qobuz opslaan — succes en falen zien
  er identiek uit. Knoppen die uitschakelen zonder uit te leggen waarom ("er is geen
  zone gekozen") laten de app kapot lijken terwijl hij dat niet is.
- **Lege/laad/fout-states zijn niet uniform (11 bevindingen).** Sommige schermen
  flitsen een "geen resultaten"-melding vóór het laden klaar is; lange AI/sonische
  operaties hebben geen foutpad en "doen gewoon niks" als ze falen; niet elk scherm
  gebruikt de bestaande `SkeletonRows`.
- **Het design-system wordt te vaak omzeild (11 consistentie-bevindingen).** Losse
  `Color`, magische spacing-getallen, hardcoded goud/zwart i.p.v. de accent-tint, en
  drie schermen die de gedeelde `GenerationStepper` niet gebruiken — samen geeft dat
  net die "elk scherm is door iemand anders gebouwd"-indruk.
- **Microcopy lekt techniek naar de gebruiker.** De Analyzer-tab is volledig Engels;
  `/text-embed`, `CLAP · PCA`, `MOO/1 · SOOD · GRDB 6`, "Draait `roonsage-analyzer
  serve`?" staan in zichtbare UI-tekst.
- **iOS is af op het oppervlak, maar enkele kernflows werken er niet.** De
  multi-select "Bewaar als playlist" in de bibliotheek is op iPhone/iPad onbereikbaar;
  vaste pixelbreedtes klippen bij grote Dynamic Type.

**Kortom:** geen herbouw nodig — een gerichte *polish-pass* + het afdwingen van het
al-bestaande design-system tilt dit van "krachtige hobby-app" naar "professioneel
product". De grootste hefboom is toegankelijkheid + feedback, want die raken elk
scherm en zijn grotendeels klein werk.

---

## 2. Thematische bevindingen

Severity: **🔴 high · 🟠 medium · ⚪ low** · Effort: **S** (<1u) · **M** (uur) · **L** (dag+)

### A. Toegankelijkheid — *grootste systemische gat (17)*

> Waarom het telt: dit is het verschil tussen "werkt voor mij" en "werkt voor
> iedereen". Het is ook het meest zichtbare professionaliteits-signaal — VoiceOver,
> Dynamic Type en 44pt-tikdoelen zijn harde Apple-richtlijnen.

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🔴 | `NowPlayingView.swift:451` | Scrubber is een hand-getekende `GeometryReader`+drag, dus VoiceOver kan de tijd *lezen* maar niet *spoelen* | `.accessibilityAdjustableAction { … seek ±5% }` + hint | M |
| 🔴 | `LibraryView.swift:426` (`LibraryTrackRow`) | Rij leest als 4–7 losse atomen ("LIVE", "1998", "8A"…) i.p.v. één track | `.accessibilityElement(children:.combine)` + samengestelde label; art `.accessibilityHidden` | S |
| 🔴 | `ZoneControlWidget`/`RoonSageWidgets` | Widget/Live-Activity-transportknoppen < 44pt tikdoel | Vergroot tikgebied / `.contentShape` | S |
| 🟠 | `DashboardView.swift:116` (`StatusCard`) | Statuskaarten lezen als "icoon + kaal getal", geen label | `.accessibilityElement(.combine)` + label | S |
| 🟠 | `AIComponents.swift:26` / `AskView.swift:76` | Prompt-/zoekvelden zonder VO-label/-hint | `.accessibilityLabel/Hint` | S |
| 🟠 | `AskView.swift:48` / `GenerateView.swift:403` | Inline actieknoppen in resultaatrijen < 44pt | Vergroot frame/`contentShape` | S |
| 🟠 | `ZoneControlWidget` (hele file) | Geen VO-labels op widget-/Live-Activity-controls of -tekst | Labels per control | S |
| 🟠 | `LibraryView.swift:476/498` (grid-cellen) | Album/artiest-cellen zonder a11y-label, wisselend tikgebied | Label + uniform `contentShape` | S |
| 🟠 | `NowPlayingView.swift:511` (volume-mute) | 28pt tikdoel | `.frame(minWidth:44,minHeight:44)` | S |
| 🟠 | `QueueView.swift:21` (rij) | Queue-rijen zonder VO-label, niet als actie aangekondigd | Label + `.isButton`-trait | S |
| 🟠 | `ConnectView.swift:159` / `SettingsView.swift:159` | Icoonknoppen, spinners, statusbanner zonder VO-label | Labels toevoegen | S |
| 🟠 | `MusicMapView.swift:58` | Canvas-kaart volledig onzichtbaar voor VoiceOver | Tracks als a11y-elementen óf samenvattende beschrijving | M |
| 🟠 | `DiscoveryView.swift:216` (stat-cards) | Vaste 3-koloms HStack overstroomt bij grote Dynamic Type | `ViewThatFits`/grid die wrapt | S |
| ⚪ | `RootView.swift:240` | Sidebar-rijen zonder a11y-hint; chevron untokenized opacity | Hints + token | M |
| ⚪ | `SonicFingerprintView.swift:263` | Radar-label onbereikbaar (ouder is óók a11y-element met andere label) | Combineren of label opheffen | S |
| ⚪ | `TasteProfileView.swift:202` / `YearInReviewView.swift:107` | Proportionele balken puur visueel, magnitude niet voorgelezen | `.accessibilityValue("\(pct)%")` | S |

### B. Stille acties & feedback (13)

> Waarom het telt: een professionele app *bevestigt* elke betekenisvolle actie en
> *legt uit* waarom iets niet kan. Stille successen/fouten voelen als bugs.

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🔴 | `PlaylistsView.swift:153` | Playlist afspelen geeft nul feedback — succes én falen zijn onzichtbaar | Toast/Haptic + foutpad | S |
| 🔴 | `SonicRadioView.swift:200` (+ MusicMap/SonicSearch/SongPaths/Alchemy) | Play-knoppen schakelen stil uit zonder zone; elders wél een hint | Uniforme "kies een zone"-hint i.p.v. verborgen/disabled | M |
| 🟠 | `DiscoveryView.swift` (5× `.disabled`) | Hele Discovery dood zonder zone, geen picker, geen hint | Zone-picker of inline hint | M |
| 🟠 | `GenerateView.swift:399` | Reorder hangt aan verborgen drag-handles op iOS | Zichtbare handle/`EditMode`-cue (zoals DJSetView) | S |
| 🟠 | `AskView.swift:19` | Geen naamveld — opgeslagen playlist heet altijd "Vraag: …" | Naamveld vóór opslaan | S |
| 🟠 | `AIComponents.swift:221` (`GenerationStepper`) | 4 even-trage stappen zonder voortgang *binnen* een stap | Indeterminate→bepaalde sub-progress of tijdsindicatie | M |
| 🟠 | `GenerateView.swift:313/359` | Qobuz-status is enige bevestiging; geen optimistische afloop | Optimistische status + duidelijke succes/fout | M |
| 🟠 | `ZoneControlWidget`/`NowPlayingIntents.swift:20` | Widget-transporttik geeft geen optimistische feedback; trage ZeroTier-reconnect leest als dode knop | Direct state-flip + timeline-reload | M |
| 🟠 | `QueueView.swift:58` | Queue-tik faalt stil (`try?` slikt de fout) | Toast + pressed-state | S |
| 🟠 | `NowPlayingView.swift:478` | Play/pause + queue lopen een poll-cyclus achter | Optimistische state-update | M |
| 🟠 | `SettingsView.swift:139` | Servertoken slaat op bij élke toetsaanslag, geen bevestiging/validatie | Opslaan op commit + "opgeslagen ✓"/validatie | M |
| 🟠 | `PlaylistsView.swift:127/76` | Qobuz-banner: succes en fout in dezelfde neutrale grijstint | Semantische kleur (`roonSuccess`/`roonDanger`) | M |
| ⚪ | `YearInReviewView.swift:16` | Picker: jaren zónder data niet te onderscheiden van jaren mét | Disable/markeer lege jaren | M |

### C. Lege / laad / fout-states (11)

> Waarom het telt: de eerste 300 ms van elk scherm en het pad ná een fout bepalen
> of de app "snel en stabiel" of "knipperig en broos" voelt.

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🔴 | `AnalyzerModel.swift:155/177` + `DashboardView.swift:62` | Serve/analyse-fouten onzichtbaar op Dashboard; alleen rauwe dev-strings | Zichtbare fout-state + nette copy | M |
| 🔴 | `SongPathsView`/`SongAlchemyView`/`SonicSearchView` | Lange operaties (bridge/mix/zoek/pad) hebben geen fout-state — falen = "doet niks" | `error`-tak + retry | M |
| 🟠 | `LibraryView.swift:192` (album/artiest-grids) | "Geen albums/artiesten" flitst bij elke zoek-/tabwissel | Laad-vlag vóór empty-state tonen | S |
| 🟠 | `LibraryView.swift:356` | Laadfout niet te onderscheiden van lege bibliotheek | Aparte fout-state + retry | M |
| 🟠 | `ZoneControlWidget:68` | Widget-empty zegt "open de app" maar tikken doet niks | `widgetURL(...)` deeplink | M |
| 🟠 | `PlaylistsView.swift:19` | Empty-state flitst bij elke open (rendert vóór async load) | Laad-vlag | S |
| 🟠 | `YearInReviewView.swift:200` | Toont vorig jaar onder nieuwe jaartitel bij transient fout | Clear bij wissel + fout-state | S |
| 🟠 | `TasteProfileView.swift:40` | Kale blanco i.p.v. de `SkeletonRows` die elk ander lijstscherm gebruikt | Skeleton-tak | S |
| ⚪ | `SonicRadioView.swift:46` | Kale centrale `ProgressView` i.p.v. standaard `SkeletonRows` | Skeleton | S |
| ⚪ | `RecommendView.swift:59` | Terugkerende gebruiker krijgt blanco resultaatgebied | Idle-guidance/hint | S |
| 🟠 | `PlaylistsView.swift:21` | Empty-state is doodlopend — zegt wat te doen maar biedt geen knop | Actieknop (→ Genereer/Templates) | M |

### D. Design-system-consistentie (11)

> Waarom het telt: `Theme.swift` definieert al `Spacing`, `Radius`, `Typography`,
> `Card`, `Badge` en semantische kleuren. Elke plek die ze omzeilt creëert drift en
> "verschillende handen"-gevoel. Dit is grotendeels mechanisch op te lossen.

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🔴 | `RecommendView.swift:114` | Negeert de gedeelde `GenerationStepper`; rauwe `Text(phase)` — Recommend oogt minder af dan Generate | Hergebruik `GenerationStepper` | M |
| 🟠 | `DashboardView.swift:122` (`StatusCard`) | Herontwerpt het kaart-oppervlak, negeert semantische statuskleuren | `Card`/`cardStyle()` + `roon*`-tokens | S |
| ⚪ | `NowPlayingView.swift:420` | Hardcoded `Color.white.opacity`, hoogtes, `size:56`, 28pt | Tokens | S |
| ⚪ | `LibraryView.swift:318` (`tagChips`) | Hand-getekende pill negeert `Badge`/WCAG-veilige accent | `Badge` | M |
| ⚪ | `LibraryView.swift` (rijen/cellen) | Magische spacing/radius (10,6,5,75…) omzeilen tokens | `Spacing`/`Radius` | S |
| ⚪ | `ConnectView.swift:39` | Hardcoded spacing/radius op het connect-scherm | Tokens | S |
| ⚪ | `PlaylistsView.swift:90` | Hardcoded spacing/frames | Tokens | S |
| ⚪ | `DiscoveryView.swift:346` (`StatCard`) | Rauwe spacing-getallen | `Spacing` | S |
| ⚪ | `DiscoveryView.swift:91` | Hardcoded zwart-opacity-schaduwen i.p.v. adaptief token | Schaduw-token | M |
| ⚪ | `GenerateView.swift:467` (template-pills) | Hardcoded goud+zwart, negeert gekozen accent | `.tint`/accent | S |
| ⚪ | `SonicFingerprintView.swift:246/76` | Eenmalige amber-kleur i.p.v. token (radar) | Token | S |
| ⚪ | `ZoneControlWidget:160` (accessory) | Negeert goud-accent, monochroom | Accent | S |

### E. Navigatie & informatie-architectuur (4)

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🟠 | `RootView.swift:330` | iOS-tab-binding propt 14 features in 2 tabs en verliest je plek bij terugkeren | Eigen `NavigationPath` per hub | L |
| 🟠 | `RootView.swift:194` | "Ontdek" propt 9 sonic-tools met onduidelijk doel in één groep | Subgroepen/omschrijvingen | S |
| 🟠 | `MusicMapView.swift:176` | Kleurt elk punt op Camelot-key maar toont nooit een legenda | Legenda/sleutel-uitleg | M |
| ⚪ | `PlaylistsView.swift` | 63 templates + generate-flow onzichtbaar vanaf het Playlists-scherm dat ze voedt | Entry-point/CTA naar Templates | M |

### F. Microcopy & taal (6)

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🔴 | `AnalyzerView.swift` (hele view) | Analyzer-tab volledig Engels terwijl de rest Nederlands is | Vertalen | M |
| 🟠 | `RoonClient.swift:36` | First-run-fouten tonen rauwe technische strings met "Fout:"-prefix | Vriendelijke, herstelgerichte copy | M |
| 🟠 | `SonicSearchView.swift:37` / `SonicRadioView.swift:301` / `MusicMapView.swift:44` | Dev-jargon (`/text-embed`, `CLAP · PCA`) in lege/fout-copy | Gebruikerstaal | S |
| ⚪ | `SettingsView.swift:410/528/179` | `MOO/1 · SOOD · GRDB 6`, "Draait `roonsage-analyzer serve`?" in zichtbare copy | Opschonen/verbergen | S |
| ⚪ | `SettingsView.swift:144` | Token-uitleg verwijst naar sectie "Bibliotheek" die de lezer niet ziet | Correcte verwijzing | S |
| ⚪ | `RecommendView.swift:192` | "Onbekend" lekt als artiest-fallback | Schonere fallback | S |

### G. Cross-platform / iOS (7)

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🔴 | `LibraryView.swift:180` | Multi-select "Bewaar als playlist" onbereikbaar op iOS (`List(selection:)` vereist Edit-mode) | `EditButton`/`editMode` of tap-to-toggle | M |
| 🟠 | `RoonSageWidgets.swift:124` | Hardcoded witte tekst in Live Activity onleesbaar op licht/getint lockscreen | Adaptieve kleur | S |
| 🟠 | `NowPlayingView.swift:330` (`featureRow`) | Knoprij kan clippen op smalle iPhone | `ViewThatFits`/wrap | M |
| 🟠 | `ConnectView.swift:174` | Handmatig IP-formulier met vaste pixelbreedtes klipt op iOS / grote Dynamic Type | Flexibele layout | S |
| ⚪ | `LibraryView.swift:110` | Geen pull-to-refresh; sync verstopt in toolbar-icoon | `.refreshable` | S |
| ⚪ | `RootView.swift:470` | macOS-toolbar transport/zone zonder `.help()`-tooltips | Tooltips | S |
| 🟠 | `MusicMapView.swift:82` | Selectiekaart vast-gepositioneerd, kan het aangetikte punt bedekken | Dynamische positie | M |

### H. Waargenomen performance (4)

| Sev | Scherm / bestand | Probleem | Fix | Eff |
|-----|------------------|----------|-----|-----|
| 🟠 | `DiscoveryView.swift:329` | Laadt in twee zichtbare fasen — hero/shelves poppen ná stat-cards/charts | Eén render-gate of skeleton | S |
| 🟠 | `MusicMapView.swift:159/51` | Herberekent `Bounds(tracks)` bij elke render én elke tik (O(n) in body/gesture) | Memoize bounds | S |
| 🟠 | `SonicFingerprintView.swift:155/251` | Niet-lazy `ForEach` in kaart; radar her-rendert elke frame via `TimelineView(.animation)` | `LazyVStack` + radar alleen animeren waar nodig | M |

---

## 3. Top 10 verbeteringen (geprioriteerd)

1. 🔴 **Scrubber VoiceOver-spoelbaar** maken — `NowPlayingView.swift:451` (M).
2. 🔴 **Bibliotheek-rijen als één a11y-element** met samengestelde label — `LibraryView.swift:426` (S).
3. 🔴 **iOS "Bewaar als playlist" bereikbaar** maken (EditMode/tap-toggle) — `LibraryView.swift:180` (M).
4. 🔴 **Stille acties van feedback voorzien** — playlist-play, queue-tik, Qobuz-save: toast + `Haptics` + semantische kleur (`PlaylistsView`, `QueueView`, `GenerateView`) (S–M).
5. 🔴 **"Kies een zone"-hint** i.p.v. stil-disabled/verborgen play-knoppen, overal uniform (`SonicRadioView`, `DiscoveryView`, Music Map, Sonic-tools) (M).
6. 🔴 **Fout-states voor lange operaties** (Analyzer serve/analyse, bridge/mix/zoek/pad) — zichtbaar + retry (M).
7. 🔴 **Analyzer-tab vertalen** naar Nederlands — `AnalyzerView.swift` (M).
8. 🔴 **Widget/Live-Activity-tikdoelen ≥ 44pt** + VoiceOver-labels + adaptieve tekstkleur (S).
9. 🟠 **Uniforme empty/loading-states**: laad-vlag vóór empty-state (geen flits) + overal `SkeletonRows` (Library-grids, Playlists, Taste, Sonic Radio) (S).
10. 🟠 **Recommend op de gedeelde `GenerationStepper`** zodat de 3 AI-schermen één familie zijn — `RecommendView.swift:114` (M).

## 4. Quick wins (< 1 uur elk, hoge impact)

Allemaal effort **S** met direct zichtbaar resultaat:

- Bibliotheek-rij `.accessibilityElement(.combine)` (#6)
- Volume-mute + inline resultaatknoppen naar 44pt (#33, #20)
- Queue-rijen + grid-cellen + prompt/zoekvelden VoiceOver-labels (#34, #27, #19)
- Laad-vlag vóór empty-state in Library-grids & Playlists (geen flits) (#26, #42)
- Taste-profiel & Sonic Radio → bestaande `SkeletonRows` (#53, #74)
- Qobuz-/playlist-banners → `roonSuccess`/`roonDanger` i.p.v. grijs (#44)
- Dev-jargon uit lege/fout-copy (`/text-embed`, `CLAP · PCA`, `MOO/1 · SOOD`) (#47, #69)
- `.refreshable` pull-to-refresh op de bibliotheek (#64)
- macOS-toolbar `.help()`-tooltips (#65)
- Hardcoded spacing/kleuren → tokens in Now Playing, Connect, Playlists, StatCard (#67, #68, #71, #55)

## 5. Voorgesteld foundation-werk

Eén investering die hele klassen bovenstaande issues voorkomt:

1. **A11y-conventies afdwingen.** Voeg aan `Theme.swift`/`Compat.swift` helpers toe:
   een `.tappable44()`-modifier (zet `contentShape` + min 44pt), en een lint/grep-check
   in CI die icon-only `Button`/`Image` zónder `.accessibilityLabel` flagt. Dekt het
   leeuwendeel van de 17 a11y-bevindingen structureel af.
2. **Eén `AsyncStateView<T>`-wrapper** (loading → `SkeletonRows` · empty →
   `ContentUnavailableView` + CTA · error → bericht + retry · content). Vervang de
   ad-hoc `if let stats`/`ProgressView`-takken. Lost de hele C-categorie + de
   empty-state-flits in één patroon op.
3. **Schaduw- + on-art-kleur-tokens** toevoegen (`Color.roonShadow`, adaptieve
   on-artwork-tekst) zodat hardcoded `black.opacity`/`.white` verdwijnen — fixt de
   Live-Activity-leesbaarheid en de drift in schaduwen.
4. **`ZonePicker`/`ZoneGate`-component**: één plek die óf de actie toelaat óf een
   "kies een zone"-hint toont. Vervangt alle losse `.disabled(selectedZone == nil)`.
5. **Microcopy-pass + Engels-leak-grep**: scan op user-facing string-literals met
   technische termen; Analyzer-tab volledig vertalen.

> Met deze 5 bouwstenen worden ~45 van de 78 bevindingen *systematisch* opgelost
> i.p.v. één voor één.

## 6. Uitvoerplan in fasen

**Fase 1 — Polish-pass (1–2 dagen, vooral S-effort).** Quick wins uit §4 + Top-10
#1–#8. Direct zichtbaar professioneler: feedback op elke actie, 44pt-tikdoelen,
VoiceOver-labels, geen empty-state-flitsen, jargon uit copy. Geen architectuur.

**Fase 2 — Foundation (2–3 dagen).** De 5 bouwstenen uit §5: `AsyncStateView`,
`.tappable44()` + CI-a11y-check, `ZoneGate`, schaduw/on-art-tokens, microcopy-pass.
Migreer de bestaande schermen erop. Voorkomt regressie van Fase 1.

**Fase 3 — Power-feature-helderheid (2–4 dagen).** Maak de geavanceerde tools
begrijpelijk: Music-Map-legenda + dynamische selectiekaart + memoized bounds,
Recommend op `GenerationStepper`, iOS-hub `NavigationPath` (plek onthouden),
"Ontdek"-subgroepering, Templates-entrypoint vanuit Playlists, GenerationStepper
sub-progress.

---

### Nog te verifiëren (sessielimiet kapte verify af)

Deze units kregen audit-bevindingen maar geen voltooide adversariële verificatie —
hier zitten vrijwel zeker extra bevindingen: **DJ Set / Live DJ**, **macOS-shell**
(menubar-transport, update-flow, logconsole — incl. signaal dat de logconsole
dev-begrippen aan gebruikers toont), en de losse cross-cutting sweeps. Aanrader: die
6 los nadraaien zodra de limiet reset; de 11 voltooide units komen uit cache.
