#!/usr/bin/env bash
# setup.sh — scaffolds the transcriber project from scratch
# Usage:  bash setup.sh [target-directory]
set -e

TARGET="${1:-transcriber}"
echo "Creating project in ./$TARGET"

mkdir -p "$TARGET"/{jobs,routes,services,tasks,templates,static/{js,css},nginx,storage/tmp}

# app.py
cat > "$TARGET/app.py" << 'EOF_APP_PY'
"""
app.py — Flask application factory.

Import and call create_app() to get the configured Flask instance.
Both run.py (dev) and gunicorn (prod) use this.
"""

from flask import Flask

import config


def create_app() -> Flask:
    app = Flask(__name__)

    # ── Core config ───────────────────────────────────────────────────────────
    app.secret_key = config.SECRET_KEY
    app.debug = config.DEBUG
    app.config["MAX_CONTENT_LENGTH"] = config.MAX_UPLOAD_BYTES

    # ── Register blueprints ───────────────────────────────────────────────────
    # Blueprints are registered here as they are built in later steps.
    # Each import is guarded so the scaffold boots even before those files exist.

    try:
        from routes.upload import upload_bp
        app.register_blueprint(upload_bp)
    except ImportError:
        pass

    try:
        from routes.job import job_bp
        app.register_blueprint(job_bp)
    except ImportError:
        pass

    try:
        from routes.processing import processing_bp
        app.register_blueprint(processing_bp)
    except ImportError:
        pass

    try:
        from routes.download import download_bp
        app.register_blueprint(download_bp)
    except ImportError:
        pass

    # ── Health check ──────────────────────────────────────────────────────────
    @app.get("/health")
    def health():
        return {"status": "ok"}, 200

    return app
EOF_APP_PY

# config.py
cat > "$TARGET/config.py" << 'EOF_CONFIG_PY'
"""
config.py — Central application configuration.

Reads from environment variables (populated via .env in dev, real env in prod).
All other modules import from here — never read os.environ directly elsewhere.
"""

import os
from pathlib import Path

from dotenv import load_dotenv

# Load .env from the project root (no-op if already set in environment)
load_dotenv(Path(__file__).parent / ".env")


def _require(key: str) -> str:
    """Return env var or raise at startup — fail fast on missing config."""
    value = os.environ.get(key)
    if not value:
        raise RuntimeError(f"Required environment variable '{key}' is not set. See .env.example.")
    return value


def _int(key: str, default: int) -> int:
    return int(os.environ.get(key, default))


def _bool(key: str, default: bool) -> bool:
    return os.environ.get(key, str(int(default))).lower() in ("1", "true", "yes")


# ── Flask ─────────────────────────────────────────────────────────────────────

SECRET_KEY: str = _require("FLASK_SECRET_KEY")
FLASK_ENV: str = os.environ.get("FLASK_ENV", "production")
DEBUG: bool = _bool("FLASK_DEBUG", False)

# ── Server ────────────────────────────────────────────────────────────────────

GUNICORN_WORKERS: int = _int("GUNICORN_WORKERS", 4)
GUNICORN_PORT: int = _int("GUNICORN_PORT", 5000)

# ── Storage ───────────────────────────────────────────────────────────────────

# Absolute path to the storage root, resolved relative to project root
_PROJECT_ROOT = Path(__file__).parent
STORAGE_DIR: Path = (_PROJECT_ROOT / os.environ.get("STORAGE_DIR", "storage")).resolve()
TMP_DIR: Path = STORAGE_DIR / "tmp"

# Ensure storage directories exist at import time
STORAGE_DIR.mkdir(parents=True, exist_ok=True)
TMP_DIR.mkdir(parents=True, exist_ok=True)

# ── Job Expiry ────────────────────────────────────────────────────────────────

JOB_TTL_SECONDS: int = _int("JOB_TTL_SECONDS", 604800)  # 1 week

# ── External Commands ─────────────────────────────────────────────────────────

# WhisperX command template.
# Placeholders filled by services/whisperx.py: {input}, {output_dir}
WHISPERX_CMD: str = os.environ.get(
    "WHISPERX_CMD",
    "whisperx {input} --output_dir {output_dir} --output_format all",
)

# ffmpeg subtitle burn-in template.
# Placeholders filled by services/ffmpeg.py: {input}, {srt}, {output}
FFMPEG_CMD: str = os.environ.get(
    "FFMPEG_CMD",
    "ffmpeg -i {input} -vf subtitles={srt} {output}",
)

# ── Speaker Clips ─────────────────────────────────────────────────────────────

SPEAKER_CLIP_MAX_SECONDS: int = _int("SPEAKER_CLIP_MAX_SECONDS", 10)

# ── Upload ────────────────────────────────────────────────────────────────────

MAX_UPLOAD_BYTES: int = _int("MAX_UPLOAD_BYTES", 2 * 1024 * 1024 * 1024)  # 2GB
EOF_CONFIG_PY

# models.py
cat > "$TARGET/models.py" << 'EOF_MODELS_PY'
"""
models.py — Core data models for the transcriber app.

Job is the single source of truth for a transcription job. It is persisted
as job.json inside storage/<job_id>/ and loaded back on every request.
"""

import json
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Optional


# ── Status Enum ───────────────────────────────────────────────────────────────

class JobStatus(str, Enum):
    """
    Linear state machine for a transcription job.

        UPLOADING → TRANSCRIBING → AWAITING_NAMES → RENDERING → DONE

    The back button resets DONE → AWAITING_NAMES (deletes the MP4, re-enables
    speaker rename). FAILED is a terminal error state.
    """

    UPLOADING = "UPLOADING"
    TRANSCRIBING = "TRANSCRIBING"
    AWAITING_NAMES = "AWAITING_NAMES"
    RENDERING = "RENDERING"
    DONE = "DONE"
    FAILED = "FAILED"


# ── Speaker Model ─────────────────────────────────────────────────────────────

@dataclass
class Speaker:
    """
    One detected speaker from the WhisperX diarization output.

    speaker_id:   WhisperX label, e.g. "SPEAKER_00"
    display_name: User-provided name; defaults to speaker_id until renamed
    clip_path:    Relative path (from storage/<job_id>/) to the WAV clip used
                  for identification, e.g. "speaker_clips/SPEAKER_00.wav"
    """

    speaker_id: str
    display_name: str
    clip_path: Optional[str] = None

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Speaker":
        return cls(**data)


# ── Job Model ─────────────────────────────────────────────────────────────────

@dataclass
class Job:
    """
    Full state of a transcription job.

    Fields are intentionally flat so they serialise cleanly to/from JSON.
    Paths stored here are ABSOLUTE; they are re-resolved from config.STORAGE_DIR
    on deserialisation so the storage root can be remounted without breaking jobs.
    """

    # ── Identity ──────────────────────────────────────────────────────────────
    job_id: str
    original_filename: str

    # ── Lifecycle ─────────────────────────────────────────────────────────────
    status: JobStatus = JobStatus.UPLOADING
    created_at: str = field(default_factory=lambda: _utcnow_iso())
    updated_at: str = field(default_factory=lambda: _utcnow_iso())

    # ── File Paths (absolute) ─────────────────────────────────────────────────
    # Set after upload assembly completes
    audio_path: Optional[str] = None

    # Set after WhisperX completes
    transcript_txt_path: Optional[str] = None
    transcript_srt_path: Optional[str] = None

    # Set after rendering completes
    output_mp4_path: Optional[str] = None

    # ── Speakers ──────────────────────────────────────────────────────────────
    # Populated after SRT parsing; each entry is a Speaker dict
    speakers: list = field(default_factory=list)

    # ── Error ─────────────────────────────────────────────────────────────────
    # Human-readable message set on FAILED
    error: Optional[str] = None

    # ── Helpers ───────────────────────────────────────────────────────────────

    @property
    def job_dir(self) -> Path:
        """Absolute path to this job's storage directory."""
        from config import STORAGE_DIR
        return STORAGE_DIR / self.job_id

    @property
    def speaker_clips_dir(self) -> Path:
        return self.job_dir / "speaker_clips"

    def get_speakers(self) -> list["Speaker"]:
        """Return speakers as Speaker objects (they are stored as dicts in JSON)."""
        return [Speaker.from_dict(s) for s in self.speakers]

    def set_speakers(self, speakers: list["Speaker"]) -> None:
        self.speakers = [s.to_dict() for s in speakers]

    def touch(self) -> None:
        """Update updated_at to now."""
        self.updated_at = _utcnow_iso()

    # ── Serialisation ─────────────────────────────────────────────────────────

    def to_dict(self) -> dict:
        d = asdict(self)
        d["status"] = self.status.value  # enum → string
        return d

    def save(self) -> None:
        """Persist the job to job.json inside its storage directory."""
        self.touch()
        self.job_dir.mkdir(parents=True, exist_ok=True)
        job_file = self.job_dir / "job.json"
        job_file.write_text(json.dumps(self.to_dict(), indent=2))

    @classmethod
    def from_dict(cls, data: dict) -> "Job":
        data = dict(data)  # don't mutate caller's dict
        data["status"] = JobStatus(data["status"])
        return cls(**data)

    @classmethod
    def load(cls, job_id: str) -> Optional["Job"]:
        """
        Load a Job from disk. Returns None if the job directory or job.json
        does not exist (caller should treat as 404).
        """
        from config import STORAGE_DIR
        job_file = STORAGE_DIR / job_id / "job.json"
        if not job_file.exists():
            return None
        data = json.loads(job_file.read_text())
        return cls.from_dict(data)


# ── Utility ───────────────────────────────────────────────────────────────────

def _utcnow_iso() -> str:
    """Current UTC time as an ISO-8601 string."""
    return datetime.now(timezone.utc).isoformat()
EOF_MODELS_PY

# run.py
cat > "$TARGET/run.py" << 'EOF_RUN_PY'
"""
run.py — Development entry point.

Usage:
    python run.py

This starts Flask's built-in dev server with reloading enabled.
For production, use gunicorn directly (see README).
"""

from app import create_app
import config

if __name__ == "__main__":
    app = create_app()
    app.run(
        host="0.0.0.0",
        port=config.GUNICORN_PORT,
        debug=config.DEBUG,
        use_reloader=config.DEBUG,
    )
EOF_RUN_PY

# requirements.txt
cat > "$TARGET/requirements.txt" << 'EOF_REQUIREMENTS_TXT'
# Web framework
flask>=3.0,<4.0
gunicorn>=21.0,<22.0

# Environment variable loading
python-dotenv>=1.0,<2.0

# Note: WhisperX is called via subprocess (not imported), so it is not listed here.
# It must be installed in the execution environment separately.
# See DOCKER_DEPLOYMENT.md for the Dockerfile install sequence.
EOF_REQUIREMENTS_TXT

# jobs/__init__.py
touch "$TARGET/jobs/__init__.py"

# jobs/manager.py
cat > "$TARGET/jobs/manager.py" << 'EOF_JOBS_MANAGER_PY'
"""
jobs/manager.py — JobManager

Single interface for all job lifecycle operations. The rest of the app
never touches job.json directly — it goes through this class.

Celery upgrade path
-------------------
Only JobManager.submit_task() needs to change. Today it spawns a daemon
thread; swapping to Celery means replacing that one method body:

    # Today (threading):
    threading.Thread(target=task_fn, args=(job_id, *args), daemon=True).start()

    # Celery (future):
    celery_task.delay(job_id, *args)

Everything else — routes, services, tests — remains unchanged.
"""

import threading
import uuid
from typing import Callable, Optional

from models import Job, JobStatus


class JobManager:
    """
    Manages the lifecycle of transcription jobs.

    All methods are thread-safe for concurrent gunicorn workers because
    the unit of persistence is a single file (job.json) written atomically,
    and job state transitions are append-only from the perspective of each
    background worker.
    """

    # ── Factory / Retrieval ───────────────────────────────────────────────────

    def create_job(self, filename: str) -> Job:
        """
        Create a new job, persist it, and return the Job object.

        The job starts in UPLOADING status. The caller (upload route) is
        responsible for assembling chunks and then calling update_job() to
        advance the status and set audio_path.
        """
        job_id = str(uuid.uuid4())
        job = Job(job_id=job_id, original_filename=filename)
        job.save()
        return job

    def get_job(self, job_id: str) -> Optional[Job]:
        """
        Load a job from disk. Returns None if the job does not exist.

        Callers should treat None as a 404.
        """
        return Job.load(job_id)

    def update_job(self, job_id: str, **kwargs) -> None:
        """
        Load a job, apply keyword-argument updates, and re-persist it.

        Example:
            manager.update_job(job_id, status=JobStatus.TRANSCRIBING)
            manager.update_job(job_id, audio_path="/storage/abc/audio.mp3")

        Raises ValueError if the job does not exist.
        """
        job = self.get_job(job_id)
        if job is None:
            raise ValueError(f"Job '{job_id}' not found")

        for key, value in kwargs.items():
            if not hasattr(job, key):
                raise ValueError(f"Job has no attribute '{key}'")
            setattr(job, key, value)

        job.save()

    # ── Task Submission ───────────────────────────────────────────────────────

    def submit_task(self, job_id: str, task_fn: Callable, *args) -> None:
        """
        Submit a background task for a job.

        TODAY: Runs task_fn in a daemon thread.
        CELERY UPGRADE: Replace this method body only. All callers stay the same.

        task_fn signature must be: task_fn(job_id: str, *args) -> None
        The task is responsible for updating job status via update_job().
        """
        thread = threading.Thread(
            target=self._run_task,
            args=(job_id, task_fn, *args),
            daemon=True,
            name=f"job-{job_id[:8]}",
        )
        thread.start()

    def _run_task(self, job_id: str, task_fn: Callable, *args) -> None:
        """
        Wrapper that catches unhandled exceptions from task_fn and marks the
        job as FAILED so the frontend doesn't poll forever.
        """
        try:
            task_fn(job_id, *args)
        except Exception as exc:
            import traceback
            error_msg = f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}"
            try:
                self.update_job(job_id, status=JobStatus.FAILED, error=error_msg)
            except Exception:
                pass  # best-effort; don't mask the original error in logs
            raise


# ── Module-level singleton ────────────────────────────────────────────────────
# Import this instance everywhere: `from jobs.manager import job_manager`

job_manager = JobManager()
EOF_JOBS_MANAGER_PY

# jobs/runner.py
cat > "$TARGET/jobs/runner.py" << 'EOF_JOBS_RUNNER_PY'
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
EOF_JOBS_RUNNER_PY

# routes/__init__.py
touch "$TARGET/routes/__init__.py"

# routes/upload.py
cat > "$TARGET/routes/upload.py" << 'EOF_ROUTES_UPLOAD_PY'
"""
routes/upload.py — Chunked file upload handling for Dropzone.js.

Dropzone sends multipart POST requests, one chunk at a time, with these fields:
  - file:             the chunk bytes
  - dzuuid:           unique upload session ID (same for all chunks of one file)
  - dzchunkindex:     0-based index of this chunk
  - dztotalchunkcount: total number of chunks
  - dzfilename:       original filename

NOTE: When a file is smaller than the configured chunkSize, Dropzone sends it
as a single non-chunked POST with no dz* metadata fields at all. Both cases
are handled below.

Chunks are written to storage/tmp/<dzuuid>/<index>.part and assembled in order
once the final chunk arrives. The temp directory is deleted after assembly.
"""

import uuid
import shutil
from pathlib import Path

from flask import Blueprint, jsonify, render_template, request, url_for

import config
from jobs.manager import job_manager
from models import JobStatus

upload_bp = Blueprint("upload", __name__)


# ── Upload Page ───────────────────────────────────────────────────────────────

@upload_bp.get("/")
def index():
    return render_template("upload.html", max_upload_mb=config.MAX_UPLOAD_BYTES // (1024 * 1024))


# ── Chunked Upload Endpoint ───────────────────────────────────────────────────

@upload_bp.post("/upload")
def upload_chunk():
    """
    Receive one chunk (or a complete file) from Dropzone.js.

    On the final chunk, assemble the file, create a Job, and return the job URL
    so the frontend can redirect to the processing page.
    """
    chunk = request.files.get("file")
    if chunk is None:
        return jsonify({"error": "No file in request"}), 400

    dz_uuid       = request.form.get("dzuuid", "").strip()
    chunk_index   = int(request.form.get("dzchunkindex", 0))
    total_chunks  = int(request.form.get("dztotalchunkcount", 1))
    original_name = request.form.get("dzfilename", "").strip() or (chunk.filename or "upload")

    # ── Single-shot upload (file smaller than chunkSize) ──────────────────────
    # Dropzone omits all dz* fields when no chunking is needed.
    if not dz_uuid:
        dz_uuid = str(uuid.uuid4())
        chunk_dir = config.TMP_DIR / dz_uuid
        chunk_dir.mkdir(parents=True, exist_ok=True)
        (chunk_dir / "0.part").write_bytes(chunk.read())
        try:
            job = _assemble_upload(chunk_dir, 1, original_name)
        except Exception as exc:
            _cleanup_chunk_dir(chunk_dir)
            return jsonify({"error": f"Assembly failed: {exc}"}), 500
        _cleanup_chunk_dir(chunk_dir)
        return jsonify({
            "status": "complete",
            "job_id": job.job_id,
            "redirect": url_for("job.processing_status", job_id=job.job_id),
        }), 200

    # ── Chunked upload ────────────────────────────────────────────────────────
    chunk_dir = config.TMP_DIR / dz_uuid
    chunk_dir.mkdir(parents=True, exist_ok=True)
    part_path = chunk_dir / f"{chunk_index}.part"
    chunk.save(str(part_path))

    # Not all chunks received yet — acknowledge and wait
    received = len(list(chunk_dir.glob("*.part")))
    if received < total_chunks:
        return jsonify({"status": "chunk_received", "received": received, "total": total_chunks}), 200

    # All chunks present — assemble
    try:
        job = _assemble_upload(chunk_dir, total_chunks, original_name)
    except Exception as exc:
        _cleanup_chunk_dir(chunk_dir)
        return jsonify({"error": f"Assembly failed: {exc}"}), 500

    _cleanup_chunk_dir(chunk_dir)

    return jsonify({
        "status": "complete",
        "job_id": job.job_id,
        "redirect": url_for("job.processing_status", job_id=job.job_id),
    }), 200


# ── Assembly Helpers ──────────────────────────────────────────────────────────

def _assemble_upload(chunk_dir: Path, total_chunks: int, original_name: str):
    """
    Concatenate all .part files in order into a single audio file,
    create a Job record, and kick off transcription.

    Returns the newly created Job.
    """
    job = job_manager.create_job(original_name)
    job_dir = job.job_dir
    job_dir.mkdir(parents=True, exist_ok=True)

    safe_name = _safe_filename(original_name)
    dest_path = job_dir / safe_name

    with open(dest_path, "wb") as out:
        for i in range(total_chunks):
            part = chunk_dir / f"{i}.part"
            out.write(part.read_bytes())

    job_manager.update_job(
        job.job_id,
        status=JobStatus.TRANSCRIBING,
        audio_path=str(dest_path),
    )

    from jobs.runner import run_transcription
    job_manager.submit_task(job.job_id, run_transcription)

    return job_manager.get_job(job.job_id)


def _cleanup_chunk_dir(chunk_dir: Path) -> None:
    """Delete the temp chunk directory after assembly (or on failure)."""
    try:
        shutil.rmtree(chunk_dir, ignore_errors=True)
    except Exception:
        pass


def _safe_filename(name: str) -> str:
    """Strip path components and replace dangerous characters."""
    name = Path(name).name
    safe = "".join(c if c.isalnum() or c in "._- " else "_" for c in name)
    return safe or "upload"
EOF_ROUTES_UPLOAD_PY

# routes/job.py
cat > "$TARGET/routes/job.py" << 'EOF_ROUTES_JOB_PY'
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
EOF_ROUTES_JOB_PY

# routes/processing.py
cat > "$TARGET/routes/processing.py" << 'EOF_ROUTES_PROCESSING_PY'
"""
routes/processing.py — Render processing and back-navigation.

  POST /job/<job_id>/back   — Delete MP4, reset status to AWAITING_NAMES
"""

from flask import Blueprint, jsonify, url_for
from jobs.manager import job_manager
from models import JobStatus
import os

processing_bp = Blueprint("processing", __name__, url_prefix="/job")


@processing_bp.post("/<job_id>/back")
def go_back(job_id: str):
    """
    User clicked Back from the download page.

    Deletes the rendered MP4 and resets status to AWAITING_NAMES so the
    user can re-enter speaker names and re-render.
    """
    job = job_manager.get_job(job_id)
    if job is None:
        return jsonify({"error": "not_found"}), 404

    # Delete the MP4 if it exists
    if job.output_mp4_path:
        try:
            os.remove(job.output_mp4_path)
        except FileNotFoundError:
            pass

    job_manager.update_job(
        job_id,
        status=JobStatus.AWAITING_NAMES,
        output_mp4_path=None,
    )

    return jsonify({
        "status": "reset",
        "redirect": url_for("job.speakers", job_id=job_id),
    }), 200
EOF_ROUTES_PROCESSING_PY

# routes/download.py
cat > "$TARGET/routes/download.py" << 'EOF_ROUTES_DOWNLOAD_PY'
"""
routes/download.py — Final download page, MP4 streaming, and transcript download.

  GET /job/<job_id>/download     — Download page (with embedded player)
  GET /job/<job_id>/file         — Stream the rendered MP4
  GET /job/<job_id>/transcript   — Download the .txt transcript
"""

from pathlib import Path

from flask import Blueprint, abort, render_template, send_file, url_for

from jobs.manager import job_manager
from models import JobStatus

download_bp = Blueprint("download", __name__, url_prefix="/job")


@download_bp.get("/<job_id>/download")
def download_page(job_id: str):
    job = job_manager.get_job(job_id)
    if job is None:
        abort(404)
    if job.status != JobStatus.DONE:
        from flask import redirect
        return redirect(url_for("job.processing_status", job_id=job_id))
    return render_template("download.html", job=job)


@download_bp.get("/<job_id>/file")
def download_file(job_id: str):
    """
    Stream the rendered MP4.

    Served without as_attachment so the browser can play it inline in the
    <video> element. The HTML download attribute on the <a> tag handles
    triggering a save dialog when the user clicks Download.
    """
    job = job_manager.get_job(job_id)
    if job is None:
        abort(404)
    if job.status != JobStatus.DONE or not job.output_mp4_path:
        abort(404)

    path = Path(job.output_mp4_path)
    if not path.exists():
        abort(404)

    return send_file(
        str(path),
        mimetype="video/mp4",
        as_attachment=False,          # allows <video> streaming
        download_name=f"{path.stem}_subtitled.mp4",
        conditional=True,             # supports Range requests for seeking
    )


@download_bp.get("/<job_id>/transcript")
def download_transcript(job_id: str):
    """Download the plain-text transcript (.txt) as an attachment."""
    job = job_manager.get_job(job_id)
    if job is None:
        abort(404)
    if job.status != JobStatus.DONE or not job.transcript_txt_path:
        abort(404)

    path = Path(job.transcript_txt_path)
    if not path.exists():
        abort(404)

    stem = Path(job.original_filename).stem
    return send_file(
        str(path),
        mimetype="text/plain",
        as_attachment=True,
        download_name=f"{stem}_transcript.txt",
    )
EOF_ROUTES_DOWNLOAD_PY

# services/__init__.py
touch "$TARGET/services/__init__.py"

# services/whisperx.py
cat > "$TARGET/services/whisperx.py" << 'EOF_SERVICES_WHISPERX_PY'
"""
services/whisperx.py — WhisperX transcription via subprocess.

Runs the WHISPERX_CMD template from config, substituting {input} and
{output_dir}. Expects WhisperX to produce at minimum:
  <output_dir>/<stem>.srt
  <output_dir>/<stem>.txt

Raises RuntimeError on non-zero exit.
"""

import shlex
import subprocess
from pathlib import Path

import config


def run_whisperx(audio_path: str, output_dir: str) -> dict:
    """
    Run WhisperX on the given audio file.

    Args:
        audio_path:  Absolute path to the source audio/video file.
        output_dir:  Directory where WhisperX should write its output files.

    Returns:
        {
          "txt_path": str,   # absolute path to the .txt transcript
          "srt_path": str,   # absolute path to the .srt transcript
        }

    Raises:
        RuntimeError: if WhisperX exits non-zero or expected output files
                      are not found.
    """
    audio_path = str(audio_path)
    output_dir = str(output_dir)

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    cmd_str = config.WHISPERX_CMD.format(
        input=audio_path,
        output_dir=output_dir,
    )
    cmd = shlex.split(cmd_str)

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"WhisperX failed (exit {result.returncode}):\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )

    # Locate output files — WhisperX names them after the input stem
    stem = Path(audio_path).stem
    out = Path(output_dir)

    txt_path = out / f"{stem}.txt"
    srt_path = out / f"{stem}.srt"

    if not srt_path.exists():
        raise RuntimeError(
            f"WhisperX did not produce expected SRT file at {srt_path}.\n"
            f"Files in output_dir: {list(out.iterdir())}"
        )

    if not txt_path.exists():
        raise RuntimeError(
            f"WhisperX did not produce expected TXT file at {txt_path}.\n"
            f"Files in output_dir: {list(out.iterdir())}"
        )

    return {
        "txt_path": str(txt_path),
        "srt_path": str(srt_path),
    }
EOF_SERVICES_WHISPERX_PY

# services/srt_parser.py
cat > "$TARGET/services/srt_parser.py" << 'EOF_SERVICES_SRT_PARSER_PY'
"""
services/srt_parser.py — Parse WhisperX SRT output into structured segments.

WhisperX SRT format example:

    1
    00:00:01,000 --> 00:00:04,500
    [SPEAKER_00]: Hello, welcome to the show.

    2
    00:00:05,000 --> 00:00:08,200
    [SPEAKER_01]: Thanks for having me.

Each subtitle block may or may not have a [SPEAKER_XX]: prefix.
Blocks without a speaker label are assigned speaker=None.
"""

import re
from pathlib import Path
from typing import Optional


# Matches "[SPEAKER_00]:" at the start of a subtitle line (with optional space after colon)
_SPEAKER_RE = re.compile(r"^\[([A-Z_0-9]+)\]:\s*")

# Matches SRT timestamp line: 00:00:01,000 --> 00:00:04,500
_TIMESTAMP_RE = re.compile(
    r"^(\d{2}):(\d{2}):(\d{2}),(\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2}),(\d{3})$"
)


def parse_srt(srt_path: str) -> list[dict]:
    """
    Parse a WhisperX SRT file into a list of segment dicts.

    Returns:
        [
          {
            "index":    int,            # 1-based subtitle index
            "start":    float,          # start time in seconds
            "end":      float,          # end time in seconds
            "speaker":  str | None,     # e.g. "SPEAKER_00" or None
            "text":     str,            # cleaned text without speaker prefix
          },
          ...
        ]
    """
    text = Path(srt_path).read_text(encoding="utf-8", errors="replace")
    blocks = _split_blocks(text)
    segments = []
    for block in blocks:
        seg = _parse_block(block)
        if seg is not None:
            segments.append(seg)
    return segments


def get_speakers(segments: list[dict]) -> list[str]:
    """
    Return a sorted, deduplicated list of speaker IDs found in the segments.
    Segments with speaker=None are ignored.
    """
    seen = set()
    result = []
    for seg in segments:
        sp = seg.get("speaker")
        if sp and sp not in seen:
            seen.add(sp)
            result.append(sp)
    return sorted(result)


def segments_for_speaker(segments: list[dict], speaker_id: str) -> list[dict]:
    """Return only segments belonging to the given speaker."""
    return [s for s in segments if s.get("speaker") == speaker_id]


def apply_speaker_names(srt_path: str, name_map: dict, out_path: str) -> None:
    """
    Write a new SRT file replacing [SPEAKER_XX]: prefixes with display names.

    Args:
        srt_path:  Input SRT path (WhisperX output).
        name_map:  { "SPEAKER_00": "Alice", "SPEAKER_01": "Bob", ... }
        out_path:  Where to write the renamed SRT.
    """
    text = Path(srt_path).read_text(encoding="utf-8", errors="replace")
    blocks = _split_blocks(text)
    output_blocks = []

    for block in blocks:
        lines = block.strip().splitlines()
        if len(lines) < 3:
            output_blocks.append(block)
            continue

        # Lines: 0=index, 1=timestamp, 2+=text (may span multiple lines)
        renamed_text_lines = []
        for line in lines[2:]:
            m = _SPEAKER_RE.match(line)
            if m:
                speaker_id = m.group(1)
                display = name_map.get(speaker_id, speaker_id)
                rest = line[m.end():]
                renamed_text_lines.append(f"{display}: {rest}")
            else:
                renamed_text_lines.append(line)

        output_blocks.append(
            "\n".join(lines[:2] + renamed_text_lines)
        )

    Path(out_path).write_text("\n\n".join(output_blocks) + "\n", encoding="utf-8")


# ── Internal helpers ──────────────────────────────────────────────────────────

def _split_blocks(text: str) -> list[str]:
    """Split SRT text into individual subtitle blocks (separated by blank lines)."""
    return [b.strip() for b in re.split(r"\n\s*\n", text) if b.strip()]


def _parse_block(block: str) -> Optional[dict]:
    lines = block.strip().splitlines()
    if len(lines) < 3:
        return None

    # Line 0: subtitle index
    try:
        index = int(lines[0].strip())
    except ValueError:
        return None

    # Line 1: timestamps
    m = _TIMESTAMP_RE.match(lines[1].strip())
    if not m:
        return None
    h1, m1, s1, ms1, h2, m2, s2, ms2 = (int(x) for x in m.groups())
    start = h1 * 3600 + m1 * 60 + s1 + ms1 / 1000
    end   = h2 * 3600 + m2 * 60 + s2 + ms2 / 1000

    # Lines 2+: text content (may span multiple lines)
    raw_text = " ".join(lines[2:]).strip()

    # Extract speaker prefix if present
    speaker = None
    text = raw_text
    sm = _SPEAKER_RE.match(raw_text)
    if sm:
        speaker = sm.group(1)
        text = raw_text[sm.end():].strip()

    return {
        "index":   index,
        "start":   start,
        "end":     end,
        "speaker": speaker,
        "text":    text,
    }
EOF_SERVICES_SRT_PARSER_PY

# services/audio_clip.py
cat > "$TARGET/services/audio_clip.py" << 'EOF_SERVICES_AUDIO_CLIP_PY'
"""
services/audio_clip.py — Extract short WAV clips for speaker identification.

Uses ffmpeg via subprocess to cut a segment from the source audio.

Clip selection logic (per HANDOFF.md):
  - First play (avoid_longest=False):  use the speaker's LONGEST segment
  - Regenerate   (avoid_longest=True): use a random segment, excluding the longest

Clip length is capped at config.SPEAKER_CLIP_MAX_SECONDS, centred within the
chosen segment.
"""

import random
import subprocess
from pathlib import Path
from typing import Optional

import config


def extract_all_speaker_clips(
    audio_path: str,
    segments: list[dict],
    job_dir: str,
) -> dict:
    """
    Extract one clip per speaker found in segments.

    Args:
        audio_path:  Source audio file.
        segments:    Parsed SRT segments (from srt_parser.parse_srt).
        job_dir:     Job storage directory (clips saved to <job_dir>/speaker_clips/).

    Returns:
        { "SPEAKER_00": "/abs/path/to/SPEAKER_00.wav", ... }
    """
    from services.srt_parser import get_speakers, segments_for_speaker

    clips_dir = Path(job_dir) / "speaker_clips"
    clips_dir.mkdir(parents=True, exist_ok=True)

    result = {}
    for speaker_id in get_speakers(segments):
        speaker_segs = segments_for_speaker(segments, speaker_id)
        clip_path = extract_speaker_clip(
            audio_path=audio_path,
            segments=speaker_segs,
            speaker_id=speaker_id,
            job_dir=job_dir,
            avoid_longest=False,
        )
        result[speaker_id] = clip_path

    return result


def extract_speaker_clip(
    audio_path: str,
    segments: list[dict],
    speaker_id: str,
    job_dir: str,
    avoid_longest: bool = False,
) -> str:
    """
    Extract a single WAV clip for one speaker.

    Args:
        audio_path:    Source audio.
        segments:      This speaker's segments only.
        speaker_id:    Used for the output filename.
        job_dir:       Job directory root.
        avoid_longest: If True, exclude the longest segment when picking.
                       Used by the Regenerate button.

    Returns:
        Absolute path to the written WAV file.
    """
    if not segments:
        raise ValueError(f"No segments provided for {speaker_id}")

    segment = _pick_segment(segments, avoid_longest=avoid_longest)
    start, end = _clip_window(segment["start"], segment["end"])

    clips_dir = Path(job_dir) / "speaker_clips"
    clips_dir.mkdir(parents=True, exist_ok=True)
    out_path = clips_dir / f"{speaker_id}.wav"

    _ffmpeg_extract(audio_path, start, end - start, str(out_path))
    return str(out_path)


# ── Helpers ───────────────────────────────────────────────────────────────────

# Minimum segment duration (seconds) worth using as an identification clip.
# Segments shorter than this are skipped during random selection.
_MIN_SEGMENT_SECONDS = 2.0


def _pick_segment(segments: list[dict], avoid_longest: bool) -> dict:
    """
    Pick which segment to use for the clip.

    avoid_longest=False -> longest segment (most speech content)
    avoid_longest=True  -> random segment that is:
                            1. not the longest
                            2. at least _MIN_SEGMENT_SECONDS long
                          Falls back to next-longest if no such segment exists.
    """
    if len(segments) == 1:
        return segments[0]

    # Sort by duration descending so fallbacks are always the best available
    by_duration = sorted(segments, key=lambda s: s["end"] - s["start"], reverse=True)
    longest = by_duration[0]

    if not avoid_longest:
        return longest

    # Candidates: not the longest AND long enough to be useful
    candidates = [
        s for s in by_duration[1:]
        if (s["end"] - s["start"]) >= _MIN_SEGMENT_SECONDS
    ]

    if candidates:
        return random.choice(candidates)

    # Nothing long enough besides the longest -- return next best
    if len(by_duration) > 1:
        return by_duration[1]

    return longest


def _clip_window(start: float, end: float) -> tuple[float, float]:
    """
    Return (clip_start, clip_end) capped at SPEAKER_CLIP_MAX_SECONDS,
    centred within the segment.
    """
    max_len = float(config.SPEAKER_CLIP_MAX_SECONDS)
    seg_len = end - start

    if seg_len <= max_len:
        return start, end

    # Centre the clip within the segment
    excess = seg_len - max_len
    clip_start = start + excess / 2
    clip_end = clip_start + max_len
    return clip_start, clip_end


def _ffmpeg_extract(audio_path: str, start: float, duration: float, out_path: str) -> None:
    """
    Run ffmpeg to cut [start, start+duration] from audio_path into out_path (WAV).
    Raises RuntimeError on non-zero exit.
    """
    cmd = [
        "ffmpeg",
        "-y",                        # overwrite output without asking
        "-ss", str(start),
        "-t",  str(duration),
        "-i",  audio_path,
        "-ac", "1",                  # mono
        "-ar", "16000",              # 16 kHz — good for speech playback
        out_path,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        raise RuntimeError(
            f"ffmpeg clip extraction failed (exit {result.returncode}):\n"
            f"stderr: {result.stderr}"
        )
EOF_SERVICES_AUDIO_CLIP_PY

# services/ffmpeg.py
cat > "$TARGET/services/ffmpeg.py" << 'EOF_SERVICES_FFMPEG_PY'
"""
services/ffmpeg.py — Render subtitled MP4 via ffmpeg subprocess.

Uses the FFMPEG_CMD template from config, substituting {input}, {srt}, {output}.
"""

import shlex
import subprocess
from pathlib import Path

import config


def render_subtitled_video(
    audio_path: str,
    srt_path: str,
    output_path: str,
) -> str:
    """
    Burn subtitles into a video/audio file using ffmpeg.

    Args:
        audio_path:   Source audio (or video) file.
        srt_path:     SRT file with renamed speaker labels.
        output_path:  Destination MP4 path.

    Returns:
        output_path (for chaining convenience).

    Raises:
        RuntimeError: if ffmpeg exits non-zero.
    """
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)

    cmd_str = config.FFMPEG_CMD.format(
        input=audio_path,
        srt=srt_path,
        output=output_path,
    )
    cmd = shlex.split(cmd_str)

    # Prepend -y to overwrite output without prompting (not in template to keep
    # the template user-configurable, so we inject it here)
    if cmd[0] == "ffmpeg" and "-y" not in cmd:
        cmd.insert(1, "-y")

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        raise RuntimeError(
            f"ffmpeg render failed (exit {result.returncode}):\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )

    return output_path
EOF_SERVICES_FFMPEG_PY

# tasks/__init__.py
touch "$TARGET/tasks/__init__.py"

# tasks/expiry.py
cat > "$TARGET/tasks/expiry.py" << 'EOF_TASKS_EXPIRY_PY'
"""
tasks/expiry.py — Job expiry sweep.

Deletes job directories (and all their files) for jobs older than
config.JOB_TTL_SECONDS (default: 1 week).

This script is designed to be run from cron or supervisord on an hourly schedule:

    # crontab entry
    0 * * * * cd /app && python -m tasks.expiry >> /var/log/expiry.log 2>&1

    # supervisord entry (see supervisord.conf)
    [program:expiry]
    command=python -m tasks.expiry
    ...

It can also be imported and called directly:
    from tasks.expiry import run_expiry_sweep
    run_expiry_sweep()
"""

import logging
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path

import config
from models import Job

log = logging.getLogger(__name__)


def run_expiry_sweep() -> dict:
    """
    Scan all job directories and delete expired ones.

    A job is expired if its created_at timestamp is older than JOB_TTL_SECONDS.
    Jobs with a missing or unparseable job.json are also deleted (orphaned dirs).

    Returns:
        { "scanned": int, "deleted": int, "errors": int }
    """
    scanned = 0
    deleted = 0
    errors  = 0
    now     = time.time()
    cutoff  = now - config.JOB_TTL_SECONDS

    storage = config.STORAGE_DIR
    if not storage.exists():
        log.info("Storage directory does not exist; nothing to sweep.")
        return {"scanned": 0, "deleted": 0, "errors": 0}

    for job_dir in storage.iterdir():
        if not job_dir.is_dir():
            continue
        # Skip the tmp dir — that's managed by the upload route
        if job_dir.name == "tmp":
            continue

        scanned += 1
        job_file = job_dir / "job.json"

        if not job_file.exists():
            # Orphaned directory — delete it
            log.warning("Orphaned job dir (no job.json): %s", job_dir)
            _delete_dir(job_dir)
            deleted += 1
            continue

        try:
            job = Job.load(job_dir.name)
            if job is None:
                raise ValueError("Job.load returned None")

            created_ts = _parse_iso(job.created_at)
            if created_ts is None or created_ts < cutoff:
                log.info(
                    "Expiring job %s (created %s, TTL %ds)",
                    job.job_id, job.created_at, config.JOB_TTL_SECONDS,
                )
                _delete_dir(job_dir)
                deleted += 1

        except Exception as exc:
            log.error("Error processing job dir %s: %s", job_dir, exc)
            errors += 1

    log.info(
        "Expiry sweep complete: scanned=%d deleted=%d errors=%d",
        scanned, deleted, errors,
    )
    return {"scanned": scanned, "deleted": deleted, "errors": errors}


def _delete_dir(path: Path) -> None:
    """Remove a directory tree, ignoring errors."""
    try:
        shutil.rmtree(path)
    except Exception as exc:
        log.error("Failed to delete %s: %s", path, exc)


def _parse_iso(ts: str) -> float | None:
    """Parse an ISO-8601 timestamp string to a POSIX timestamp, or None."""
    try:
        dt = datetime.fromisoformat(ts)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    result = run_expiry_sweep()
    print(result)
EOF_TASKS_EXPIRY_PY

# templates/base.html
cat > "$TARGET/templates/base.html" << 'EOF_TEMPLATES_BASE_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}Transcriber{% endblock %}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@300;400;500&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:        #0d0d0d;
      --surface:   #161616;
      --border:    #2a2a2a;
      --accent:    #e8ff47;
      --accent2:   #47ffe8;
      --text:      #e8e8e8;
      --muted:     #666;
      --danger:    #ff4747;
      --mono:      'IBM Plex Mono', monospace;
      --sans:      'IBM Plex Sans', sans-serif;
      --radius:    4px;
    }

    html, body {
      height: 100%;
      background: var(--bg);
      color: var(--text);
      font-family: var(--sans);
      font-size: 15px;
      line-height: 1.6;
    }

    /* Subtle grid texture */
    body::before {
      content: '';
      position: fixed;
      inset: 0;
      background-image:
        linear-gradient(rgba(255,255,255,.015) 1px, transparent 1px),
        linear-gradient(90deg, rgba(255,255,255,.015) 1px, transparent 1px);
      background-size: 40px 40px;
      pointer-events: none;
      z-index: 0;
    }

    .page {
      position: relative;
      z-index: 1;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }

    header {
      border-bottom: 1px solid var(--border);
      padding: 18px 32px;
      display: flex;
      align-items: center;
      gap: 12px;
    }

    .logo {
      text-decoration: none;
      font-family: var(--mono);
      font-size: 13px;
      font-weight: 600;
      letter-spacing: .12em;
      text-transform: uppercase;
      color: var(--accent);
    }

    .logo span { color: var(--muted); }

    main {
      flex: 1;
      max-width: 800px;
      width: 100%;
      margin: 0 auto;
      padding: 48px 32px;
    }

    h1 {
      font-family: var(--mono);
      font-size: 22px;
      font-weight: 600;
      letter-spacing: .04em;
      margin-bottom: 8px;
    }

    .subtitle {
      font-size: 14px;
      color: var(--muted);
      margin-bottom: 40px;
    }

    /* Buttons */
    .btn {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-family: var(--mono);
      font-size: 13px;
      font-weight: 500;
      letter-spacing: .06em;
      text-transform: uppercase;
      padding: 10px 20px;
      border-radius: var(--radius);
      border: none;
      cursor: pointer;
      transition: opacity .15s, transform .1s;
      text-decoration: none;
    }
    .btn:active { transform: scale(.98); }
    .btn-primary { background: var(--accent); color: #000; }
    .btn-primary:hover { opacity: .88; }
    .btn-secondary { background: transparent; color: var(--text); border: 1px solid var(--border); }
    .btn-secondary:hover { border-color: var(--muted); }
    .btn-danger { background: var(--danger); color: #fff; }
    .btn-danger:hover { opacity: .85; }
    .btn:disabled { opacity: .35; cursor: not-allowed; }

    /* Cards */
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 24px;
    }

    /* Status badge */
    .status-badge {
      display: inline-block;
      font-family: var(--mono);
      font-size: 11px;
      letter-spacing: .1em;
      text-transform: uppercase;
      padding: 3px 8px;
      border-radius: 2px;
      background: var(--border);
      color: var(--muted);
    }
    .status-badge.active   { background: rgba(232,255,71,.15); color: var(--accent); }
    .status-badge.done     { background: rgba(71,255,232,.15); color: var(--accent2); }
    .status-badge.error    { background: rgba(255,71,71,.15);  color: var(--danger); }

    /* Flash / error box */
    .alert {
      padding: 14px 18px;
      border-radius: var(--radius);
      font-size: 14px;
      margin-bottom: 20px;
    }
    .alert-error { background: rgba(255,71,71,.1); border: 1px solid rgba(255,71,71,.3); color: #ff9090; }

    /* Monospace labels */
    .label {
      font-family: var(--mono);
      font-size: 11px;
      letter-spacing: .08em;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 6px;
    }
  </style>
  {% block head %}{% endblock %}
</head>
<body>
<div class="page">
  <header>
    <a href="/" class="logo">Trans<span>//</span>criber</a>
  </header>
  <main>
    {% block content %}{% endblock %}
  </main>
</div>
{% block scripts %}{% endblock %}
</body>
</html>
EOF_TEMPLATES_BASE_HTML

# templates/upload.html
cat > "$TARGET/templates/upload.html" << 'EOF_TEMPLATES_UPLOAD_HTML'
{% extends "base.html" %}
{% block title %}Upload — Transcriber{% endblock %}

{% block head %}
<script src="https://cdnjs.cloudflare.com/ajax/libs/dropzone/5.9.3/dropzone.min.js"></script>
<style>
  .upload-zone {
    border: 2px dashed var(--border);
    border-radius: var(--radius);
    padding: 64px 32px;
    text-align: center;
    cursor: pointer;
    transition: border-color .2s, background .2s;
    position: relative;
    overflow: hidden;
  }
  .upload-zone:hover,
  .upload-zone.dz-drag-hover {
    border-color: var(--accent);
    background: rgba(232,255,71,.03);
  }
  .upload-zone .icon {
    font-size: 40px;
    margin-bottom: 16px;
    opacity: .5;
  }
  .upload-zone h2 {
    font-family: var(--mono);
    font-size: 16px;
    font-weight: 500;
    margin-bottom: 8px;
  }
  .upload-zone p {
    font-size: 13px;
    color: var(--muted);
  }
  .upload-zone .formats {
    display: flex;
    justify-content: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-top: 20px;
  }
  .format-tag {
    font-family: var(--mono);
    font-size: 11px;
    padding: 3px 8px;
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--muted);
  }

  /* Progress */
  #progress-wrap {
    display: none;
    margin-top: 32px;
  }
  .progress-bar-track {
    background: var(--border);
    border-radius: 2px;
    height: 4px;
    overflow: hidden;
    margin-bottom: 12px;
  }
  .progress-bar-fill {
    height: 100%;
    background: var(--accent);
    width: 0%;
    transition: width .3s;
  }
  #progress-label {
    font-family: var(--mono);
    font-size: 12px;
    color: var(--muted);
  }

  /* Error state */
  #upload-error {
    display: none;
    margin-top: 20px;
  }
</style>
{% endblock %}

{% block content %}
<h1>Upload Audio</h1>
<p class="subtitle">Upload an audio or video file to transcribe and identify speakers.</p>

<div id="upload-error" class="alert alert-error"></div>

<form id="dropzone-form" class="upload-zone dropzone" action="/upload">
  <div class="icon">⬆</div>
  <h2>Drop your file here</h2>
  <p>or click to browse</p>
  <div class="formats">
    <span class="format-tag">MP3</span>
    <span class="format-tag">MP4</span>
    <span class="format-tag">WAV</span>
    <span class="format-tag">M4A</span>
    <span class="format-tag">FLAC</span>
    <span class="format-tag">OGG</span>
    <span class="format-tag">WEBM</span>
  </div>
  <!-- Dropzone injects its own preview elements; we hide the default ones -->
  <div class="dz-message" style="display:none"></div>
</form>

<div id="progress-wrap">
  <div class="label">Uploading</div>
  <div class="progress-bar-track">
    <div class="progress-bar-fill" id="progress-bar"></div>
  </div>
  <div id="progress-label">0%</div>
</div>
{% endblock %}

{% block scripts %}
<script>
Dropzone.autoDiscover = false;

const MAX_FILE_SIZE_MB = {{ max_upload_mb }};
const CHUNK_SIZE = 50 * 1024 * 1024; // 50MB chunks

const dz = new Dropzone('#dropzone-form', {
  url: '/upload',
  maxFiles: 1,
  maxFilesize: MAX_FILE_SIZE_MB,
  chunking: true,
  chunkSize: CHUNK_SIZE,
  parallelChunkUploads: false,
  retryChunks: true,
  retryChunksLimit: 3,
  acceptedFiles: 'audio/*,video/*,.mp3,.mp4,.wav,.m4a,.flac,.ogg,.webm,.mkv',
  previewsContainer: false,
  clickable: true,

  init() {
    this.on('addedfile', () => {
      document.getElementById('progress-wrap').style.display = 'block';
      document.getElementById('upload-error').style.display = 'none';
    });

    this.on('uploadprogress', (file, progress) => {
      document.getElementById('progress-bar').style.width = progress + '%';
      document.getElementById('progress-label').textContent =
        Math.round(progress) + '% — ' + formatBytes(file.upload.bytesSent) +
        ' / ' + formatBytes(file.size);
    });

    this.on('success', (file, response) => {
      if (response.redirect) {
        window.location.href = response.redirect;
      }
    });

    this.on('error', (file, message) => {
      const errEl = document.getElementById('upload-error');
      errEl.style.display = 'block';
      errEl.textContent = typeof message === 'string'
        ? message
        : (message.error || 'Upload failed. Please try again.');
      document.getElementById('progress-wrap').style.display = 'none';
      dz.removeAllFiles();
    });
  }
});

function formatBytes(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}
</script>
{% endblock %}
EOF_TEMPLATES_UPLOAD_HTML

# templates/processing.html
cat > "$TARGET/templates/processing.html" << 'EOF_TEMPLATES_PROCESSING_HTML'
{% extends "base.html" %}
{% block title %}Processing — Transcriber{% endblock %}

{% block head %}
<style>
  .status-grid {
    display: grid;
    gap: 12px;
    margin-bottom: 32px;
  }
  .status-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 20px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    transition: border-color .3s;
  }
  .status-row.active  { border-color: rgba(232,255,71,.3); }
  .status-row.done    { border-color: rgba(71,255,232,.2); }
  .status-row.error   { border-color: rgba(255,71,71,.3); }

  .status-row .step-name {
    font-family: var(--mono);
    font-size: 13px;
    font-weight: 500;
  }

  /* Spinner */
  .spinner {
    width: 16px;
    height: 16px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin .7s linear infinite;
    flex-shrink: 0;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* Checkmark / X icons */
  .icon-done  { color: var(--accent2); font-size: 16px; }
  .icon-error { color: var(--danger);  font-size: 16px; }
  .icon-wait  { color: var(--muted);   font-size: 16px; opacity: .4; }

  /* Error detail */
  .error-detail {
    margin-top: 24px;
    padding: 16px;
    background: rgba(255,71,71,.07);
    border: 1px solid rgba(255,71,71,.25);
    border-radius: var(--radius);
    font-family: var(--mono);
    font-size: 12px;
    color: #ff9090;
    white-space: pre-wrap;
    overflow-x: auto;
  }

  .job-meta {
    font-family: var(--mono);
    font-size: 12px;
    color: var(--muted);
    margin-bottom: 32px;
  }
  .job-meta span { color: var(--text); }
</style>
{% endblock %}

{% block content %}
<h1>Processing</h1>

<div class="job-meta">
  Job <span>{{ job.job_id[:8] }}…</span> &nbsp;·&nbsp; <span>{{ job.original_filename }}</span>
</div>

{% if error %}
  <div class="alert alert-error">{{ error }}</div>
{% endif %}

<div class="status-grid" id="status-grid">
  <div class="status-row {% if job.status.value in ['TRANSCRIBING'] %}active{% elif job.status.value in ['AWAITING_NAMES','RENDERING','DONE'] %}done{% elif job.status.value == 'FAILED' %}error{% endif %}" id="row-upload">
    <div class="step-name">Upload</div>
    {% if job.status.value == 'UPLOADING' %}
      <div class="spinner"></div>
    {% elif job.status.value == 'FAILED' and not job.transcript_srt_path %}
      <span class="icon-error">✕</span>
    {% else %}
      <span class="icon-done">✓</span>
    {% endif %}
  </div>

  <div class="status-row {% if job.status.value == 'TRANSCRIBING' %}active{% elif job.status.value in ['AWAITING_NAMES','RENDERING','DONE'] %}done{% elif job.status.value == 'FAILED' %}error{% endif %}" id="row-transcribe">
    <div class="step-name">Transcription</div>
    {% if job.status.value == 'TRANSCRIBING' %}
      <div class="spinner"></div>
    {% elif job.status.value in ['AWAITING_NAMES','RENDERING','DONE'] %}
      <span class="icon-done">✓</span>
    {% elif job.status.value == 'FAILED' %}
      <span class="icon-error">✕</span>
    {% else %}
      <span class="icon-wait">○</span>
    {% endif %}
  </div>

  <div class="status-row {% if job.status.value == 'RENDERING' %}active{% elif job.status.value == 'DONE' %}done{% elif job.status.value == 'FAILED' %}error{% endif %}" id="row-render">
    <div class="step-name">Render</div>
    {% if job.status.value == 'RENDERING' %}
      <div class="spinner"></div>
    {% elif job.status.value == 'DONE' %}
      <span class="icon-done">✓</span>
    {% elif job.status.value == 'FAILED' %}
      <span class="icon-error">✕</span>
    {% else %}
      <span class="icon-wait">○</span>
    {% endif %}
  </div>
</div>

{% if job.status.value == 'FAILED' and job.error %}
<div class="label">Error detail</div>
<div class="error-detail">{{ job.error }}</div>
{% endif %}

{% if job.status.value not in ['FAILED', 'DONE', 'AWAITING_NAMES'] %}
<p style="font-size:13px; color:var(--muted);">This page will update automatically. You can close this tab and return to this URL later.</p>
{% endif %}
{% endblock %}

{% block scripts %}
<script>
const JOB_ID = "{{ job.job_id }}";
const CURRENT_STATUS = "{{ job.status.value }}";

// Don't poll if we're already in a terminal/redirect state
const POLL_STATES = ['UPLOADING', 'TRANSCRIBING', 'RENDERING'];

if (POLL_STATES.includes(CURRENT_STATUS)) {
  startPolling();
}

function startPolling() {
  const interval = setInterval(async () => {
    try {
      const res = await fetch(`/job/${JOB_ID}/status`);
      const data = await res.json();

      if (data.redirect) {
        clearInterval(interval);
        window.location.href = data.redirect;
        return;
      }

      if (data.status === 'FAILED') {
        clearInterval(interval);
        // Reload to show error state rendered by server
        window.location.reload();
      }
    } catch (e) {
      // Network error — keep polling
    }
  }, 3000);
}
</script>
{% endblock %}
EOF_TEMPLATES_PROCESSING_HTML

# templates/speakers.html
cat > "$TARGET/templates/speakers.html" << 'EOF_TEMPLATES_SPEAKERS_HTML'
{% extends "base.html" %}
{% block title %}Identify Speakers — Transcriber{% endblock %}

{% block head %}
<script src="https://cdnjs.cloudflare.com/ajax/libs/wavesurfer.js/7.7.3/wavesurfer.min.js"></script>
<style>
  .speaker-list {
    display: grid;
    gap: 16px;
    margin-bottom: 40px;
  }

  .speaker-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
    transition: border-color .2s;
  }
  .speaker-card:focus-within { border-color: rgba(232,255,71,.35); }

  .speaker-header {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 16px 20px;
    border-bottom: 1px solid var(--border);
  }

  .speaker-id-badge {
    font-family: var(--mono);
    font-size: 11px;
    padding: 3px 8px;
    background: rgba(255,255,255,.06);
    border-radius: 2px;
    color: var(--muted);
    white-space: nowrap;
    flex-shrink: 0;
  }

  .name-input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    font-family: var(--sans);
    font-size: 15px;
    font-weight: 500;
    color: var(--text);
    caret-color: var(--accent);
  }
  .name-input::placeholder { color: var(--muted); font-weight: 300; }

  .speaker-body {
    padding: 16px 20px;
  }

  /* WaveSurfer container */
  .waveform-wrap {
    position: relative;
    margin-bottom: 12px;
  }
  .waveform {
    height: 52px;
    border-radius: 2px;
    overflow: hidden;
  }

  .waveform-controls {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-top: 10px;
  }

  .play-btn {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: var(--accent);
    color: #000;
    border: none;
    cursor: pointer;
    font-size: 12px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    transition: opacity .15s;
  }
  .play-btn:hover { opacity: .82; }

  .time-display {
    font-family: var(--mono);
    font-size: 11px;
    color: var(--muted);
    min-width: 70px;
  }

  .regen-btn {
    margin-left: auto;
    font-family: var(--mono);
    font-size: 11px;
    letter-spacing: .06em;
    text-transform: uppercase;
    background: transparent;
    border: 1px solid var(--border);
    color: var(--muted);
    padding: 4px 10px;
    border-radius: 2px;
    cursor: pointer;
    transition: border-color .15s, color .15s;
  }
  .regen-btn:hover { border-color: var(--muted); color: var(--text); }
  .regen-btn:disabled { opacity: .35; cursor: not-allowed; }

  /* Submit area */
  .submit-area {
    display: flex;
    align-items: center;
    gap: 16px;
  }
  .submit-hint {
    font-size: 13px;
    color: var(--muted);
  }

  /* Submitting overlay */
  #submit-overlay {
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(13,13,13,.8);
    z-index: 100;
    align-items: center;
    justify-content: center;
    flex-direction: column;
    gap: 16px;
  }
  #submit-overlay.visible { display: flex; }
  #submit-overlay .spinner {
    width: 32px;
    height: 32px;
    border: 3px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin .7s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  #submit-overlay p {
    font-family: var(--mono);
    font-size: 13px;
    color: var(--muted);
  }
</style>
{% endblock %}

{% block content %}
<h1>Identify Speakers</h1>
<p class="subtitle">Listen to each clip and enter the speaker's name. Blank fields keep the auto-assigned label.</p>

<div id="submit-error" class="alert alert-error" style="display:none"></div>

<form id="speakers-form">
  <div class="speaker-list">
    {% for speaker in speakers %}
    <div class="speaker-card" data-speaker-id="{{ speaker.speaker_id }}">
      <div class="speaker-header">
        <span class="speaker-id-badge">{{ speaker.speaker_id }}</span>
        <input
          class="name-input"
          type="text"
          name="speaker_{{ speaker.speaker_id }}"
          placeholder="Enter name…"
          autocomplete="off"
          spellcheck="false"
        >
      </div>
      <div class="speaker-body">
        <div class="waveform-wrap">
          <div class="waveform" id="waveform-{{ speaker.speaker_id }}"></div>
        </div>
        <div class="waveform-controls">
          <button type="button" class="play-btn" id="play-{{ speaker.speaker_id }}" title="Play/Pause">▶</button>
          <div class="time-display" id="time-{{ speaker.speaker_id }}">0:00</div>
          <button type="button" class="regen-btn" id="regen-{{ speaker.speaker_id }}" title="Try a different clip">↻ Different clip</button>
        </div>
      </div>
    </div>
    {% endfor %}
  </div>

  <div class="submit-area">
    <button type="submit" class="btn btn-primary" id="submit-btn">Confirm &amp; Render →</button>
    <span class="submit-hint">Processing takes a few minutes.</span>
  </div>
</form>

<div id="submit-overlay">
  <div class="spinner"></div>
  <p>Starting render…</p>
</div>
{% endblock %}

{% block scripts %}
<script>
const JOB_ID = "{{ job.job_id }}";

// ── WaveSurfer instances ────────────────────────────────────────────────────
const wavesurfers = {};

document.querySelectorAll('.speaker-card').forEach(card => {
  const speakerId = card.dataset.speakerId;
  const container = document.getElementById(`waveform-${speakerId}`);
  const playBtn   = document.getElementById(`play-${speakerId}`);
  const timeEl    = document.getElementById(`time-${speakerId}`);
  const regenBtn  = document.getElementById(`regen-${speakerId}`);

  const ws = WaveSurfer.create({
    container,
    waveColor:     '#3a3a3a',
    progressColor: '#e8ff47',
    cursorColor:   'transparent',
    barWidth:      2,
    barGap:        1,
    barRadius:     2,
    height:        52,
    normalize:     true,
    url:           `/job/${JOB_ID}/speaker/${speakerId}/clip`,
  });

  wavesurfers[speakerId] = ws;

  ws.on('ready', () => {
    timeEl.textContent = formatTime(ws.getDuration());
    playBtn.disabled = false;
  });

  ws.on('audioprocess', () => {
    timeEl.textContent = formatTime(ws.getCurrentTime()) + ' / ' + formatTime(ws.getDuration());
  });

  ws.on('finish', () => {
    playBtn.textContent = '▶';
  });

  ws.on('error', (err) => {
    container.innerHTML = '<p style="font-size:12px;color:var(--muted);padding:16px 0;">Clip unavailable</p>';
    playBtn.disabled = true;
  });

  playBtn.addEventListener('click', () => {
    // Pause all other players first
    Object.entries(wavesurfers).forEach(([id, w]) => {
      if (id !== speakerId && w.isPlaying()) {
        w.pause();
        document.getElementById(`play-${id}`).textContent = '▶';
      }
    });
    ws.playPause();
    playBtn.textContent = ws.isPlaying() ? '⏸' : '▶';
  });

  regenBtn.addEventListener('click', async () => {
    regenBtn.disabled = true;
    regenBtn.textContent = '↻ Loading…';
    try {
      const res = await fetch(`/job/${JOB_ID}/speaker/${speakerId}/regenerate`, { method: 'POST' });
      const data = await res.json();
      if (data.error) throw new Error(data.error);
      // Reload the waveform with a cache-buster
      ws.load(data.clip_url + '?t=' + Date.now());
      playBtn.textContent = '▶';
    } catch (e) {
      alert('Could not regenerate clip: ' + e.message);
    } finally {
      regenBtn.disabled = false;
      regenBtn.textContent = '↻ Different clip';
    }
  });
});

// ── Form submit ──────────────────────────────────────────────────────────────
document.getElementById('speakers-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const submitBtn = document.getElementById('submit-btn');
  submitBtn.disabled = true;
  document.getElementById('submit-error').style.display = 'none';
  document.getElementById('submit-overlay').classList.add('visible');

  // Build name map from inputs
  const speakers = {};
  document.querySelectorAll('.speaker-card').forEach(card => {
    const sid = card.dataset.speakerId;
    const input = card.querySelector('.name-input');
    speakers[sid] = input.value.trim();
  });

  try {
    const res = await fetch(`/job/${JOB_ID}/speakers`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ speakers }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Submit failed');
    window.location.href = data.redirect;
  } catch (e) {
    document.getElementById('submit-overlay').classList.remove('visible');
    const err = document.getElementById('submit-error');
    err.style.display = 'block';
    err.textContent = e.message;
    submitBtn.disabled = false;
  }
});

function formatTime(s) {
  if (!isFinite(s)) return '0:00';
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60).toString().padStart(2, '0');
  return `${m}:${sec}`;
}
</script>
{% endblock %}
EOF_TEMPLATES_SPEAKERS_HTML

# templates/download.html
cat > "$TARGET/templates/download.html" << 'EOF_TEMPLATES_DOWNLOAD_HTML'
{% extends "base.html" %}
{% block title %}Download — Transcriber{% endblock %}

{% block head %}
<style>
  .done-badge {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-family: var(--mono);
    font-size: 12px;
    color: var(--accent2);
    margin-bottom: 32px;
  }
  .done-badge::before {
    content: '';
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--accent2);
    box-shadow: 0 0 8px var(--accent2);
    flex-shrink: 0;
  }

  /* ── Video player ─────────────────────────────────────────────────────── */
  .video-wrap {
    position: relative;
    width: 100%;
    background: #000;
    border-radius: var(--radius);
    overflow: hidden;
    border: 1px solid var(--border);
    margin-bottom: 24px;
  }

  .video-wrap video {
    display: block;
    width: 100%;
    max-height: 480px;
    background: #000;
  }

  /* ── File / action row ────────────────────────────────────────────────── */
  .file-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    flex-wrap: wrap;
    margin-bottom: 32px;
  }

  .file-info .file-name {
    font-family: var(--mono);
    font-size: 15px;
    font-weight: 500;
    margin-bottom: 4px;
  }

  .file-info .file-meta {
    font-size: 13px;
    color: var(--muted);
  }

  .divider {
    border: none;
    border-top: 1px solid var(--border);
    margin: 32px 0;
  }

  .back-section {
    display: flex;
    align-items: center;
    gap: 16px;
    flex-wrap: wrap;
  }

  .back-hint {
    font-size: 13px;
    color: var(--muted);
  }

  /* ── Confirm modal ────────────────────────────────────────────────────── */
  #back-modal {
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(13,13,13,.85);
    z-index: 100;
    align-items: center;
    justify-content: center;
  }
  #back-modal.visible { display: flex; }
  .modal-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 32px;
    max-width: 420px;
    width: 90%;
  }
  .modal-card h3 {
    font-family: var(--mono);
    font-size: 15px;
    margin-bottom: 12px;
  }
  .modal-card p {
    font-size: 14px;
    color: var(--muted);
    margin-bottom: 24px;
    line-height: 1.6;
  }
  .modal-actions {
    display: flex;
    gap: 12px;
  }
</style>
{% endblock %}

{% block content %}
<div class="done-badge">Complete</div>

<h1>Your file is ready</h1>
<p class="subtitle">Watch the subtitled video below, or download it.</p>

<!-- ── Embedded video player ──────────────────────────────────────────────── -->
<div class="video-wrap">
  <video
    controls
    preload="metadata"
    src="/job/{{ job.job_id }}/file"
  >
    Your browser does not support the video tag.
    <a href="/job/{{ job.job_id }}/file">Download the video instead.</a>
  </video>
</div>

<!-- ── Filename + download button ────────────────────────────────────────── -->
<div class="file-card">
  <div class="file-info">
    <div class="file-name">{{ job.original_filename | replace('.', '_subtitled.', 1) }}</div>
    <div class="file-meta">MP4 · Subtitled &amp; speaker-labelled</div>
  </div>
  <div style="display:flex; gap:10px; flex-wrap:wrap;">
    <a href="/job/{{ job.job_id }}/file" class="btn btn-primary" download>Download MP4</a>
    <a href="/job/{{ job.job_id }}/transcript" class="btn btn-secondary" download>Download Transcript</a>
  </div>
</div>

<hr class="divider">

<div class="back-section">
  <button class="btn btn-secondary" id="back-btn">← Edit Speaker Names</button>
  <span class="back-hint">This will delete the current video and let you re-render with updated names.</span>
</div>

<!-- ── Confirm modal ──────────────────────────────────────────────────────── -->
<div id="back-modal">
  <div class="modal-card">
    <h3>Go back and re-render?</h3>
    <p>The current MP4 will be deleted. You'll return to the speaker naming screen and can re-render with updated names.</p>
    <div class="modal-actions">
      <button class="btn btn-danger" id="confirm-back-btn">Yes, delete &amp; go back</button>
      <button class="btn btn-secondary" id="cancel-back-btn">Cancel</button>
    </div>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
const JOB_ID = "{{ job.job_id }}";

document.getElementById('back-btn').addEventListener('click', () => {
  document.getElementById('back-modal').classList.add('visible');
});

document.getElementById('cancel-back-btn').addEventListener('click', () => {
  document.getElementById('back-modal').classList.remove('visible');
});

document.getElementById('confirm-back-btn').addEventListener('click', async () => {
  const btn = document.getElementById('confirm-back-btn');
  btn.disabled = true;
  btn.textContent = 'Deleting…';

  try {
    const res = await fetch(`/job/${JOB_ID}/back`, { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Failed');
    window.location.href = data.redirect;
  } catch (e) {
    alert('Error: ' + e.message);
    btn.disabled = false;
    btn.textContent = 'Yes, delete & go back';
  }
});
</script>
{% endblock %}
EOF_TEMPLATES_DOWNLOAD_HTML

# nginx/nginx.conf
cat > "$TARGET/nginx/nginx.conf" << 'EOF_NGINX_NGINX_CONF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Allow large uploads (up to 2GB)
    client_max_body_size 2048m;

    # Increase timeouts for long transcription jobs
    proxy_read_timeout    3600;
    proxy_connect_timeout 60;
    proxy_send_timeout    3600;

    sendfile on;
    keepalive_timeout 65;

    # Logging
    access_log /var/log/nginx/access.log;

    server {
        listen 80;
        server_name _;

        # Proxy everything to gunicorn
        location / {
            proxy_pass         http://127.0.0.1:5000;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;

            # Required for chunked upload progress
            proxy_request_buffering off;
        }

        # Serve static files directly (bypass gunicorn)
        location /static/ {
            alias /app/static/;
            expires 7d;
            add_header Cache-Control "public, immutable";
        }
    }
}
EOF_NGINX_NGINX_CONF

# supervisord.conf
cat > "$TARGET/supervisord.conf" << 'EOF_SUPERVISORD_CONF'
[supervisord]
nodaemon=true
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor

[unix_http_server]
file=/var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

; ── nginx ────────────────────────────────────────────────────────────────────
[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
priority=10
stdout_logfile=/var/log/supervisor/nginx.stdout.log
stderr_logfile=/var/log/supervisor/nginx.stderr.log

; ── gunicorn ─────────────────────────────────────────────────────────────────
[program:gunicorn]
command=gunicorn
    --workers %(ENV_GUNICORN_WORKERS)s
    --bind 127.0.0.1:%(ENV_GUNICORN_PORT)s
    --timeout 3600
    --worker-class sync
    --log-level info
    --access-logfile -
    --error-logfile -
    "app:create_app()"
directory=/app
autostart=true
autorestart=true
priority=20
stdout_logfile=/var/log/supervisor/gunicorn.stdout.log
stderr_logfile=/var/log/supervisor/gunicorn.stderr.log

; ── expiry sweep (runs every hour via a simple loop) ─────────────────────────
[program:expiry]
command=bash -c "while true; do python -m tasks.expiry; sleep 3600; done"
directory=/app
autostart=true
autorestart=true
priority=30
stdout_logfile=/var/log/supervisor/expiry.stdout.log
stderr_logfile=/var/log/supervisor/expiry.stderr.log
EOF_SUPERVISORD_CONF

# Dockerfile
cat > "$TARGET/Dockerfile" << 'EOF_DOCKERFILE'
# ── Base image ─────────────────────────────────────────────────────────────
# nvidia/cuda base for GPU access by WhisperX
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# ── System deps ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-venv \
    python3-pip \
    ffmpeg \
    nginx \
    supervisor \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Make python3.11 the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
 && update-alternatives --install /usr/bin/python  python  /usr/bin/python3.11 1

# ── Install WhisperX ───────────────────────────────────────────────────────
# WhisperX requires torch; install CPU-only torch first to avoid pulling in
# the huge CUDA torch wheel (the CUDA runtime is already on the base image).
# Users who need GPU-accelerated WhisperX can switch to the CUDA torch wheel.
RUN pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir whisperx

# ── App dependencies ───────────────────────────────────────────────────────
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Copy application ───────────────────────────────────────────────────────
COPY . .

# Create storage directories (will be volume-mounted in production)
RUN mkdir -p storage/tmp

# ── nginx config ───────────────────────────────────────────────────────────
COPY nginx/nginx.conf /etc/nginx/nginx.conf
# Remove default nginx site
RUN rm -f /etc/nginx/sites-enabled/default

# ── supervisord config ─────────────────────────────────────────────────────
COPY supervisord.conf /etc/supervisor/conf.d/transcriber.conf

# ── Ports ──────────────────────────────────────────────────────────────────
EXPOSE 80

# ── Entrypoint ─────────────────────────────────────────────────────────────
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
EOF_DOCKERFILE

# docker-compose.yml
cat > "$TARGET/docker-compose.yml" << 'EOF_DOCKER_COMPOSE_YML'
version: "3.9"

services:
  transcriber:
    build: .
    image: transcriber:latest
    container_name: transcriber

    # ── GPU access ──────────────────────────────────────────────────────────
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

    # ── Ports ───────────────────────────────────────────────────────────────
    ports:
      - "80:80"

    # ── Persistent storage ──────────────────────────────────────────────────
    # Job data survives container restarts.
    volumes:
      - ./storage:/app/storage

    # ── Environment ─────────────────────────────────────────────────────────
    env_file:
      - .env

    restart: unless-stopped
EOF_DOCKER_COMPOSE_YML

# README.md
cat > "$TARGET/README.md" << 'EOF_README_MD'
# Transcriber

Upload an audio or video file → WhisperX transcribes and diarizes it → assign names to speakers → download a subtitled MP4.

---

## How it works

1. **Upload** — drop a file (up to 2 GB). Dropzone.js sends it in 50 MB chunks.
2. **Transcribe** — WhisperX runs in the background; the browser polls for status.
3. **Identify speakers** — listen to a clip from each detected speaker and type their name.
4. **Render** — ffmpeg burns the named subtitles into the video.
5. **Download** — grab the finished MP4. Use the Back button to re-render with different names.

Jobs persist on disk for one week (configurable), so you can close the browser and return via the URL.

---

## Prerequisites

| Tool | Version |
|---|---|
| Python | 3.11+ |
| ffmpeg | any recent |
| WhisperX | latest (`pip install whisperx`) |
| Docker + nvidia-docker | for containerised run |

---

## Configuration

Copy `.env.example` to `.env` and edit as needed:

```sh
cp .env.example .env
```

Key variables:

| Variable | Default | Description |
|---|---|---|
| `FLASK_SECRET_KEY` | *(required)* | Flask session secret — change in production |
| `WHISPERX_CMD` | `whisperx {input} --output_dir {output_dir} --output_format all` | WhisperX command template |
| `FFMPEG_CMD` | `ffmpeg -i {input} -vf subtitles={srt} {output}` | ffmpeg subtitle burn-in template |
| `GUNICORN_WORKERS` | `4` | Number of gunicorn worker processes |
| `JOB_TTL_SECONDS` | `604800` | Job expiry (seconds). Default: 1 week |
| `SPEAKER_CLIP_MAX_SECONDS` | `10` | Max length of speaker identification clips |
| `MAX_UPLOAD_BYTES` | `2147483648` | 2 GB upload limit |

---

## Run environments

### 1. Python virtualenv (development)

```sh
# Create and activate virtualenv
python3 -m venv .venv
source .venv/bin/activate       # Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Install WhisperX (requires torch — see WhisperX docs for GPU setup)
pip install whisperx

# Copy and edit config
cp .env.example .env

# Run
python run.py
```

App available at http://localhost:5000

---

### 2. Docker (single container)

```sh
# Build
docker build -t transcriber .

# Run
docker run \
  --gpus all \
  -p 80:80 \
  --env-file .env \
  -v $(pwd)/storage:/app/storage \
  transcriber
```

App available at http://localhost

---

### 3. Docker Compose

```sh
# Build and start
docker-compose up --build

# Start in background
docker-compose up -d --build

# View logs
docker-compose logs -f

# Stop
docker-compose down
```

App available at http://localhost

---

## Project structure

```
transcriber/
├── app.py                  Flask application factory
├── config.py               Central config — reads .env
├── models.py               Job dataclass + JobStatus enum
├── run.py                  Dev entry point (python run.py)
│
├── routes/
│   ├── upload.py           Chunked upload + job creation
│   ├── job.py              Status polling + speaker endpoints
│   ├── processing.py       Back-navigation (reset to AWAITING_NAMES)
│   └── download.py         Download page + file serving
│
├── jobs/
│   ├── manager.py          JobManager — create/get/update/submit_task
│   └── runner.py           Background tasks: run_transcription, run_render
│
├── services/
│   ├── whisperx.py         WhisperX subprocess wrapper
│   ├── srt_parser.py       Parse WhisperX SRT, apply speaker names
│   ├── audio_clip.py       Extract speaker WAV clips via ffmpeg
│   └── ffmpeg.py           Subtitle burn-in render via ffmpeg
│
├── tasks/
│   └── expiry.py           Hourly job expiry sweep
│
├── templates/
│   ├── base.html
│   ├── upload.html
│   ├── processing.html
│   ├── speakers.html
│   └── download.html
│
├── nginx/nginx.conf
├── supervisord.conf
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── .env.example
└── storage/                Job data (git-ignored)
    └── tmp/                Chunk staging area
```

---

## Celery upgrade path

Today, background tasks run in daemon threads. To switch to Celery, change **only** `JobManager.submit_task()` in `jobs/manager.py`:

```python
# Today (threading — one method body to replace):
def submit_task(self, job_id, task_fn, *args):
    threading.Thread(target=self._run_task, args=(job_id, task_fn, *args), daemon=True).start()

# Celery (future):
def submit_task(self, job_id, task_fn, *args):
    celery_task.delay(job_id, *args)
```

No other files need to change.

---

## Job state machine

```
UPLOADING → TRANSCRIBING → AWAITING_NAMES → RENDERING → DONE
                                  ↑________________________________|
                                         (back button resets here)
```

Failed jobs land in `FAILED` status with an `error` field containing the traceback.

---

## WhisperX SRT format

WhisperX outputs speaker labels as `[SPEAKER_00]:` prefixes on subtitle lines:

```
1
00:00:01,000 --> 00:00:04,500
[SPEAKER_00]: Hello, welcome to the show.
```

`srt_parser.py` handles this format for both parsing and name replacement.
EOF_README_MD

# .env.example
cat > "$TARGET/.env.example" << 'EOF__ENV_EXAMPLE'
# ── Flask ────────────────────────────────────────────────────────────────────
FLASK_SECRET_KEY=change-me-in-production
FLASK_ENV=production
FLASK_DEBUG=0

# ── Server ───────────────────────────────────────────────────────────────────
# Number of gunicorn worker processes
GUNICORN_WORKERS=4
# Port gunicorn listens on (nginx proxies to this)
GUNICORN_PORT=5000

# ── Storage ──────────────────────────────────────────────────────────────────
# Root directory for job data and temp chunk uploads
STORAGE_DIR=storage

# ── Job Expiry ───────────────────────────────────────────────────────────────
# How many seconds a job lives before the expiry sweep deletes it (default: 1 week)
JOB_TTL_SECONDS=604800

# ── WhisperX ─────────────────────────────────────────────────────────────────
# Command template for transcription.
# Placeholders: {input} = audio file path, {output_dir} = output directory
WHISPERX_CMD=whisperx {input} --output_dir {output_dir} --output_format all

# ── ffmpeg ───────────────────────────────────────────────────────────────────
# Command template for subtitle burn-in render.
# Placeholders: {input} = original audio, {srt} = srt path, {output} = output mp4
FFMPEG_CMD=ffmpeg -i {input} -vf subtitles={srt} {output}

# ── Speaker Clip ─────────────────────────────────────────────────────────────
# Maximum length in seconds for speaker identification clips
SPEAKER_CLIP_MAX_SECONDS=10

# ── Upload ───────────────────────────────────────────────────────────────────
# Maximum upload size in bytes (default: 2GB)
MAX_UPLOAD_BYTES=2147483648
EOF__ENV_EXAMPLE

# .gitignore
cat > "$TARGET/.gitignore" << 'EOF__GITIGNORE'
# Environment
.env

# Storage (job data — never commit)
storage/

# Python
__pycache__/
*.py[cod]
*.egg-info/
dist/
build/
.venv/
venv/
env/

# IDE
.vscode/
.idea/

# OS
.DS_Store
Thumbs.db
EOF__GITIGNORE

echo ""
echo "Done! $TARGET/ is ready."
echo ""
echo "Next steps:"
echo "  cd $TARGET"
echo "  cp .env.example .env   # edit FLASK_SECRET_KEY"
echo "  pip install -r requirements.txt"
echo "  python run.py"
