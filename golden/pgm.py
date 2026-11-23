"""Minimal binary PGM (P5, maxval 255) reader/writer.

The C++ testbench (hls/sobel_otsu/tb_sobel_otsu.cpp) reads the same format, so
keep the header strictly "P5\\n<cols> <rows>\\n255\\n" when writing.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np


def write_pgm(path: str | Path, img: np.ndarray) -> None:
    if img.ndim != 2 or img.dtype != np.uint8:
        raise ValueError("write_pgm expects a 2-D uint8 array")
    rows, cols = img.shape
    with open(path, "wb") as f:
        f.write(f"P5\n{cols} {rows}\n255\n".encode("ascii"))
        f.write(np.ascontiguousarray(img).tobytes())


def read_pgm(path: str | Path) -> np.ndarray:
    data = Path(path).read_bytes()
    tokens = []
    pos = 0
    # Header: magic, width, height, maxval, separated by whitespace; '#' comments allowed.
    while len(tokens) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        tokens.append(data[start:pos].decode("ascii"))
    pos += 1  # exactly one whitespace byte before the raster
    magic, cols, rows, maxval = tokens[0], int(tokens[1]), int(tokens[2]), int(tokens[3])
    if magic != "P5" or maxval != 255:
        raise ValueError(f"{path}: only P5 with maxval 255 supported")
    raster = np.frombuffer(data, dtype=np.uint8, count=rows * cols, offset=pos)
    return raster.reshape(rows, cols).copy()
