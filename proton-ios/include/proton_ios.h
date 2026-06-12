#ifndef PROTON_IOS_H
#define PROTON_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum proton_ios_status {
    PROTON_IOS_OK = 0,
    PROTON_IOS_ERROR_NOT_INITIALIZED = 1,
    PROTON_IOS_ERROR_INVALID_ARGUMENT = 2,
    PROTON_IOS_ERROR_UNSUPPORTED = 3
} proton_ios_status_t;

int proton_ios_initialize(const char *runtime_root, const char *prefix_root);
int proton_ios_run(const char *exe_path, int argc, const char * const *argv);
void proton_ios_shutdown(void);
const char *proton_ios_last_error(void);

#ifdef __cplusplus
}
#endif

#endif

