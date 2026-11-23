"""Fill docs/register_map.md from the HLS-generated driver header.

After `make synth` (or export), Vitis HLS writes xsobel_otsu_hw.h somewhere
under hls/sobel_otsu/sobel_otsu_hls/ (exact path varies by version). This
script finds it, parses the #defines and the register comment block, and
replaces the GENERATED section of docs/register_map.md.

    python docs/gen_register_map.py [--header path/to/xsobel_otsu_hw.h]

The driver itself never uses these offsets (it uses register_map names from
the .hwh); this file is documentation for humans.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "register_map.md"
BEGIN, END = "<!-- BEGIN GENERATED -->", "<!-- END GENERATED -->"


def find_header() -> Path | None:
    hits = sorted((ROOT / "hls" / "sobel_otsu").rglob("xsobel_otsu_hw.h"))
    return hits[0] if hits else None


def parse(text: str):
    addr = {}
    bits = {}
    for m in re.finditer(r"#define\s+XSOBEL_OTSU_CONTROL_ADDR_(\w+)\s+(0x[0-9a-fA-F]+)", text):
        addr[m.group(1)] = int(m.group(2), 16)
    for m in re.finditer(r"#define\s+XSOBEL_OTSU_CONTROL_BITS_(\w+)\s+(\d+)", text):
        bits[m.group(1)] = int(m.group(2))
    comment = re.search(r"((?://[^\n]*\n)+)", text[text.find("// control"):] if "// control" in text else text)
    return addr, bits, comment.group(1) if comment else ""


def render(addr, bits, comment, source: str) -> str:
    lines = [BEGIN, "", f"Generated from `{source}`.", "",
             "| offset | register | width | note |", "|---|---|---|---|"]
    for name, off in sorted(addr.items(), key=lambda kv: kv[1]):
        if name == "AP_CTRL":
            reg, note = "CTRL", "AP_START / AP_DONE / AP_IDLE / AP_READY / AUTO_RESTART"
        elif name.endswith("_DATA"):
            reg = name[:-5].lower()
            note = ""
        elif name.endswith("_CTRL"):
            reg = name[:-5].lower() + "_ctrl"
            note = "bit 0 = ap_vld (output valid)"
        else:
            reg, note = name.lower(), ""
        lines.append(f"| 0x{off:02X} | `{reg}` | {bits.get(name, '')} | {note} |")
    lines += ["", "Raw comment block from the header:", "", "```", comment.rstrip(), "```", "", END]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--header", type=Path, default=None)
    args = ap.parse_args()
    header = args.header or find_header()
    if header is None or not header.exists():
        print("xsobel_otsu_hw.h not found. Run `make synth` first (needs Vitis HLS), "
              "or pass --header.", file=sys.stderr)
        sys.exit(1)
    addr, bits, comment = parse(header.read_text())
    if not addr:
        print(f"no XSOBEL_OTSU_CONTROL_ADDR_* defines in {header}", file=sys.stderr)
        sys.exit(1)
    header = header.resolve()
    source = header.relative_to(ROOT).as_posix() if header.is_relative_to(ROOT) else header.as_posix()
    doc = DOC.read_text(encoding="utf-8")
    block = render(addr, bits, comment, source)
    doc = doc[:doc.index(BEGIN)] + block + doc[doc.index(END) + len(END):]
    DOC.write_text(doc, encoding="utf-8")
    print(f"updated {DOC} from {header}")


if __name__ == "__main__":
    main()
