# RoonSage

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)

AI-powered playlist curation and album recommendations for Roon — using music you own, music on Qobuz, or both.

![RoonSage playlist view](docs/images/screenshot-playlist.png)

RoonSage is a self-hosted web app that connects to your Roon Core as an Extension. It syncs your library to a local SQLite cache and exposes a full MCP server so Claude Desktop can search your library, curate playlists, recommend albums, and control every aspect of Roon playback — all through natural conversation.

---

## Claude Desktop Integration

This is the primary way to use RoonSage. A full MCP server gives Claude Desktop **26 tools** to interact with your library and Roon — and Claude does all the curation work itself, using its own musical judgment. No separate API key, no per-token costs — just your existing Claude Pro subscription.

```
"Maak een playlist voor een late vrijdagavond, iets melancholisch maar niet depressief."
"Meer zoals wat er nu speelt, maar wat energieker."
"Zoek een jazzalbum dat ik nog niet ken en speel het af."
"Geef me alles van Nick Cave dat ik bezit."
"Zet shuffle aan en volume op 40%."
"Groepeer woonkamer en keuken."
```

### Hoe Claude curates

Claude handelt **alle** playlist-, seed- en aanbevelingsflows zelf af. De backend levert data en Roon-connectiviteit; Claude doet het denkwerk.

**Drie flows:**

| Flow | Wat de gebruiker zegt | Hoe Claude het aanpakt |
|------|-----------------------|------------------------|
| **Prompt-playlist** | "Maak een playlist van mellow 90s electronic" | `get_library_stats` → `filter_tracks(compact)` → curate zelf → `curate_and_play` |
| **Seed-playlist** | "Meer zoals Portishead – Glory Box" | `search_library` → analyse → `filter_tracks(compact)` → curate → `curate_and_play` |
| **Albumaanbeveling** | "Aanbeveel me een album voor zondagochtend" | `filter_tracks` of `get_artist_albums` → kies album → editorial pitch → `play_album` |

**Drie bronmodi — Claude detecteert of vraagt:**

| Bron | Wanneer | Aanpak |
|------|---------|--------|
| **Bibliotheek** | "uit mijn collectie", "wat ik heb" | `filter_tracks(compact)` → curate → `curate_and_play` |
| **Hybrid** | "mix van eigen + nieuw", "aangevuld met ontdekkingen" | `filter_tracks(compact)` + `search_qobuz` → meng → `play_tracks` |
| **Qobuz** | "iets nieuws", "verrass me", "ken ik nog niet" | meerdere `search_qobuz` calls → curate → `play_tracks` |

Bij twijfel vraagt Claude welke bron je wilt.

### Setup

De MCP server draait lokaal op je Mac/PC — niet in Docker. RoonSage zelf (Docker of bare metal) moet al draaien voordat Claude Desktop er verbinding mee maakt.

```bash
# 1. Installeer de MCP dependency (eenmalig per machine)
pip3 install "mcp[cli]"

# 2. Configureer Claude Desktop automatisch
python3 scripts/install_mcp.py

# 3. Herstart Claude Desktop
```

Als RoonSage op een ander adres draait, stel dan `ROONSAGE_URL` in vóór het starten van Claude Desktop (standaard: `http://localhost:5765`).

**Handmatige configuratie** — voeg toe aan `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) of `~/.config/claude/claude_desktop_config.json` (Linux):

```json
{
  "mcpServers": {
    "roonsage": {
      "command": "python",
      "args": ["/volledig/pad/naar/roonsage/mcp_server.py"]
    }
  }
}
```

### Welk Claude-model kiezen?

| Model | Geschikt voor |
|-------|--------------|
| **Claude Sonnet 4.6** | Dagelijks gebruik — snel, nauwkeurig |
| **Claude Opus 4.6** | Abstracte prompts, deep discovery, multi-turn verfijning |
| **Claude Haiku 4.5** | Snelle, eenvoudige verzoeken |

Begin met Sonnet. Schakel over naar Opus voor prompts als "iets dat aanvoelt als rijden in de regen 's nachts."

### Beschikbare tools (26)

**Library**

| Tool | Wat het doet |
|------|-------------|
| `get_library_stats` | Genre-, decade- en totaaloverzicht uit de cache |
| `get_library_status` | Cache-versheid; `needs_resync` vlag |
| `search_library` | Zoek op track-, artiest- of albumnaam |
| `search_qobuz` | Zoek in de Qobuz-catalogus via Roon; resultaten zijn direct afspeelbaar |
| `filter_tracks` | Filter op genre, decade, live-uitsluiting. `output_format="compact"` geeft een genummerde lijst + `session_id`. `"ultra"` geeft alleen artiest — titel per regel. `"json"` geeft volledige metadata. Ondersteunt `artist_limit` en `exclude_keywords`. |
| `get_artist_albums` | Alle albums van een artiest uit de SQLite cache |
| `sync_library` | Start een achtergrond-library sync vanuit Roon |

**Playlist curatie & generatie**

| Tool | Wat het doet |
|------|-------------|
| `curate_and_play` | Speelt een selectie af die Claude koos uit `filter_tracks` compact output — vertaalt tracknummers via `session_id` naar Roon item_keys en start afspelen |
| `validate_playlist` | Controleer een track-selectie op duplicaten, clustering en overrepresentatie vóór afspelen |
| `generate_playlist` | Natuurlijke taal → playlist via de backend pipeline (library/hybrid/qobuz). Fallback wanneer de context te groot is of op expliciet verzoek. |
| `seed_track_playlist` | "Meer zoals dit" — playlist op basis van een seed-track via backend pipeline (fallback) |
| `analyze_prompt` | Preview hoe een prompt vertaald wordt naar genre/decade-filters |
| `recommend_album` | Snelle AI-albumaanbeveling (library of discovery mode) — fallback |
| `recommend_album_interactive` | 2-staps Q&A voor gepersonaliseerde picks — fallback |

**Afspelen**

| Tool | Wat het doet |
|------|-------------|
| `play_album` | Zoek en speel een album in één stap |
| `play_radio` | Speel een internetradiostation op naam |
| `browse_playlists` | Toon of speel alle Roon-afspeellijsten |
| `list_zones` | Lijst van actieve Roon-zones |
| `get_now_playing` | Huidige afspeelstatus per zone |
| `play_tracks` | Stuur tracks naar een zone (vervangt wachtrij) |
| `queue_tracks` | Voeg tracks toe aan de wachtrij |

**Transport & zone-beheer**

| Tool | Wat het doet |
|------|-------------|
| `transport_control` | Play, pause, stop, volgende, vorige, shuffle, repeat, seek |
| `volume_control` | Volume instellen, aanpassen, dempen of opvragen per zone |
| `transfer_zone` | Verplaats afspelen van de ene naar de andere zone |
| `zone_grouping` | Zones groeperen of loskoppelen voor gesynchroniseerd afspelen |
| `get_result_history` | Eerder gegenereerde playlists en aanbevelingen |

---

## Quick Start

```bash
docker run -d \
  --name roonsage \
  -p 5765:5765 \
  -v roonsage-data:/app/data \
  --restart unless-stopped \
  -e ROON_HOST=192.168.1.x \
  -e GEMINI_API_KEY=your-key \
  ghcr.io/Georgemvp/roonsage:latest
```

Open **http://localhost:5765** — een setup-wizard begeleidt je bij het verbinden met Roon, het kiezen van een AI-provider en het synchroniseren van je bibliotheek.

**Autoriseer in Roon:** Settings → Extensions → vind **RoonSage** → Enable.

> **Gratis optie:** Google Gemini heeft een gratis API-tier die voldoet voor persoonlijk gebruik. Geen creditcard nodig. Zie [`docs/gemini-free-credit-guide.md`](docs/gemini-free-credit-guide.md).

---

## Web UI

De web-interface werkt zonder Claude Desktop en biedt dezelfde playlist- en aanbevelingsfuncties via een standaard browserformulier.

![Home screen](docs/images/screenshot-home.png)

**Playlist van prompt** — beschrijf een sfeer in natuurlijke taal. RoonSage analyseert je prompt, vertaalt het naar genre/decade-filters, stuurt de gefilterde tracks naar de LLM en geeft een afspeelbare playlist terug. Werkt met bibliotheken van 50.000+ tracks.

**Playlist van seed** — kies een nummer, selecteer muzikale dimensies (sfeer, tijdperk, instrumentatie, productiestijl) en krijg een playlist die die kwaliteiten verkent.

**Verfijnen & itereren** — gebruik de Refine-knop op elk resultaat om bij te sturen zonder opnieuw te beginnen. "Donkerder", "meer jaren 80", "minder jazz" — de LLM ziet de originele prompt plus je notities.

**Albumaanbevelingen** — beschrijf een moment of stemming, beantwoord twee snelle vragen en krijg één albumaanbeveling met een editorial pitch. Library mode beveelt albums aan die je bezit; Discovery mode vindt albums die je nog niet hebt (gezocht op Qobuz).

**Qobuz-integratie** — drie bronmodi: Alleen mijn bibliotheek, Mix (bibliotheek + Qobuz-ontdekkingen), en Qobuz Discovery (alleen nieuwe muziek). Automatisch gedetecteerd als Qobuz geconfigureerd is in Roon.

**Slim filteren** — filter op genre, decade en live-uitsluiting vóór de LLM iets ziet. Realtime trackaantallen tonen precies hoe je keuzes de pool verkleinen. Geschatte tokenkosten worden getoond vóór je genereert.

**Tijdsbewuste context** — de huidige dag en het uur worden als subtiele stemmingshints meegestuurd in generatieprompts. Vrijdagavond-picks verschillen van dinsdagochtend.

![Album recommendation](docs/images/screenshot-album.png)

---

## Hoe het werkt

RoonSage gebruikt een filter-first architectuur voor grote bibliotheken. De LLM ziet nooit je hele bibliotheek — alleen een gefilterd, behapbaar deel.

Er zijn twee paden, afhankelijk van hoe je RoonSage gebruikt:

### Pad A — Claude Desktop (native curatie, snel)

Claude curates de playlist zelf op basis van eigen muzikale kennis. Geen backend LLM-call.

```
┌─────────────────────────────────────────────────────────────────┐
│  1. ANALYSEER (Claude)                                           │
│     Claude interpreteert je prompt — mood, genre, era, tempo     │
│     Detecteert ook gewenste bron: library / hybrid / qobuz       │
├─────────────────────────────────────────────────────────────────┤
│  2. STATS (optioneel, bij library/hybrid)                        │
│     get_library_stats → Claude ziet welke genres/decades bestaan │
├─────────────────────────────────────────────────────────────────┤
│  3. FILTER & ZOEK                                                │
│     Library/hybrid: filter_tracks(compact) → genummerde lijst    │
│     + key_map met maximaal 500 tracks                            │
│     Hybrid/qobuz: search_qobuz voor Qobuz-tracks                │
├─────────────────────────────────────────────────────────────────┤
│  4. CUREER (Claude)                                              │
│     Claude kiest de beste 15–50 tracks op basis van muzikale     │
│     kennis: diversiteit, flow, geen clustering, juiste sfeer     │
│     Bij hybrid: library- en Qobuz-tracks gemengd door de lijst   │
├─────────────────────────────────────────────────────────────────┤
│  5. SPEEL AF                                                     │
│     curate_and_play of play_tracks → item_keys naar Roon-zone    │
│     Directe afspeling in elke Roon-client                        │
└─────────────────────────────────────────────────────────────────┘
```

### Pad B — Web UI en fallback (backend pipeline)

Gebruikt door de web-interface en door Claude Desktop als de gefilterde pool te groot is of de gebruiker expliciet "automatisch" vraagt.

```
┌─────────────────────────────────────────────────────────────────┐
│  1. ANALYSEER                                                    │
│     LLM interpreteert prompt → stelt genre/decade-filters voor   │
├─────────────────────────────────────────────────────────────────┤
│  2. FILTER                                                       │
│     Bibliotheek ingeperkt via SQLite                             │
│     "90s Alternative" → 2.000 tracks                             │
├─────────────────────────────────────────────────────────────────┤
│  3. STEEKPROEF (alleen bij grote bibliotheken)                   │
│     Te groot voor contextvenster → willekeurige steekproef       │
├─────────────────────────────────────────────────────────────────┤
│  4. GENEREER                                                     │
│     Gefilterde lijst + prompt naar LLM                           │
│     LLM selecteert beste tracks op tracknummer                   │
├─────────────────────────────────────────────────────────────────┤
│  5. MATCH                                                        │
│     Tracknummer → O(1) opzoeken in SQLite-cache                  │
│     Fallback naar fuzzy matching (rapidfuzz) indien nodig        │
├─────────────────────────────────────────────────────────────────┤
│  6. SPEEL AF                                                     │
│     Tracks naar Roon-zone via Browse API                         │
└─────────────────────────────────────────────────────────────────┘
```

Library-data wordt eenmalig gesynchroniseerd naar SQLite via de Roon Browse API (`browse_browse` / `browse_load`). Alle vervolgqueries lezen uit de lokale cache — geen Roon API-calls nodig tijdens generatie.

---

## Installatie

### Docker Compose

```bash
mkdir roonsage && cd roonsage
curl -O https://raw.githubusercontent.com/Georgemvp/roonsage/main/docker-compose.yml
# bewerk docker-compose.yml: stel ROON_HOST en een API-sleutel in
docker compose up -d
```

### NAS-platforms

<details>
<summary><strong>Synology (Container Manager)</strong></summary>

**GUI:** Container Manager → Registry → zoek `ghcr.io/Georgemvp/roonsage` → Download `latest` → Container aanmaken → Poort 5765:5765 → voeg `ROON_HOST` en API-sleutel toe.

**Docker Compose:**
```bash
mkdir -p /volume1/docker/roonsage && cd /volume1/docker/roonsage
curl -O https://raw.githubusercontent.com/Georgemvp/roonsage/main/docker-compose.yml
nano docker-compose.yml  # stel ROON_HOST en API-sleutel in
```
Daarna Container Manager → Project → Create, wijs naar `/volume1/docker/roonsage`.

ARM-gebaseerde Synology-units zonder Docker: gebruik [Bare Metal](#bare-metal) hieronder.
</details>

<details>
<summary><strong>Unraid</strong></summary>

Docker → Add Container → Repository: `ghcr.io/Georgemvp/roonsage:latest` → Poort 5765:5765 → voeg `ROON_HOST` en API-sleutel toe.
</details>

<details>
<summary><strong>TrueNAS SCALE</strong></summary>

Apps → Discover Apps → Custom App → Image `ghcr.io/Georgemvp/roonsage`, tag `latest` → Poort 5765 → voeg omgevingsvariabelen toe.
</details>

<details>
<summary><strong>Portainer</strong></summary>

Stacks → Add Stack:
```yaml
services:
  roonsage:
    image: ghcr.io/Georgemvp/roonsage:latest
    ports:
      - "5765:5765"
    environment:
      - ROON_HOST=192.168.1.x
      - ROON_PORT=9330
      - GEMINI_API_KEY=your-key
    volumes:
      - ./data:/app/data
    restart: unless-stopped
```
</details>

### Bare Metal

```bash
git clone https://github.com/Georgemvp/roonsage.git
cd roonsage
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
export ROON_HOST=192.168.1.x ROON_PORT=9330 GEMINI_API_KEY=your-key
uvicorn backend.main:app --host 0.0.0.0 --port 5765
```

<details>
<summary><strong>systemd service</strong></summary>

```ini
# /etc/systemd/system/roonsage.service
[Unit]
Description=RoonSage
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/roonsage
EnvironmentFile=/path/to/roonsage/.env
ExecStart=/path/to/roonsage/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 5765
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable roonsage && sudo systemctl start roonsage
```
</details>

---

## Configuratie

### Omgevingsvariabelen

| Variabele | Verplicht | Standaard | Beschrijving |
|-----------|-----------|-----------|-------------|
| `ROON_HOST` | Ja | — | IP of hostnaam van je Roon Core |
| `ROON_PORT` | Nee | `9330` | Roon Core-poort |
| `ROON_CORE_ID` | Nee | auto | Opgeslagen na eerste autorisatie |
| `ROON_TOKEN` | Nee | auto | Opgeslagen na eerste autorisatie |
| `GEMINI_API_KEY` | Een van drie | — | Google Gemini (heeft gratis tier) |
| `ANTHROPIC_API_KEY` | Een van drie | — | Anthropic Claude |
| `OPENAI_API_KEY` | Een van drie | — | OpenAI GPT |
| `LLM_PROVIDER` | Nee | auto-detect | Forceer: `gemini`, `anthropic`, `openai`, `ollama`, `custom` |
| `OLLAMA_URL` | Nee | `http://localhost:11434` | Ollama server URL |
| `CUSTOM_LLM_URL` | Nee | — | OpenAI-compatibele API base URL |
| `CUSTOM_CONTEXT_WINDOW` | Nee | `32768` | Contextvenster voor custom provider |
| `ROONSAGE_PASSWORD` | Nee | — | Schakel HTTP Basic Auth in op alle endpoints |
| `ROONSAGE_URL` | Nee | `http://localhost:5765` | Adres waarop de MCP server RoonSage bereikt |

Instellingen kunnen ook via de web-UI worden aangepast (Instellingen-pagina). UI-opgeslagen instellingen gaan naar `data/config.user.yaml`. Omgevingsvariabelen hebben altijd voorrang.

### config.yaml

```yaml
roon:
  host: "192.168.1.x"
  port: 9330

llm:
  provider: "gemini"
  model_analysis: "gemini-2.5-flash"
  model_generation: "gemini-2.5-flash"
  smart_generation: false  # true = analysemodel ook voor generatie (hogere kwaliteit, ~3–5× kosten)

defaults:
  track_count: 25
```

### Modelkeuze voor de Web UI

De Web UI gebruikt een twee-model strategie: een slimmer model voor prompt-analyse, een goedkoper model voor track-selectie.

| Rol | Anthropic | OpenAI | Gemini |
|-----|-----------|--------|--------|
| Analyse | `claude-sonnet-4-5` | `gpt-4.1` | `gemini-2.5-flash` |
| Generatie | `claude-haiku-4-5` | `gpt-4.1-mini` | `gemini-2.5-flash` |
| Max tracks naar AI | ~3.500 | ~2.300 | **~18.000** |

Gemini's contextvenster van 1M tokens maakt het mogelijk om veel meer tracks naar het model te sturen, wat de variëteit verbetert bij grote bibliotheken.

### Lokale LLM (experimenteel)

<details>
<summary><strong>Ollama</strong></summary>

```bash
ollama pull llama3:8b
```

```bash
LLM_PROVIDER=ollama
OLLAMA_URL=http://localhost:11434
```

Selecteer je model in de Instellingen — het contextvenster wordt automatisch gedetecteerd. Modellen met 8K+ context werken het best (`llama3:8b`, `qwen3:8b`, `mistral`).
</details>

<details>
<summary><strong>Custom OpenAI-compatibele API</strong></summary>

Voor LM Studio, text-generation-webui, vLLM of vergelijkbaar:

```bash
LLM_PROVIDER=custom
CUSTOM_LLM_URL=http://localhost:5000/v1
CUSTOM_CONTEXT_WINDOW=32768
```

Stel modelnaam en API-sleutel (indien vereist) in via de Instellingen.
</details>

---

## Beveiliging

RoonSage is ontworpen voor thuisnetwerk-gebruik. Zonder `ROONSAGE_PASSWORD` heeft iedereen op je netwerk toegang tot de web-UI.

`ROONSAGE_PASSWORD` schakelt HTTP Basic Auth in op alle endpoints. Health check (`/api/health`) en de art-proxy zijn hiervan vrijgesteld, zodat Docker-health checks en albumafbeeldingen blijven werken zonder credentials.

LLM-powered endpoints hebben een rate limit van 30 verzoeken per uur per IP. API-sleutels worden opgeslagen in `data/config.user.yaml` (rechten 600) en worden nooit blootgesteld via de API.

---

## Ontwikkeling

```bash
git clone https://github.com/Georgemvp/roonsage.git
cd roonsage
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
export ROON_HOST=192.168.1.x ROON_PORT=9330 GEMINI_API_KEY=your-key
uvicorn backend.main:app --reload --port 5765
```

```bash
pytest tests/ -v   # tests uitvoeren
ruff check .       # linting
```

**Stack:** Python 3.11+, FastAPI, python-roonapi, anthropic / openai / google-genai SDK's, rapidfuzz, SQLite, vanilla HTML/CSS/JS.

---

## API Reference

Interactieve docs op `/docs` wanneer de server draait.

| Endpoint | Methode | Beschrijving |
|----------|---------|-------------|
| `/api/health` | GET | Health check |
| `/api/config` | GET/POST | Configuratie ophalen of aanpassen |
| `/api/setup/status` | GET | Status van de onboarding-checklist |
| `/api/setup/validate-roon` | POST | Roon Core-verbinding valideren |
| `/api/setup/validate-ai` | POST | AI-provider-credentials valideren |
| `/api/library/stats/cached` | GET | Genre/decade/totaal uit SQLite |
| `/api/library/status` | GET | Cache-status, trackcount, needs_resync |
| `/api/library/sync` | POST | Achtergrond library sync starten |
| `/api/library/search` | GET | Zoeken op track/artiest/album |
| `/api/library/artist-albums` | GET | Alle albums van artiest uit cache |
| `/api/library/filter` | POST | Filter op genre/decade/live-uitsluiting |
| `/api/library/filter/session` | POST | Server-side key_map opslaan voor curate_and_play |
| `/api/library/filter/curate` | POST | Gecureerde track-selectie afspelen via session_id + track-nummers |
| `/api/library/filter/validate` | POST | Track-selectie valideren op kwaliteitsproblemen |
| `/api/analyze/prompt` | POST | Prompt analyseren → filter-mapping |
| `/api/generate/stream` | POST | Playlist generatie streamen (SSE) |
| `/api/roon/zones` | GET | Actieve Roon-zones ophalen |
| `/api/roon/transport` | POST | play/pause/stop/volgende/vorige/shuffle/repeat/seek |
| `/api/roon/volume` | POST | Volume instellen/aanpassen/dempen/opvragen |
| `/api/roon/transfer` | POST | Afspelen verplaatsen naar andere zone |
| `/api/roon/group` | POST | Zones groeperen of loskoppelen |
| `/api/roon/radio` | POST | Internetradiostation afspelen |
| `/api/roon/playlists` | POST | Roon-afspeellijsten tonen of afspelen |
| `/api/roon/qobuz-search` | POST | Qobuz-catalogus doorzoeken via Roon |
| `/api/queue` | POST | Tracks naar een Roon-zone sturen |
| `/api/queue/append` | POST | Tracks toevoegen aan een zone-wachtrij |
| `/api/recommend/questions` | POST | Verhelderende vragen genereren |
| `/api/recommend/generate` | POST | Albumaanbevelingen genereren |
| `/api/results` | GET | Resultatenhistorie ophalen |
| `/api/art/{item_key}` | GET | Albumhoezen proxyen vanuit Roon |

---

## Credits

RoonSage is gebaseerd op [MediaSage](https://github.com/ecwilsonaz/mediasage) van Eric Wilson, oorspronkelijk gebouwd voor Plex. RoonSage is onafhankelijk doorontwikkeld voor Roon met significante nieuwe functionaliteit, waaronder MCP-integratie, Qobuz-ondersteuning, zone-beheer, tijdsbewuste context en een volledige library-cache laag.

---

## Licentie

MIT
