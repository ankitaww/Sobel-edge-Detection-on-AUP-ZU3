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
# # 03 — Live video: USB webcam → PL → display
#
# Grabs frames from a USB webcam (OpenCV), runs them through the IP in auto
# mode (T adapts frame to frame) or manual mode, and shows the result plus a
# live plot of the threshold and edge count.
#
# * Toggle manual/auto with the buttons; the slider sets the manual T.
# * On the board, slide switch 0 also toggles auto mode and the LEDs show T
#   (if the GPIO cells are in the overlay).
# * Without a camera, a synthetic scene with changing brightness is used, which
#   shows nicely how auto mode compensates and a fixed T does not.
#
# Display: frames are shown in the notebook (JPEG via IPython). For full-rate
# output, use the Mini DisplayPort — see the optional cell at the end.

# %%
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path.cwd().parent))
from sobel_otsu import make_backend          # noqa: E402
from golden.gen_vectors import synthetic_scene  # noqa: E402

import cv2
import ipywidgets as widgets
import matplotlib.pyplot as plt
from IPython.display import display

W, H = 640, 480
N_FRAMES = 300
sob = make_backend()
print("backend:", sob.name)

cap = cv2.VideoCapture(0)
if cap.isOpened():
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
    print("webcam OK")
else:
    cap = None
    base = synthetic_scene(H, W, seed=3)
    print("no webcam: using a synthetic scene with varying brightness")


def grab(i):
    if cap is not None:
        ok, frame = cap.read()
        if ok:
            return cv2.resize(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), (W, H))
    gain = 1.0 + 0.6 * np.sin(i / 25.0)            # 0.4x .. 1.6x
    return np.clip(base.astype(np.float32) * gain, 0, 255).astype(np.uint8)


# %%
mode_btn = widgets.ToggleButtons(options=[("auto", 3), ("manual", 1)], value=3, description="mode")
t_slider = widgets.IntSlider(value=64, min=0, max=255, description="manual T")
img_w = widgets.Image(format="jpeg", width=W, height=H)
display(widgets.VBox([widgets.HBox([mode_btn, t_slider]), img_w]))

# %%
hist_t, hist_e, hist_fps = [], [], []
reset = True
t_prev = time.perf_counter()
for i in range(N_FRAMES):
    frame = grab(i)
    mode = mode_btn.value
    if getattr(sob, "switches", None) and sob.switches() is not None:
        mode = 3 if (sob.switches() & 1) else mode    # switch 0 forces auto
    out, info = sob.process(frame, mode, t_slider.value, reset=reset)
    reset = False
    if hasattr(sob, "leds"):
        sob.leds(info["thresh_used"])
    hist_t.append(info["thresh_used"])
    hist_e.append(info["edge_count"])
    now = time.perf_counter()
    hist_fps.append(1.0 / max(now - t_prev, 1e-9))
    t_prev = now
    if i % 2 == 0:                                   # JPEG encode is the bottleneck
        img_w.value = cv2.imencode(".jpg", np.hstack([frame, out]))[1].tobytes()

if cap is not None:
    cap.release()

# %%
fig, ax = plt.subplots(3, 1, figsize=(10, 7), sharex=True)
ax[0].plot(hist_t); ax[0].set_ylabel("T used")
ax[1].plot(hist_e); ax[1].set_ylabel("edge count")
ax[2].plot(hist_fps); ax[2].set_ylabel("loop fps"); ax[2].set_xlabel("frame")
plt.tight_layout(); plt.show()
print(f"median loop rate: {np.median(hist_fps):.1f} fps (includes capture + notebook display)")

# %% [markdown]
# ## Optional: Mini DisplayPort output
# TODO(verify-on-board): PYNQ's `DisplayPort` class drives the PS DisplayPort on
# ZU boards. The mode/pixel-format API below follows the PYNQ 3.x docs; check it
# on the AUP-ZU3 before relying on it.

# %%
RUN_DP = False
if RUN_DP and sob.name == "hw":
    from pynq.lib.video import DisplayPort, VideoMode, PIXEL_GRAY
    dp = DisplayPort()
    dp.configure(VideoMode(W, H, 8), PIXEL_GRAY)
    for i in range(N_FRAMES):
        out, _ = sob.process(grab(i), 3)
        fb = dp.newframe()
        fb[:] = out
        dp.writeframe(fb)
    dp.close()
