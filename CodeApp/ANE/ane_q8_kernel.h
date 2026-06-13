// ane_q8_kernel.h — Fast Q8_0 quantized matrix-vector multiply
//
// Computes y = W*x for GGUF Q8_0 weights without materializing the weight
// matrix in F32. The activation vector stays FP32; each row accumulates
// scale * dot(int8_weight_block, fp32_activation_block). Rows are processed
// in parallel with GCD.

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
