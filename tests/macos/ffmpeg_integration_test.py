#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from ncm_fixture import build_ncm


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "dist" / "NCM批量转MP3.app"
APP_BIN = APP / "Contents" / "MacOS" / "NCMConverter"
BUNDLED_FFMPEG = APP / "Contents" / "Resources" / "ffmpeg"
def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ncm-ffmpeg-test-") as tmp:
        tmp_path = Path(tmp)
        out_dir = tmp_path / "out"
        cover = tmp_path / "cover.png"

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
                "color=c=orange:s=64x64",
                "-frames:v",
                "1",
                str(cover),
            ],
            check=True,
        )

        for audio_format, codec in (("flac", "flac"), ("mp3", "libmp3lame")):
            audio = tmp_path / f"tone.{audio_format}"
            source_ncm = tmp_path / f"tone-{audio_format}.ncm"
            title = f"Synthetic {audio_format.upper()}"

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
                    codec,
                    str(audio),
                ],
                check=True,
            )
            build_ncm(
                source_ncm,
                audio.read_bytes(),
                audio_format,
                title=title,
                cover=cover.read_bytes(),
            )

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

            output = out_dir / f"Codex - {title}.mp3"
            if not output.exists():
                raise AssertionError(f"expected MP3 output: {output}")

            subprocess.run(
                [
                    str(BUNDLED_FFMPEG),
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-i",
                    str(output),
                    "-f",
                    "null",
                    "-",
                ],
                check=True,
            )

            extracted_cover = tmp_path / f"{audio_format}-cover.jpg"
            subprocess.run(
                [
                    str(BUNDLED_FFMPEG),
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-i",
                    str(output),
                    "-map",
                    "0:v:0",
                    "-frames:v",
                    "1",
                    str(extracted_cover),
                ],
                check=True,
            )
            if not extracted_cover.read_bytes().startswith(b"\xff\xd8\xff"):
                raise AssertionError(f"missing JPEG cover in {output.name}")

            metadata = subprocess.run(
                [
                    str(BUNDLED_FFMPEG),
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-i",
                    str(output),
                    "-f",
                    "ffmetadata",
                    "-",
                ],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            ).stdout
            for expected in (f"title={title}", "artist=Codex", "album=Synthetic Album"):
                if expected not in metadata:
                    raise AssertionError(f"missing metadata {expected!r} in {output.name}: {metadata}")

            print(f"bundled ffmpeg cover metadata ok: {output.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
