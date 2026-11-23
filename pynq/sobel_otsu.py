"""Python driver for the self-tuning Sobel overlay (AUP-ZU3 / PYNQ v3.1).

Two backends with the same API:

* ``SobelOtsu``       — the FPGA: AXI DMA moves the frame through the HLS IP,
                        AXI-Lite registers are accessed via ``register_map``.
* ``SoftwareBackend`` — the golden model (golden/sobel_golden.py), so notebooks
                        and eval/ scripts run on a laptop without a board.

Pick one with ``make_backend()``: argument ``"hw"``/``"sw"``/``"auto"`` or the
``SOBEL_BACKEND`` environment variable (``auto`` = hardware if ``pynq`` imports
and the bitstream exists, else software).

    from sobel_otsu import make_backend
    sob = make_backend()                 # or SobelOtsu("overlay/sobel_otsu.bit", ignore_version=True)
    out, info = sob.process(img, mode=2, reset=True)
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import numpy as np

_HERE = Path(__file__).resolve().parent
DEFAULT_BITFILE = _HERE / "overlay" / "sobel_otsu.bit"

# The golden model lives in ../golden in the repo; `make deploy` copies it next
# to this file on the board (pynq/golden/). Support both layouts.
for _p in (_HERE, _HERE.parent):
    if (_p / "golden" / "sobel_golden.py").exists() and str(_p) not in sys.path:
        sys.path.insert(0, str(_p))
from golden import sobel_golden as golden  # noqa: E402

MODES = {"mag": 0, "manual": 1, "auto": 2, "auto_smooth": 3}


def _check_args(img: np.ndarray, mode: int, thresh_manual: int) -> np.ndarray:
    img = np.ascontiguousarray(img)
    golden.check_frame(img)                      # same size limits as the IP (SPEC §1)
    if mode not in (0, 1, 2, 3):
        raise ValueError("mode must be 0..3")
    if not 0 <= int(thresh_manual) <= 255:
        raise ValueError("thresh_manual must be 0..255")
    return img


class _Base:
    def __init__(self) -> None:
        self._last: dict = {}

    def process(self, img, mode, thresh_manual=64, reset=False):   # pragma: no cover - interface
        raise NotImplementedError

    def process_still_auto(self, img):
        """Still image in auto mode: pass 1 (with reset) measures, pass 2 applies
        the image's own Otsu threshold. Returns pass 2's (out, info)."""
        self.process(img, golden.MODE_AUTO, reset=True)
        return self.process(img, golden.MODE_AUTO)

    def stats(self) -> dict:
        """Registers and timing of the last process() call."""
        return dict(self._last)


# ============================================================================ software
class SoftwareBackend(_Base):
    """Golden-model backend with the same API and state behaviour as the IP."""

    name = "sw"

    def __init__(self) -> None:
        super().__init__()
        self._state = golden.State()

    def process(self, img, mode, thresh_manual=64, reset=False):
        img = _check_args(img, mode, thresh_manual)
        t0 = time.perf_counter()
        out, info, self._state = golden.sobel_otsu_frame(img, mode, thresh_manual, self._state, reset=reset)
        info = dict(info, time_s=time.perf_counter() - t0, t_reg_next=self._state.t_reg)
        self._last = info
        return out, info


# ============================================================================ hardware
class SobelOtsu(_Base):
    """FPGA backend.

    Args:
        bitfile: path to sobel_otsu.bit (the .hwh with the same stem must sit next to it).
        ignore_version: passed to pynq.Overlay. Needed when the bitstream was built
            with a newer Vivado (e.g. 2025.1) than the PYNQ image expects (2024.1).
        timeout_s: per-frame DMA/IP timeout.
    """

    name = "hw"

    # TODO(verify-on-board): this class has not been run on an AUP-ZU3 yet
    # (written against the PYNQ 3.x DMA/register_map API).
    def __init__(self, bitfile=DEFAULT_BITFILE, ignore_version=False, timeout_s=2.0):
        super().__init__()
        from pynq import Overlay, allocate   # imported here so the module loads on a laptop
        self._allocate = allocate
        self.timeout_s = timeout_s
        try:
            self.overlay = Overlay(str(bitfile), ignore_version=ignore_version)
        except Exception as e:  # PYNQ raises different types across versions
            hint = ""
            if "version" in str(e).lower() and not ignore_version:
                hint = ("\nHint: the bitstream was built with a different Vivado version than this "
                        "PYNQ image expects. Retry with SobelOtsu(..., ignore_version=True); if it "
                        "still fails, rebuild the overlay with Vivado 2024.1 (see README).")
            raise RuntimeError(f"Could not load overlay {bitfile}: {e}{hint}") from e
        # Cell names are fixed by vivado/create_project.tcl.
        self.ip = self.overlay.sobel_otsu_0
        self.dma = self.overlay.axi_dma_0
        self.gpio_sw = getattr(self.overlay, "gpio_sw", None)
        self.gpio_led = getattr(self.overlay, "gpio_led", None)
        self._shape = None
        self._in = self._out = None

    # ---------------------------------------------------------------- buffers
    def _buffers(self, shape):
        """Re-allocate the contiguous DMA buffers only when the frame size changes."""
        if shape != self._shape:
            for b in (self._in, self._out):
                if b is not None:
                    b.freebuffer()
            self._in = self._allocate(shape=shape, dtype=np.uint8)
            self._out = self._allocate(shape=shape, dtype=np.uint8)
            self._shape = shape
        return self._in, self._out

    def _dma_status(self) -> str:
        rm = self.dma.register_map
        try:
            return f"MM2S_DMASR={rm.MM2S_DMASR}\nS2MM_DMASR={rm.S2MM_DMASR}"
        except AttributeError:   # register names differ between DMA versions
            return (f"MM2S_DMASR=0x{self.dma.read(0x04):08x} S2MM_DMASR=0x{self.dma.read(0x34):08x}"
                    " (raw read: register_map names not found)")

    def _wait(self, cond, what):
        t_end = time.perf_counter() + self.timeout_s
        while not cond():
            if time.perf_counter() > t_end:
                raise TimeoutError(
                    f"Timeout ({self.timeout_s}s) waiting for {what}.\n{self._dma_status()}\n"
                    f"sobel_otsu CTRL={self.ip.register_map.CTRL}\n"
                    "Common causes: wrong rows/cols, IP not started, TLAST missing, DMA length "
                    "register too narrow (needs 26 bits for 1080p).")

    # ---------------------------------------------------------------- main call
    def process(self, img, mode, thresh_manual=64, reset=False):
        """Send one frame through the IP. Returns (out, info) like the golden model."""
        img = _check_args(img, mode, thresh_manual)
        rows, cols = img.shape
        inb, outb = self._buffers(img.shape)
        inb[:] = img
        inb.flush()                    # CPU cache -> DDR before the DMA reads it
        outb.invalidate()              # drop stale cache lines before the DMA writes

        rm = self.ip.register_map      # never hard-code offsets: names come from the .hwh
        rm.rows = rows
        rm.cols = cols
        rm.mode = mode
        rm.thresh_manual = int(thresh_manual)
        rm.reset_state = 1 if reset else 0

        t0 = time.perf_counter()
        rm.CTRL.AP_START = 1
        # Receive first, so the S2MM channel is ready before the first output beat.
        self.dma.recvchannel.transfer(outb)
        self.dma.sendchannel.transfer(inb)
        self._wait(lambda: self.dma.sendchannel.idle, "DMA MM2S (send)")
        self._wait(lambda: self.dma.recvchannel.idle, "DMA S2MM (receive)")
        # The IP still runs Otsu after the last pixel left: wait for ap_idle
        # before reading the output registers (AP_DONE is clear-on-read, AP_IDLE is not).
        self._wait(lambda: int(rm.CTRL.AP_IDLE) == 1, "sobel_otsu ap_idle")
        t1 = time.perf_counter()

        outb.invalidate()
        out = np.array(outb)           # copy out of the CMA buffer
        info = {
            "thresh_used": int(rm.thresh_used),
            "otsu_thresh": int(rm.otsu_thresh),
            "edge_count": int(rm.edge_count),
            "time_s": t1 - t0,
        }
        self._last = info
        return out, info

    def leds(self, value: int) -> None:
        if self.gpio_led is not None:
            self.gpio_led.channel1.write(value & 0xFF, 0xFF)

    def switches(self) -> int | None:
        return None if self.gpio_sw is None else int(self.gpio_sw.channel1.read())

    def close(self) -> None:
        for b in (self._in, self._out):
            if b is not None:
                b.freebuffer()
        self._in = self._out = self._shape = None


# ============================================================================ factory
def make_backend(kind: str | None = None, bitfile=DEFAULT_BITFILE, ignore_version=True):
    """Return SobelOtsu ("hw"), SoftwareBackend ("sw") or, for "auto", whichever works.

    kind defaults to $SOBEL_BACKEND, then "auto". ignore_version defaults to True
    here because our bitstreams are built with Vivado 2025.1 (see README).
    """
    kind = (kind or os.environ.get("SOBEL_BACKEND", "auto")).lower()
    if kind == "sw":
        return SoftwareBackend()
    if kind == "hw":
        return SobelOtsu(bitfile, ignore_version=ignore_version)
    if kind != "auto":
        raise ValueError("backend must be 'hw', 'sw' or 'auto'")
    try:
        import pynq  # noqa: F401
    except ImportError:
        return SoftwareBackend()
    if not Path(bitfile).exists():
        return SoftwareBackend()
    return SobelOtsu(bitfile, ignore_version=ignore_version)
