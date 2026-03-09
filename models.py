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
