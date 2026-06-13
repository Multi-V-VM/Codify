// ane_q8_kernel.c — Correct Q8_0 quantized matrix-vector multiply
//
// Strategy:
//   1. Keep the activation vector in FP32. Do not requantize it.
//   2. For each weight row, accumulate sum_b( wscale_b * dot(wq_b, x_b) ).
//      This matches GGUF Q8_0 semantics and avoids compounding activation
//      quantization error across transformer layers.
//   3. Rows are split across cores with dispatch_apply.

#include "ane_q8_kernel.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#define Q8_BLOCK 32
#define Q8_BLOCK_BYTES 34 /* 2-byte fp16 scale + 32 int8 */

static inline float fp16_bits_to_fp32(uint16_t h) {
#if defined(__aarch64__)
    __fp16 f;
    memcpy(&f, &h, sizeof(f));
    return (float)f;
#else
    uint32_t sign = (uint32_t)(h & 0x8000) << 16;
    uint32_t exp = (h >> 10) & 0x1F;
    uint32_t mant = h & 0x3FF;
    uint32_t bits;
    if (exp == 0) {
        if (mant == 0) {
            bits = sign;
        } else {
            int e = -1;
            do {
                mant <<= 1;
                e++;
            } while (!(mant & 0x400));
            mant &= 0x3FF;
            bits = sign | (uint32_t)(127 - 15 - e) << 23 | mant << 13;
        }
    } else if (exp == 31) {
        bits = sign | 0x7F800000u | mant << 13;
    } else {
        bits = sign | (exp - 15 + 127) << 23 | mant << 13;
    }
    float f;
    memcpy(&f, &bits, sizeof(f));
    return f;
#endif
}

// Dot product of one Q8_0 weight row against an FP32 activation vector.
static float q8_row_dot_f32(const uint8_t *row, const float *x, int nblocks) {
    float sum = 0.0f;
    for (int b = 0; b < nblocks; b++) {
        const uint8_t *blk = row + (size_t)b * Q8_BLOCK_BYTES;
        const int8_t *wq = (const int8_t *)(blk + 2);
        const float *xb = x + (size_t)b * Q8_BLOCK;
        uint16_t wscale_bits;
        memcpy(&wscale_bits, blk, 2);
        const float scale = fp16_bits_to_fp32(wscale_bits);

#if defined(__aarch64__)
        float block_sum = 0.0f;
        for (int i = 0; i < Q8_BLOCK; i += 4) {
            float32x4_t xv = vld1q_f32(xb + i);
            float32x4_t wv = {
                (float)wq[i],
                (float)wq[i + 1],
                (float)wq[i + 2],
                (float)wq[i + 3]
            };
            block_sum += vaddvq_f32(vmulq_f32(xv, wv));
        }
        sum += scale * block_sum;
#else
        float block_sum = 0.0f;
        for (int i = 0; i < Q8_BLOCK; i++) {
            block_sum += (float)wq[i] * xb[i];
        }
        sum += scale * block_sum;
#endif
    }
    return sum;
}

void ane_q8_matvec(const void *w, const float *x, float *y,
                   int32_t out_dim, int32_t in_dim) {
    const int nblocks = in_dim / Q8_BLOCK;
    const size_t bytes_per_row = (size_t)nblocks * Q8_BLOCK_BYTES;
    const uint8_t *wbytes = (const uint8_t *)w;

    // Parallelize across rows only when there is enough work to amortize the
    // dispatch overhead (small projections like [dim -> n_groups] stay serial).
    const long total_macs = (long)out_dim * in_dim;
#if defined(__APPLE__)
    if (total_macs >= (256 * 1024) && out_dim >= 64) {
        const int rows_per_chunk = 64;
        const size_t nchunks =
            ((size_t)out_dim + rows_per_chunk - 1) / rows_per_chunk;
        dispatch_apply(nchunks, DISPATCH_APPLY_AUTO, ^(size_t c) {
            const int start = (int)(c * rows_per_chunk);
            const int end = start + rows_per_chunk < out_dim
                                ? start + rows_per_chunk
                                : out_dim;
            for (int r = start; r < end; r++) {
                y[r] = q8_row_dot_f32(wbytes + (size_t)r * bytes_per_row, x,
                                      nblocks);
            }
        });
    } else
#else
    (void)total_macs;
#endif
    {
        for (int r = 0; r < out_dim; r++) {
            y[r] = q8_row_dot_f32(wbytes + (size_t)r * bytes_per_row, x,
                                  nblocks);
        }
    }

}
