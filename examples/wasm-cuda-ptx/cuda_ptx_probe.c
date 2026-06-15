// Minimal CUDA Driver PTX WebAssembly probe for CodifyOne.
//
// This is intentionally freestanding: it does not depend on a WASI libc, only
// on fd_write for logging and explicit CUDA Driver imports supplied by host.

typedef __SIZE_TYPE__ size_t;

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

__attribute__((import_module("env"), import_name("cuInit")))
extern int cuInit(unsigned int flags);

__attribute__((import_module("env"), import_name("cuDeviceGetCount")))
extern int cuDeviceGetCount(int *count);

__attribute__((import_module("env"), import_name("cuDeviceGet")))
extern int cuDeviceGet(int *device, int ordinal);

__attribute__((import_module("env"), import_name("cuCtxCreate_v2")))
extern int cuCtxCreate_v2(void **context, unsigned int flags, int device);

__attribute__((import_module("env"), import_name("cuCtxSynchronize")))
extern int cuCtxSynchronize(void);

__attribute__((import_module("env"), import_name("cuMemAlloc_v2")))
extern int cuMemAlloc_v2(void **device_ptr, size_t size);

__attribute__((import_module("env"), import_name("cuMemFree_v2")))
extern int cuMemFree_v2(void *device_ptr);

__attribute__((import_module("env"), import_name("cuMemcpyHtoD_v2")))
extern int cuMemcpyHtoD_v2(void *dst_device, const void *src_host, size_t size);

__attribute__((import_module("env"), import_name("cuMemcpyDtoH_v2")))
extern int cuMemcpyDtoH_v2(void *dst_host, const void *src_device, size_t size);

__attribute__((import_module("env"), import_name("cuModuleLoadData")))
extern int cuModuleLoadData(void **module, const void *image);

__attribute__((import_module("env"), import_name("cuModuleUnload")))
extern int cuModuleUnload(void *module);

__attribute__((import_module("env"), import_name("cuModuleGetFunction")))
extern int cuModuleGetFunction(void **function, void *module, const char *name);

__attribute__((import_module("env"), import_name("cuLaunchKernel")))
extern int cuLaunchKernel(
    void *function,
    unsigned int grid_dim_x,
    unsigned int grid_dim_y,
    unsigned int grid_dim_z,
    unsigned int block_dim_x,
    unsigned int block_dim_y,
    unsigned int block_dim_z,
    unsigned int shared_mem_bytes,
    void *stream,
    void **kernel_params,
    void **extra);

enum {
    CUDA_SUCCESS = 0,
    CUDA_ERROR_NOT_SUPPORTED = 801,
};

static const char kVectorAddPtx[] =
    ".version 7.0\n"
    ".target sm_50\n"
    ".address_size 64\n"
    ".visible .entry vector_add(\n"
    "    .param .u64 vector_add_param_0,\n"
    "    .param .u64 vector_add_param_1,\n"
    "    .param .u64 vector_add_param_2,\n"
    "    .param .u32 vector_add_param_3\n"
    ")\n"
    "{\n"
    "    .reg .pred %p;\n"
    "    .reg .b32 %r<5>;\n"
    "    .reg .b64 %rd<10>;\n"
    "    .reg .f32 %f<4>;\n"
    "    ld.param.u64 %rd1, [vector_add_param_0];\n"
    "    ld.param.u64 %rd2, [vector_add_param_1];\n"
    "    ld.param.u64 %rd3, [vector_add_param_2];\n"
    "    ld.param.u32 %r1, [vector_add_param_3];\n"
    "    mov.u32 %r2, %tid.x;\n"
    "    mov.u32 %r3, %ctaid.x;\n"
    "    mov.u32 %r4, %ntid.x;\n"
    "    mad.lo.s32 %r2, %r3, %r4, %r2;\n"
    "    setp.ge.s32 %p, %r2, %r1;\n"
    "    @%p bra DONE;\n"
    "    mul.wide.s32 %rd4, %r2, 4;\n"
    "    add.s64 %rd5, %rd1, %rd4;\n"
    "    add.s64 %rd6, %rd2, %rd4;\n"
    "    add.s64 %rd7, %rd3, %rd4;\n"
    "    ld.global.f32 %f1, [%rd5];\n"
    "    ld.global.f32 %f2, [%rd6];\n"
    "    add.f32 %f3, %f1, %f2;\n"
    "    st.global.f32 [%rd7], %f3;\n"
    "DONE:\n"
    "    ret;\n"
    "}\n";

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

static void cleanup(void *module, void *a_dev, void *b_dev, void *c_dev) {
    if (module != 0) {
        (void)cuModuleUnload(module);
    }
    if (a_dev != 0) {
        (void)cuMemFree_v2(a_dev);
    }
    if (b_dev != 0) {
        (void)cuMemFree_v2(b_dev);
    }
    if (c_dev != 0) {
        (void)cuMemFree_v2(c_dev);
    }
}

int main(void) {
    write_str("codifyone cuda ptx wasm probe\n");

    int rc = cuInit(0);
    write_status("cuInit", rc);
    if (rc != CUDA_SUCCESS) {
        return 10;
    }

    int count = 0;
    rc = cuDeviceGetCount(&count);
    write_status("cuDeviceGetCount", rc);
    if (rc != CUDA_SUCCESS || count <= 0) {
        return 11;
    }

    int device = 0;
    void *context = 0;
    rc = cuDeviceGet(&device, 0);
    write_status("cuDeviceGet", rc);
    if (rc != CUDA_SUCCESS) {
        return 12;
    }
    rc = cuCtxCreate_v2(&context, 0, device);
    write_status("cuCtxCreate_v2", rc);
    if (rc != CUDA_SUCCESS) {
        return 13;
    }

    const int n = 4;
    float a[4] = {1.0f, 2.0f, 3.0f, 4.0f};
    float b[4] = {10.0f, 20.0f, 30.0f, 40.0f};
    float c[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    void *a_dev = 0;
    void *b_dev = 0;
    void *c_dev = 0;
    void *module = 0;
    void *function = 0;

    rc = cuMemAlloc_v2(&a_dev, sizeof(a));
    write_status("cuMemAlloc(A)", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 14;
    }
    rc = cuMemAlloc_v2(&b_dev, sizeof(b));
    write_status("cuMemAlloc(B)", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 15;
    }
    rc = cuMemAlloc_v2(&c_dev, sizeof(c));
    write_status("cuMemAlloc(C)", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 16;
    }
    rc = cuMemcpyHtoD_v2(a_dev, a, sizeof(a));
    write_status("cuMemcpyHtoD(A)", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 17;
    }
    rc = cuMemcpyHtoD_v2(b_dev, b, sizeof(b));
    write_status("cuMemcpyHtoD(B)", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 18;
    }

    rc = cuModuleLoadData(&module, kVectorAddPtx);
    write_status("cuModuleLoadData(PTX)", rc);
    if (rc == CUDA_ERROR_NOT_SUPPORTED) {
        write_str("SKIP: no linked CUDA PTX backend\n");
        cleanup(module, a_dev, b_dev, c_dev);
        return 0;
    }
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 19;
    }

    rc = cuModuleGetFunction(&function, module, "vector_add");
    write_status("cuModuleGetFunction(vector_add)", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 20;
    }

    void *args[] = {&a_dev, &b_dev, &c_dev, (void *)&n};
    rc = cuLaunchKernel(function, 1, 1, 1, 32, 1, 1, 0, 0, args, 0);
    write_status("cuLaunchKernel(vector_add)", rc);
    if (rc == CUDA_ERROR_NOT_SUPPORTED) {
        write_str("SKIP: no linked CUDA PTX launch backend\n");
        cleanup(module, a_dev, b_dev, c_dev);
        return 0;
    }
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 21;
    }

    rc = cuCtxSynchronize();
    write_status("cuCtxSynchronize", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 22;
    }

    rc = cuMemcpyDtoH_v2(c, c_dev, sizeof(c));
    write_status("cuMemcpyDtoH(C)", rc);
    if (rc != CUDA_SUCCESS) {
        cleanup(module, a_dev, b_dev, c_dev);
        return 23;
    }

    cleanup(module, a_dev, b_dev, c_dev);

    if (!near_f32(c[0], 11.0f) || !near_f32(c[1], 22.0f) ||
        !near_f32(c[2], 33.0f) || !near_f32(c[3], 44.0f)) {
        write_str("FAIL: expected [11, 22, 33, 44]\n");
        return 24;
    }

    write_str("PASS: CUDA Driver PTX WASM path computed vector add\n");
    return 0;
}
