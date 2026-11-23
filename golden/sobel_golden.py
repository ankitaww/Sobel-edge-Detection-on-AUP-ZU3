"""Golden (reference) model of the self-tuning Sobel IP.

Pure NumPy, follows spec/SPEC.md exactly. Every other implementation (HLS C++,
FPGA, driver) is checked against this file, so keep it simple and obviously
correct rather than fast.

Typical use::

    from golden.sobel_golden import sobel_otsu_frame, State
    out, info, state = sobel_otsu_frame(img, mode=2, thresh_manual=0, state=State(), reset=True)
    out, info, state = sobel_otsu_frame(img, mode=2, thresh_manual=0, state=state)
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

MIN_DIM = 3
MAX_ROWS = 1080
MAX_COLS = 1920
T_RESET = 64      # SPEC §3: T_reg power-on / reset value
T_MIN, T_MAX = 8, 200   # SPEC §4 step 5 clamp range
HIST_BITS = 22    # SPEC §3: histogram counter width

MODE_MAG, MODE_MANUAL, MODE_AUTO, MODE_AUTO_SMOOTH = 0, 1, 2, 3


@dataclass(frozen=True)
class State:
    """Persistent IP state between frames.

    Only T_reg is stored: the histogram is cleared at the end of every frame
    (SPEC §4 step 6), so between frames it is always all-zero.
    """
    t_reg: int = T_RESET


def check_frame(img: np.ndarray) -> None:
    """Raise ValueError unless img is a valid SPEC §1 frame."""
    if img.ndim != 2 or img.dtype != np.uint8:
        raise ValueError(f"expected 2-D uint8 image, got shape {img.shape} dtype {img.dtype}")
    rows, cols = img.shape
    if not (MIN_DIM <= rows <= MAX_ROWS and MIN_DIM <= cols <= MAX_COLS):
        raise ValueError(f"frame {rows}x{cols} outside {MIN_DIM}..{MAX_ROWS} x {MIN_DIM}..{MAX_COLS}")


def sobel_mag(img: np.ndarray) -> np.ndarray:
    """SPEC §2: L1 gradient magnitude, saturated to 255; border ring = 0. Returns uint8."""
    p = img.astype(np.int32)
    p1, p2, p3 = p[:-2, :-2], p[:-2, 1:-1], p[:-2, 2:]
    p4, p6 = p[1:-1, :-2], p[1:-1, 2:]
    p7, p8, p9 = p[2:, :-2], p[2:, 1:-1], p[2:, 2:]
    gx = (p3 + 2 * p6 + p9) - (p1 + 2 * p4 + p7)
    gy = (p7 + 2 * p8 + p9) - (p1 + 2 * p2 + p3)
    mag = np.zeros(img.shape, dtype=np.uint8)
    mag[1:-1, 1:-1] = np.minimum(np.abs(gx) + np.abs(gy), 255)
    return mag


def histogram(mag: np.ndarray) -> np.ndarray:
    """256-bin histogram of the interior magnitudes (border excluded). int64 array."""
    return np.bincount(mag[1:-1, 1:-1].ravel(), minlength=256).astype(np.int64)


def otsu_threshold(hist: np.ndarray) -> int:
    """SPEC §5, float32 arithmetic in exactly the specified order.

    Every float operation is done on np.float32 scalars so the rounding matches
    the hardware's binary32 operators.
    """
    hist = [int(h) for h in hist]
    n = sum(hist)
    st = sum(i * h for i, h in enumerate(hist))
    best_var = np.float32(-1.0)
    best_t = 0
    w = 0
    s = 0
    for t in range(256):
        w += hist[t]
        s += t * hist[t]
        if w == 0 or w == n:
            continue
        w0 = np.float32(w)
        w1 = np.float32(n - w)
        m_b = np.float32(s) / w0
        m_f = np.float32(st - s) / w1
        d = m_b - m_f
        var = w0 * w1 * d * d          # ((w0*w1)*d)*d, all float32
        if var > best_var:
            best_var = var
            best_t = t
    return best_t


def _clamp(x: int, lo: int = T_MIN, hi: int = T_MAX) -> int:
    return min(max(x, lo), hi)


def sobel_otsu_frame(img: np.ndarray, mode: int, thresh_manual: int = 64,
                     state: State | None = None, reset: bool = False):
    """Process one frame exactly like the IP (SPEC §4).

    Args:
        img: 2-D uint8 frame.
        mode: 0 magnitude, 1 manual, 2 auto, 3 auto + smoothing (others -> 0).
        thresh_manual: T for mode 1 (signed int compare).
        state: persistent state before this frame; None = power-on state.
        reset: value of the reset_state register.

    Returns:
        (out, info, new_state) where out is uint8 like img, info is a dict with
        the output registers thresh_used / otsu_thresh / edge_count.
    """
    check_frame(img)
    state = State() if state is None else state
    if mode not in (0, 1, 2, 3):
        mode = MODE_MAG                         # SPEC §7
    t_reg = T_RESET if reset else state.t_reg   # step 1 (hist is already zero)

    mag = sobel_mag(img)
    hist = histogram(mag)

    if mode == MODE_MAG:
        out = mag
        thresh_used = 0
        edge_count = 0
    else:
        t = int(thresh_manual) if mode == MODE_MANUAL else t_reg
        thresh_used = t
        out = np.zeros_like(img)
        interior = mag[1:-1, 1:-1].astype(np.int64)
        edges = interior > t
        out[1:-1, 1:-1][edges] = 255
        edge_count = int(edges.sum())

    otsu = otsu_threshold(hist)
    if mode == MODE_AUTO:
        t_reg = _clamp(otsu)
    elif mode == MODE_AUTO_SMOOTH:
        t_reg = _clamp((3 * t_reg + otsu) >> 2)

    info = {"thresh_used": thresh_used, "otsu_thresh": otsu, "edge_count": edge_count}
    return out, info, State(t_reg=t_reg)


def process_still_auto(img: np.ndarray):
    """Two passes in mode 2 (first with reset); returns the second pass (out, info)."""
    _, _, st = sobel_otsu_frame(img, MODE_AUTO, state=State(), reset=True)
    out, info, _ = sobel_otsu_frame(img, MODE_AUTO, state=st)
    return out, info
