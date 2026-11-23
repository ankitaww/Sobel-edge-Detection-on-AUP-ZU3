// sobel_otsu.h — types and top-level prototype of the self-tuning Sobel IP.
// Behaviour is defined by spec/SPEC.md; keep this file and the spec in sync.
#ifndef SOBEL_OTSU_H
#define SOBEL_OTSU_H

#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>

// Maximum frame size (SPEC §1). MAX_W sizes the line buffers, so it drives BRAM use.
#define MAX_H 1080
#define MAX_W 1920

// Persistent-threshold constants (SPEC §3, §4).
#define T_RESET 64
#define T_MIN 8
#define T_MAX 200

// One AXI4-Stream beat: 8-bit data + TKEEP/TSTRB/TLAST and 1-bit TUSER/TID/TDEST.
// ap_axiu<8,1,1,1> is accepted by every Vitis HLS version from 2020.x to 2025.x
// (newer releases also allow 0-width side channels, older ones do not).
typedef ap_axiu<8, 1, 1, 1> pix_t;

typedef ap_uint<8> u8_t;
// Histogram counter: 22 bits holds the max interior pixel count 1078*1918 = 2 067 604.
typedef ap_uint<22> hist_t;

void sobel_otsu(hls::stream<pix_t>& in, hls::stream<pix_t>& out,
                int rows, int cols, int mode, int thresh_manual, int reset_state,
                int& thresh_used, int& otsu_thresh, int& edge_count);

#endif
