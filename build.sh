#!/usr/bin/env bash
# build.sh - one-command build on Linux with only Vivado + Vitis 2025.2.
# Twin of build.bat (same steps, checks, logs and outputs). No Python/make needed.
#
#   ./build.sh all                 csim, synth, cosim, export, bit, board
#   ./build.sh csim                one step (several allowed: ./build.sh synth bit)
#   ./build.sh --dry-run all       print every command instead of running it
#
# Logs:     results/logs/<step>.log   (also shown live on screen)
# Results:  results/hls_summary.txt, results/vivado_summary.txt, results/*.rpt
# Board:    results/sobel_board.zip   (upload to Jupyter on the board)
set -uo pipefail

# ---- settings: edit here, or NAME=value ./build.sh ... --------------------------
XILINX_VERSION="${XILINX_VERSION:-2025.2}"
XILINX_ROOT="${XILINX_ROOT:-/tools/Xilinx/$XILINX_VERSION}"
PART="${PART:-xczu3eg-sfvc784-2-e}"
CLK_MHZ="${CLK_MHZ:-150}"
COSIM_MAX_PIXELS="${COSIM_MAX_PIXELS:-20000}"   # -1 = all sequences (1080p takes hours)
JOBS="${JOBS:-4}"
# ---------------------------------------------------------------------------------
export XILINX_VERSION PART CLK_MHZ COSIM_MAX_PIXELS JOBS

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$ROOT/results"
LOGDIR="$RESULTS/logs"
HLS_DIR="$ROOT/hls/sobel_otsu"
OVERLAY="$ROOT/pynq/overlay"
ALL_STEPS=(csim synth cosim export bit board)

usage() {
    cat <<EOF
Usage:  ./build.sh [--dry-run] STEP [STEP ...]

  csim     HLS C simulation against the golden vectors (must print PASS)
  synth    HLS synthesis  -> results/hls_summary.txt (pixel loop II, clock, resources)
  cosim    HLS C/RTL co-simulation (COSIM_MAX_PIXELS=$COSIM_MAX_PIXELS)
  export   HLS IP export for Vivado
  bit      Vivado bitstream -> pynq/overlay/sobel_otsu.bit/.hwh, results/vivado_summary.txt
  board    pack results/sobel_board.zip for the PYNQ board
  all      ${ALL_STEPS[*]}

  --dry-run  print the commands instead of running them

Settings (environment): XILINX_ROOT (default /tools/Xilinx/$XILINX_VERSION)
  CLK_MHZ  PART  COSIM_MAX_PIXELS  JOBS
EOF
    exit 1
}

# ---- arguments -----------------------------------------------------------------
DRY=0
STEPS=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        all) STEPS+=("${ALL_STEPS[@]}") ;;
        csim|synth|cosim|export|bit|board) STEPS+=("$a") ;;
        -h|--help|help) usage ;;
        *) echo "ERROR: unknown step \"$a\""; echo; usage ;;
    esac
done
[ ${#STEPS[@]} -gt 0 ] || usage

NEED_HLS=0; NEED_VIVADO=0
for s in "${STEPS[@]}"; do
    case "$s" in csim|synth|cosim|export) NEED_HLS=1 ;; bit) NEED_VIVADO=1 ;; esac
done

# ---- path check (Linux has no 260-char limit, but spaces still break the tools)
if [[ "$ROOT" == *" "* ]]; then
    echo "ERROR: the repo path contains a space:"
    echo "           \"$ROOT\""
    echo "       Vivado/Vitis need a path without spaces. Move the folder, e.g. to ~/sobel."
    exit 1
fi

echo "== repo      : $ROOT"
echo "== steps     : ${STEPS[*]}"
echo "== settings  : PART=$PART CLK_MHZ=$CLK_MHZ COSIM_MAX_PIXELS=$COSIM_MAX_PIXELS JOBS=$JOBS"
[ "$DRY" = 1 ] && echo "== DRY RUN: commands are printed, not run."

# ---- test vectors (committed in git) --------------------------------------------
if [ "$NEED_HLS" = 1 ] && [ ! -f "$ROOT/hls/tb_data/cases.txt" ]; then
    echo "ERROR: hls/tb_data/cases.txt is missing. The test vectors are part of the repo;"
    echo "       extract/clone it again, or regenerate with: make vectors"
    exit 1
fi

# ---- find Vivado / Vitis -----------------------------------------------------------
missing_tools() {
    local m=""
    if [ "$NEED_HLS" = 1 ] && ! command -v vitis-run >/dev/null 2>&1; then m="$m vitis-run"; fi
    if [ "$NEED_VIVADO" = 1 ] && ! command -v vivado >/dev/null 2>&1; then m="$m vivado"; fi
    echo "$m"
}
find_tools() {
    if [ -z "$(missing_tools)" ]; then echo "== Vivado/Vitis already on PATH"; return 0; fi
    echo "== Xilinx install: $XILINX_ROOT"
    local f
    for f in "$XILINX_ROOT/Vitis/settings64.sh" "$XILINX_ROOT/Vivado/settings64.sh"; do
        if [ "$DRY" = 1 ]; then echo "[dry-run] source $f"; continue; fi
        # settings64.sh is not written for 'set -u'.
        if [ -f "$f" ]; then set +u; source "$f"; set -u; fi
    done
    [ "$DRY" = 1 ] && return 0
    # Fallback if a settings64.sh is missing: put the bin folders on PATH.
    [ -x "$XILINX_ROOT/Vitis/bin/vitis-run" ] && PATH="$XILINX_ROOT/Vitis/bin:$PATH"
    [ -x "$XILINX_ROOT/Vivado/bin/vivado" ] && PATH="$XILINX_ROOT/Vivado/bin:$PATH"
    local m; m="$(missing_tools)"
    if [ -n "$m" ]; then
        echo
        echo "ERROR: Vivado/Vitis $XILINX_VERSION not found (missing:$m)."
        echo "       Tell build.sh where they are installed, e.g."
        echo "           export XILINX_ROOT=/tools/Xilinx/$XILINX_VERSION"
        echo "       (the folder that contains Vivado/ and Vitis/), then run it again."
        return 1
    fi
}
if [ "$NEED_HLS" = 1 ] || [ "$NEED_VIVADO" = 1 ]; then
    find_tools || { [ "$DRY" = 1 ] || exit 1; }
fi
[ "$DRY" = 1 ] || mkdir -p "$LOGDIR"

# ---- helpers ------------------------------------------------------------------------
# run_tool <dir> <command...>: output to screen and $STEP_LOG; returns the command's exit code.
run_tool() {
    local dir="$1"; shift
    if [ "$DRY" = 1 ]; then
        echo "[dry-run] cd $dir"
        echo "[dry-run] $*   (output -> $STEP_LOG)"
        return 0
    fi
    ( cd "$dir" && "$@" ) 2>&1 | tee "$STEP_LOG"
    return "${PIPESTATUS[0]}"
}

# The testbench must have printed "RESULT         : PASS" (exit codes alone are
# not trusted). Fallback: the HLS tool's own logs.
need_tb_pass() {
    [ "$DRY" = 1 ] && return 0
    grep -qF "RESULT         : PASS" "$STEP_LOG" && return 0
    local f
    f="$(grep -rlF --include='*.log' "RESULT         : PASS" "$HLS_DIR/sobel_otsu_hls" 2>/dev/null | head -n1)"
    if [ -n "$f" ]; then echo "== testbench PASS line found in $f"; return 0; fi
    echo "ERROR: the tool finished, but the testbench line \"RESULT         : PASS\""
    echo "       was not found in results/logs/$STEP.log or in the HLS logs."
    return 1
}

# run_hls.tcl reads HLS_STEP from the environment.
hls() { export HLS_STEP="$1"; run_tool "$HLS_DIR" vitis-run --mode hls --tcl run_hls.tcl; }

# ---- steps ---------------------------------------------------------------------------
# Each HLS run starts a fresh component (open_component -reset), so synth, cosim
# and export each re-run csynth_design. Slower, but every step stands alone.
step_csim()  { hls csim  && need_tb_pass; }
step_cosim() { hls cosim && need_tb_pass; }

step_synth() {
    [ "$DRY" = 1 ] || rm -f "$RESULTS/hls_summary.txt"
    hls synth || return 1
    [ "$DRY" = 1 ] && return 0
    if [ ! -f "$RESULTS/hls_summary.txt" ]; then
        echo "WARNING: results/hls_summary.txt was not written - read the csynth report by hand."
    elif grep -qF "WARNING: PIXEL LOOP II" "$RESULTS/hls_summary.txt"; then
        WARN_II=1
    fi
    return 0
}

step_export() {
    [ "$DRY" = 1 ] || rm -f "$HLS_DIR/export/sobel_otsu.zip"
    hls export || return 1
    [ "$DRY" = 1 ] && return 0
    [ -f "$HLS_DIR/export/sobel_otsu.zip" ] && return 0
    # TODO(verify-in-vitis): 2025.2 may leave only an unpacked IP (component.xml).
    [ -n "$(find "$HLS_DIR/sobel_otsu_hls" -name component.xml 2>/dev/null | head -n1)" ] && return 0
    echo "ERROR: export finished but neither hls/sobel_otsu/export/sobel_otsu.zip"
    echo "       nor a component.xml under hls/sobel_otsu/sobel_otsu_hls was found."
    return 1
}

step_bit() {
    if [ "$DRY" = 0 ]; then
        mkdir -p "$ROOT/vivado/build"
        # Delete the old overlay so a stale .bit can never look like a fresh one.
        rm -f "$OVERLAY/sobel_otsu.bit" "$OVERLAY/sobel_otsu.hwh"
    fi
    run_tool "$ROOT/vivado/build" vivado -mode batch -source ../create_project.tcl -nojournal -log vivado.log || return 1
    [ "$DRY" = 1 ] && return 0
    if [ ! -f "$OVERLAY/sobel_otsu.bit" ] || [ ! -f "$OVERLAY/sobel_otsu.hwh" ]; then
        echo "ERROR: Vivado finished but pynq/overlay/sobel_otsu.bit / .hwh are missing."
        return 1
    fi
    echo "== overlay: pynq/overlay/sobel_otsu.bit + sobel_otsu.hwh"
}

# Copy the board files into results/board_stage/sobel/ and pack them.
pack_board() {
    local stage="$RESULTS/board_stage"
    rm -rf "$stage"
    mkdir -p "$stage/sobel/overlay" "$stage/sobel/notebooks" "$stage/sobel/golden"
    cp "$ROOT/pynq/sobel_otsu.py" "$stage/sobel/"
    cp "$OVERLAY/sobel_otsu.bit" "$OVERLAY/sobel_otsu.hwh" "$stage/sobel/overlay/"
    cp "$ROOT"/pynq/notebooks/0{1_bringup,2_benchmark,3_live_video}.py "$stage/sobel/notebooks/"
    ( cd "$ROOT/golden" && find . -type f ! -path '*/__pycache__/*' ! -path './tests/*' ! -name '*.pyc' \
        -exec cp --parents {} "$stage/sobel/golden/" \; )
    ( cd "$stage" && find sobel -type f | sort | sed 's/^/  + /' )
    if command -v zip >/dev/null 2>&1; then
        ( cd "$stage" && zip -q -r "$RESULTS/sobel_board.zip" sobel ) || return 1
        BOARD_FILE=sobel_board.zip
    elif tar --version 2>/dev/null | grep -qi bsdtar; then
        ( cd "$stage" && tar -a -cf "$RESULTS/sobel_board.zip" sobel ) || return 1
        BOARD_FILE=sobel_board.zip
    else
        ( cd "$stage" && tar -czf "$RESULTS/sobel_board.tar.gz" sobel ) || return 1
        BOARD_FILE=sobel_board.tar.gz
        echo "== no zip tool found: wrote a .tar.gz instead"
    fi
    rm -rf "$stage"
    echo "== wrote results/$BOARD_FILE"
}

step_board() {
    BOARD_FILE=sobel_board.zip
    if [ "$DRY" = 0 ]; then
        rm -f "$RESULTS/sobel_board.zip" "$RESULTS/sobel_board.tar.gz"
        if [ ! -f "$OVERLAY/sobel_otsu.bit" ] || [ ! -f "$OVERLAY/sobel_otsu.hwh" ]; then
            echo "ERROR: pynq/overlay/sobel_otsu.bit or sobel_otsu.hwh is missing."
            echo "       Build the overlay first:   ./build.sh bit    (or: ./build.sh all)"
            return 1
        fi
    fi
    if [ "$DRY" = 1 ]; then
        echo "[dry-run] stage sobel/{sobel_otsu.py,overlay,golden,notebooks} in results/board_stage"
        echo "[dry-run] cd results/board_stage && zip -r $RESULTS/sobel_board.zip sobel   (or tar)"
    else
        pack_board 2>&1 | tee "$STEP_LOG"
        [ "${PIPESTATUS[0]}" = 0 ] || return 1
    fi
    local unpack="unzip -o $BOARD_FILE"
    [ "$BOARD_FILE" = sobel_board.tar.gz ] && unpack="tar xzf $BOARD_FILE"
    cat <<EOF

---------------- on the board (PYNQ v3.1, USB-C cable) ----------------
 1. Open http://192.168.3.1:9090 in a browser (password: xilinx).
 2. In the top folder click Upload, pick results/$BOARD_FILE, click Upload.
 3. New - Terminal, then:   cd /home/xilinx/jupyter_notebooks
                            $unpack
EOF
    [ "$BOARD_FILE" = sobel_board.zip ] && echo "    (no unzip? use: python3 -m zipfile -e sobel_board.zip .)"
    cat <<'EOF'
 4. Open the folder sobel/notebooks, New - Python 3 notebook, run a cell:
        %run 01_bringup.py
    It must print PASS.
------------------------------------------------------------------------
EOF
}

fmt_time() { printf '%dh %02dm %02ds' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

show_failure() {
    echo
    echo "***************************************************************"
    echo "FAILED at step $1"
    echo "***************************************************************"
    [ -f "$STEP_LOG" ] || return 0
    echo "Last 40 lines of results/logs/$1.log:"
    echo "---------------------------------------------------------------"
    tail -n 40 "$STEP_LOG"
    echo "---------------------------------------------------------------"
}

# ---- run the steps; stop at the first failure ------------------------------------------
declare -A ST TM
FAILED=""
WARN_II=""
for STEP in "${STEPS[@]}"; do
    STEP_LOG="$LOGDIR/$STEP.log"
    [ "$DRY" = 1 ] || rm -f "$STEP_LOG"   # a failure never shows lines from an older run
    echo
    echo "==============================================================="
    echo "== step $STEP    log: results/logs/$STEP.log"
    echo "==============================================================="
    t0=$SECONDS
    "step_$STEP"
    rc=$?
    TM[$STEP]=$((SECONDS - t0))
    if [ $rc -ne 0 ]; then ST[$STEP]=FAIL; elif [ "$DRY" = 1 ]; then ST[$STEP]=dry-run; else ST[$STEP]=PASS; fi
    echo "== step $STEP: ${ST[$STEP]}  ($(fmt_time "${TM[$STEP]}"))"
    if [ $rc -ne 0 ]; then show_failure "$STEP"; FAILED="$STEP"; break; fi
done

# ---- final table -------------------------------------------------------------------------
echo
echo "======================== build summary ========================"
for s in "${STEPS[@]}"; do
    if [ -n "${ST[$s]:-}" ]; then
        printf '  %-8s  %-14s  %s\n' "$s" "${ST[$s]}" "$(fmt_time "${TM[$s]}")"
    else
        printf '  %-8s  %-14s\n' "$s" "not run"
    fi
done
echo "==============================================================="
[ -n "$WARN_II" ] && echo "WARNING: the HLS pixel loop II is not 1 - see results/hls_summary.txt"
if [ -n "$FAILED" ]; then
    echo "RESULT: FAIL at step $FAILED   - log: results/logs/$FAILED.log"
    exit 1
fi
if [ "$DRY" = 1 ]; then echo "RESULT: dry run finished - nothing was built"; exit 0; fi
echo "RESULT: PASS"
[ -f "$RESULTS/hls_summary.txt" ] && echo "  HLS summary   : results/hls_summary.txt"
[ -f "$RESULTS/vivado_summary.txt" ] && echo "  Vivado summary: results/vivado_summary.txt"
exit 0
