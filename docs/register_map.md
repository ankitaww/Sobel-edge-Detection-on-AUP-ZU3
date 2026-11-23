# Register map — `sobel_otsu` AXI-Lite (`s_axi_control`)

The **driver never uses these offsets**: `pynq/sobel_otsu.py` accesses
registers by name through `ip.register_map`, which PYNQ builds from the
`.hwh` file. This page is for humans (debugging with `devmem`, reports).

Meaning of each register: see [spec/SPEC.md](../spec/SPEC.md) §3.

## How to fill this page

```
make synth      # needs Vitis HLS 2025.1
make regmap     # parses the generated xsobel_otsu_hw.h into the section below
```

## Expected layout (before synthesis — to be replaced)

Vitis HLS normally lays out the control bundle like this (each scalar input
gets an 8-byte slot, each output a data word plus an `_ctrl` word with the
`ap_vld` bit). **Unverified** — the generated section below is authoritative.

| offset | register | dir | notes |
|---|---|---|---|
| 0x00 | `CTRL` | r/w | bit0 AP_START, bit1 AP_DONE (clear on read), bit2 AP_IDLE, bit3 AP_READY, bit7 AUTO_RESTART |
| 0x04 | GIE | r/w | global interrupt enable (unused, we poll) |
| 0x08 | IER | r/w | interrupt enable |
| 0x0C | ISR | r/w | interrupt status |
| 0x10 | `rows` | w | |
| 0x18 | `cols` | w | |
| 0x20 | `mode` | w | |
| 0x28 | `thresh_manual` | w | |
| 0x30 | `reset_state` | w | |
| 0x38 | `thresh_used` | r | + `thresh_used_ctrl` (ap_vld) |
| 0x48 | `otsu_thresh` | r | + `_ctrl` |
| 0x58 | `edge_count` | r | + `_ctrl` |

## Generated

<!-- BEGIN GENERATED -->
*Not generated yet — run `make synth && make regmap`.*
<!-- END GENERATED -->

## AXI DMA (for reference)

Simple-mode registers used in the timeout error message: `MM2S_DMASR` (0x04),
`S2MM_DMASR` (0x34). Bit 0 = halted, bit 1 = idle, bits 4–6 = DMA errors
(internal / slave / decode). See PG021.
