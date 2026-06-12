# iOS Porting Plan

## Milestone 0: Repo Hygiene

- Keep `proton/` as an upstream submodule.
- Put iOS glue outside the submodule unless a patch must be carried against
  Proton/Wine.
- Track generated build products under `build/` and keep them ignored.

## Milestone 1: Toolchain Skeleton

- Resolve Xcode SDK paths with `xcrun`.
- Target `arm64-apple-ios` for devices and `arm64-apple-ios-simulator` for
  simulator smoke tests.
- Prefer static libraries for the first package because iOS dynamic loading is
  constrained and code signing makes plugin-style loading harder.

## Milestone 2: Wine Core

- Start from the Proton Wine submodule, not the top-level Proton Makefile.
- Disable Linux-specific integrations first:
  - X11/Wayland display drivers
  - ALSA/PulseAudio
  - udev
  - ptrace-based debugging helpers
  - Steam Runtime assumptions
- Build the smallest server/client pair that can initialize a prefix-like
  directory and return a controlled failure for unsupported APIs.

## Milestone 3: Swift Bridge

Expose a C ABI with a stable surface:

```c
int proton_ios_initialize(const char *runtime_root, const char *prefix_root);
int proton_ios_run(const char *exe_path, int argc, const char * const *argv);
void proton_ios_shutdown(void);
```

The Swift side should own app sandbox paths, logging, and UI lifecycle. The C
side should avoid global process exits and return structured error codes.

## Milestone 4: Graphics

Treat graphics as a separate project. The first useful target is a headless or
software-rendering Wine core. After that, evaluate:

- WineD3D through an OpenGL ES or Metal-backed route.
- Vulkan through MoltenVK where viable.
- A custom D3D-to-Metal path for narrow workloads.
- Integration points with `hetgpu-ios` if compute translation becomes useful.

## Patch Policy

Patch upstream only when necessary. Keep patches small and name them by layer:

- `ios-build-*`
- `ios-runtime-*`
- `ios-graphics-*`

Each patch should explain whether it is intended to be upstreamable or a local
iOS-only carry.

