"""Edge quality on BSDS500: fixed threshold (tuned on train) vs self-tuning (Otsu).

    python eval/bsds_eval.py                       # BSDS500 in data/bsds500/ (see download_bsds.md)
    python eval/bsds_eval.py --synthetic           # no dataset needed: synthetic scenes
    SOBEL_BACKEND=hw python eval/bsds_eval.py      # on the board, through the FPGA

1. train split: get the gradient magnitude (mode 0) for every image, sweep T and
   pick the T with the best dataset-level F  ->  "fixed T".
2. test split: F for  fixed T  and for  auto (two passes in mode 2, i.e. each
   image's own Otsu threshold).
Metric: precision/recall/F with a 2-px tolerance — see eval/common.py.
Results: eval/results/bsds_<tag>.json, bsds_<tag>_curve.csv, bsds_<tag>.png
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

T_GRID = list(range(0, 256, 4))


def magnitudes(be, samples):
    mags = []
    for s in samples:
        out, _ = be.process(common.crop_to_limits(s.img), 0, reset=True)
        mags.append(out)
    return mags


def tune_fixed_t(be, train, tol):
    mags = magnitudes(be, train)
    gt_d = [common._dist_to(np.logical_or.reduce(s.gts)) for s in train]
    curve = []
    for t in T_GRID:
        c = common.Counts()
        for s, m, d in zip(train, mags, gt_d):
            c.add(common.edge_counts(m > t, s.gts, tol, gt_dist=d))
        curve.append((t, c.precision, c.recall, c.f))
    best = max(curve, key=lambda r: r[3])
    return best[0], curve


def evaluate(be, test, t_fixed, tol):
    fixed, auto = common.Counts(), common.Counts()
    auto_ts = []
    for s in test:
        img = common.crop_to_limits(s.img)
        mag, _ = be.process(img, 0, reset=True)
        d = common._dist_to(np.logical_or.reduce(s.gts))
        fixed.add(common.edge_counts(mag > t_fixed, s.gts, tol, gt_dist=d))
        out, info = be.process_still_auto(img)
        auto_ts.append(info["thresh_used"])
        auto.add(common.edge_counts(out == 255, s.gts, tol, gt_dist=d))
    return fixed, auto, auto_ts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--synthetic", action="store_true", help="use synthetic scenes instead of BSDS500")
    ap.add_argument("--limit", type=int, default=None, help="max images per split")
    ap.add_argument("--tol", type=float, default=2.0, help="match tolerance in pixels")
    ap.add_argument("--backend", default=None, help="hw | sw | auto (default: $SOBEL_BACKEND or auto)")
    args = ap.parse_args()

    be = common.backend(args.backend)
    tag = "synthetic" if args.synthetic else "bsds500"
    train = common.get_dataset("train", args.synthetic, args.limit)
    test = common.get_dataset("test", args.synthetic, args.limit)
    print(f"backend={be.name} data={tag} train={len(train)} test={len(test)} tol={args.tol}px")

    t_fixed, curve = tune_fixed_t(be, train, args.tol)
    fixed, auto, auto_ts = evaluate(be, test, t_fixed, args.tol)

    res = {
        "data": tag, "backend": be.name, "tol_px": args.tol,
        "n_train": len(train), "n_test": len(test),
        "fixed_T_from_train": t_fixed,
        "test_fixed": {"P": fixed.precision, "R": fixed.recall, "F": fixed.f},
        "test_auto": {"P": auto.precision, "R": auto.recall, "F": auto.f,
                      "T_median": float(np.median(auto_ts)), "T_min": int(min(auto_ts)),
                      "T_max": int(max(auto_ts))},
    }
    common.RESULTS.mkdir(parents=True, exist_ok=True)
    (common.RESULTS / f"bsds_{tag}.json").write_text(json.dumps(res, indent=2))
    with open(common.RESULTS / f"bsds_{tag}_curve.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["T", "precision", "recall", "F"])
        w.writerows(curve)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ts, _, _, fs = zip(*curve)
    plt.figure(figsize=(6, 4))
    plt.plot(ts, fs, label="fixed T (train split)")
    plt.axvline(t_fixed, ls="--", c="gray", label=f"best fixed T = {t_fixed}")
    plt.axhline(auto.f, c="tab:red", label=f"auto (test) F = {auto.f:.3f}")
    plt.axhline(fixed.f, c="tab:blue", ls=":", label=f"fixed (test) F = {fixed.f:.3f}")
    plt.xlabel("threshold T"); plt.ylabel("F"); plt.title(f"Edge F-score ({tag}, tol {args.tol:g}px)")
    plt.legend(fontsize=8); plt.tight_layout()
    plt.savefig(common.RESULTS / f"bsds_{tag}.png", dpi=120)

    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
