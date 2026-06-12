#include "proton_ios.h"

#include <stdio.h>
#include <string.h>

static int g_initialized;
static char g_last_error[256];
static char g_runtime_root[1024];
static char g_prefix_root[1024];

static int set_error(proton_ios_status_t status, const char *message)
{
    if (message == NULL) {
        message = "unknown error";
    }

    snprintf(g_last_error, sizeof(g_last_error), "%s", message);
    return (int)status;
}

int proton_ios_initialize(const char *runtime_root, const char *prefix_root)
{
    if (runtime_root == NULL || runtime_root[0] == '\0') {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "runtime_root is required");
    }

    if (prefix_root == NULL || prefix_root[0] == '\0') {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "prefix_root is required");
    }

    snprintf(g_runtime_root, sizeof(g_runtime_root), "%s", runtime_root);
    snprintf(g_prefix_root, sizeof(g_prefix_root), "%s", prefix_root);
    g_initialized = 1;
    g_last_error[0] = '\0';
    return PROTON_IOS_OK;
}

int proton_ios_run(const char *exe_path, int argc, const char * const *argv)
{
    (void)argc;
    (void)argv;

    if (!g_initialized) {
        return set_error(PROTON_IOS_ERROR_NOT_INITIALIZED, "proton_ios_initialize must be called first");
    }

    if (exe_path == NULL || exe_path[0] == '\0') {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "exe_path is required");
    }

    return set_error(PROTON_IOS_ERROR_UNSUPPORTED, "Wine execution is not wired into the iOS bridge yet");
}

void proton_ios_shutdown(void)
{
    g_initialized = 0;
    g_runtime_root[0] = '\0';
    g_prefix_root[0] = '\0';
    g_last_error[0] = '\0';
}

const char *proton_ios_last_error(void)
{
    if (g_last_error[0] == '\0') {
        return "";
    }

    return g_last_error;
}

