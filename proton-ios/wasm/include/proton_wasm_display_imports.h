#ifndef PROTON_WASM_DISPLAY_IMPORTS_H
#define PROTON_WASM_DISPLAY_IMPORTS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PROTON_WASM_HOST_IMPORT
#if defined(__wasm__)
#define PROTON_WASM_HOST_IMPORT(module_name, import_name_value) \
    __attribute__((import_module(module_name), import_name(import_name_value)))
#else
#define PROTON_WASM_HOST_IMPORT(module_name, import_name_value)
#endif
#endif

#define PROTON_WASM_DISPLAY_FORMAT_RGBA8 1u

typedef enum proton_wasm_input_event_type {
    PROTON_WASM_INPUT_NONE = 0,
    PROTON_WASM_INPUT_POINTER_DOWN = 1,
    PROTON_WASM_INPUT_POINTER_UP = 2,
    PROTON_WASM_INPUT_POINTER_MOVE = 3,
    PROTON_WASM_INPUT_WHEEL = 4,
    PROTON_WASM_INPUT_KEY_DOWN = 5,
    PROTON_WASM_INPUT_KEY_UP = 6
} proton_wasm_input_event_type_t;

typedef struct proton_wasm_input_event {
    uint32_t event_type;
    uint32_t code;
    int32_t x;
    int32_t y;
    int32_t value;
    uint32_t modifiers;
} proton_wasm_input_event_t;

PROTON_WASM_HOST_IMPORT("env", "proton_wasm_display_configure")
int proton_wasm_display_configure(uint32_t width, uint32_t height, uint32_t format);

PROTON_WASM_HOST_IMPORT("env", "proton_wasm_present_rgba")
int proton_wasm_present_rgba(const void *rgba, uint32_t width, uint32_t height, uint32_t stride);

PROTON_WASM_HOST_IMPORT("env", "proton_wasm_set_window_title")
int proton_wasm_set_window_title(const char *title, uint32_t title_len);

PROTON_WASM_HOST_IMPORT("env", "proton_wasm_poll_input_event")
int proton_wasm_poll_input_event(proton_wasm_input_event_t *event, uint32_t event_size);

#ifdef __cplusplus
}
#endif

#endif
