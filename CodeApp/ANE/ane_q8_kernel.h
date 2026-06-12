// ane_q8_kernel.h — Fast Q8_0 quantized matrix-vector multiply
//
// Computes y = W*x for GGUF Q8_0 weights without materializing the weight
// matrix in F32: the activation vector is quantized to int8 once, each row
// is then an int8·int8 dot product (NEON-accelerated on arm64) scaled by the
// per-block fp16 weight scales. Rows are processed in parallel with GCD.

#ifndef ANE_Q8_KERNEL_H
#define ANE_Q8_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// y = W*x. W is row-major Q8_0: out_dim rows, each row in_dim/32 blocks of
// [fp16 scale][32 x int8] (34 bytes). in_dim must be a multiple of 32.
void ane_q8_matvec(const void *w, const float *x, float *y,
                   int32_t out_dim, int32_t in_dim);

#ifdef __cplusplus
}
#endif

#endif /* ANE_Q8_KERNEL_H */
