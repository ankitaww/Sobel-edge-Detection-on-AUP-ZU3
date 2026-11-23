// sobel_otsu.cpp — self-tuning Sobel edge detector (HLS IP).
//
// Streams one pixel per clock. While frame N streams through, a 256-bin
// histogram of the gradient magnitude is built; after the last pixel an Otsu
// pass picks the threshold that (in auto modes) is applied to frame N+1.
// The exact behaviour is spec/SPEC.md — read that first.
#include "sobel_otsu.h"

// |Gx| + |Gy| saturated to 255 (SPEC §2). Only shifts and adds: "2*p" is a
// wire shift, so the gradient path uses no DSP multipliers.
static u8_t sobel_mag(const u8_t w[3][3]) {
#pragma HLS INLINE
    // Widen to 10 bits *before* shifting: ap_uint's << keeps the operand width,
    // so (u8 << 1) would drop the MSB. A column sum is at most 4*255 = 1020.
    typedef ap_uint<10> u10_t;
    u10_t gx_pos = (u10_t)w[0][2] + ((u10_t)w[1][2] << 1) + (u10_t)w[2][2];
    u10_t gx_neg = (u10_t)w[0][0] + ((u10_t)w[1][0] << 1) + (u10_t)w[2][0];
    u10_t gy_pos = (u10_t)w[2][0] + ((u10_t)w[2][1] << 1) + (u10_t)w[2][2];
    u10_t gy_neg = (u10_t)w[0][0] + ((u10_t)w[0][1] << 1) + (u10_t)w[0][2];
    // 12 signed bits cover -1020..1020.
    ap_int<12> gx = (ap_int<12>)gx_pos - (ap_int<12>)gx_neg;
    ap_int<12> gy = (ap_int<12>)gy_pos - (ap_int<12>)gy_neg;
    ap_uint<11> ax = (gx < 0) ? (ap_uint<11>)(-gx) : (ap_uint<11>)gx;
    ap_uint<11> ay = (gy < 0) ? (ap_uint<11>)(-gy) : (ap_uint<11>)gy;
    ap_uint<12> sum = ax + ay;   // 0..2040
    return (sum > 255) ? (u8_t)255 : (u8_t)sum;
}

static int clamp_t(int x) {
#pragma HLS INLINE
    return (x < T_MIN) ? T_MIN : (x > T_MAX) ? T_MAX : x;
}

void sobel_otsu(hls::stream<pix_t>& in, hls::stream<pix_t>& out,
                int rows, int cols, int mode, int thresh_manual, int reset_state,
                int& thresh_used, int& otsu_thresh, int& edge_count) {
    // Streams map to AXI4-Stream so they connect directly to the AXI DMA.
#pragma HLS INTERFACE mode=axis port=in
#pragma HLS INTERFACE mode=axis port=out
    // All scalars plus block-level control (ap_start/ap_done/ap_idle) sit in one
    // AXI-Lite register file ("control") that PYNQ reads via register_map.
#pragma HLS INTERFACE mode=s_axilite port=rows bundle=control
#pragma HLS INTERFACE mode=s_axilite port=cols bundle=control
#pragma HLS INTERFACE mode=s_axilite port=mode bundle=control
#pragma HLS INTERFACE mode=s_axilite port=thresh_manual bundle=control
#pragma HLS INTERFACE mode=s_axilite port=reset_state bundle=control
#pragma HLS INTERFACE mode=s_axilite port=thresh_used bundle=control
#pragma HLS INTERFACE mode=s_axilite port=otsu_thresh bundle=control
#pragma HLS INTERFACE mode=s_axilite port=edge_count bundle=control
#pragma HLS INTERFACE mode=s_axilite port=return bundle=control

    // ---- persistent state (SPEC §3) -------------------------------------
    // 'static' = the value survives between calls, i.e. between frames. That is
    // what makes frame N's Otsu result available to frame N+1.
    static int t_reg = T_RESET;
    static hist_t hist[256];   // zero at power-on (bitstream init) and after every frame
    // Simple dual-port BRAM: one read port + one write port per cycle is
    // exactly what the histogram update below needs.
#pragma HLS BIND_STORAGE variable=hist type=ram_s2p impl=bram
    // The update below never reads a bin that was written fewer than 2
    // iterations earlier (see "same-bin forwarding"), and the write data comes
    // straight from registers, so the RAW hazard HLS would assume does not
    // exist. Telling it so lets the pixel loop reach II=1. Cosim checks this.
#pragma HLS DEPENDENCE variable=hist type=inter dependent=false

    // ---- line buffer: the previous 2 rows --------------------------------
    // 2 x MAX_W bytes. 'static' only so C simulation reads zeros instead of
    // uninitialised memory on the first rows (those outputs are border pixels
    // anyway); in hardware it costs nothing (BRAM init in the bitstream).
    static u8_t linebuf[2][MAX_W];
    // Split the two rows into two BRAMs so both can be read in the same cycle.
#pragma HLS ARRAY_PARTITION variable=linebuf dim=1 type=complete
#pragma HLS BIND_STORAGE variable=linebuf type=ram_s2p impl=bram
    // Column c is read and re-written in the same iteration; it is read again
    // only one full row later (>= cols+1 >= 4 iterations), so no inter-iteration
    // dependence exists.
#pragma HLS DEPENDENCE variable=linebuf type=inter dependent=false

    // 3x3 window in flip-flops: all 9 pixels are needed every cycle.
    u8_t win[3][3];
#pragma HLS ARRAY_PARTITION variable=win dim=0 type=complete
    // Defined start value (9 register resets); only border outputs ever see it.
    for (int k = 0; k < 3; k++)
        for (int j = 0; j < 3; j++) win[k][j] = 0;

    // ---- step 1: optional reset -------------------------------------------
    if (reset_state != 0) {
        t_reg = T_RESET;
    CLEAR:
        for (int i = 0; i < 256; i++) {
#pragma HLS PIPELINE II=1
            hist[i] = 0;
        }
    }

    // ---- step 2: threshold for this frame ----------------------------------
    const int m = (mode >= 0 && mode <= 3) ? mode : 0;      // SPEC §7
    const int t_frame = (m == 1) ? thresh_manual : t_reg;
    const bool binarise = (m != 0);

    // ---- step 3: pixel loop -------------------------------------------------
    // Output pixel (r-1, c-1) needs input pixel (r, c), so the window lags the
    // input by one row and one column. Iterating r over 0..rows and c over
    // 0..cols (one extra row and column) flushes that lag, and outputs are
    // produced in exactly the input order. The extra iterations only ever emit
    // border pixels, so their missing input does not matter.
    //
    // Histogram "same-bin forwarding": the current bin's running count lives in
    // a register (cur_bin/cur_val) and is written to BRAM only when the bin
    // changes; the previously written bin is also kept (last_bin/last_val) so a
    // pattern like a,b,a never reads a BRAM word written in the previous cycle.
    // Every BRAM read therefore sees a word written >= 2 iterations ago.
    ap_uint<8> cur_bin = 0, last_bin = 0;
    hist_t cur_val = 0, last_val = 0;   // hist[] is all-zero at frame start
    int edges = 0;
    int r = 0, c = 0;
    const int total = (rows + 1) * (cols + 1);

PIXEL:
    for (int i = 0; i < total; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=16 max=2076601
        u8_t p = 0;
        if (r < rows && c < cols) p = in.read().data;

        u8_t top = 0, mid = 0;
        if (c < cols) {
            top = linebuf[0][c];        // row r-2
            mid = linebuf[1][c];        // row r-1
            linebuf[0][c] = mid;
            linebuf[1][c] = p;
        }

        // Shift the window left and insert the new column (rows r-2, r-1, r).
        for (int k = 0; k < 3; k++) {
            win[k][0] = win[k][1];
            win[k][1] = win[k][2];
        }
        win[0][2] = top;
        win[1][2] = mid;
        win[2][2] = p;

        if (r >= 1 && c >= 1) {
            const int orow = r - 1, ocol = c - 1;
            const bool interior = orow >= 1 && orow <= rows - 2 && ocol >= 1 && ocol <= cols - 2;
            u8_t v = 0;
            if (interior) {
                const u8_t mag = sobel_mag(win);
                // histogram update (every mode)
                if (mag == cur_bin) {
                    cur_val++;
                } else {
                    hist[cur_bin] = cur_val;
                    const hist_t base = (mag == last_bin) ? last_val : hist[mag];
                    last_bin = cur_bin;
                    last_val = cur_val;
                    cur_bin = mag;
                    cur_val = base + 1;
                }
                if (!binarise) {
                    v = mag;
                } else if ((int)mag > t_frame) {
                    v = 255;
                    edges++;
                }
            }
            pix_t o;
            o.data = v;
            o.keep = -1;            // all bytes valid
            o.strb = -1;
            o.user = 0;
            o.id = 0;
            o.dest = 0;
            // TLAST on the final pixel only: AXI DMA S2MM ends the transfer on it.
            o.last = (orow == rows - 1 && ocol == cols - 1) ? 1 : 0;
            out.write(o);
        }

        if (c == cols) { c = 0; r++; } else { c++; }
    }
    hist[cur_bin] = cur_val;   // flush the pending bin

    // ---- step 4: Otsu (SPEC §5) ---------------------------------------------
    // Runs once per frame (~1k cycles vs ~2M for the pixel loop), so II > 1 is fine.
    int n = 0, st = 0;
SUMS:
    for (int t = 0; t < 256; t++) {
#pragma HLS PIPELINE II=1
        const int h = hist[t];
        n += h;
        st += t * h;
    }

    float best_var = -1.0f;
    int best_t = 0;
    int w = 0, s = 0;
OTSU:
    for (int t = 0; t < 256; t++) {
        // Not II=1: best_var is a float compare-and-select recurrence.
#pragma HLS PIPELINE
        const int h = hist[t];
        hist[t] = 0;              // step 6 fused here: the histogram is cleared as it is read
        w += h;
        s += t * h;
        if (w == 0 || w == n) continue;
        // Exact SPEC order. Vitis HLS does not reassociate float operations,
        // so ((w0*w1)*d)*d is preserved.
        const float w0 = (float)w;
        const float w1 = (float)(n - w);
        const float mb = (float)s / w0;
        const float mf = (float)(st - s) / w1;
        const float d = mb - mf;
        const float var = w0 * w1 * d * d;
        if (var > best_var) {     // strict '>' -> lowest t wins ties
            best_var = var;
            best_t = t;
        }
    }

    // ---- step 5: threshold update ---------------------------------------------
    thresh_used = binarise ? t_frame : 0;
    edge_count = binarise ? edges : 0;
    otsu_thresh = best_t;
    if (m == 2) {
        t_reg = clamp_t(best_t);
    } else if (m == 3) {
        t_reg = clamp_t((3 * t_reg + best_t) >> 2);
    }
}
