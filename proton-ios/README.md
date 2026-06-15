# Proton iOS Port

This directory is an iOS port overlay for Valve's Proton source tree. The
upstream checkout lives in `proton/` and should stay as close to upstream as
possible; iOS-specific build glue, notes, and experiments live beside it here.

## Current Scope

The first milestone is not "Steam Proton on iOS" as a drop-in runtime. Proton
is built around Linux, Wine, Steam Runtime containers, ELF loaders, Unix process
semantics, and GPU stacks such as Vulkan/DXVK. iOS is Darwin-based, app
sandboxed, code-signing constrained, and does not allow the same process/JIT
model for App Store builds.

The practical first milestone is:

1. Keep the Valve Proton submodule reproducible.
2. Build a native iOS Wine/Proton core for `arm64-apple-ios` as far as the
   platform allows.
3. Package the resulting static or dynamic pieces as an `XCFramework`.
4. Provide a small C ABI that CodifyOne can call from Swift.
5. Run the WASI Wine loader through the bundled Wasmer runtime, with CPU work
   staying inside WASM and GPU work crossing the CUDA/cuBLAS-style hetGPU host
   import boundary.
6. Stub or replace Linux/Steam-only services behind narrow interfaces.

## Repository Layout

- `proton/` - Valve Proton submodule.
- `include/` and `src/` - small C ABI bridge for Swift integration.
- `scripts/` - iOS bootstrap and build helpers.
- `docs/` - porting notes and decision records.
- `build/` - generated local build output. This path is ignored by Git.

## Quick Start

Run the environment check first:

```bash
./scripts/check_ios_port_env.sh
```

Then initialize the Proton submodule set when network access is available:

```bash
git -C proton submodule update --init --recursive
```

The iOS build is intentionally split into small stages. Do not expect the
upstream `proton/Makefile` to work for iOS; it targets the Steam Runtime
container flow.

Once full Xcode is selected and iOS SDKs are available, the bridge skeleton can
be packaged with:

```bash
./scripts/build_bridge_xcframework.sh
```

At runtime, initialize the bridge with the directory containing the Wine WASM
build and a writable prefix directory, then enable hetGPU when GPU imports
should be routed to the Apple runtime:

```c
proton_ios_initialize(runtime_root, prefix_root);
proton_ios_configure_gpu(PROTON_IOS_GPU_HETGPU, "metal");
proton_ios_run("game.exe", argc, argv);
```

## Porting Strategy

The port is treated as three layers:

- **Build layer**: cross-compilers, SDK paths, CMake/Meson/autoconf toolchain
  files, and Xcode packaging.
- **Runtime layer**: filesystem, process, socket, signal, thread, and sandbox
  compatibility for Wine/Proton on Darwin/iOS.
- **Graphics layer**: GPU calls cross the WASM boundary as host imports and are
  routed to hetGPU Apple Metal/ANE entry points. DXVK/Vulkan pieces still need
  a narrower translation strategy before they become general-purpose.

## Known Hard Stops

- 32-bit Windows support is out of scope on modern iOS.
- Unrestricted JIT and executable writable memory are not App Store friendly.
- Spawning arbitrary helper processes is limited by the iOS sandbox.
- Steam client integration, anti-cheat services, OpenXR, and many media codecs
  need platform-specific replacements or stubs.
