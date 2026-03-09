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
