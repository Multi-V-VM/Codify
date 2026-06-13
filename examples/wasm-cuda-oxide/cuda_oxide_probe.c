// Minimal CUDA/cuBLAS WebAssembly probe for CodifyOne.
//
// This is intentionally freestanding: it does not depend on a WASI libc, only
// on fd_write for logging and explicit CUDA/cuBLAS imports supplied by the host.

typedef __SIZE_TYPE__ size_t;
typedef unsigned int uint32_t;

struct wasi_ciovec {
    const char *buf;
    size_t buf_len;
};

__attribute__((import_module("wasi_snapshot_preview1"), import_name("fd_write")))
extern int wasi_fd_write(
    int fd,
    const struct wasi_ciovec *iovs,
    size_t iovs_len,
    size_t *nwritten);

__attribute__((import_module("env"), import_name("cudaMalloc")))
extern int cudaMalloc(void **dev_ptr, size_t size);

__attribute__((import_module("env"), import_name("cudaFree")))
extern int cudaFree(void *dev_ptr);

__attribute__((import_module("env"), import_name("cudaMemcpy")))
extern int cudaMemcpy(void *dst, const void *src, size_t size, int kind);

__attribute__((import_module("env"), import_name("cudaDeviceSynchronize")))
extern int cudaDeviceSynchronize(void);

__attribute__((import_module("env"), import_name("cublasCreate_v2")))
extern int cublasCreate_v2(void **handle);

__attribute__((import_module("env"), import_name("cublasDestroy_v2")))
extern int cublasDestroy_v2(void *handle);

__attribute__((import_module("env"), import_name("cublasSgemm_v2")))
extern int cublasSgemm_v2(
    void *handle,
    int transa,
    int transb,
    int m,
    int n,
    int k,
    const float *alpha,
    const float *a,
    int lda,
    const float *b,
    int ldb,
    const float *beta,
    float *c,
    int ldc);

enum {
    CUDA_MEMCPY_HOST_TO_DEVICE = 1,
    CUDA_MEMCPY_DEVICE_TO_HOST = 2,
    CUBLAS_OP_N = 0,
};

static size_t str_len(const char *s) {
    size_t n = 0;
    while (s[n] != 0) {
        ++n;
    }
    return n;
}

static void write_str(const char *s) {
    struct wasi_ciovec iov = {s, str_len(s)};
    size_t written = 0;
    (void)wasi_fd_write(1, &iov, 1, &written);
}

static void write_i32(int value) {
    char buf[16];
    size_t pos = 0;
    unsigned int n;

    if (value < 0) {
        buf[pos++] = '-';
        n = (unsigned int)(0 - value);
    } else {
        n = (unsigned int)value;
    }

    char digits[10];
    size_t count = 0;
    do {
        digits[count++] = (char)('0' + (n % 10));
        n /= 10;
    } while (n != 0);

    while (count != 0) {
        buf[pos++] = digits[--count];
    }
    buf[pos] = 0;
    write_str(buf);
}

static void write_status(const char *label, int rc) {
    write_str(label);
    write_str(" -> ");
    write_i32(rc);
    write_str("\n");
}

static int near_f32(float a, float b) {
    float d = a - b;
    if (d < 0.0f) {
        d = -d;
    }
    return d < 0.001f;
}

static void cleanup(void *handle, void *a_dev, void *b_dev, void *c_dev) {
    if (handle != 0) {
        (void)cublasDestroy_v2(handle);
    }
    if (a_dev != 0) {
        (void)cudaFree(a_dev);
    }
    if (b_dev != 0) {
        (void)cudaFree(b_dev);
    }
    if (c_dev != 0) {
        (void)cudaFree(c_dev);
    }
}

int main(void) {
    write_str("codifyone cuda oxide wasm probe\n");
    write_str("2x2 SGEMM through CUDA/cuBLAS imports\n");

    // Column-major matrices for cuBLAS:
    // A = [[1, 2], [3, 4]], B = [[5, 6], [7, 8]]
    const float host_a[4] = {1.0f, 3.0f, 2.0f, 4.0f};
    const float host_b[4] = {5.0f, 7.0f, 6.0f, 8.0f};
    const float expected[4] = {19.0f, 43.0f, 22.0f, 50.0f};
    float host_c[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    const float alpha = 1.0f;
    const float beta = 0.0f;

    void *handle = 0;
    void *a_dev = 0;
    void *b_dev = 0;
    void *c_dev = 0;

    int rc = cudaMalloc(&a_dev, sizeof(host_a));
    write_status("cudaMalloc(A)", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 10;
    }

    rc = cudaMalloc(&b_dev, sizeof(host_b));
    write_status("cudaMalloc(B)", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 11;
    }

    rc = cudaMalloc(&c_dev, sizeof(host_c));
    write_status("cudaMalloc(C)", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 12;
    }

    rc = cudaMemcpy(a_dev, host_a, sizeof(host_a), CUDA_MEMCPY_HOST_TO_DEVICE);
    write_status("cudaMemcpy(A H2D)", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 13;
    }

    rc = cudaMemcpy(b_dev, host_b, sizeof(host_b), CUDA_MEMCPY_HOST_TO_DEVICE);
    write_status("cudaMemcpy(B H2D)", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 14;
    }

    rc = cublasCreate_v2(&handle);
    write_status("cublasCreate_v2", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 15;
    }

    rc = cublasSgemm_v2(
        handle,
        CUBLAS_OP_N,
        CUBLAS_OP_N,
        2,
        2,
        2,
        &alpha,
        (const float *)a_dev,
        2,
        (const float *)b_dev,
        2,
        &beta,
        (float *)c_dev,
        2);
    write_status("cublasSgemm_v2", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 16;
    }

    rc = cudaDeviceSynchronize();
    write_status("cudaDeviceSynchronize", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 17;
    }

    rc = cudaMemcpy(host_c, c_dev, sizeof(host_c), CUDA_MEMCPY_DEVICE_TO_HOST);
    write_status("cudaMemcpy(C D2H)", rc);
    if (rc != 0) {
        cleanup(handle, a_dev, b_dev, c_dev);
        return 18;
    }

    write_str("C = [");
    write_i32((int)host_c[0]);
    write_str(", ");
    write_i32((int)host_c[2]);
    write_str("; ");
    write_i32((int)host_c[1]);
    write_str(", ");
    write_i32((int)host_c[3]);
    write_str("]\n");

    int ok = near_f32(host_c[0], expected[0])
        && near_f32(host_c[1], expected[1])
        && near_f32(host_c[2], expected[2])
        && near_f32(host_c[3], expected[3]);

    cleanup(handle, a_dev, b_dev, c_dev);

    if (!ok) {
        write_str("FAIL: expected [19, 22; 43, 50]\n");
        return 20;
    }

    write_str("PASS: CUDA/cuBLAS WASM path computed the expected SGEMM\n");
    return 0;
}
