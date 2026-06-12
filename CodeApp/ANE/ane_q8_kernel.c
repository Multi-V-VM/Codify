// ane_q8_kernel.c — Fast Q8_0 quantized matrix-vector multiply
//
// Strategy (same as llama.cpp's q8_0 x q8_0 vec_dot):
//   1. Quantize the activation x into int8 blocks of 32 with one float scale
//      per block (d = absmax/127).
//   2. For each weight row, accumulate sum_b( wscale_b * xscale_b *
//      dot_int8(wq_b, xq_b) ). The int8 dot runs on NEON; weights are read
//      directly from the mmap'd GGUF tensor, never expanded to F32.
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

// Quantize a block of 32 floats to int8 with a single scale (absmax/127).
static void quantize_block(const float *x, int8_t *xq, float *scale) {
    float amax = 0.0f;
    for (int i = 0; i < Q8_BLOCK; i++) {
        float a = fabsf(x[i]);
        if (a > amax) amax = a;
    }
    float d = amax / 127.0f;
    float id = d > 0.0f ? 1.0f / d : 0.0f;
    for (int i = 0; i < Q8_BLOCK; i++) {
        float v = x[i] * id;
        xq[i] = (int8_t)lrintf(v);
    }
    *scale = d;
}

// Dot product of one Q8_0 weight row against the pre-quantized activation.
static float q8_row_dot(const uint8_t *row, const int8_t *xq,
                        const float *xscales, int nblocks) {
    float sum = 0.0f;
#if defined(__aarch64__)
    for (int b = 0; b < nblocks; b++) {
        const uint8_t *blk = row + (size_t)b * Q8_BLOCK_BYTES;
        // Unaligned loads are fine on arm64.
        int8x16_t w0 = vld1q_s8((const int8_t *)(blk + 2));
        int8x16_t w1 = vld1q_s8((const int8_t *)(blk + 18));
        int8x16_t x0 = vld1q_s8(xq + (size_t)b * Q8_BLOCK);
        int8x16_t x1 = vld1q_s8(xq + (size_t)b * Q8_BLOCK + 16);

#if defined(__ARM_FEATURE_DOTPROD)
        int32x4_t acc = vdupq_n_s32(0);
        acc = vdotq_s32(acc, w0, x0);
        acc = vdotq_s32(acc, w1, x1);
        int32_t isum = vaddvq_s32(acc);
#else
        // Widening multiply: int8 -> int16 products, accumulate in int32.
        int16x8_t p0 = vmull_s8(vget_low_s8(w0), vget_low_s8(x0));
        p0 = vmlal_s8(p0, vget_high_s8(w0), vget_high_s8(x0));
        int16x8_t p1 = vmull_s8(vget_low_s8(w1), vget_low_s8(x1));
        p1 = vmlal_s8(p1, vget_high_s8(w1), vget_high_s8(x1));
        int32_t isum = vaddvq_s32(vaddq_s32(vpaddlq_s16(p0), vpaddlq_s16(p1)));
#endif

        uint16_t wscale_bits;
        memcpy(&wscale_bits, blk, 2);
        sum += fp16_bits_to_fp32(wscale_bits) * xscales[b] * (float)isum;
    }
#else
    for (int b = 0; b < nblocks; b++) {
        const uint8_t *blk = row + (size_t)b * Q8_BLOCK_BYTES;
        const int8_t *wq = (const int8_t *)(blk + 2);
        const int8_t *xb = xq + (size_t)b * Q8_BLOCK;
        int32_t isum = 0;
        for (int i = 0; i < Q8_BLOCK; i++) {
            isum += (int32_t)wq[i] * (int32_t)xb[i];
        }
        uint16_t wscale_bits;
        memcpy(&wscale_bits, blk, 2);
        sum += fp16_bits_to_fp32(wscale_bits) * xscales[b] * (float)isum;
    }
#endif
    return sum;
}

void ane_q8_matvec(const void *w, const float *x, float *y,
                   int32_t out_dim, int32_t in_dim) {
    const int nblocks = in_dim / Q8_BLOCK;
    const size_t bytes_per_row = (size_t)nblocks * Q8_BLOCK_BYTES;
    const uint8_t *wbytes = (const uint8_t *)w;

    // Quantize the activation once.
    int8_t *xq = (int8_t *)malloc((size_t)nblocks * Q8_BLOCK);
    float *xscales = (float *)malloc((size_t)nblocks * sizeof(float));
    if (!xq || !xscales) {
        free(xq);
        free(xscales);
        memset(y, 0, (size_t)out_dim * sizeof(float));
        return;
    }
    for (int b = 0; b < nblocks; b++) {
        quantize_block(x + (size_t)b * Q8_BLOCK, xq + (size_t)b * Q8_BLOCK,
                       &xscales[b]);
    }

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
                y[r] = q8_row_dot(wbytes + (size_t)r * bytes_per_row, xq,
                                  xscales, nblocks);
            }
        });
    } else
#else
    (void)total_macs;
#endif
    {
        for (int r = 0; r < out_dim; r++) {
            y[r] = q8_row_dot(wbytes + (size_t)r * bytes_per_row, xq, xscales,
                              nblocks);
        }
    }

    free(xq);
    free(xscales);
}
