"""Audio feature analysis subsystem (v13.0).

Extracts BPM, musical key (Camelot notation) and Spotify-style audio features
(energy, danceability, valence, loudness) from the actual audio files in the
user's library. Powers harmonic-mixing DJ-set generation and audio-aware
filter parameters (`bpm_min`, `bpm_max`, `energy_min`, `camelot_keys`).

Submodules:
  camelot       — key → Camelot wheel conversion + compatibility helpers.
  path_resolver — maps Roon tracks to filesystem paths via tag scanning.
  analyzer      — librosa-based BPM / key / energy analyser.
  worker        — background queue worker (mirrors enrichment_worker pattern).
"""
