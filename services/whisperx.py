"""
services/whisperx.py — WhisperX transcription via subprocess.

Runs the WHISPERX_CMD template from config, substituting {input} and
{output_dir}. Expects WhisperX to produce at minimum:
  <output_dir>/<stem>.srt
  <output_dir>/<stem>.txt

Raises RuntimeError on non-zero exit.
"""

import shlex
import subprocess
from pathlib import Path

import config


def run_whisperx(audio_path: str, output_dir: str) -> dict:
    """
    Run WhisperX on the given audio file.

    Args:
        audio_path:  Absolute path to the source audio/video file.
        output_dir:  Directory where WhisperX should write its output files.

    Returns:
        {
          "txt_path": str,   # absolute path to the .txt transcript
          "srt_path": str,   # absolute path to the .srt transcript
        }

    Raises:
        RuntimeError: if WhisperX exits non-zero or expected output files
                      are not found.
    """
    audio_path = str(audio_path)
    output_dir = str(output_dir)

    Path(output_dir).mkdir(parents=True, exist_ok=True)

    cmd_str = config.WHISPERX_CMD.format(
        input=audio_path,
        output_dir=output_dir,
    )
    cmd = shlex.split(cmd_str)

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"WhisperX failed (exit {result.returncode}):\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )

    # Locate output files — WhisperX names them after the input stem
    stem = Path(audio_path).stem
    out = Path(output_dir)

    txt_path = out / f"{stem}.txt"
    srt_path = out / f"{stem}.srt"

    if not srt_path.exists():
        raise RuntimeError(
            f"WhisperX did not produce expected SRT file at {srt_path}.\n"
            f"Files in output_dir: {list(out.iterdir())}"
        )

    if not txt_path.exists():
        raise RuntimeError(
            f"WhisperX did not produce expected TXT file at {txt_path}.\n"
            f"Files in output_dir: {list(out.iterdir())}"
        )

    return {
        "txt_path": str(txt_path),
        "srt_path": str(srt_path),
    }
