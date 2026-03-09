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
