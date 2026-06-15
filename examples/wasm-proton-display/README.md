# Proton WebView Display Probe

This probe exercises the Proton display transport:

```bash
./examples/wasm-proton-display/build.sh Resources/NodeJS/proton_display_probe.wasm
wasm Resources/NodeJS/proton_display_probe.wasm
```

The module imports:

- `proton_wasm_display_configure`
- `proton_wasm_present_rgba`
- `proton_wasm_poll_input_event`
- `proton_wasm_set_window_title`

It renders RGBA frames through the Wasmer host import bridge, then Swift forwards
them into the terminal WebView canvas.
