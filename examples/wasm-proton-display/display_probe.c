#include "../../proton-ios/wasm/include/proton_wasm_display_imports.h"

#include <stdint.h>

enum {
    WIDTH = 320,
    HEIGHT = 180,
    STRIDE = WIDTH * 4
};

static uint8_t frame[HEIGHT * STRIDE];

static unsigned cstr_len(const char *value)
{
    unsigned len = 0;

    while (value[len] != '\0') {
        ++len;
    }
    return len;
}

static void fill_frame(unsigned tick)
{
    unsigned x;
    unsigned y;

    for (y = 0; y < HEIGHT; ++y) {
        for (x = 0; x < WIDTH; ++x) {
            unsigned offset = y * STRIDE + x * 4;
            unsigned grid = ((x + tick) / 16u) ^ ((y + tick / 2u) / 16u);
            frame[offset + 0] = (uint8_t)((x + tick) & 0xffu);
            frame[offset + 1] = (uint8_t)((y * 2u + tick) & 0xffu);
            frame[offset + 2] = (uint8_t)(grid & 1u ? 224u : 64u);
            frame[offset + 3] = 255u;
        }
    }
}

int main(void)
{
    const char *title = "Proton WebView framebuffer probe";
    unsigned tick;

    proton_wasm_set_window_title(title, cstr_len(title));
    if (proton_wasm_display_configure(WIDTH, HEIGHT, PROTON_WASM_DISPLAY_FORMAT_RGBA8) != 0) {
        return 1;
    }

    for (tick = 0; tick < 90; ++tick) {
        proton_wasm_input_event_t event;
        while (proton_wasm_poll_input_event(&event, sizeof(event)) > 0) {
            if (event.event_type == PROTON_WASM_INPUT_POINTER_DOWN) {
                tick += 8;
            }
        }
        fill_frame(tick * 3u);
        if (proton_wasm_present_rgba(frame, WIDTH, HEIGHT, STRIDE) != 0) {
            return 2;
        }
    }

    return 0;
}
