#ifndef HETGPU_APPLE_RUNTIME_H
#define HETGPU_APPLE_RUNTIME_H

#include <stddef.h>
#include <stdint.h>
#include "ane_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

int hetgpu_ane_gemm(int transa, int transb,
                    int m, int n, int k,
                    float alpha,
                    const void *A, int Atype, int lda,
                    const void *B, int Btype, int ldb,
                    float beta,
                    void *C, int Ctype, int ldc);

int hetgpu_apple_ane_gemm(int transa, int transb,
                          int m, int n, int k,
                          float alpha,
                          const void *A, int Atype, int lda,
                          const void *B, int Btype, int ldb,
                          float beta,
                          void *C, int Ctype, int ldc);

int hetgpu_apple_metal_gemm(int transa, int transb,
                            int m, int n, int k,
                            float alpha,
                            const void *A, int Atype, int lda,
                            const void *B, int Btype, int ldb,
                            float beta,
                            void *C, int Ctype, int ldc);

#ifdef __cplusplus
}
#endif

#endif
