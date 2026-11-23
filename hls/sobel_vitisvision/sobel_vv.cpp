// sobel_vv.cpp — comparison variant built from the Vitis Vision library
// (xf::cv::Sobel + xf::cv::magnitude + xf::cv::convertTo + xf::cv::Threshold).
//
// Purpose: a "what does the vendor library cost/achieve" baseline for the
// benchmark and resource tables. It is NOT bit-exact with spec/SPEC.md:
// the library handles the border differently, and there is no histogram/Otsu.
//
// TODO(verify-in-vitis): template parameter lists of the xf::cv functions
// changed between Vitis_Libraries releases (XFCVDEPTH arguments were added in
// 2022.1). This file follows the 2024.x/2025.x headers; check the signatures
// in $XF_VISION_INCLUDE if compilation fails.
#include <ap_axi_sdata.h>
#include <hls_stream.h>

#include "common/xf_common.hpp"
#include "core/xf_magnitude.hpp"
#include "imgproc/xf_convert_bitdepth.hpp"
#include "imgproc/xf_sobel.hpp"
#include "imgproc/xf_threshold.hpp"

#define VV_MAX_H 1080
#define VV_MAX_W 1920
#define VV_NPC XF_NPPC1   // 1 pixel/clock, same as the hand-written IP

typedef ap_axiu<8, 1, 1, 1> pix_t;

static void stream_to_mat(hls::stream<pix_t>& in, xf::cv::Mat<XF_8UC1, VV_MAX_H, VV_MAX_W, VV_NPC>& m) {
    const int n = m.rows * m.cols;
    for (int i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=2073600
        m.write(i, in.read().data);
    }
}

static void mat_to_stream(xf::cv::Mat<XF_8UC1, VV_MAX_H, VV_MAX_W, VV_NPC>& m, hls::stream<pix_t>& out) {
    const int n = m.rows * m.cols;
    for (int i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT max=2073600
        pix_t o;
        o.data = m.read(i);
        o.keep = -1;
        o.strb = -1;
        o.user = 0;
        o.id = 0;
        o.dest = 0;
        o.last = (i == n - 1);   // TLAST ends the DMA S2MM transfer
        out.write(o);
    }
}

// Equivalent of the hand-written IP's mode 1: out = 255 if mag > thresh else 0.
void sobel_vv(hls::stream<pix_t>& in, hls::stream<pix_t>& out, int rows, int cols, int thresh) {
#pragma HLS INTERFACE mode=axis port=in
#pragma HLS INTERFACE mode=axis port=out
#pragma HLS INTERFACE mode=s_axilite port=rows bundle=control
#pragma HLS INTERFACE mode=s_axilite port=cols bundle=control
#pragma HLS INTERFACE mode=s_axilite port=thresh bundle=control
#pragma HLS INTERFACE mode=s_axilite port=return bundle=control

    xf::cv::Mat<XF_8UC1, VV_MAX_H, VV_MAX_W, VV_NPC> src(rows, cols);
    xf::cv::Mat<XF_16SC1, VV_MAX_H, VV_MAX_W, VV_NPC> gx(rows, cols), gy(rows, cols), mag16(rows, cols);
    xf::cv::Mat<XF_8UC1, VV_MAX_H, VV_MAX_W, VV_NPC> mag8(rows, cols), dst(rows, cols);

    // Each function becomes a process connected by FIFOs, so the whole chain
    // streams at 1 pixel/clock instead of running stage after stage.
#pragma HLS DATAFLOW
    stream_to_mat(in, src);
    xf::cv::Sobel<XF_BORDER_CONSTANT, XF_FILTER_3X3, XF_8UC1, XF_16SC1, VV_MAX_H, VV_MAX_W, VV_NPC, false>(src, gx, gy);
    xf::cv::magnitude<XF_L1NORM, XF_16SC1, XF_16SC1, VV_MAX_H, VV_MAX_W, VV_NPC>(gx, gy, mag16);
    // 16S -> 8U conversion saturates to 0..255, like the hand-written IP.
    xf::cv::convertTo<XF_16SC1, XF_8UC1, VV_MAX_H, VV_MAX_W, VV_NPC>(mag16, mag8, XF_CONVERT_16S_TO_8U, 0);
    // BINARY: dst = (src > thresh) ? maxval : 0, the same strict ">" as SPEC section 4.
    xf::cv::Threshold<XF_THRESHOLD_TYPE_BINARY, XF_8UC1, VV_MAX_H, VV_MAX_W, VV_NPC>(
        mag8, dst, (unsigned char)thresh, (unsigned char)255);
    mat_to_stream(dst, out);
}
