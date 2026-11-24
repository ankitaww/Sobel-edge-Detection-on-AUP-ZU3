"""Generate HLS testbench vectors from the golden model.

Writes into hls/tb_data/ (default):
    inputs/<image>.pgm        input frames
    expected/<NNN>.pgm        expected output of frame NNN
    cases.txt                 one line per frame, executed in order by the testbench

cases.txt columns (whitespace separated, '#' = comment):
    seq  frame_id  input  expected  mode  thresh_manual  reset  thresh_used  otsu_thresh  edge_count

Frames with the same `seq` form a sequence: they must run back-to-back because
T_reg carries over between them. Every sequence starts with reset=1, so
sequences are independent and the testbench may skip a whole sequence (e.g. the
1080p one during cosim) without breaking the others.

Usage:  python golden/gen_vectors.py [--out hls/tb_data] [--no-large]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from golden.pgm import write_pgm  # noqa: E402
from golden.sobel_golden import State, sobel_otsu_frame  # noqa: E402


# ---------------------------------------------------------------- test images
def synthetic_scene(rows: int, cols: int, seed: int = 0) -> np.ndarray:
    """Smooth background + a few shapes + mild noise: a stand-in for a real photo."""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:rows, 0:cols].astype(np.float32)
    img = 60 + 50 * (x / cols) + 30 * np.sin(y / rows * 3.0)
    for _ in range(12):
        cy, cx = rng.uniform(0, rows), rng.uniform(0, cols)
        rad = rng.uniform(0.03, 0.15) * min(rows, cols)
        val = rng.uniform(-70, 120)
        if rng.random() < 0.5:
            img[(y - cy) ** 2 + (x - cx) ** 2 < rad ** 2] += val
        else:
            img[(abs(y - cy) < rad) & (abs(x - cx) < 1.6 * rad)] += val
    img += rng.normal(0, 4, img.shape)
    return np.clip(img, 0, 255).astype(np.uint8)


def make_images(large: bool) -> dict[str, np.ndarray]:
    rng = np.random.default_rng(1234)
    imgs: dict[str, np.ndarray] = {}
    imgs["rand3x3"] = rng.integers(0, 256, (3, 3), dtype=np.uint8)
    imgs["rand4x5"] = rng.integers(0, 256, (4, 5), dtype=np.uint8)
    imgs["rand7x11"] = rng.integers(0, 256, (7, 11), dtype=np.uint8)
    imgs["rand33x47"] = rng.integers(0, 256, (33, 47), dtype=np.uint8)
    imgs["wide3x1920"] = rng.integers(0, 256, (3, 1920), dtype=np.uint8)
    imgs["tall1080x3"] = rng.integers(0, 256, (1080, 3), dtype=np.uint8)
    imgs["black16x16"] = np.zeros((16, 16), np.uint8)
    imgs["white16x16"] = np.full((16, 16), 255, np.uint8)
    step_v = np.zeros((24, 31), np.uint8)
    step_v[:, 15:] = 180
    imgs["stepv24x31"] = step_v
    step_h = np.zeros((25, 30), np.uint8)
    step_h[12:, :] = 40
    imgs["steph25x30"] = step_h
    imgs["ramp20x64"] = np.tile(np.arange(64, dtype=np.uint8) * 4, (20, 1))
    yy, xx = np.mgrid[0:32, 0:40]
    imgs["checker32x40"] = (((yy // 4 + xx // 4) % 2) * 255).astype(np.uint8)
    scene = synthetic_scene(480, 640, seed=7)
    imgs["scene640x480"] = scene
    imgs["scene640x480_dark"] = (scene.astype(np.float32) * 0.45).astype(np.uint8)
    if large:
        imgs["scene1920x1080"] = synthetic_scene(1080, 1920, seed=8)
    return imgs


# ---------------------------------------------------------------- sequences
def make_sequences(imgs: dict[str, np.ndarray]):
    """Return a list of sequences; each is a list of (image, mode, thresh_manual, reset)."""
    seqs = []
    small = ["rand3x3", "rand4x5", "rand7x11", "rand33x47", "wide3x1920", "tall1080x3",
             "black16x16", "white16x16", "stepv24x31", "steph25x30", "ramp20x64", "checker32x40"]
    for name in small:
        # every mode, plus a second auto pass so T_reg feedback is exercised on each image
        seqs.append([(name, 0, 64, 1), (name, 1, 50, 0), (name, 1, 0, 0), (name, 1, 255, 0),
                     (name, 2, 0, 0), (name, 2, 0, 0), (name, 3, 0, 0), (name, 7, 0, 0)])
    # still-image auto: same image twice in mode 2, then a darker image in mode 3 (smoothing)
    seqs.append([("scene640x480", 2, 0, 1), ("scene640x480", 2, 0, 0),
                 ("scene640x480_dark", 3, 0, 0), ("scene640x480_dark", 3, 0, 0),
                 ("scene640x480_dark", 1, 40, 0), ("scene640x480_dark", 0, 0, 0),
                 ("scene640x480_dark", 3, 0, 0),
                 ("scene640x480", 2, 0, 1)])          # mid-sequence reset
    if "scene1920x1080" in imgs:
        seqs.append([("scene1920x1080", 2, 0, 1), ("scene1920x1080", 2, 0, 0),
                     ("scene1920x1080", 0, 0, 0)])
    return seqs


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[1] / "hls" / "tb_data"))
    ap.add_argument("--no-large", action="store_true", help="skip the 1920x1080 sequence")
    args = ap.parse_args()

    out = Path(args.out)
    (out / "inputs").mkdir(parents=True, exist_ok=True)
    (out / "expected").mkdir(parents=True, exist_ok=True)

    imgs = make_images(large=not args.no_large)
    for name, img in imgs.items():
        write_pgm(out / "inputs" / f"{name}.pgm", img)

    lines = ["# seq frame input expected mode thresh_manual reset thresh_used otsu_thresh edge_count"]
    frame_id = 0
    for seq_id, seq in enumerate(make_sequences(imgs)):
        state = State()
        for name, mode, tm, reset in seq:
            res, info, state = sobel_otsu_frame(imgs[name], mode, tm, state, reset=bool(reset))
            exp = f"expected/{frame_id:03d}.pgm"
            write_pgm(out / exp, res)
            lines.append(f"{seq_id} {frame_id} inputs/{name}.pgm {exp} {mode} {tm} {reset} "
                         f"{info['thresh_used']} {info['otsu_thresh']} {info['edge_count']}")
            frame_id += 1
    # Bytes, not text mode: always LF line endings, so the committed vectors are
    # identical whether they were generated on Windows or Linux.
    (out / "cases.txt").write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    print(f"wrote {len(imgs)} images, {frame_id} frames -> {out}")


if __name__ == "__main__":
    main()
