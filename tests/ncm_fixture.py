from __future__ import annotations

import base64
import json
import struct
import subprocess
from pathlib import Path


MAGIC = b"CTENFDAM"
CORE_KEY = bytes.fromhex("687A4852416D736F356B496E62617857")
META_KEY = bytes.fromhex("2331346C6A6B5F215C5D2630553C2728")
OPENSSL = "/usr/bin/openssl"


def aes_encrypt(data: bytes, key: bytes) -> bytes:
    proc = subprocess.run(
        [
            OPENSSL,
            "enc",
            "-e",
            "-aes-128-ecb",
            "-K",
            key.hex(),
            "-nosalt",
        ],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return proc.stdout


def build_key_box(key_data: bytes) -> list[int]:
    if not key_data:
        raise ValueError("empty key data")

    box = list(range(256))
    c = 0
    last_byte = 0
    key_offset = 0
    for i in range(256):
        swap = box[i]
        c = (swap + last_byte + key_data[key_offset]) & 0xFF
        key_offset += 1
        if key_offset >= len(key_data):
            key_offset = 0
        box[i] = box[c]
        box[c] = swap
        last_byte = c
    return box


def xor_with_box(data: bytes, box: list[int]) -> bytes:
    out = bytearray(data)
    for idx in range(len(out)):
        j = (idx + 1) & 0xFF
        out[idx] ^= box[(box[j] + box[(box[j] + j) & 0xFF]) & 0xFF]
    return bytes(out)


def build_ncm(
    path: Path,
    audio: bytes,
    audio_format: str,
    title: str = "Synthetic Track",
    album: str = "Synthetic Album",
    cover: bytes = b"",
) -> None:
    key_data = b"test-stream-key"
    encrypted_key = bytes(byte ^ 0x64 for byte in aes_encrypt(b"neteasecloudmusic" + key_data, CORE_KEY))

    metadata = {
        "musicName": title,
        "artist": [["Codex", 1]],
        "album": album,
        "format": audio_format,
    }
    meta_plain = b"music:" + json.dumps(metadata, ensure_ascii=False).encode("utf-8")
    meta_payload = b"163 key(Don't modify):" + base64.b64encode(aes_encrypt(meta_plain, META_KEY))
    encrypted_meta = bytes(byte ^ 0x63 for byte in meta_payload)
    encrypted_audio = xor_with_box(audio, build_key_box(key_data))

    blob = bytearray()
    blob += MAGIC
    blob += b"\x02\x00"
    blob += struct.pack("<I", len(encrypted_key))
    blob += encrypted_key
    blob += struct.pack("<I", len(encrypted_meta))
    blob += encrypted_meta
    blob += b"\x00" * 5
    cover_padding = b"\x00" * 3 if cover else b""
    blob += struct.pack("<I", len(cover) + len(cover_padding))
    blob += struct.pack("<I", len(cover))
    blob += cover
    blob += cover_padding
    blob += encrypted_audio
    path.write_bytes(bytes(blob))
