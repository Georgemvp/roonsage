"""Lyrics extraction + semantic search (v13.0).

Reads embedded lyrics from audio tags via mutagen, embeds them with a
multilingual GTE transformer, and answers natural-language queries by
ranking stored embeddings via cosine similarity.

Submodules:
  extractor — pull lyrics text from MP3 / FLAC / M4A tags.
  embedder  — load the GTE-multilingual model and produce text embeddings.
  search    — query encoding + ranking.
"""
