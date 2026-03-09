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
