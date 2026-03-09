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
