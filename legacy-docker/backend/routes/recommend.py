"""Album recommendation endpoints."""

import asyncio
import json
import logging
import random
import threading
from urllib.parse import quote

import httpx
from fastapi import APIRouter, HTTPException, Query, Request
from starlette.responses import StreamingResponse

from backend import library_cache
from backend.config import get_config
from backend.dependencies import limiter
from backend.llm_client import TOKENS_PER_ALBUM, estimate_cost_for_model, get_llm_client
from backend.models import (
    AlbumCandidate,
    AlbumPreviewResponse,
    AnalyzePromptFiltersRequest,
    AnalyzePromptFiltersResponse,
    RecommendGenerateRequest,
    RecommendGenerateResponse,
    RecommendQuestionsRequest,
    RecommendQuestionsResponse,
    RecommendSessionState,
    RecommendSwitchModeRequest,
    RecommendSwitchModeResponse,
    album_key,
)
from backend.roon_client import get_roon_client
from backend.taste_profile import TasteProfile

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/recommend", tags=["recommend"])


def _rerank_albums_by_taste(candidates: list, limit: int) -> list:
    """Score album candidates by taste-profile affinity and return top ``limit``."""
    try:
        profile = TasteProfile.get()
        top_artists: set[str] = {a.lower() for a in profile.get("artists", {})}
        skip_artists: set[str] = {
            s["artist"].lower()
            for s in profile.get("skip_signals", {}).get("artists", [])
        }
    except Exception:
        top_artists, skip_artists = set(), set()

    def _score(c) -> float:
        name = (c.album_artist or "").lower()
        s = 0.0
        if name in top_artists:
            s += 3.0
        if name in skip_artists:
            s -= 4.0
        s += random.random()
        return s

    scored = sorted(candidates, key=_score, reverse=True)
    return scored[:limit]

# Module-level pipeline instance (initialized lazily)
_recommendation_pipeline = None
_recommendation_pipeline_llm = None  # Track which LLM client the pipeline was built with
_music_research_client = None
_art_proxy_client: httpx.AsyncClient | None = None
_art_proxy_lock = asyncio.Lock()
_pipeline_lock = threading.Lock()
_research_client_lock = threading.Lock()


def _get_pipeline():
    """Get or create the recommendation pipeline. Recreates if LLM client changed."""
    global _recommendation_pipeline, _recommendation_pipeline_llm
    llm_client = get_llm_client()
    if llm_client is None:
        return None
    if _recommendation_pipeline is None or _recommendation_pipeline_llm is not llm_client:
        with _pipeline_lock:
            if _recommendation_pipeline is None or _recommendation_pipeline_llm is not llm_client:
                from backend.recommender import RecommendationPipeline
                config = get_config()
                old_pipeline = _recommendation_pipeline
                _recommendation_pipeline = RecommendationPipeline(config, llm_client)
                if old_pipeline is not None:
                    _recommendation_pipeline.migrate_sessions_from(old_pipeline)
                _recommendation_pipeline_llm = llm_client
    return _recommendation_pipeline


def _get_research_client():
    """Get or create the music research client."""
    global _music_research_client
    if _music_research_client is None:
        with _research_client_lock:
            if _music_research_client is None:
                from backend.music_research import MusicResearchClient
                _music_research_client = MusicResearchClient()
    return _music_research_client


async def _get_art_proxy_client() -> httpx.AsyncClient:
    """Get or create the shared httpx client for art proxying."""
    global _art_proxy_client
    if _art_proxy_client is None or _art_proxy_client.is_closed:
        async with _art_proxy_lock:
            if _art_proxy_client is None or _art_proxy_client.is_closed:
                _art_proxy_client = httpx.AsyncClient(timeout=10.0)
    return _art_proxy_client


async def _set_cover_art_from_research(rec, rd, research_client) -> None:
    """Fetch cover art from Cover Art Archive when rec has no art_url."""
    if not rec.art_url and rd.earliest_release_mbid:
        art_url = await research_client.fetch_cover_art(
            rd.earliest_release_mbid, release_group_mbid=rd.musicbrainz_id,
        )
        if art_url:
            rec.art_url = f"/api/external-art?url={quote(art_url, safe='')}"


def _apply_year_override(rec, rd):
    """Override rec.year with MusicBrainz release_date year when available."""
    if rd.release_date and len(rd.release_date) >= 4:
        try:
            mb_year = int(rd.release_date[:4])
            if rec.year != mb_year:
                logger.info(
                    "Year override: Roon=%s → MusicBrainz=%s for %s — %s",
                    rec.year, mb_year, rec.artist, rec.album,
                )
                rec.year = mb_year
        except ValueError:
            pass


@router.get("/albums/preview", response_model=AlbumPreviewResponse)
async def recommend_albums_preview(
    genres: str | None = Query(None, description="Comma-separated genre names"),
    decades: str | None = Query(None, description="Comma-separated decade names"),
    max_albums: int = Query(2500, description="Max albums to send to AI"),
) -> AlbumPreviewResponse:
    """Preview filtered album counts and cost estimates for recommendation."""
    genre_list = [g.strip() for g in genres.split(",") if g.strip()] if genres else None
    decade_list = [d.strip() for d in decades.split(",") if d.strip()] if decades else None

    if library_cache.has_cached_tracks():
        candidates = await asyncio.to_thread(
            library_cache.get_album_candidates,
            genres=genre_list,
            decades=decade_list,
        )
        matching_albums = len(candidates)
    else:
        matching_albums = 0

    albums_to_send = min(matching_albums, max_albums) if max_albums > 0 else matching_albums
    config = get_config()

    analysis_input = 800 + 1500 + 2000 + 1500
    analysis_output = 50 + 800 + 200 + 800
    generation_input = 600 + (albums_to_send * TOKENS_PER_ALBUM) + 400 + 2000
    generation_output = 200 + 300 + 500

    estimated_input_tokens = analysis_input + generation_input

    analysis_cost = estimate_cost_for_model(
        config.llm.model_analysis, analysis_input, analysis_output, config=config.llm
    )
    generation_cost = estimate_cost_for_model(
        config.llm.model_generation, generation_input, generation_output, config=config.llm
    )
    estimated_cost = analysis_cost + generation_cost

    return AlbumPreviewResponse(
        matching_albums=matching_albums,
        albums_to_send=albums_to_send,
        estimated_input_tokens=estimated_input_tokens,
        estimated_cost=estimated_cost,
    )


@router.post("/analyze-prompt", response_model=AnalyzePromptFiltersResponse)
async def recommend_analyze_prompt(request: AnalyzePromptFiltersRequest) -> AnalyzePromptFiltersResponse:
    """Analyze a prompt and suggest relevant genre/decade filters."""
    pipeline = _get_pipeline()
    if not pipeline:
        return AnalyzePromptFiltersResponse(
            genres=request.genres,
            decades=request.decades,
            reasoning="LLM not configured; returning all filters.",
        )

    try:
        result = await asyncio.to_thread(
            pipeline.analyze_prompt_filters,
            request.prompt,
            request.genres,
            request.decades,
        )
        return AnalyzePromptFiltersResponse(
            genres=result["genres"],
            decades=result["decades"],
            reasoning=result["reasoning"],
        )
    except Exception:
        logger.exception("analyze-prompt failed, returning all filters")
        return AnalyzePromptFiltersResponse(
            genres=request.genres,
            decades=request.decades,
            reasoning="Analysis failed; returning all filters.",
        )


@router.post("/questions", response_model=RecommendQuestionsResponse)
@limiter.limit("30/hour")
async def recommend_questions(
    request: Request, body: RecommendQuestionsRequest
) -> RecommendQuestionsResponse:
    """Generate clarifying questions for album recommendation."""
    pipeline = _get_pipeline()
    if not pipeline:
        raise HTTPException(status_code=503, detail="LLM not configured")

    try:
        session_state = RecommendSessionState(
            mode="library",
            prompt=body.prompt,
            filters={"genres": [], "decades": []},
            questions=[],
            album_candidates=[],
            taste_profile=None,
            familiarity_pref="any",
        )
        session_id = pipeline.create_session(session_state)

        dimension_ids = await asyncio.to_thread(
            pipeline.gap_analysis, body.prompt, session_id
        )
        questions = await asyncio.to_thread(
            pipeline.generate_questions, body.prompt, dimension_ids, session_id
        )

        pipeline.update_session_questions(session_id, questions)

        total_tokens, total_cost = pipeline.get_session_costs(session_id)

        return RecommendQuestionsResponse(
            questions=questions,
            session_id=session_id,
            token_count=total_tokens,
            estimated_cost=total_cost,
        )
    except Exception as e:
        if 'session_id' in locals():
            pipeline.delete_session(session_id)
        raise HTTPException(status_code=500, detail=f"Question generation failed: {str(e)}") from e


@router.post("/switch-mode", response_model=RecommendSwitchModeResponse)
async def recommend_switch_mode(request: RecommendSwitchModeRequest) -> RecommendSwitchModeResponse:
    """Switch a recommendation session to a different mode, keeping answers."""
    pipeline = _get_pipeline()
    if not pipeline:
        raise HTTPException(status_code=503, detail="LLM not configured")

    old_session = pipeline.get_session(request.session_id)
    if not old_session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if request.mode == old_session.mode:
        return RecommendSwitchModeResponse(session_id=request.session_id)

    new_session = RecommendSessionState(
        mode=request.mode,
        prompt=old_session.prompt,
        filters=old_session.filters,
        questions=old_session.questions,
        answers=old_session.answers,
        answer_texts=old_session.answer_texts,
        album_candidates=[],
        taste_profile=None,
        familiarity_pref=old_session.familiarity_pref,
        previously_recommended=old_session.previously_recommended,
    )
    new_session_id = pipeline.create_session(new_session)
    pipeline.delete_session(request.session_id)

    return RecommendSwitchModeResponse(session_id=new_session_id)


@router.post("/generate")
@limiter.limit("30/hour")
async def recommend_generate(request: Request, body: RecommendGenerateRequest) -> StreamingResponse:
    """Generate album recommendations with SSE progress streaming."""
    pipeline = _get_pipeline()
    if not pipeline:
        raise HTTPException(status_code=503, detail="LLM not configured")

    session = pipeline.get_session(body.session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    pipeline.update_session_answers(
        body.session_id, body.answers, body.answer_texts
    )

    genre_list = body.genres if body.genres else None
    decade_list = body.decades if body.decades else None
    loaded_candidates = None
    loaded_taste_profile = None

    if not library_cache.has_cached_tracks():
        if body.mode == "library":
            raise HTTPException(status_code=400, detail="Library cache is empty. Please sync your library first.")
        elif body.mode == "discovery":
            raise HTTPException(status_code=400, detail="Library cache is empty. Discovery mode needs your library to build a taste profile. Please sync first.")
    else:
        candidates_raw = await asyncio.to_thread(
            library_cache.get_album_candidates,
            genres=genre_list if body.mode == "library" else None,
            decades=decade_list if body.mode == "library" else None,
        )

        if body.mode == "library" and not candidates_raw:
            if library_cache.has_cached_tracks():
                sync_state = library_cache.get_sync_state()
                if sync_state["is_syncing"]:
                    raise HTTPException(
                        status_code=409,
                        detail="Library sync in progress. Album recommendations will be available once it completes.",
                    )
                raise HTTPException(
                    status_code=400,
                    detail="Your library needs a fresh sync to enable album recommendations. Please re-sync from Settings or the footer Refresh link.",
                )
            raise HTTPException(status_code=400, detail="No albums match your filters. Try broadening your genre or decade selection.")

        loaded_candidates = [AlbumCandidate(**c) for c in candidates_raw]

        if body.max_albums > 0 and len(loaded_candidates) > body.max_albums:
            loaded_candidates = _rerank_albums_by_taste(loaded_candidates, body.max_albums)

        if body.mode == "discovery":
            all_raw = await asyncio.to_thread(
                library_cache.get_album_candidates, genres=None, decades=None
            )
            all_candidates = [AlbumCandidate(**c) for c in all_raw]
            loaded_taste_profile = pipeline.build_taste_profile(all_candidates)

    pipeline.update_session_generate_state(
        body.session_id,
        mode=body.mode,
        filters={"genres": body.genres, "decades": body.decades},
        familiarity_pref=body.familiarity_pref,
        album_candidates=loaded_candidates,
        taste_profile=loaded_taste_profile,
    )

    _prompt = session.prompt
    _answers = list(body.answers) if body.answers else []
    _answer_texts = list(body.answer_texts) if body.answer_texts else []
    _familiarity_pref = body.familiarity_pref
    _previously_recommended = list(session.previously_recommended) if session.previously_recommended else None

    async def event_stream():
        research_warning = None
        research_data = {}

        _ua = (request.headers.get("user-agent") or "").lower()
        _is_ios = "iphone" in _ua or "ipad" in _ua

        async def _check_disconnect():
            """Abort if the client has disconnected (saves LLM token costs)."""
            if _is_ios:
                return False
            if await request.is_disconnected():
                logger.info("Client disconnected, aborting recommendation for session %s", body.session_id)
                return True
            return False

        try:
            is_discovery = body.mode == "discovery"
            selecting_msg = "Finding albums to recommend..." if is_discovery else "Choosing albums from your library..."

            yield f"event: progress\ndata: {json.dumps({'step': 'selecting', 'message': selecting_msg})}\n\n"

            familiarity_data = None
            if body.familiarity_pref != "any" and not is_discovery:
                try:
                    candidate_keys = [c.parent_item_key for c in loaded_candidates if c.parent_item_key]
                    if candidate_keys:
                        familiarity_data = await asyncio.to_thread(
                            library_cache.get_album_familiarity, candidate_keys
                        )
                except Exception as e:
                    logger.warning("Familiarity query failed: %s", e)

            if is_discovery:
                if not loaded_taste_profile:
                    raise ValueError(
                        "Discovery mode requires a library profile. "
                        "Please sync your library and start a new recommendation."
                    )
                recommendations = await asyncio.to_thread(
                    pipeline.select_discovery_albums,
                    prompt=_prompt,
                    answers=_answers,
                    answer_texts=_answer_texts,
                    taste_profile=loaded_taste_profile,
                    session_id=body.session_id,
                    previously_recommended=_previously_recommended,
                    max_exclusion_albums=body.max_albums if body.max_albums > 0 else 2500,
                    use_taste_profile=body.use_taste_profile,
                )
            else:
                recommendations = await asyncio.to_thread(
                    pipeline.select_albums,
                    prompt=_prompt,
                    answers=_answers,
                    answer_texts=_answer_texts,
                    album_candidates=loaded_candidates,
                    session_id=body.session_id,
                    familiarity_pref=body.familiarity_pref,
                    familiarity_data=familiarity_data,
                    previously_recommended=_previously_recommended,
                    use_taste_profile=body.use_taste_profile,
                )

            if not recommendations:
                raise ValueError(
                    "No matching albums found. "
                    "Try broadening your prompt or adjusting filters."
                )

            if not is_discovery:
                roon_client_for_tracks = get_roon_client()
                for rec in recommendations:
                    if not rec.track_item_keys and rec.item_key:
                        try:
                            track_keys = await asyncio.to_thread(
                                roon_client_for_tracks.get_album_track_keys,
                                rec.item_key,
                            )
                            rec.track_item_keys = track_keys
                        except Exception as e:
                            logger.warning(
                                "Failed to get track keys for album %s: %s", rec.album, e
                            )

            if await _check_disconnect():
                return
            yield f"event: progress\ndata: {json.dumps({'step': 'researching_primary', 'message': 'Researching an album...'})}\n\n"

            research_client = _get_research_client()
            primary = next((r for r in recommendations if r.rank == "primary"), None)
            if primary:
                try:
                    rd = await research_client.research_album(primary.artist, primary.album, full=True, year=primary.year)
                    if rd.musicbrainz_id:
                        research_data[album_key(primary.artist, primary.album)] = rd
                        primary.research_available = True
                        _apply_year_override(primary, rd)

                        if is_discovery:
                            valid = await asyncio.to_thread(
                                pipeline.validate_discovery_album,
                                primary, rd, _prompt, request.session_id,
                            )
                            if not valid:
                                logger.info("Primary discovery album failed validation")
                                research_warning = "The primary recommendation could not be fully verified against available sources."

                        await _set_cover_art_from_research(primary, rd, research_client)
                    elif is_discovery:
                        logger.warning("Discovery album not found in MusicBrainz: %s — %s", primary.artist, primary.album)
                        research_warning = "This album could not be verified in MusicBrainz — details may be approximate."
                except Exception as e:
                    logger.warning("Primary research failed: %s", e)
                    research_warning = "Research was unavailable for the primary album — factual details could not be verified and may be approximate."

            if await _check_disconnect():
                return
            yield f"event: progress\ndata: {json.dumps({'step': 'researching_secondary', 'message': 'Looking up additional picks...'})}\n\n"

            secondaries = [r for r in recommendations if r.rank == "secondary"]
            for sec in secondaries:
                try:
                    rd = await research_client.research_album(sec.artist, sec.album, full=False, year=sec.year)
                    if rd.musicbrainz_id:
                        research_data[album_key(sec.artist, sec.album)] = rd
                        sec.research_available = True
                        _apply_year_override(sec, rd)

                        await _set_cover_art_from_research(sec, rd, research_client)
                except Exception as e:
                    logger.warning("Secondary research failed for %s: %s", sec.album, e)

            extracted_facts = {}
            primary_key = album_key(primary.artist, primary.album) if primary else None

            if primary_key and primary_key in research_data:
                yield f"event: progress\ndata: {json.dumps({'step': 'extracting_facts', 'message': 'Analyzing research sources...'})}\n\n"

                try:
                    facts = await asyncio.to_thread(
                        pipeline.extract_facts,
                        artist=primary.artist,
                        album=primary.album,
                        research=research_data[primary_key],
                        session_id=body.session_id,
                    )
                    extracted_facts[primary_key] = facts
                except Exception as e:
                    logger.warning("Fact extraction failed: %s", e)

            if await _check_disconnect():
                return
            yield f"event: progress\ndata: {json.dumps({'step': 'writing', 'message': 'Writing the pitch...'})}\n\n"

            recommendations = await asyncio.to_thread(
                pipeline.write_pitches,
                recommendations=recommendations,
                prompt=_prompt,
                answers=_answers,
                answer_texts=_answer_texts,
                session_id=body.session_id,
                research=research_data if research_data else None,
                familiarity_pref=_familiarity_pref,
                familiarity_data=familiarity_data,
                extracted_facts=extracted_facts if extracted_facts else None,
            )

            if await _check_disconnect():
                return
            if primary and primary_key and primary_key in extracted_facts:
                yield f"event: progress\ndata: {json.dumps({'step': 'validating', 'message': 'Fact-checking the pitch...'})}\n\n"

                try:
                    validation = await asyncio.to_thread(
                        pipeline.validate_pitch,
                        pitch=primary.pitch,
                        facts=extracted_facts[primary_key],
                        session_id=body.session_id,
                    )

                    if not validation.valid:
                        logger.info(
                            "Pitch validation found %d issues, rewriting",
                            len(validation.issues),
                        )
                        yield f"event: progress\ndata: {json.dumps({'step': 'rewriting', 'message': 'Refining the pitch...'})}\n\n"

                        from backend.recommender import format_answers_for_pitch
                        answers_str = format_answers_for_pitch(_answers, _answer_texts)

                        await asyncio.to_thread(
                            pipeline.rewrite_pitch,
                            rec=primary,
                            facts=extracted_facts[primary_key],
                            validation=validation,
                            prompt=_prompt,
                            answers_str=answers_str,
                            session_id=body.session_id,
                        )

                        revalidation = await asyncio.to_thread(
                            pipeline.validate_pitch,
                            pitch=primary.pitch,
                            facts=extracted_facts[primary_key],
                            session_id=body.session_id,
                        )

                        if not revalidation.valid:
                            logger.warning(
                                "Pitch still has %d issues after rewrite",
                                len(revalidation.issues),
                            )
                            if not research_warning:
                                research_warning = (
                                    "Some details could not be fully verified "
                                    "against available sources."
                                )
                except Exception as e:
                    logger.warning("Pitch validation failed: %s", e)

            if not research_data:
                research_warning = "Research was unavailable — factual details could not be verified and may be approximate."

            # For discovery mode: try to find albums on Qobuz so they're playable.
            # Run searches in parallel to keep latency low (1-3 s per album).
            if is_discovery:
                from rapidfuzz import fuzz

                from backend.qobuz_browser import search_qobuz_tracks

                discovery_recs = [r for r in recommendations if not r.track_item_keys]
                if discovery_recs:
                    yield f"event: progress\ndata: {json.dumps({'step': 'qobuz_lookup', 'message': 'Zoeken naar album op Qobuz...'})}\n\n"

                    async def _qobuz_lookup(rec):
                        """Search Qobuz for rec; mutate rec in place. Never raises."""
                        try:
                            query = f"{rec.artist} {rec.album}"
                            results = await search_qobuz_tracks(query, limit=20)
                            if not results:
                                rec.playable = False
                                return
                            # Filter to tracks that belong to this album (fuzzy match)
                            album_tracks = [
                                t for t in results
                                if fuzz.ratio(
                                    (t.get("album") or "").lower(),
                                    rec.album.lower(),
                                ) >= 70
                            ]
                            if not album_tracks:
                                # Relax: use any result from this artist
                                album_tracks = [
                                    t for t in results
                                    if fuzz.partial_ratio(
                                        (t.get("artist") or "").lower(),
                                        rec.artist.lower(),
                                    ) >= 70
                                ]
                            if album_tracks:
                                rec.track_item_keys = [t["item_key"] for t in album_tracks]
                                rec.item_key = album_tracks[0]["item_key"]
                                rec.source = "qobuz"
                                rec.playable = True
                            else:
                                rec.playable = False
                        except Exception as exc:
                            logger.warning(
                                "Qobuz lookup failed for %s — %s: %s",
                                rec.artist, rec.album, exc,
                            )
                            rec.playable = False

                    await asyncio.gather(*[_qobuz_lookup(r) for r in discovery_recs])

            total_tokens, total_cost = pipeline.get_session_costs(body.session_id)
            result = RecommendGenerateResponse(
                recommendations=recommendations,
                token_count=total_tokens,
                estimated_cost=total_cost,
                research_warning=research_warning,
            )

            rec_result_id = None
            try:
                primary_rec = next((r for r in recommendations if r.rank == "primary"), None)
                if primary_rec:
                    rec_title = f"{primary_rec.album} by {primary_rec.artist}"
                    rec_artist = primary_rec.artist
                    rec_art_key = primary_rec.track_item_keys[0] if primary_rec.track_item_keys else None
                    rec_subtitle = primary_rec.pitch.hook if primary_rec.pitch and primary_rec.pitch.hook else _prompt
                else:
                    rec_title = "Album Recommendation"
                    rec_artist = None
                    rec_art_key = None
                    rec_subtitle = _prompt
                rec_result_id = await asyncio.to_thread(
                    library_cache.save_result,
                    result_type="album_recommendation",
                    title=rec_title,
                    prompt=_prompt,
                    snapshot=result.model_dump(mode="json"),
                    track_count=len(recommendations),
                    artist=rec_artist,
                    art_item_key=rec_art_key,
                    subtitle=rec_subtitle,
                )
            except Exception as e:
                logger.warning("Failed to save recommendation result: %s", e)

            result_payload = result.model_dump(mode="json")
            if rec_result_id:
                result_payload["result_id"] = rec_result_id
            yield f"event: result\ndata: {json.dumps(result_payload)}\n\n"

            new_keys = [
                album_key(rec.artist, rec.album)
                for rec in recommendations
            ]
            pipeline.update_previously_recommended(body.session_id, new_keys)

            logger.info(
                "recommend.cost_summary | session=%s albums_researched=%d facts_extracted=%d research_warning=%s",
                body.session_id,
                len(research_data),
                len(extracted_facts),
                research_warning is not None,
            )

        except Exception as e:
            logger.exception("Recommendation generation failed")
            if isinstance(e, ValueError):
                error_data = json.dumps({"message": str(e)})
            else:
                error_data = json.dumps({"message": "An error occurred during recommendation generation. Please try again."})
            yield f"event: error\ndata: {error_data}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
