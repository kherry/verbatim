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
