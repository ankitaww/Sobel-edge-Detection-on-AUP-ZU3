// tb_sobel_otsu.cpp — C/RTL testbench for sobel_otsu.
//
// Replays hls/tb_data/cases.txt (written by golden/gen_vectors.py) frame by
// frame, in order, so the IP's static T_reg feedback is exercised exactly as on
// the board. Compares every output pixel, the TLAST/TKEEP side channels and the
// three output registers with the golden model. Returns non-zero on ANY
// mismatch — csim/cosim report failure based on this return value.
//
// Arguments (all optional):
//   --data <dir>        vector directory (default: $TB_DATA or "../tb_data")
//   --max-pixels <n>    skip whole sequences containing a frame larger than n
//                       pixels (used to keep RTL cosim time reasonable)
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "sobel_otsu.h"

struct Image {
    int rows = 0, cols = 0;
    std::vector<unsigned char> px;
};

// Minimal P5 reader matching golden/pgm.py (supports '#' comments in the header).
static bool read_pgm(const std::string& path, Image& img) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    char magic[3] = {0};
    int vals[3];
    bool ok = std::fscanf(f, "%2s", magic) == 1 && std::strcmp(magic, "P5") == 0;
    for (int i = 0; ok && i < 3; i++) {
        int ch;
        while ((ch = std::fgetc(f)) != EOF && (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '#')) {
            if (ch == '#') while ((ch = std::fgetc(f)) != EOF && ch != '\n') {}
        }
        if (ch == EOF) { ok = false; break; }
        std::ungetc(ch, f);
        ok = std::fscanf(f, "%d", &vals[i]) == 1;
    }
    ok = ok && vals[2] == 255 && std::fgetc(f) != EOF;   // single whitespace byte
    if (ok) {
        img.cols = vals[0];
        img.rows = vals[1];
        img.px.resize((size_t)img.rows * img.cols);
        ok = std::fread(img.px.data(), 1, img.px.size(), f) == img.px.size();
    }
    std::fclose(f);
    return ok;
}

struct Case {
    int seq, frame, mode, tm, reset, exp_used, exp_otsu, exp_edges;
    std::string input, expected;
};

int main(int argc, char** argv) {
    std::string dir = std::getenv("TB_DATA") ? std::getenv("TB_DATA") : "../tb_data";
    long max_pixels = -1;
    for (int i = 1; i < argc; i++) {
        if (!std::strcmp(argv[i], "--data") && i + 1 < argc) dir = argv[++i];
        else if (!std::strcmp(argv[i], "--max-pixels") && i + 1 < argc) max_pixels = std::atol(argv[++i]);
    }

    std::ifstream cf(dir + "/cases.txt");
    if (!cf) {
        std::printf("ERROR: cannot open %s/cases.txt — run `make vectors` first\n", dir.c_str());
        return 2;
    }
    std::vector<Case> cases;
    std::string line;
    while (std::getline(cf, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        Case c;
        ss >> c.seq >> c.frame >> c.input >> c.expected >> c.mode >> c.tm >> c.reset
           >> c.exp_used >> c.exp_otsu >> c.exp_edges;
        if (ss) cases.push_back(c);
    }

    // Load images once; decide which sequences to skip.
    std::map<std::string, Image> images;
    std::map<int, bool> skip_seq;
    for (const Case& c : cases) {
        if (!images.count(c.input)) {
            Image img;
            if (!read_pgm(dir + "/" + c.input, img)) {
                std::printf("ERROR: cannot read %s\n", c.input.c_str());
                return 2;
            }
            images[c.input] = img;
        }
        const Image& img = images[c.input];
        if (max_pixels >= 0 && (long)img.rows * img.cols > max_pixels) skip_seq[c.seq] = true;
    }

    int frames_run = 0, frames_failed = 0, frames_skipped = 0;
    long total_pix_mismatch = 0;
    for (const Case& c : cases) {
        if (skip_seq.count(c.seq)) { frames_skipped++; continue; }
        const Image& img = images[c.input];
        Image exp;
        if (!read_pgm(dir + "/" + c.expected, exp)) {
            std::printf("ERROR: cannot read %s\n", c.expected.c_str());
            return 2;
        }

        hls::stream<pix_t> s_in, s_out;
        for (size_t k = 0; k < img.px.size(); k++) {
            pix_t b;
            b.data = img.px[k];
            b.keep = -1;
            b.strb = -1;
            b.user = 0;
            b.id = 0;
            b.dest = 0;
            b.last = (k + 1 == img.px.size());
            s_in.write(b);
        }

        int used = -1, otsu = -1, edges = -1;
        sobel_otsu(s_in, s_out, img.rows, img.cols, c.mode, c.tm, c.reset, used, otsu, edges);

        long pix_bad = 0, side_bad = 0, first_bad = -1;
        const size_t npix = img.px.size();
        for (size_t k = 0; k < npix; k++) {
            if (s_out.empty()) { pix_bad += (long)(npix - k); break; }
            pix_t o = s_out.read();
            if ((int)o.data != exp.px[k]) {
                if (first_bad < 0) first_bad = (long)k;
                pix_bad++;
            }
            const bool want_last = (k + 1 == npix);
            if ((bool)o.last != want_last || o.keep != 1 || o.strb != 1) side_bad++;
        }
        long extra = 0;
        while (!s_out.empty()) { s_out.read(); extra++; }
        bool in_left = !s_in.empty();

        const bool regs_ok = used == c.exp_used && otsu == c.exp_otsu && edges == c.exp_edges;
        const bool ok = pix_bad == 0 && side_bad == 0 && extra == 0 && !in_left && regs_ok;
        frames_run++;
        total_pix_mismatch += pix_bad;
        if (!ok) {
            frames_failed++;
            std::printf("FAIL frame %3d (seq %d, %s %dx%d, mode %d):", c.frame, c.seq, c.input.c_str(),
                        img.cols, img.rows, c.mode);
            if (pix_bad) std::printf(" %ld pixel mismatches (first at r=%ld c=%ld);", pix_bad,
                                     first_bad / img.cols, first_bad % img.cols);
            if (side_bad) std::printf(" %ld TLAST/TKEEP errors;", side_bad);
            if (extra) std::printf(" %ld extra output beats;", extra);
            if (in_left) std::printf(" input not fully consumed;");
            if (!regs_ok)
                std::printf(" regs used/otsu/edges = %d/%d/%d expected %d/%d/%d;", used, otsu, edges,
                            c.exp_used, c.exp_otsu, c.exp_edges);
            std::printf("\n");
        }
    }

    std::printf("\n==== sobel_otsu testbench summary ====\n");
    std::printf("frames run     : %d\n", frames_run);
    std::printf("frames skipped : %d (max-pixels filter)\n", frames_skipped);
    std::printf("frames failed  : %d\n", frames_failed);
    std::printf("pixel mismatch : %ld\n", total_pix_mismatch);
    std::printf("RESULT         : %s\n", (frames_failed == 0 && frames_run > 0) ? "PASS" : "FAIL");
    return (frames_failed == 0 && frames_run > 0) ? 0 : 1;
}
