# Wasmer iOS Runtime

Native WebAssembly runtime for iOS with WASIX p1 support, built using Wasmer and Rust.

## Features

- Native WASM execution (no JavaScript overhead)
- WASIX p1 support for enhanced POSIX compatibility
- File descriptor mapping for stdin/stdout/stderr
- Environment variable support
- Optimized for iOS (size and performance)

## Building the XCFramework

### Prerequisites

1. Install Rust and Cargo:
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

2. Install iOS targets:
   ```bash
   rustup target add aarch64-apple-ios
   rustup target add aarch64-apple-ios-sim
   rustup target add x86_64-apple-ios
   ```

### Build

Run the build script:

```bash
./build_xcframework.sh
```

This will:
1. Build the Rust library for all iOS architectures
2. Create a universal simulator binary
3. Package everything into `WasmerRuntime.xcframework`

The build may take 10-30 minutes on the first run as it downloads and compiles Wasmer dependencies.

## Integration into Code App

### 1. Copy XCFramework

```bash
cp -r WasmerRuntime.xcframework ../Resources/
```

### 2. Link in Xcode

Open `Code.xcodeproj` and:
1. Select the "Code App" target
2. Go to "General" → "Frameworks, Libraries, and Embedded Content"
3. Click "+" and add `WasmerRuntime.xcframework`
4. Set "Embed" to "Do Not Embed" (it's a static library)

Alternatively, add to `project.pbxproj` manually.

### 3. Add Swift Wrapper

The Swift wrapper is already created at:
```
CodeApp/Utilities/wasmer.swift
```

Add it to your Xcode project if not already included.

### 4. Register Command

In `CodeApp/CodeApp.swift`, add to the `setupEnvironment()` function:

```swift
replaceCommand("wasmer", "wasmer", true)
```

### 5. Build and Run

Build the Code App. The `wasmer` command should now be available in the terminal.

## Usage

Execute WASM files:

```bash
wasmer program.wasm
wasmer program.wasm arg1 arg2
wasmer --version
```

## Architecture

```
┌─────────────────────┐
│   Swift Command     │  wasmer.swift
│   @_cdecl("wasmer") │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  C ABI Bridge       │  wasmer_ios.h
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Rust Library      │  lib.rs
│  - wasmer_execute   │
│  - WASIX builder    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Wasmer Runtime     │
│  + WASIX Support    │
└─────────────────────┘
```

## WASIX p1 Support

WASIX (WebAssembly System Interface eXtended) provides enhanced POSIX compatibility:

- Extended file system operations
- Better process control
- Enhanced networking (where permitted on iOS)
- Improved threading support

The implementation in `lib.rs` uses `wasmer-wasix` crate to provide these features.

## File Structure

```
wasmer-ios/
├── Cargo.toml              # Rust package configuration
├── src/
│   └── lib.rs              # Main implementation
├── include/
│   └── wasmer_ios.h        # C header for Swift bridging
├── build_xcframework.sh    # Build script
├── README.md               # This file
└── WasmerRuntime.xcframework  # Generated output (after build)
```

## Troubleshooting

### Build fails with linker errors

Make sure you have Xcode Command Line Tools installed:
```bash
xcode-select --install
```

### "Target not found" errors

Ensure all iOS targets are installed:
```bash
rustup target list --installed
```

### Large binary size

The framework is optimized for size in `Cargo.toml`:
- `opt-level = "z"` - Maximum size optimization
- `lto = true` - Link-time optimization
- `strip = true` - Strip debug symbols

### Runtime errors

Check that:
1. The XCFramework is properly linked in Xcode
2. The `wasmer.swift` file is included in the build
3. The command is registered in `setupEnvironment()`

## License

This wrapper is part of the Code App project. Wasmer is licensed under the MIT License.
