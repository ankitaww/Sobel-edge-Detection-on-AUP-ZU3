# Getting BSDS500

The scripts do **not** download the dataset (licence + size). Do it once by hand:

1. Download the archive from the Berkeley page:
   <https://www2.eecs.berkeley.edu/Research/Projects/CS/vision/grouping/resources.html>
   → "BSDS500" (`BSR_bsds500.tgz`, ~70 MB). Mirrors on Kaggle / GitHub also
   exist; check the folder layout matches.
2. Unpack so this path exists (any of the three accepted layouts):

```
data/bsds500/BSDS500/data/images/{train,val,test}/*.jpg
data/bsds500/BSDS500/data/groundTruth/{train,val,test}/*.mat
```

   e.g. `mkdir -p data/bsds500 && tar -xzf BSR_bsds500.tgz -C data/bsds500 --strip-components=1`
   (the archive's top folder is `BSR/`).
3. `data/bsds500/` is git-ignored — don't commit it.

Check: `python eval/bsds_eval.py --limit 5` should print `data=bsds500 train=5 test=5`.

Notes

* 200 train / 100 val / 200 test images, 481×321 or 321×481 — all within the IP's frame limit.
* Ground truth `.mat` files hold 4–9 human annotations each; we use all of them (see `eval/common.py`).
* Our metric is a simplified 2-px-tolerance P/R/F, **not** the official BSDS benchmark code; numbers are comparable across our methods only.
