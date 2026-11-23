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
# # 01 — Bring-up: load the overlay and check bit-exactness
#
# Runs the same synthetic test images the HLS testbench uses through the
# backend (FPGA if available, otherwise the software golden model), compares
# every pixel and register with the golden model, and shows a few results.
#
# Set `SOBEL_BACKEND=sw` to force the laptop path, `hw` to insist on the board.

# %%
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

HERE = Path.cwd()
sys.path.insert(0, str(HERE.parent))          # pynq/ -> sobel_otsu.py
from sobel_otsu import make_backend, golden   # noqa: E402
from golden.gen_vectors import make_images    # noqa: E402

sob = make_backend()
print("backend:", sob.name)
if sob.name == "hw":
    print(sob.overlay.ip_dict.keys())
    print(sob.ip.register_map)

# %% [markdown]
# ## Register sanity check
# Mode 1 with a fixed threshold on a vertical step: we know the answer by hand.

# %%
step = np.zeros((8, 10), np.uint8)
step[:, 5:] = 100
out, info = sob.process(step, mode=1, thresh_manual=50, reset=True)
print(info)
print(out)
# interior columns 4 and 5 are edges, 6 interior rows -> 12 edge pixels
assert info["edge_count"] == 12, info

# %% [markdown]
# ## Bit-exact comparison against the golden model, every mode
# Each image runs as a sequence (reset, then modes 0,1,2,2,3) so the T_reg
# feedback is compared too.

# %%
imgs = make_images(large=True)
fails = 0
for name, img in imgs.items():
    st = golden.State()
    for k, (mode, tm) in enumerate([(0, 64), (1, 50), (2, 0), (2, 0), (3, 0)]):
        reset = k == 0
        hw_out, hw_info = sob.process(img, mode, tm, reset=reset)
        g_out, g_info, st = golden.sobel_otsu_frame(img, mode, tm, st, reset=reset)
        bad = int(np.count_nonzero(hw_out != g_out))
        regs_ok = all(hw_info[k2] == g_info[k2] for k2 in g_info)
        if bad or not regs_ok:
            fails += 1
            print(f"MISMATCH {name} mode {mode}: {bad} pixels, hw {hw_info} golden {g_info}")
print("PASS" if fails == 0 else f"FAIL ({fails} frames)")

# %% [markdown]
# ## Look at the result

# %%
img = imgs["scene640x480"]
mag, _ = sob.process(img, mode=0, reset=True)
auto_out, auto_info = sob.process_still_auto(img)
fig, ax = plt.subplots(1, 3, figsize=(15, 4))
ax[0].imshow(img, cmap="gray"); ax[0].set_title("input")
ax[1].imshow(mag, cmap="gray"); ax[1].set_title("mode 0: |Gx|+|Gy|")
ax[2].imshow(auto_out, cmap="gray"); ax[2].set_title(f"auto (Otsu T={auto_info['thresh_used']})")
for a in ax:
    a.axis("off")
plt.show()
print(sob.stats())
