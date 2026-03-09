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
