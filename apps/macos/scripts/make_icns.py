#!/usr/bin/env python3
from __future__ import annotations

import struct
import sys
from pathlib import Path


CHUNKS = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]


def main() -> int:
    iconset = Path(sys.argv[1])
    output = Path(sys.argv[2])
    body = bytearray()

    for code, filename in CHUNKS:
        data = (iconset / filename).read_bytes()
        body += code.encode("ascii")
        body += struct.pack(">I", len(data) + 8)
        body += data

    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
