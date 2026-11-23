"""Shared helpers for the evaluation scripts: datasets, edge metric, backend.

Edge metric (used by bsds_eval.py and robustness_sweep.py)
-----------------------------------------------------------
A simplified version of the BSDS boundary benchmark, with a fixed pixel
tolerance instead of the official bipartite (CSA) matching:

* precision = fraction of predicted edge pixels within `tol` px of a boundary
  pixel of ANY annotator,
* recall    = fraction of ground-truth boundary pixels (summed over annotators)
  within `tol` px of a predicted edge pixel,
* F = 2PR / (P + R), counts accumulated over the whole set (dataset-level F).

Distances come from scipy's Euclidean distance transform. The numbers are
comparable between our methods but NOT with published BSDS ODS/OIS scores.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "pynq"))

from golden import sobel_golden as golden  # noqa: E402

BSDS_DIR = ROOT / "data" / "bsds500"
RESULTS = ROOT / "eval" / "results"


@dataclass
class Sample:
    name: str
    img: np.ndarray                         # uint8 grayscale
    gts: list = field(default_factory=list)  # list of bool boundary maps (one per annotator)


# ---------------------------------------------------------------- datasets
def find_bsds_root(base: Path = BSDS_DIR) -> Path | None:
    """Locate .../data/ (containing images/ and groundTruth/) under data/bsds500/."""
    for cand in [base / "BSDS500" / "data", base / "data", base]:
        if (cand / "images").is_dir() and (cand / "groundTruth").is_dir():
            return cand
    return None


def load_bsds(split: str, limit: int | None = None) -> list[Sample]:
    from PIL import Image
    from scipy.io import loadmat

    root = find_bsds_root()
    if root is None:
        raise FileNotFoundError(f"BSDS500 not found under {BSDS_DIR}. See eval/download_bsds.md, "
                                "or run with --synthetic.")
    imgs = sorted((root / "images" / split).glob("*.jpg"))[:limit]
    out = []
    for p in imgs:
        gray = np.asarray(Image.open(p).convert("L"), dtype=np.uint8)
        mat = loadmat(root / "groundTruth" / split / (p.stem + ".mat"))
        gts = [np.asarray(g["Boundaries"][0, 0], dtype=bool) for g in mat["groundTruth"][0]]
        out.append(Sample(p.stem, gray, gts))
    return out


def synthetic_set(n: int, seed: int, shape=(240, 320)) -> list[Sample]:
    """Piecewise-constant scenes (random discs/rectangles) + blur + noise.
    Ground truth = pixels where the region label changes (one 'annotator')."""
    rng = np.random.default_rng(seed)
    h, w = shape
    y, x = np.mgrid[0:h, 0:w]
    out = []
    for i in range(n):
        labels = np.zeros(shape, np.int32)
        for k in range(1, 9):
            cy, cx = rng.uniform(0, h), rng.uniform(0, w)
            r = rng.uniform(0.08, 0.3) * min(h, w)
            if rng.random() < 0.5:
                m = (y - cy) ** 2 + (x - cx) ** 2 < r ** 2
            else:
                m = (abs(y - cy) < r) & (abs(x - cx) < 1.5 * r)
            labels[m] = k
        levels = rng.uniform(40, 215, 9)
        img = levels[labels]
        img = ndimage.gaussian_filter(img, rng.uniform(0.6, 1.5))
        img = img + rng.normal(0, rng.uniform(2, 8), shape)
        img = np.clip(img, 0, 255).astype(np.uint8)
        gt = np.zeros(shape, bool)
        gt[:, 1:] |= labels[:, 1:] != labels[:, :-1]
        gt[1:, :] |= labels[1:, :] != labels[:-1, :]
        out.append(Sample(f"syn{seed}_{i:03d}", img, [gt]))
    return out


def get_dataset(split: str, synthetic: bool, limit: int | None) -> list[Sample]:
    if synthetic:
        n = limit or 20
        return synthetic_set(n, seed={"train": 1, "val": 2, "test": 3}[split])
    return load_bsds(split, limit)


# ---------------------------------------------------------------- metric
@dataclass
class Counts:
    tp_pred: int = 0   # predicted edge pixels that match a GT boundary
    n_pred: int = 0
    tp_gt: int = 0     # GT boundary pixels that are matched by a prediction
    n_gt: int = 0

    def add(self, other: "Counts") -> None:
        self.tp_pred += other.tp_pred
        self.n_pred += other.n_pred
        self.tp_gt += other.tp_gt
        self.n_gt += other.n_gt

    @property
    def precision(self) -> float:
        return self.tp_pred / self.n_pred if self.n_pred else 0.0

    @property
    def recall(self) -> float:
        return self.tp_gt / self.n_gt if self.n_gt else 0.0

    @property
    def f(self) -> float:
        p, r = self.precision, self.recall
        return 2 * p * r / (p + r) if p + r else 0.0


def _dist_to(mask: np.ndarray) -> np.ndarray:
    """Distance of every pixel to the nearest True pixel of mask (inf if none)."""
    if not mask.any():
        return np.full(mask.shape, np.inf)
    return ndimage.distance_transform_edt(~mask)


def edge_counts(pred: np.ndarray, gts: list[np.ndarray], tol: float = 2.0,
                gt_dist: np.ndarray | None = None) -> Counts:
    """Counts for one image. pred: bool edge map; gts: boundary maps."""
    if gt_dist is None:
        gt_dist = _dist_to(np.logical_or.reduce(gts))
    pd = _dist_to(pred)
    c = Counts(n_pred=int(pred.sum()), tp_pred=int((gt_dist[pred] <= tol).sum()))
    for g in gts:
        c.n_gt += int(g.sum())
        c.tp_gt += int((pd[g] <= tol).sum())
    return c


# ---------------------------------------------------------------- helpers
def crop_to_limits(img: np.ndarray) -> np.ndarray:
    """Crop to the IP's max frame (SPEC §1) — BSDS images (481x321) already fit."""
    return img[:golden.MAX_ROWS, :golden.MAX_COLS]


def backend(kind: str | None):
    from sobel_otsu import make_backend
    return make_backend(kind)
