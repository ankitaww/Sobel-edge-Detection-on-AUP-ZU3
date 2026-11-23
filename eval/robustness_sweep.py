"""Robustness of fixed vs auto threshold under brightness/contrast changes.

Every test image is multiplied by a gain s in 0.4x..1.6x (clipped to 0..255),
which scales the gradient magnitudes roughly by s. A fixed threshold tuned at
s = 1 then over- or under-detects; the self-tuning (Otsu) threshold should
follow the image.

    python eval/robustness_sweep.py --synthetic
    python eval/robustness_sweep.py --fixed-t 72         # override the fixed T
    python eval/robustness_sweep.py                      # BSDS500 test split

The fixed T is taken from --fixed-t, else from eval/results/bsds_<tag>.json
(written by bsds_eval.py), else tuned on the train split here.
Results: eval/results/robustness_<tag>.csv and .png
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
from bsds_eval import tune_fixed_t  # noqa: E402

SCALES = np.round(np.linspace(0.4, 1.6, 13), 2)


def scale_img(img: np.ndarray, s: float) -> np.ndarray:
    return np.clip(img.astype(np.float32) * s, 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--tol", type=float, default=2.0)
    ap.add_argument("--fixed-t", type=int, default=None)
    ap.add_argument("--backend", default=None)
    args = ap.parse_args()

    be = common.backend(args.backend)
    tag = "synthetic" if args.synthetic else "bsds500"
    test = common.get_dataset("test", args.synthetic, args.limit)

    t_fixed = args.fixed_t
    src = "--fixed-t"
    jpath = common.RESULTS / f"bsds_{tag}.json"
    if t_fixed is None and jpath.exists():
        t_fixed, src = json.loads(jpath.read_text())["fixed_T_from_train"], str(jpath.name)
    if t_fixed is None:
        t_fixed, _ = tune_fixed_t(be, common.get_dataset("train", args.synthetic, args.limit), args.tol)
        src = "tuned on train split"
    print(f"backend={be.name} data={tag} n={len(test)} fixed T={t_fixed} ({src})")

    gt_d = [common._dist_to(np.logical_or.reduce(s.gts)) for s in test]
    rows = []
    for s in SCALES:
        fixed, auto = common.Counts(), common.Counts()
        ts = []
        for smp, d in zip(test, gt_d):
            img = scale_img(common.crop_to_limits(smp.img), s)
            out_f, _ = be.process(img, 1, t_fixed, reset=True)
            fixed.add(common.edge_counts(out_f == 255, smp.gts, args.tol, gt_dist=d))
            out_a, info = be.process_still_auto(img)
            ts.append(info["thresh_used"])
            auto.add(common.edge_counts(out_a == 255, smp.gts, args.tol, gt_dist=d))
        rows.append([float(s), fixed.precision, fixed.recall, fixed.f,
                     auto.precision, auto.recall, auto.f, float(np.median(ts))])
        print(f"scale {s:4.2f}: F fixed {fixed.f:.3f}  F auto {auto.f:.3f}  (median auto T {np.median(ts):.0f})")

    common.RESULTS.mkdir(parents=True, exist_ok=True)
    with open(common.RESULTS / f"robustness_{tag}.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["scale", "P_fixed", "R_fixed", "F_fixed", "P_auto", "R_auto", "F_auto", "T_auto_median"])
        w.writerows(rows)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    a = np.array(rows)
    fig, ax = plt.subplots(1, 2, figsize=(10, 4))
    ax[0].plot(a[:, 0], a[:, 3], "o-", label=f"fixed T={t_fixed}")
    ax[0].plot(a[:, 0], a[:, 6], "s-", label="auto (Otsu)")
    ax[0].set_xlabel("intensity gain"); ax[0].set_ylabel("F"); ax[0].legend(); ax[0].set_title("F vs gain")
    ax[1].plot(a[:, 0], a[:, 7], "s-", c="tab:orange")
    ax[1].axhline(t_fixed, ls="--", c="tab:blue")
    ax[1].set_xlabel("intensity gain"); ax[1].set_ylabel("T"); ax[1].set_title("median auto threshold")
    fig.suptitle(f"Robustness ({tag}, tol {args.tol:g}px)")
    fig.tight_layout()
    fig.savefig(common.RESULTS / f"robustness_{tag}.png", dpi=120)


if __name__ == "__main__":
    main()
