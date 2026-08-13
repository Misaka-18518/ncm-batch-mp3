#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from ncm_fixture import build_key_box, build_ncm


ROOT = Path(__file__).resolve().parents[2]
APP_BIN = ROOT / "dist" / "NCM批量转MP3.app" / "Contents" / "MacOS" / "NCMConverter"


def main() -> int:
    expected_key_box_prefix = [
        70, 218, 132, 64, 217, 166, 112, 195,
        68, 11, 211, 232, 95, 55, 88, 238,
        228, 34, 90, 131, 76, 19, 50, 174,
        108, 173, 40, 122, 251, 145, 35, 59,
    ]
    key_box = build_key_box(b"test-stream-key")
    if key_box[: len(expected_key_box_prefix)] != expected_key_box_prefix:
        raise AssertionError("key-box does not match ncmdump reference algorithm")

    with tempfile.TemporaryDirectory(prefix="ncm-synthetic-test-") as tmp:
        tmp_path = Path(tmp)
        source = tmp_path / "sample.ncm"
        out_dir = tmp_path / "out"
        expected_audio = b"ID3\x04\x00\x00\x00\x00\x00\x10" + b"synthetic audio payload" * 64
        build_ncm(source, expected_audio, "mp3")

        subprocess.run(
            [
                str(APP_BIN),
                "--cli-convert",
                str(source),
                "--output",
                str(out_dir),
                "--rename",
            ],
            check=True,
        )

        outputs = list(out_dir.glob("*.mp3"))
        if len(outputs) != 1:
            raise AssertionError(f"expected one mp3, got {outputs}")
        actual = outputs[0].read_bytes()
        if actual != expected_audio:
            raise AssertionError("roundtrip audio bytes do not match")
        print(f"synthetic roundtrip ok: {outputs[0].name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
