#!/usr/bin/env bash
# build.sh — build the overlay without make. Run from anywhere.
#   CLK_MHZ=150 JOBS=8 ./vivado/build.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/build"
cd "$here/build"
vivado -mode batch -nojournal -log "$here/build/vivado.log" -source "$here/create_project.tcl"
ls -l "$here/../pynq/overlay/"
