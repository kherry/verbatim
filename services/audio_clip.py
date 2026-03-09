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
