# Makefile — self-tuning Sobel on AUP-ZU3.  `make help` lists the targets.
#
# On Windows run make from Git Bash or an MSYS2 shell (`mingw32-make` works);
# the recipes use POSIX shell syntax.

# ---- tool versions and commands: change here only ----------------------------
# Switching the whole flow to 2024.1 (to match PYNQ v3.1) = edit XILINX_VERSION
# and source that version's settings64 script. See README "Version mismatch".
XILINX_VERSION ?= 2025.2
HLS            ?= vitis-run --mode hls --tcl
VIVADO         ?= vivado -mode batch -source
PART           ?= xczu3eg-sfvc784-2-e
CLK_MHZ        ?= 150
BOARD_IP       ?= 192.168.3.1
BOARD_USER     ?= xilinx
BOARD_DIR      ?= /home/xilinx/jupyter_notebooks/sobel

PYTHON         ?= python3
CXX            ?= g++
# Directories holding ap_int.h, hls_stream.h, ap_axi_sdata.h for `make tb-gpp`
# (e.g. "$XILINX_HLS/include"; see README).
HLS_INCLUDE    ?=
# Pixel limit per test sequence during RTL cosim (-1 = all; 1080p takes hours).
COSIM_MAX_PIXELS ?= 20000

# Passed to the Tcl scripts through the environment.
export PART CLK_MHZ COSIM_MAX_PIXELS XILINX_VERSION

HLS_DIR := hls/sobel_otsu
VV_DIR  := hls/sobel_vitisvision

.PHONY: help setup test vectors csim synth cosim export vv tb-gpp bit regmap notebooks deploy clean

help:
	@echo "setup      install host Python packages (requirements.txt)"
	@echo "test       run the golden-model unit tests (pytest)"
	@echo "vectors    generate HLS testbench vectors into hls/tb_data/"
	@echo "csim       HLS C simulation                       (needs vitis-run $(XILINX_VERSION))"
	@echo "synth      HLS C synthesis"
	@echo "cosim      HLS C/RTL co-simulation (COSIM_MAX_PIXELS=$(COSIM_MAX_PIXELS))"
	@echo "export     HLS export to Vivado IP catalog"
	@echo "vv         optional Vitis Vision variant (needs XF_VISION_INCLUDE)"
	@echo "tb-gpp     build + run the testbench with plain g++ (needs HLS_INCLUDE)"
	@echo "bit        Vivado project + bitstream -> pynq/overlay/"
	@echo "regmap     fill docs/register_map.md from the HLS-generated driver header"
	@echo "notebooks  convert pynq/notebooks/*.py to .ipynb (jupytext)"
	@echo "deploy     copy driver, overlay, notebooks, golden model to $(BOARD_USER)@$(BOARD_IP)"
	@echo "clean      remove build products"

setup:
	$(PYTHON) -m pip install -r requirements.txt

test:
	$(PYTHON) -m pytest -q golden/tests

vectors:
	$(PYTHON) golden/gen_vectors.py

# ---- HLS ----------------------------------------------------------------------
csim: export HLS_STEP = csim
synth: export HLS_STEP = synth
cosim: export HLS_STEP = cosim
export: export HLS_STEP = export

csim: vectors
	cd $(HLS_DIR) && $(HLS) run_hls.tcl

synth:
	cd $(HLS_DIR) && $(HLS) run_hls.tcl

cosim: vectors
	cd $(HLS_DIR) && $(HLS) run_hls.tcl

export:
	cd $(HLS_DIR) && $(HLS) run_hls.tcl

vv: export HLS_STEP = export
vv:
	cd $(VV_DIR) && $(HLS) run_hls.tcl

# Same testbench, compiled with the host compiler. -ffp-contract=off keeps the
# float Otsu bit-exact (no FMA fusing, SPEC §5).
tb-gpp: vectors
	@if [ -z "$(HLS_INCLUDE)" ]; then \
	  echo "ERROR: set HLS_INCLUDE to the directory/directories with ap_int.h, hls_stream.h, ap_axi_sdata.h"; \
	  echo "       e.g. make tb-gpp HLS_INCLUDE=\$$XILINX_HLS/include   (see README)"; exit 1; fi
	mkdir -p build
	$(CXX) -std=c++14 -O2 -ffp-contract=off $(addprefix -I,$(HLS_INCLUDE)) -I$(HLS_DIR) \
	  $(HLS_DIR)/sobel_otsu.cpp $(HLS_DIR)/tb_sobel_otsu.cpp -o build/tb_sobel_otsu
	./build/tb_sobel_otsu --data hls/tb_data

# ---- Vivado -------------------------------------------------------------------
bit:
	mkdir -p vivado/build
	cd vivado/build && $(VIVADO) ../create_project.tcl -nojournal -log vivado.log
	@ls -l pynq/overlay/sobel_otsu.bit pynq/overlay/sobel_otsu.hwh

regmap:
	$(PYTHON) docs/gen_register_map.py

# ---- board --------------------------------------------------------------------
notebooks:
	$(PYTHON) -m jupytext --to ipynb pynq/notebooks/*.py

# The board copy is flat: sobel/{sobel_otsu.py, overlay/, notebooks/, golden/}.
deploy: notebooks
	ssh $(BOARD_USER)@$(BOARD_IP) "mkdir -p $(BOARD_DIR)"
	scp -r pynq/sobel_otsu.py pynq/overlay pynq/notebooks golden $(BOARD_USER)@$(BOARD_IP):$(BOARD_DIR)/

clean:
	rm -rf build vivado/build $(HLS_DIR)/sobel_otsu_hls $(HLS_DIR)/export $(VV_DIR)/sobel_vv_hls \
	       $(VV_DIR)/export hls/tb_data .Xil *.jou *.log
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
