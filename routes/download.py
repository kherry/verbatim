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
        download_name=f"{Path(job.original_filename).stem}_transcribed.mp4",
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
