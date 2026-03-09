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
