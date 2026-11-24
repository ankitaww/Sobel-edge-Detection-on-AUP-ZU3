# Self-tuning Sobel edge detection on the AUP-ZU3

Real-time Sobel edge detection in the programmable logic of an AMD Zynq
UltraScale+ (AUP-ZU3, 8 GB DDR4, XCZU3EG-2SFVC784E), controlled from Python
(PYNQ v3.1) on the Cortex-A53.

**What's unusual:** the IP tunes its own threshold. While frame N streams
through at 1 pixel/clock, it builds a 256-bin histogram of the gradient
magnitude. After the last pixel an Otsu engine picks the best threshold, which
is applied to frame N+1, optionally smoothed. For a still image, running it
twice gives the image's own Otsu threshold on the second pass.

Team: Deepak, &lt;member 2&gt;, &lt;member 3&gt;

```
camera/file ─► PS (Python) ─► DDR ─► AXI DMA ─► sobel_otsu (PL, 150 MHz) ─► AXI DMA ─► DDR ─► PS ─► display
                    └──────── AXI-Lite: rows, cols, mode, thresh ─► / ◄─ thresh_used, otsu_thresh, edge_count
```

| path | what |
|---|---|
| [spec/SPEC.md](spec/SPEC.md) | **pixel-exact specification: the source of truth** |
| [golden/](golden/) | NumPy golden model, PGM I/O, test-vector generator, pytest |
| [hls/sobel_otsu/](hls/sobel_otsu/) | HLS IP, C++ testbench, `run_hls.tcl` (2025.2 component flow) |
| [hls/sobel_vitisvision/](hls/sobel_vitisvision/) | optional `xf::cv::Sobel` baseline (needs Vitis_Libraries) |
| [vivado/](vivado/) | block design + bitstream script |
| [pynq/](pynq/) | driver `SobelOtsu` + `SoftwareBackend`, overlay, notebooks |
| [eval/](eval/) | BSDS500 F-score, brightness/contrast robustness |
| [docs/](docs/) | register map, design-review template |
| [build.bat](build.bat) / [build.sh](build.sh) | one-command build (Windows / Linux), no Python, git or make needed |

## Build on a laptop with only Vivado/Vitis

For a Windows laptop with just Vivado + Vitis 2025.2 installed (no Python, git
or make):

1. On GitHub: **Code → Download ZIP**.
2. Extract it so that `build.bat` ends up at **`C:\sobel\build.bat`**. Long
   paths or spaces break Vivado, and the script refuses them.
3. Once per laptop, install the AUP-ZU3 board files. Open Vivado, and in the
   Tcl console at the bottom run:
   ```tcl
   xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]
   xhub::install [xhub::get_xitems *aup-zu3*]
   ```
   (or *Tools → Vivado Store → Boards → AUP-ZU3 → Install*).
4. Open a Command Prompt and run:
   ```bat
   cd /d C:\sobel
   build.bat all
   ```
   This runs csim → synth → cosim → export → bit → board and stops at the
   first failure, printing the end of that step's log. The `bit` (Vivado) step
   takes longest; each step prints its elapsed time. If Vivado is not in `C:\Xilinx\2025.2` or
   `C:\AMDDesignTools\2025.2`, first run `set XILINX_ROOT=D:\path\to\2025.2`.
5. Upload `results\sobel_board.zip` to the board. `build.bat` prints the four
   steps at the end (Jupyter at `http://192.168.3.1:9090` → Upload → Terminal
   `unzip -o sobel_board.zip` → `%run 01_bringup.py` in `sobel/notebooks`).

Single steps: `build.bat csim`, `build.bat synth bit`, … Add `--dry-run` to see the
commands without running them. To change the clock or other settings, use
`set CLK_MHZ=125` (or `PART`, `COSIM_MAX_PIXELS`, `JOBS`) before calling the script.

What you get in `results\`:

| file | content |
|---|---|
| `logs\<step>.log` | full console output of each step |
| `hls_summary.txt` | pixel-loop II (big **WARNING** if ≠ 1), clock, 1080p latency in ms, LUT/FF/BRAM/DSP |
| `vivado_summary.txt` | Vivado version, board part, PL clock, WNS, utilization, power, GPIO cells (appended per run) |
| `timing_summary.rpt`, `utilization.rpt`, `power.rpt` | full Vivado reports |
| `sobel_board.zip` | everything the board needs |

On Linux, `./build.sh all` does the same (`XILINX_ROOT` defaults to
`/tools/Xilinx/2025.2`). The manual `make` / `vitis-run` / `vivado` commands
below still work as a fallback.

## Quick start (laptop, no board, no Xilinx tools)

```bash
python -m pip install -r requirements.txt     # or: make setup
make test                                     # golden model unit tests
make vectors                                  # regenerate hls/tb_data/ (committed; 107 frames, ~12 MB)
SOBEL_BACKEND=sw python eval/bsds_eval.py --synthetic
SOBEL_BACKEND=sw python eval/robustness_sweep.py --synthetic
make notebooks                                # .py -> .ipynb (open with Jupyter, runs with the SW backend)
```

On Windows, run `make` from Git Bash or MSYS2 (`mingw32-make` works). The
recipes use POSIX shell syntax. If `python3` isn't your interpreter, pass
`PYTHON=python` (or the path to a venv's python).

## Build order (machine with Vivado/Vitis 2025.2)

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh   # path depends on your install
make test vectors
make csim           # C simulation vs golden vectors, must print RESULT: PASS
make synth          # check the report: PIXEL loop II=1, timing at 150 MHz
make cosim          # RTL co-sim on the small sequences (COSIM_MAX_PIXELS=20000)
make export         # IP catalog zip
make regmap         # fills docs/register_map.md from the generated header
make bit            # Vivado: block design -> bitstream -> pynq/overlay/sobel_otsu.{bit,hwh}
```

`make bit` fails loudly if timing is not met (WNS < 0). Reports land in
`vivado/build/{timing_summary,utilization,power}.rpt`.

The Vivado script needs the **AUP-ZU3 board files** for the DDR4 preset. If
they are missing it prints the install commands:
`xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]` then
`xhub::install [xhub::get_xitems *aup-zu3*]`. It lists every matching board
part and picks the 8 GB one; override with `BOARD_PART=...`.

All tool settings are at the top of the [Makefile](Makefile): `XILINX_VERSION`,
`HLS`, `VIVADO`, `PART`, `CLK_MHZ`, `BOARD_IP`. If you change `CLK_MHZ`, change
it for both HLS and Vivado (one variable does both).

### Testbench without Vitis: `make tb-gpp`

The HLS testbench also builds with plain g++, but it needs the real Xilinx
headers `ap_int.h`, `hls_stream.h` and `ap_axi_sdata.h`:

```bash
make tb-gpp HLS_INCLUDE="$XILINX_HLS/include"          # from any Vitis install (copy the folder if needed)
```

The open-source repo [Xilinx/HLS_arbitrary_Precision_Types](https://github.com/Xilinx/HLS_arbitrary_Precision_Types)
only provides `ap_int.h`/`ap_fixed.h`. `hls_stream.h` and `ap_axi_sdata.h`
ship only with Vitis. You can pass several directories:
`HLS_INCLUDE="path/to/ap_types/include path/to/vitis/include"`. The repo
contains no stand-in headers on purpose.

## Running on the board

1. Flash the **PYNQ v3.1 AUP-ZU3** image to the SD card and boot. Connect USB-C
   to your PC: the board appears as a network adapter at `192.168.3.1`.
2. `make deploy` copies the driver, overlay, notebooks and golden model to
   `xilinx@192.168.3.1:/home/xilinx/jupyter_notebooks/sobel/` (password `xilinx`).
   Change the address with `make deploy BOARD_IP=...`.
3. Open Jupyter at `http://192.168.3.1:9090` → `sobel/notebooks/`:
   * `01_bringup` loads the overlay and checks every mode bit-exact against the golden model. It must print `PASS`.
   * `02_benchmark` times NumPy, OpenCV (A53), FPGA and the Vitis Vision overlay if present.
   * `03_live_video` runs USB webcam → PL → notebook, with a live T/edge-count plot and a manual/auto toggle.
4. The eval scripts can also run on the board through the FPGA:
   `SOBEL_BACKEND=hw python3 eval/bsds_eval.py` (copy `eval/` and the dataset over first).

Driver in a nutshell:

```python
from sobel_otsu import SobelOtsu, SoftwareBackend, make_backend
sob = SobelOtsu("overlay/sobel_otsu.bit", ignore_version=True)   # or make_backend("hw"/"sw"/"auto")
out, info = sob.process(img, mode=2, reset=True)   # info: thresh_used, otsu_thresh, edge_count, time_s
out, info = sob.process_still_auto(img)            # two passes, returns the self-tuned one
sob.stats()
```

Modes: 0 = magnitude, 1 = manual threshold, 2 = auto (Otsu), 3 = auto + smoothing.
See [SPEC.md §3–4](spec/SPEC.md).

### Version mismatch (PYNQ v3.1 vs Vivado 2025.2)

PYNQ v3.1 was released with Vivado **2024.1**; we build with **2025.2**. A
simple design (DMA + HLS IP + GPIO) normally still loads with
`Overlay(bitfile, ignore_version=True)`, which the driver passes through
(`make_backend()` sets it by default).

**If the overlay does not load or behaves strangely on the board, rebuild with
Vivado/Vitis 2024.1.** Install 2024.1, set `XILINX_VERSION ?= 2024.1` in the
Makefile, source the 2024.1 `settings64.sh`, then run `make export bit`.
TODO(verify-in-vitis): `run_hls.tcl` uses the `open_component` / `vitis-run`
flow, which we expect 2024.1 to support as well. If not, use
`HLS="vitis_hls -f"` and replace `open_component`/`close_component` with
`open_project`/`open_solution`/`close_project`.

## Verification status

| what | status |
|---|---|
| golden model vs independent naive reference (pytest, 39 tests) | ✅ passes |
| test vectors (107 frames, 14 sequences incl. 3×3, 4×5, 1080p, T_reg feedback) | ✅ committed; pytest checks they match the generator |
| HLS C++ logic vs golden (all 107 frames, 0 mismatches) | ✅ with g++ and a throwaway local stream shim; **real csim not run yet** |
| `make csim` / `synth` / `cosim` / `export` | ⏳ TODO(verify-in-vitis) |
| `make bit` (block design, timing) | ⏳ TODO(verify-in-vivado) |
| `build.bat` / `build.sh` | ✅ full flow run with stub `vitis-run`/`vivado` (Windows 11 + Git Bash); ⏳ TODO(verify-on-windows) with the real tools |
| driver `SobelOtsu` on the board | ⏳ TODO(verify-on-board) |
| `SoftwareBackend`, notebooks 01/02, eval scripts (synthetic data) | ✅ run on a laptop |

## Evaluation plan

| question | where |
|---|---|
| bit-exact vs golden | `make csim`, `make cosim`, notebook 01 |
| speed: NumPy / OpenCV (A53) / HLS / Vitis Vision | notebook 02 (median of 100 runs) |
| FPGA resources, timing, power | `vivado/build/*.rpt`, HLS csynth report |
| edge quality on BSDS500 | `eval/bsds_eval.py` (fixed T tuned on train vs auto) |
| robustness to brightness/contrast (0.4×–1.6×) | `eval/robustness_sweep.py` |

First result (synthetic scenes, software backend, `eval/results/`):
auto-threshold F stays ≈ 0.70 for gains 0.4×–1.2× while the fixed T drops
from 0.81 to 0.54 at 0.4×. Above ~1.2× the auto mode gets *worse*: `mag`
saturates at 255, the histogram piles up in the top bin and Otsu's threshold
drops. That's worth discussing in the report. BSDS500 numbers are still to
come.
