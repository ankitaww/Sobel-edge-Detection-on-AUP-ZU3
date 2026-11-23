# Design review — Self-tuning Sobel on AUP-ZU3

*Template. Fill in the bracketed parts; keep it short enough to present in 15 minutes.*

Team: Deepak, [member 2], [member 3] · Date: [ ] · Version reviewed: [git hash]

## 1. Requirements

| ID | requirement | how verified | status |
|---|---|---|---|
| R1 | Sobel L1 magnitude per spec/SPEC.md, bit-exact | csim + cosim vs golden vectors; board notebook 01 | [ ] |
| R2 | 1 pixel / clock (II = 1) at ≥ 150 MHz | csynth report, Vivado WNS ≥ 0 | [ ] |
| R3 | Up to 1920×1080 frames | 1080p vector + board run | [ ] |
| R4 | Self-tuning threshold: Otsu of frame N applied to frame N+1 | multi-frame test sequences | [ ] |
| R5 | Python control from PYNQ (no hard-coded offsets) | driver review | [ ] |
| R6 | Faster than OpenCV on the A53 at 1080p | notebook 02 | [ ] |
| R7 | Auto threshold more robust than fixed under gain 0.4–1.6× | eval/robustness_sweep.py | [ ] |

## 2. Architecture

**L0 — system.** Camera / file → PS (Linux, Python) → DDR → PL → DDR → PS → display.

**L1 — SoC.** Zynq UltraScale+ PS ↔ HPM0_FPD (AXI-Lite control) ↔ SmartConnect ↔
{sobel_otsu_0, axi_dma_0, gpio_sw, gpio_led}; axi_dma_0 ↔ HP0_FPD ↔ DDR4. One
clock (pl_clk0, 150 MHz).

**L2 — IP.** AXIS in → line buffer (2 × 1920 B BRAM) → 3×3 window (FFs) →
gradient (shift/add) → {threshold/mux → AXIS out, histogram (256 × 22 b BRAM,
same-bin forwarding)} → after frame: Otsu (float32) → T_reg.

**L3 — micro-architecture.** [pipeline depth, II per loop, float operator
latencies from the csynth report, histogram hazard argument, TLAST generation]

[insert block diagram from Vivado: File > Export > Export Block Design / screenshot]

## 3. Interfaces

| interface | protocol | width | notes |
|---|---|---|---|
| sobel_otsu_0/in, out | AXI4-Stream | 8 b + keep/strb/last | TLAST on last pixel only |
| sobel_otsu_0/s_axi_control | AXI4-Lite | 32 b | docs/register_map.md |
| axi_dma_0 MM2S/S2MM | AXI4 → HP0_FPD | 32 b MM, 8 b stream | simple mode, 26-bit length |

## 4. Budgets

| resource | available (XCZU3EG) | sobel_otsu | whole design | source |
|---|---|---|---|---|
| LUT | 70 560 | [ ] | [ ] | csynth / Vivado utilization.rpt |
| FF | 141 120 | [ ] | [ ] | |
| BRAM36 | 216 | [ ] | [ ] | |
| DSP | 360 | [ ] | [ ] | gradient should use 0 |
| Fmax / WNS | — | [ ] | [ ] | timing_summary.rpt |
| Power (PL) | — | [ ] | [ ] | power.rpt (vectorless estimate) + board measurement |

Timing budget per 1080p frame at 150 MHz: (1081 × 1921) cycles ≈ 13.8 ms pixel
loop + Otsu [ ] µs + DMA / Python overhead [ ] ms → [ ] fps.

## 5. Verification status

| level | what | result |
|---|---|---|
| golden | pytest (naive reference, hand cases) | [ ] |
| HLS csim | 107 frames, 14 sequences | [ ] |
| HLS cosim | sequences ≤ COSIM_MAX_PIXELS | [ ] |
| board | notebook 01 PASS | [ ] |

## 6. Risks and open questions

1. PYNQ v3.1 vs Vivado 2025.2 overlay compatibility (fallback: rebuild with 2024.1).
2. Float divide in HLS must be IEEE round-to-nearest for bit-exact Otsu — confirmed by cosim? [ ]
3. Histogram DEPENDENCE pragma: II = 1 achieved without a cosim mismatch? [ ]
4. Saturation of `mag` at high contrast pulls Otsu down (seen in synthetic robustness sweep at gain > 1.2). Mitigation? [ ]
5. [ ]
