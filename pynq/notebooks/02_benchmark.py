# ---
# jupyter:
#   jupytext:
#     formats: ipynb,py:percent
#     text_representation:
#       extension: .py
#       format_name: percent
#   kernelspec:
#     display_name: Python 3
#     language: python
#     name: python3
# ---

# %% [markdown]
# # 02 — Benchmark: NumPy vs OpenCV (A53) vs FPGA
#
# Median of N runs per implementation and frame size. "FPGA" time is the full
# call as seen from Python: register writes + DMA + IP + Otsu + register reads
# (cache flush/copy included). If a Vitis Vision overlay `overlay/sobel_vv.bit`
# exists it is measured too.
#
# On a laptop this runs with the software backend; the hardware rows are then
# just the golden model again and are labelled as such.

# %%
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path.cwd().parent))
from sobel_otsu import make_backend, golden   # noqa: E402
from golden.gen_vectors import synthetic_scene  # noqa: E402

try:
    import cv2
except ImportError:
    cv2 = None

N_RUNS = 100
SIZES = [(480, 640), (720, 1280), (1080, 1920)]
T = 64
sob = make_backend()
print("backend:", sob.name, "| OpenCV:", cv2.__version__ if cv2 else "missing")


def median_time(fn, n=N_RUNS):
    fn()                                   # warm-up (allocations, caches)
    ts = []
    for _ in range(n):
        t0 = time.perf_counter()
        fn()
        ts.append(time.perf_counter() - t0)
    return float(np.median(ts))


def numpy_sobel(img):
    """Vectorised NumPy: gradient + manual threshold (no Otsu: that is the fair
    comparison for mode 1)."""
    mag = golden.sobel_mag(img)
    return np.where(mag > T, 255, 0).astype(np.uint8)


def cv2_sobel(img):
    gx = cv2.Sobel(img, cv2.CV_16S, 1, 0, ksize=3)
    gy = cv2.Sobel(img, cv2.CV_16S, 0, 1, ksize=3)
    # min(|gx|,255) + min(|gy|,255) saturated == min(|gx|+|gy|,255): same as SPEC
    mag = cv2.add(cv2.convertScaleAbs(gx), cv2.convertScaleAbs(gy))
    _, out = cv2.threshold(mag, T, 255, cv2.THRESH_BINARY)
    return out


# %%
rows_out = []
for (h, w) in SIZES:
    img = synthetic_scene(h, w, seed=1)
    res = {"size": f"{w}x{h}"}
    res["numpy_ms"] = 1e3 * median_time(lambda: numpy_sobel(img), n=max(5, N_RUNS // 10))
    if cv2 is not None:
        res["opencv_ms"] = 1e3 * median_time(lambda: cv2_sobel(img))
        # interior agreement check: OpenCV vs our spec
        agree = np.array_equal(cv2_sobel(img)[1:-1, 1:-1], numpy_sobel(img)[1:-1, 1:-1])
        res["opencv_interior_bitexact"] = agree
    label = "fpga_ms" if sob.name == "hw" else "golden_sw_ms"
    n = N_RUNS if sob.name == "hw" else 5
    res[label] = 1e3 * median_time(lambda: sob.process(img, 1, T), n=n)
    # Ideal PL time at 1 pixel/clock, 150 MHz: (rows+1)*(cols+1) cycles
    res["pl_ideal_ms"] = 1e3 * (h + 1) * (w + 1) / 150e6
    rows_out.append(res)
    print(res)

# %%
try:
    import pandas as pd
    from IPython.display import display
    df = pd.DataFrame(rows_out)
    display(df)
    df.to_csv("benchmark_results.csv", index=False)
except ImportError:
    for r in rows_out:
        print(r)

# %% [markdown]
# ## Optional: Vitis Vision overlay
# Only if `overlay/sobel_vv.bit` exists (built from hls/sobel_vitisvision with
# the same block design, cell `sobel_vv_0`). Loading it **replaces** our
# overlay, so this cell runs last; re-run the first cell to get ours back.

# %%
vv_bit = Path.cwd().parent / "overlay" / "sobel_vv.bit"
if sob.name == "hw" and vv_bit.exists():
    # TODO(verify-on-board): minimal driver for the Vitis Vision overlay.
    from pynq import Overlay, allocate
    vv_ol = Overlay(str(vv_bit), ignore_version=True)
    dma, rm = vv_ol.axi_dma_0, vv_ol.sobel_vv_0.register_map
    for (h, w) in SIZES:
        img = synthetic_scene(h, w, seed=1)
        ib, ob = allocate(img.shape, np.uint8), allocate(img.shape, np.uint8)
        ib[:] = img
        ib.flush()

        def vv_run():
            rm.rows, rm.cols, rm.thresh = h, w, T
            rm.CTRL.AP_START = 1
            dma.recvchannel.transfer(ob)
            dma.sendchannel.transfer(ib)
            dma.sendchannel.wait()
            dma.recvchannel.wait()
            ob.invalidate()

        print(f"{w}x{h}: vitis_vision_ms = {1e3 * median_time(vv_run):.3f}")
        ib.freebuffer()
        ob.freebuffer()
else:
    print("Vitis Vision overlay not present (or software backend): skipped")
