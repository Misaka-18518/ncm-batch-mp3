#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from ncm_fixture import build_ncm


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "dist" / "NCM批量转MP3.app"
APP_BIN = APP / "Contents" / "MacOS" / "NCMConverter"
BUNDLED_FFMPEG = APP / "Contents" / "Resources" / "ffmpeg"


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ncm-ffmpeg-test-") as tmp:
        tmp_path = Path(tmp)
        flac = tmp_path / "tone.flac"
        source_ncm = tmp_path / "tone.ncm"
        out_dir = tmp_path / "out"

        subprocess.run(
            [
                str(BUNDLED_FFMPEG),
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=0.2",
                "-c:a",
                "flac",
                str(flac),
            ],
            check=True,
        )
        build_ncm(source_ncm, flac.read_bytes(), "flac", title="Synthetic FLAC")

        subprocess.run(
            [
                str(APP_BIN),
                "--cli-convert",
                str(source_ncm),
                "--output",
                str(out_dir),
                "--rename",
            ],
            check=True,
        )

        outputs = list(out_dir.glob("*.mp3"))
        if len(outputs) != 1:
            raise AssertionError(f"expected one mp3, got {outputs}")

        subprocess.run(
            [
                str(BUNDLED_FFMPEG),
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(outputs[0]),
                "-f",
                "null",
                "-",
            ],
            check=True,
        )
        print(f"bundled ffmpeg transcode ok: {outputs[0].name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
