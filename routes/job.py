"""
routes/job.py — Job status, processing page, and speaker management endpoints.

URL structure:
  GET  /job/<job_id>/status          JSON poll — used by processing.html
  GET  /job/<job_id>/processing      Processing page (transcription progress)
  GET  /job/<job_id>/speakers        Speaker identification page
  POST /job/<job_id>/speakers        Submit renamed speakers → kick off render
  GET  /job/<job_id>/speaker/<id>/clip  Stream the WAV clip for a speaker
  POST /job/<job_id>/speaker/<id>/regenerate  Regenerate clip with a different segment
"""

import mimetypes
from pathlib import Path

from flask import (
    Blueprint,
    abort,
    jsonify,
    render_template,
    request,
    send_file,
    url_for,
)

from jobs.manager import job_manager
from models import JobStatus, Speaker

job_bp = Blueprint("job", __name__, url_prefix="/job")


# ── Processing Status Page ────────────────────────────────────────────────────

@job_bp.get("/<job_id>/processing")
def processing_status(job_id: str):
    job = job_manager.get_job(job_id)
    if job is None:
        abort(404)
    # If already at speakers stage, redirect there
    if job.status == JobStatus.AWAITING_NAMES:
        return _redirect_to(url_for("job.speakers", job_id=job_id))
    if job.status == JobStatus.DONE:
        return _redirect_to(url_for("download.download_page", job_id=job_id))
    if job.status == JobStatus.FAILED:
        return render_template("processing.html", job=job, error=job.error)
    return render_template("processing.html", job=job)


# ── JSON Status Poll ──────────────────────────────────────────────────────────

@job_bp.get("/<job_id>/status")
def job_status(job_id: str):
    """
    Polled every 3s by processing.html and speakers.html.

    Returns:
      { status, redirect? }
    """
    job = job_manager.get_job(job_id)
    if job is None:
        return jsonify({"error": "not_found"}), 404

    resp = {"status": job.status.value}

    if job.status == JobStatus.AWAITING_NAMES:
        resp["redirect"] = url_for("job.speakers", job_id=job_id)
    elif job.status == JobStatus.DONE:
        resp["redirect"] = url_for("download.download_page", job_id=job_id)
    elif job.status == JobStatus.FAILED:
        resp["error"] = job.error

    return jsonify(resp), 200


# ── Speaker Identification Page ───────────────────────────────────────────────

@job_bp.get("/<job_id>/speakers")
def speakers(job_id: str):
    job = job_manager.get_job(job_id)
    if job is None:
        abort(404)
    if job.status not in (JobStatus.AWAITING_NAMES, JobStatus.RENDERING, JobStatus.DONE):
        return _redirect_to(url_for("job.processing_status", job_id=job_id))
    return render_template("speakers.html", job=job, speakers=job.get_speakers())


@job_bp.post("/<job_id>/speakers")
def submit_speakers(job_id: str):
    """
    Receive the user's speaker name assignments and kick off the render.

    Expected JSON body: { "speakers": { "SPEAKER_00": "Alice", "SPEAKER_01": "Bob" } }
    """
    job = job_manager.get_job(job_id)
    if job is None:
        return jsonify({"error": "not_found"}), 404
    if job.status != JobStatus.AWAITING_NAMES:
        return jsonify({"error": "job_not_awaiting_names", "status": job.status.value}), 409

    data = request.get_json(force=True, silent=True) or {}
    name_map: dict = data.get("speakers", {})

    # Update display names on each speaker
    updated_speakers = []
    for sp in job.get_speakers():
        new_name = name_map.get(sp.speaker_id, "").strip()
        sp.display_name = new_name if new_name else sp.speaker_id
        updated_speakers.append(sp)

    job.set_speakers(updated_speakers)
    job_manager.update_job(
        job_id,
        status=JobStatus.RENDERING,
        speakers=job.speakers,
    )

    from jobs.runner import run_render
    job_manager.submit_task(job_id, run_render)

    return jsonify({
        "status": "rendering",
        "redirect": url_for("job.processing_status", job_id=job_id),
    }), 202


# ── Speaker Clip Endpoints ────────────────────────────────────────────────────

@job_bp.get("/<job_id>/speaker/<speaker_id>/clip")
def speaker_clip(job_id: str, speaker_id: str):
    """Stream the WAV clip for a speaker."""
    job = job_manager.get_job(job_id)
    if job is None:
        abort(404)

    clip_path = _find_clip(job, speaker_id)
    if clip_path is None or not clip_path.exists():
        abort(404)

    return send_file(str(clip_path), mimetype="audio/wav")


@job_bp.post("/<job_id>/speaker/<speaker_id>/regenerate")
def regenerate_clip(job_id: str, speaker_id: str):
    """
    Re-extract a clip for a speaker, choosing a different random segment.
    Returns JSON with the new clip URL so WaveSurfer can reload.
    """
    job = job_manager.get_job(job_id)
    if job is None:
        return jsonify({"error": "not_found"}), 404

    try:
        from services.audio_clip import extract_speaker_clip
        from services.srt_parser import parse_srt

        segments = parse_srt(job.transcript_srt_path)
        speaker_segments = [s for s in segments if s.get("speaker") == speaker_id]
        if not speaker_segments:
            return jsonify({"error": "no_segments_for_speaker"}), 404

        clip_path = extract_speaker_clip(
            audio_path=job.audio_path,
            segments=speaker_segments,
            speaker_id=speaker_id,
            job_dir=str(job.job_dir),
            avoid_longest=True,  # regenerate picks a different segment
        )

        # Update stored clip path
        speakers = job.get_speakers()
        for sp in speakers:
            if sp.speaker_id == speaker_id:
                sp.clip_path = str(Path(clip_path).relative_to(job.job_dir))
        job.set_speakers(speakers)
        job_manager.update_job(job_id, speakers=job.speakers)

        return jsonify({
            "clip_url": url_for("job.speaker_clip", job_id=job_id, speaker_id=speaker_id),
        }), 200

    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


# ── Helpers ───────────────────────────────────────────────────────────────────

def _find_clip(job, speaker_id: str):
    """Return the Path to a speaker's clip, or None."""
    for sp in job.get_speakers():
        if sp.speaker_id == speaker_id and sp.clip_path:
            return job.job_dir / sp.clip_path
    # Fallback: check default location
    fallback = job.speaker_clips_dir / f"{speaker_id}.wav"
    return fallback if fallback.exists() else None


def _redirect_to(url: str):
    from flask import redirect
    return redirect(url)
