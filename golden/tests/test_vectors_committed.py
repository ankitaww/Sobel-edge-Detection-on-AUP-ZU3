"""The committed HLS test vectors (hls/tb_data/) must match the generator.

hls/tb_data/ is committed so a build laptop without Python can run csim/cosim.
This test regenerates the vectors into a temp dir and checks every file is
byte-identical, so a change to golden/ or gen_vectors.py cannot leave stale
vectors behind. Fix a failure with `make vectors` and commit hls/tb_data.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMITTED = ROOT / "hls" / "tb_data"


def _files(d: Path) -> dict:
    return {p.relative_to(d).as_posix(): p for p in sorted(d.rglob("*")) if p.is_file()}


def test_committed_vectors_are_current(tmp_path):
    assert (COMMITTED / "cases.txt").exists(), "hls/tb_data missing: run `make vectors` and commit it"
    subprocess.run([sys.executable, str(ROOT / "golden" / "gen_vectors.py"), "--out", str(tmp_path)],
                   check=True, capture_output=True)
    want, have = _files(tmp_path), _files(COMMITTED)
    assert sorted(have) == sorted(want), (
        f"file lists differ: missing {sorted(set(want) - set(have))}, extra {sorted(set(have) - set(want))}")
    stale = [name for name in want if want[name].read_bytes() != have[name].read_bytes()]
    assert not stale, f"stale vectors (run `make vectors` and commit hls/tb_data): {stale[:10]}"
