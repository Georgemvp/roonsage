"""Genre whitelist filter for the enrichment pipeline.

Ported from SoulSync (MijnEigenApp). When ``genre_whitelist.enabled`` is true
in ``data/config.user.yaml`` (or via ``GENRE_WHITELIST_ENABLED=true``), only
tags that match a curated whitelist pass through into ``track_metadata_ext``.

The whitelist removes:
  - artist names that Last.fm sometimes returns as a "tag" (Bjork, Korn, etc.)
  - radio-show / playlist tags ("BBC 6Music recommends", "starred", "favorites")
  - opinion tags ("seen live", "needs more cowbell")
  - era tags that duplicate the decade column ("70s", "80s rock")

Default is OFF — wrap every call site so existing behaviour is unchanged when
the user has not opted in.
"""

from __future__ import annotations

import os
from functools import lru_cache

from backend.config import load_user_yaml_config

# ~180 curated genres covering all major categories.
# Source: SoulSync ``core/genre_filter.py``. Users can extend / replace via
# ``data/config.user.yaml`` under ``genre_whitelist.genres``.
DEFAULT_GENRES: tuple[str, ...] = (
    # Rock
    "Rock", "Alternative Rock", "Indie Rock", "Classic Rock", "Punk Rock", "Post-Punk",
    "Psychedelic Rock", "Progressive Rock", "Garage Rock", "Grunge", "Shoegaze", "Surf Rock",
    "Stoner Rock", "Southern Rock", "Hard Rock", "Soft Rock", "Art Rock", "Glam Rock",
    "Noise Rock", "Math Rock", "Post-Rock", "Folk Rock", "Heartland Rock", "Brit Rock",
    "Space Rock", "Krautrock",
    # Punk
    "Punk", "Hardcore Punk", "Pop Punk", "Ska Punk", "Post-Hardcore",
    # Emo
    "Emo", "Midwest Emo", "Screamo",
    # Metal
    "Metal", "Heavy Metal", "Death Metal", "Black Metal", "Thrash Metal", "Doom Metal",
    "Power Metal", "Speed Metal", "Progressive Metal", "Symphonic Metal", "Metalcore",
    "Deathcore", "Nu Metal", "Industrial Metal", "Gothic Metal", "Sludge Metal",
    "Folk Metal", "Djent", "Groove Metal", "Post-Metal",
    # Pop
    "Pop", "Synth Pop", "Electropop", "Indie Pop", "Dream Pop", "Chamber Pop", "Art Pop",
    "Dance Pop", "Power Pop", "Baroque Pop", "Bedroom Pop", "K-Pop", "J-Pop", "Teen Pop",
    "Bubblegum Pop",
    # Hip Hop / Rap
    "Hip Hop", "Rap", "Trap", "Boom Bap", "Gangsta Rap", "Conscious Hip Hop",
    "Southern Hip Hop", "West Coast Hip Hop", "East Coast Hip Hop", "Dirty South", "Crunk",
    "Grime", "Drill", "Lo-Fi Hip Hop", "Abstract Hip Hop",
    # Electronic / Dance
    "Electronic", "EDM", "House", "Deep House", "Tech House", "Progressive House",
    "Techno", "Trance", "Drum and Bass", "Dubstep", "Ambient", "IDM", "Downtempo",
    "Trip Hop", "Breakbeat", "Jungle", "Garage", "UK Garage", "Future Bass", "Hardstyle",
    "Electro", "Electronica", "Chillwave", "Synthwave", "Vaporwave", "Industrial", "EBM",
    "Glitch", "Footwork", "Chillout", "Lo-Fi", "New Age",
    # R&B / Soul / Funk
    "R&B", "Soul", "Neo Soul", "Funk", "Disco", "Motown", "Gospel", "Quiet Storm",
    "Contemporary R&B", "New Jack Swing",
    # Jazz
    "Jazz", "Bebop", "Cool Jazz", "Free Jazz", "Fusion", "Smooth Jazz", "Acid Jazz",
    "Nu Jazz", "Swing", "Big Band", "Latin Jazz", "Vocal Jazz",
    # Blues
    "Blues", "Delta Blues", "Chicago Blues", "Electric Blues", "Blues Rock", "Country Blues",
    # Country
    "Country", "Alt-Country", "Americana", "Bluegrass", "Country Rock", "Outlaw Country",
    "Country Pop", "Honky Tonk", "Western Swing", "Nashville Sound",
    # Folk / Singer-Songwriter
    "Folk", "Indie Folk", "Contemporary Folk", "Singer-Songwriter", "Acoustic",
    "Freak Folk", "Folk Punk", "Neofolk",
    # Classical
    "Classical", "Opera", "Baroque", "Romantic", "Contemporary Classical", "Minimalism",
    "Orchestral", "Chamber Music", "Choral", "Soundtrack", "Film Score", "Musical Theatre",
    # Latin
    "Latin", "Reggaeton", "Salsa", "Bachata", "Cumbia", "Merengue", "Latin Pop",
    "Latin Rock", "Bossa Nova", "Samba", "MPB", "Tango", "Banda", "Norteño", "Corrido",
    "Tropical",
    # Reggae / Caribbean
    "Reggae", "Dancehall", "Dub", "Ska", "Rocksteady", "Calypso", "Soca",
    # World / International
    "World", "Afrobeat", "Afropop", "Afrobeats", "Bhangra", "Celtic", "Flamenco",
    "Fado", "Klezmer", "Polka", "Zydeco", "Highlife",
    # Alternative / Indie umbrellas
    "Alternative", "Indie", "Alternative Metal", "Alternative R&B",
    # Additional Rock
    "New Wave", "Darkwave", "Post-Grunge", "Slowcore", "Sadcore", "Post-Punk Revival",
    # Additional Metal
    "Grindcore", "Crust Punk", "Crossover Thrash", "Trap Metal",
    # Additional Hip Hop
    "Emo Rap", "Cloud Rap", "Phonk", "Horrorcore", "Nerdcore",
    # Additional Electronic
    "Dark Ambient", "Drone", "Witch House", "Hyperpop", "Future Funk",
    "Outrun", "Retrowave", "Chiptune", "Dance",
    # Additional Pop
    "German Pop", "French Pop", "Turkish Pop",
    # Additional Latin
    "Trap Latino", "Urbano Latino", "Tropicalia", "Mambo",
    # Additional Reggae
    "Roots Reggae", "Lovers Rock",
    # Additional Jazz
    "Hard Bop", "Modal Jazz", "Gypsy Jazz",
    # Additional World
    "Qawwali", "Carnatic", "Hindustani",
    # Media
    "Video Game Music", "Anime",
    # Other
    "Experimental", "Avant-Garde", "Noise", "Spoken Word", "Comedy", "Instrumental",
    "A Cappella", "Worship", "Christian", "Christmas", "Holiday", "Easy Listening",
    "Lounge", "Psychedelic", "Progressive",
)


def _normalize(genre: str) -> str:
    """Lowercase, strip, replace ``-`` / ``&``, collapse whitespace."""
    g = genre.lower().strip().replace("-", " ").replace("&", " and ")
    return " ".join(g.split())


@lru_cache(maxsize=1)
def _default_lookup() -> frozenset[str]:
    return frozenset(_normalize(g) for g in DEFAULT_GENRES)


def _user_lookup() -> frozenset[str] | None:
    """Return the user-overridden whitelist (or ``None`` to use defaults)."""
    user_cfg = load_user_yaml_config().get("genre_whitelist", {})
    user_genres = user_cfg.get("genres")
    if isinstance(user_genres, list) and user_genres:
        return frozenset(_normalize(g) for g in user_genres if isinstance(g, str))
    return None


def is_enabled() -> bool:
    """True when the whitelist filter should be applied."""
    env = os.environ.get("GENRE_WHITELIST_ENABLED")
    if env is not None and env != "":
        return env.lower() in ("1", "true", "yes", "on")
    return bool(load_user_yaml_config().get("genre_whitelist", {}).get("enabled"))


def filter_genres(genres: list[str] | None) -> list[str]:
    """Filter ``genres`` against the whitelist.

    No-op when:
      - ``genres`` is empty / not a list
      - ``genre_whitelist.enabled`` is false (the default)

    Returns the input list unchanged in the no-op cases. When enabled, returns
    a new list preserving the original casing and order, keeping only entries
    whose normalised form matches the whitelist.
    """
    if not genres or not isinstance(genres, list):
        return genres or []
    if not is_enabled():
        return genres

    lookup = _user_lookup() or _default_lookup()
    return [g for g in genres if isinstance(g, str) and _normalize(g) in lookup]


def get_active_whitelist() -> list[str]:
    """Return the currently active whitelist (user override or defaults)."""
    user_cfg = load_user_yaml_config().get("genre_whitelist", {})
    user_genres = user_cfg.get("genres")
    if isinstance(user_genres, list) and user_genres:
        return [g for g in user_genres if isinstance(g, str)]
    return list(DEFAULT_GENRES)
