"""Tests for the golden model.

The key check compares the vectorised golden model with a deliberately naive,
pixel-by-pixel re-implementation written straight from SPEC.md (including a
float32 Otsu done with the struct module, independent of NumPy).
"""
import struct
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from golden.pgm import read_pgm, write_pgm  # noqa: E402
from golden.sobel_golden import (  # noqa: E402
    State, otsu_threshold, process_still_auto, sobel_mag, sobel_otsu_frame,
)


# ---------------------------------------------------------------- naive reference
def f32(x: float) -> float:
    """Round a Python float to binary32 (round-to-nearest-even)."""
    return struct.unpack("f", struct.pack("f", x))[0]


def naive_otsu(hist):
    n = sum(hist)
    st = sum(i * h for i, h in enumerate(hist))
    best_var, best_t, w, s = -1.0, 0, 0, 0
    for t in range(256):
        w += hist[t]
        s += t * hist[t]
        if w == 0 or w == n:
            continue
        w0, w1 = f32(w), f32(n - w)
        mb = f32(f32(s) / w0)
        mf = f32(f32(st - s) / w1)
        d = f32(mb - mf)
        var = f32(f32(f32(w0 * w1) * d) * d)
        if var > best_var:
            best_var, best_t = var, t
    return best_t


def naive_frame(img, mode, tm, t_reg, reset):
    rows, cols = img.shape
    if mode not in (0, 1, 2, 3):
        mode = 0
    if reset:
        t_reg = 64
    t = tm if mode == 1 else t_reg
    hist = [0] * 256
    out = np.zeros_like(img)
    edges = 0
    for r in range(1, rows - 1):
        for c in range(1, cols - 1):
            p = [[int(img[r + i, c + j]) for j in (-1, 0, 1)] for i in (-1, 0, 1)]
            gx = (p[0][2] + 2 * p[1][2] + p[2][2]) - (p[0][0] + 2 * p[1][0] + p[2][0])
            gy = (p[2][0] + 2 * p[2][1] + p[2][2]) - (p[0][0] + 2 * p[0][1] + p[0][2])
            mag = min(abs(gx) + abs(gy), 255)
            hist[mag] += 1
            if mode == 0:
                out[r, c] = mag
            elif mag > t:
                out[r, c] = 255
                edges += 1
    otsu = naive_otsu(hist)
    if mode == 2:
        t_reg = min(max(otsu, 8), 200)
    elif mode == 3:
        t_reg = min(max((3 * t_reg + otsu) >> 2, 8), 200)
    info = {"thresh_used": 0 if mode == 0 else t, "otsu_thresh": otsu,
            "edge_count": edges if mode != 0 else 0}
    return out, info, t_reg


# ---------------------------------------------------------------- tests
@pytest.mark.parametrize("shape", [(3, 3), (4, 5), (7, 3), (3, 9), (17, 23), (32, 31)])
@pytest.mark.parametrize("mode", [0, 1, 2, 3, 5])
def test_matches_naive_reference(shape, mode):
    rng = np.random.default_rng(hash((shape, mode)) & 0xFFFF)
    img = rng.integers(0, 256, size=shape, dtype=np.uint8)
    for t_reg, reset in [(64, True), (37, False), (150, False)]:
        out, info, st = sobel_otsu_frame(img, mode, 90, State(t_reg), reset=reset)
        n_out, n_info, n_t = naive_frame(img, mode, 90, t_reg, reset)
        np.testing.assert_array_equal(out, n_out)
        assert info == n_info
        assert st.t_reg == n_t


def test_border_always_zero():
    img = np.full((10, 12), 200, np.uint8)
    img[::2] = 0
    for mode in range(4):
        out, _, _ = sobel_otsu_frame(img, mode, 0, reset=True)
        assert not out[0].any() and not out[-1].any()
        assert not out[:, 0].any() and not out[:, -1].any()


def test_hand_computed_step():
    # vertical step 0 | 100 between columns 2 and 3 -> Gx = 4*100 = 400 -> saturates
    img = np.zeros((5, 6), np.uint8)
    img[:, 3:] = 100
    mag = sobel_mag(img)
    assert mag[2, 2] == 255 and mag[2, 3] == 255
    assert mag[2, 1] == 0 and mag[2, 4] == 0
    # small step 0 | 10 -> |Gx| = 40, Gy = 0
    img[:, 3:] = 10
    assert sobel_mag(img)[2, 2] == 40


def test_flat_image_otsu_zero_and_clamp():
    img = np.full((8, 8), 77, np.uint8)
    out, info, st = sobel_otsu_frame(img, 2, state=State(), reset=True)
    assert info == {"thresh_used": 64, "otsu_thresh": 0, "edge_count": 0}
    assert st.t_reg == 8          # clamp(0, 8, 200)
    assert not out.any()


def test_otsu_two_clusters():
    hist = np.zeros(256, np.int64)
    hist[20] = 100
    hist[200] = 100
    # Every t in 20..199 separates the clusters equally; strict '>' keeps the lowest.
    assert otsu_threshold(hist) == 20


def test_mode_feedback_sequence():
    rng = np.random.default_rng(1)
    img = rng.integers(0, 256, (20, 20), dtype=np.uint8)
    _, i1, s1 = sobel_otsu_frame(img, 2, state=State(), reset=True)
    _, i2, s2 = sobel_otsu_frame(img, 2, state=s1)
    assert i1["thresh_used"] == 64
    assert i2["thresh_used"] == min(max(i1["otsu_thresh"], 8), 200)
    _, i3, s3 = sobel_otsu_frame(img, 3, state=s2)
    assert s3.t_reg == min(max((3 * s2.t_reg + i3["otsu_thresh"]) >> 2, 8), 200)
    # modes 0/1 never touch T_reg
    _, _, s4 = sobel_otsu_frame(img, 1, 10, state=s3)
    _, _, s5 = sobel_otsu_frame(img, 0, state=s4)
    assert s5.t_reg == s3.t_reg


def test_process_still_auto_uses_own_otsu():
    rng = np.random.default_rng(2)
    img = (rng.random((40, 50)) * 60).astype(np.uint8)
    img[:, 25:] += 120
    out, info = process_still_auto(img)
    assert info["thresh_used"] == min(max(info["otsu_thresh"], 8), 200)


def test_rejects_bad_frames():
    with pytest.raises(ValueError):
        sobel_otsu_frame(np.zeros((2, 5), np.uint8), 0)
    with pytest.raises(ValueError):
        sobel_otsu_frame(np.zeros((5, 1921), np.uint8), 0)
    with pytest.raises(ValueError):
        sobel_otsu_frame(np.zeros((5, 5), np.int16), 0)


def test_pgm_roundtrip(tmp_path):
    img = np.arange(35, dtype=np.uint8).reshape(5, 7)
    write_pgm(tmp_path / "a.pgm", img)
    np.testing.assert_array_equal(read_pgm(tmp_path / "a.pgm"), img)


def test_large_frame_float_rounding():
    """1080p: S exceeds 2^24, so float(S) rounds. Must still match the naive Otsu."""
    rng = np.random.default_rng(3)
    img = rng.integers(0, 256, (1080, 1920), dtype=np.uint8)
    mag = sobel_mag(img)
    hist = np.bincount(mag[1:-1, 1:-1].ravel(), minlength=256)
    assert otsu_threshold(hist) == naive_otsu([int(h) for h in hist])
