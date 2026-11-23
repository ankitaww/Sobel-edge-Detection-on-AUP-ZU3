# SPEC — Self-tuning Sobel (`sobel_otsu`) — v1.0

This document is the **single source of truth**. The golden model
(`golden/sobel_golden.py`), the HLS IP (`hls/sobel_otsu/sobel_otsu.cpp`), the
C++ testbench and the PYNQ driver must all follow it bit-exactly. If code and
spec disagree, the code is wrong (or the spec is changed first, with a version
bump and a note in §9).

---

## 1. Frame format

| item | value |
|---|---|
| pixel | 8-bit unsigned grayscale, 0..255 |
| size | `rows × cols`, **3 ≤ rows ≤ 1080**, **3 ≤ cols ≤ 1920** |
| order | row-major, one pixel per AXI4-Stream beat, top-left first |
| output | same size and order as the input; one output beat per input beat |

Coordinates: `r` = row (0..rows-1), `c` = column (0..cols-1).
**Interior** pixel: `1 ≤ r ≤ rows-2` and `1 ≤ c ≤ cols-2`. Everything else is
the **border ring**. A frame always has at least 1 interior pixel.

## 2. Gradient (interior pixels only)

The 3×3 window centred on output pixel (r, c), in row order:

```
p1 p2 p3        (r-1, c-1) (r-1, c) (r-1, c+1)
p4 p5 p6   =    (r,   c-1) (r,   c) (r,   c+1)
p7 p8 p9        (r+1, c-1) (r+1, c) (r+1, c+1)
```

```
Gx  = (p3 + 2*p6 + p9) - (p1 + 2*p4 + p7)      range -1020..1020
Gy  = (p7 + 2*p8 + p9) - (p1 + 2*p2 + p3)      range -1020..1020
mag = min(|Gx| + |Gy|, 255)                     L1 norm, saturated, 0..255
```

All arithmetic is exact integer arithmetic (no rounding anywhere).

## 3. Registers and modes

| name | dir | type | meaning |
|---|---|---|---|
| `rows`, `cols` | in | int32 | frame size (precondition: within §1 limits) |
| `mode` | in | int32 | 0 = output `mag`; 1 = manual threshold; 2 = auto (Otsu); 3 = auto + smoothing |
| `thresh_manual` | in | int32 | T for mode 1 |
| `reset_state` | in | int32 | if ≠ 0 at start of a frame: `T_reg ← 64` and histogram cleared **before** processing |
| `thresh_used` | out | int32 | T applied to this frame (0 in mode 0) |
| `otsu_thresh` | out | int32 | Otsu result computed from **this** frame's histogram (all modes) |
| `edge_count` | out | int32 | number of interior pixels output as 255 (0 in mode 0) |

Persistent state (survives between frames / calls):

| state | type | initial value |
|---|---|---|
| `T_reg` | int, 8..200 after any update | 64 (power-on and after `reset_state`) |
| `hist[256]` | 22-bit unsigned counters | all 0 |

22 bits is enough: max interior pixels = 1078 × 1918 = 2 067 604 < 2²² = 4 194 304.

## 4. Per-frame processing (normative order)

```
1. if reset_state != 0:  T_reg = 64;  hist[*] = 0
2. T = thresh_manual  if mode == 1
       T_reg          if mode in (2, 3)
       (unused)       if mode == 0
   thresh_used = T if mode in (1, 2, 3) else 0
3. for every pixel (r, c) in row-major order:
       if border:   out = 0                       (not counted anywhere)
       else:
           compute mag (§2)
           hist[mag] += 1                         (every mode)
           if mode == 0:  out = mag
           else:          out = 255 if mag > T else 0     (strict >, signed int compare)
                          if out == 255: edge_count += 1
4. otsu_thresh = OTSU(hist)                       (§5, every mode)
5. mode 2: T_reg = clamp(otsu_thresh, 8, 200)
   mode 3: T_reg = clamp((3*T_reg + otsu_thresh) >> 2, 8, 200)
   mode 0, 1: T_reg unchanged
6. hist[*] = 0
```

`clamp(x, lo, hi) = min(max(x, lo), hi)`. In mode 3 `T_reg` on the right-hand
side is the value **before** the update (the one used as `T` for this frame);
`>>` is an arithmetic shift of a non-negative int (= floor division by 4).

Consequence for still images: running the same image twice in mode 2 (first
call with `reset_state=1`) applies the image's own Otsu threshold (clamped to
8..200) on pass 2.

## 5. Otsu (float32, exact operation order)

```
N  = Σ hist[i];  ST = Σ i*hist[i]                 (integers; ST < 2^30)
best_var = -1.0f; best_t = 0; W = 0; S = 0       (W, S integers)
for t in 0..255:
    W += hist[t]; S += t*hist[t]
    if W == 0 or W == N: continue
    w0 = float(W); w1 = float(N - W)
    mB = float(S) / w0
    mF = float(ST - S) / w1
    d  = mB - mF
    var = w0 * w1 * d * d                         evaluated left to right: ((w0*w1)*d)*d
    if var > best_var: best_var = var; best_t = t  (strict >, lowest t wins ties)
otsu = best_t
```

Rules that make hardware and golden agree bit-exactly:

* `float` = IEEE-754 binary32, round-to-nearest-even for every operation and
  for each int→float conversion. No FMA contraction, no reassociation, no
  "fast-math". (g++ testbench: `-ffp-contract=off`; HLS: default settings never
  reassociate float ops.)
* `float(S)` and `float(ST - S)` may round (S can exceed 2²⁴); that rounding is
  part of the spec.
* If every interior pixel has the same `mag` the loop never updates and
  `otsu = 0` (so mode 2 then sets `T_reg = 8`).

## 6. Stream side-channels (AXI4-Stream, `ap_axiu<8,1,1,1>`)

* Output: `TKEEP = TSTRB = 1` (all ones) on every beat, `TUSER = TID = TDEST = 0`,
  **`TLAST = 1` only on the last pixel of the frame** (the AXI DMA S2MM channel
  ends the transfer on TLAST).
* Input side-channels (including input TLAST) are ignored; the IP reads exactly
  `rows*cols` beats.

## 7. Preconditions / undefined behaviour

* `rows`, `cols` outside §1 limits: undefined (the IP's line buffer is
  `MAX_W = 1920` wide). The driver and golden model reject such sizes.
* `mode` outside 0..3: the IP and golden model treat it as **mode 0**
  (`thresh_used = 0`, `edge_count = 0`, `T_reg` unchanged).
* `thresh_manual` is compared as a signed 32-bit int, so T < 0 makes every
  interior pixel an edge and T ≥ 255 makes none. The driver restricts it to 0..255.

## 8. Timing contract (informative)

The pixel loop runs at II = 1 for `(rows+1) × (cols+1)` iterations (the extra
row/column flush the 1-row/1-column window delay). Otsu then takes a few
hundred to a few thousand cycles (two 256-iteration loops). `reset_state` adds
256 cycles for the explicit clear.

## 9. Change log / resolved ambiguities

v1.0 (initial). Decisions taken where the brief was silent:

1. `reset_state` is "≠ 0" (not only "== 1").
2. `thresh_used` in mode 0 is 0; `edge_count` in mode 0 is 0 (as in the brief);
   `otsu_thresh` is still computed in mode 0.
3. Mode 3's `T_reg` on the right-hand side is the pre-update value (= `thresh_used`).
4. Invalid `mode` values behave as mode 0 (§7).
5. `var` multiplication order fixed as `((w0*w1)*d)*d`.
6. Clearing the histogram in step 6 may be fused with the Otsu pass in
   hardware (read-then-zero); the observable result is identical.
7. The degenerate "all interior mags equal" case yields `otsu = 0` (§5).
