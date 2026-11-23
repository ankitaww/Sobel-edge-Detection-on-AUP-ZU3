# CLAUDE.md — rules for AI-assisted work on this repo

Project: self-tuning Sobel edge detector (HLS IP + PYNQ driver) on the AMD
AUP-ZU3 (XCZU3EG, 8 GB), Vivado/Vitis 2025.1, PYNQ v3.1. See README.md.

## Non-negotiable rules

1. **spec/SPEC.md is the source of truth.** Behaviour changes start in the
   spec (bump the version, add a §9 change-log line), then golden model, then
   vectors, then HLS, then driver. Never "fix" the golden model to match the HLS.
2. **Golden first.** `golden/sobel_golden.py` must change and pass
   `make test` before any HLS change that alters behaviour.
3. **Bit-exact or it's a bug.** HLS csim, cosim and the board must match the
   golden output pixel-for-pixel and register-for-register. No tolerances.
   Float Otsu: keep the exact SPEC §5 operation order, float32, no FMA
   (`-ffp-contract=off`), no `-ffast-math`, no reassociation.
4. **Never hard-code register offsets** in Python. Use
   `ip.register_map.<name>` (names come from the .hwh). Offsets in
   docs/register_map.md are documentation only.
5. **Stable names.** Block-design cells `sobel_otsu_0`, `axi_dma_0`,
   `gpio_sw`, `gpio_led`, and the IP VLNV `xilinx.com:hls:sobel_otsu:1.0`
   are a contract with the driver.
6. **Be honest about verification.** Anything not run in Vitis/Vivado or on
   the board carries `TODO(verify-in-vitis)`, `TODO(verify-in-vivado)` or
   `TODO(verify-on-board)`. Remove the marker only after it was actually run,
   and say in the commit message what was run.
7. Tool versions live in one place: `XILINX_VERSION` / `HLS` / `VIVADO` at
   the top of the Makefile (and the Tcl env defaults).

## HLS coding rules

* No dynamic memory, recursion, `std::` containers or virtual functions in
  `hls/sobel_otsu/sobel_otsu.cpp` (testbench may use std::vector).
* Every pragma gets a comment saying *why*.
* `ap_uint<N> << k` keeps width N — widen before shifting.
* Pixel loop must stay II=1; check the csynth report after every change.
* 2025.1 flow: `vitis-run --mode hls --tcl run_hls.tcl`, `open_component`,
  not `vitis_hls -f` / `open_project`.

## Workflow

```
make test            # golden unit tests (always)
make vectors         # after any golden change
make csim            # or: make tb-gpp HLS_INCLUDE=$XILINX_HLS/include
make synth cosim     # before merging HLS changes
```

Add a test vector (golden/gen_vectors.py) for every bug you fix.
Keep modules short and commented for a student team.
