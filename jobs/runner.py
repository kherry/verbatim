"""
jobs/runner.py — Background task functions.

Each function has the signature:  fn(job_id: str) -> None
They are submitted via job_manager.submit_task() and run in daemon threads.

Error handling: JobManager._run_task() wraps each call and sets status=FAILED
on any unhandled exception, so individual steps only need to handle expected
errors (e.g. missing files). Unexpected exceptions bubble up automatically.
"""

import logging
from pathlib import Path

from jobs.manager import job_manager
from models import JobStatus, Speaker

log = logging.getLogger(__name__)


# ── Transcription ─────────────────────────────────────────────────────────────

def run_transcription(job_id: str) -> None:
    """
    Step 1 of the pipeline: run WhisperX on the uploaded audio.

    On success:   job.status → AWAITING_NAMES
    On failure:   job.status → FAILED  (handled by JobManager._run_task)
    """
    job = job_manager.get_job(job_id)
    if job is None:
        log.error("run_transcription: job %s not found", job_id)
        return

    log.info("Starting transcription for job %s (%s)", job_id, job.original_filename)

    output_dir = str(job.job_dir)

    from services.whisperx import run_whisperx
    paths = run_whisperx(
        audio_path=job.audio_path,
        output_dir=output_dir,
    )

    txt_path = paths["txt_path"]
    srt_path = paths["srt_path"]

    log.info("Transcription complete for job %s. Parsing SRT...", job_id)

    from services.srt_parser import parse_srt, get_speakers
    segments = parse_srt(srt_path)

    log.info("Extracting speaker clips for job %s...", job_id)
    from services.audio_clip import extract_all_speaker_clips
    clip_map = extract_all_speaker_clips(
        audio_path=job.audio_path,
        segments=segments,
        job_dir=str(job.job_dir),
    )

    speakers = []
    for speaker_id in get_speakers(segments):
        clip_abs = clip_map.get(speaker_id)
        clip_rel = None
        if clip_abs:
            try:
                clip_rel = str(Path(clip_abs).relative_to(job.job_dir))
            except ValueError:
                clip_rel = clip_abs

        speakers.append(Speaker(
            speaker_id=speaker_id,
            display_name=speaker_id,
            clip_path=clip_rel,
        ))

    job.set_speakers(speakers)
    job_manager.update_job(
        job_id,
        status=JobStatus.AWAITING_NAMES,
        transcript_txt_path=txt_path,
        transcript_srt_path=srt_path,
        speakers=job.speakers,
    )

    log.info(
        "Job %s ready for speaker naming. Found %d speakers.",
        job_id, len(speakers),
    )


# ── Render ────────────────────────────────────────────────────────────────────

def run_render(job_id: str) -> None:
    """
    Step 2 of the pipeline: apply speaker names to the SRT and render via ffmpeg.

    On success:   job.status → DONE
    On failure:   job.status → FAILED  (handled by JobManager._run_task)
    """
    job = job_manager.get_job(job_id)
    if job is None:
        log.error("run_render: job %s not found", job_id)
        return

    log.info("Starting render for job %s", job_id)

    name_map = {sp.speaker_id: sp.display_name for sp in job.get_speakers()}

    renamed_srt_path = str(job.job_dir / "transcript_named.srt")
    from services.srt_parser import apply_speaker_names
    apply_speaker_names(
        srt_path=job.transcript_srt_path,
        name_map=name_map,
        out_path=renamed_srt_path,
    )

    output_mp4 = str(job.job_dir / "output.mp4")
    from services.ffmpeg import render_subtitled_video
    render_subtitled_video(
        audio_path=job.audio_path,
        srt_path=renamed_srt_path,
        output_path=output_mp4,
    )

    job_manager.update_job(
        job_id,
        status=JobStatus.DONE,
        output_mp4_path=output_mp4,
    )

    log.info("Render complete for job %s → %s", job_id, output_mp4)
